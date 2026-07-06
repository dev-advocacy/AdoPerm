# =============================================================================
# ado.http.ps1
# REST API implementation for Azure DevOps Server (on-premises).
# Dot-sourced at script level when the platform is detected as Server.
# Overrides the CLI-based functions from ado.client.ps1,
# ado.permissions.ps1, ado.membership.ps1, and ado.policies.ps1.
# Compatible with Windows PowerShell 5.1 and PowerShell 7+.
# =============================================================================

# Ensure TLS 1.2 is enabled for HTTPS connections.
try {
    [System.Net.ServicePointManager]::SecurityProtocol =
        [System.Net.ServicePointManager]::SecurityProtocol -bor
        [System.Net.SecurityProtocolType]::Tls12
} catch { }

# ---------------------------------------------------------------------------
# Internal HTTP helpers
# ---------------------------------------------------------------------------

function New-AdoBasicAuthHeader {
    <#
    .SYNOPSIS
    Builds an HTTP Basic Authorization header.
    Priority:
    1) PAT from $env:AZURE_DEVOPS_EXT_PAT (encoded as :PAT)
    2) Basic username/password from script variables
    Returns an empty hashtable when no explicit Basic auth is configured.
    #>
    $pat = $env:AZURE_DEVOPS_EXT_PAT
    if (-not [string]::IsNullOrWhiteSpace($pat)) {
        $encoded = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(':' + $pat))
        return @{ Authorization = ('Basic {0}' -f $encoded) }
    }

    if (-not [string]::IsNullOrWhiteSpace($Script:AdoBasicAuthUsername) -and
        -not [string]::IsNullOrWhiteSpace($Script:AdoBasicAuthPassword)) {
        $pair = '{0}:{1}' -f $Script:AdoBasicAuthUsername, $Script:AdoBasicAuthPassword
        $encoded = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
        return @{ Authorization = ('Basic {0}' -f $encoded) }
    }

    return @{}
}

function New-AdoWebRequestAuthOptions {
    <#
    .SYNOPSIS
    Builds auth options for Invoke-WebRequest.
    Uses explicit Basic header when configured; otherwise uses default
    Windows credentials to avoid interactive prompts on Server/TFS.
    #>
    $headers = New-AdoBasicAuthHeader
    $options = @{}

    if ($headers.Count -gt 0) {
        $options['Headers'] = $headers
    }
    else {
        $options['UseDefaultCredentials'] = $true
    }

    return $options
}

function Test-HasExplicitBasicAuth {
    return (
        -not [string]::IsNullOrWhiteSpace($Script:AdoBasicAuthUsername) -and
        -not [string]::IsNullOrWhiteSpace($Script:AdoBasicAuthPassword)
    )
}

function Invoke-AdoWebRequestGet {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri
    )

    $authOptions = New-AdoWebRequestAuthOptions
    try {
        return Invoke-WebRequest -Uri $Uri @authOptions -Method Get -UseBasicParsing -ErrorAction Stop
    }
    catch {
        $statusCode = Get-HttpStatusCodeFromError -ErrorRecord $_
        $canFallbackToIntegrated = (Test-HasExplicitBasicAuth) -and ($statusCode -eq 401)
        if (-not $canFallbackToIntegrated) {
            throw
        }

        Write-Log -Level 'Warn' -Message ('Basic authentication returned 401 for [{0}]. Retrying once with Windows integrated credentials.' -f $Uri)
        return Invoke-WebRequest -Uri $Uri -UseDefaultCredentials -Method Get -UseBasicParsing -ErrorAction Stop
    }
}

function Invoke-AdoRestGet {
    <#
    .SYNOPSIS
    Performs an authenticated GET request against the Azure DevOps REST API.
    Supports retry with exponential backoff when -EnableRetry is active.
    Returns the parsed JSON response object.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri
    )

    Assert-NotCancelled

    $attempt = 1

    while ($true) {
        Write-Log -Level 'Debug' -Message ('REST GET: {0}' -f $Uri)
        try {
            $raw = Invoke-AdoWebRequestGet -Uri $Uri
            return ($raw.Content | ConvertFrom-Json)
        }
        catch {
            $statusCode = $null
            if ($_.Exception.Response) {
                try { $statusCode = [int]$_.Exception.Response.StatusCode } catch { }
            }

            $looksTransient = ($statusCode -in @(429, 502, 503, 504)) -or
                ($_.Exception.Message -match '(?i)timeout|timed out|connection reset|temporarily unavailable|try again|throttl')

            $canRetry = $EnableRetry.IsPresent -and $looksTransient -and $attempt -lt $RetryMaxAttempts
            if (-not $canRetry) {
                throw ('REST GET failed: {0}' -f $_.Exception.Message)
            }

            $backoffMs = [Math]::Min(30000, $RetryBaseDelayMs * [Math]::Pow(2, ($attempt - 1)))
            $jitterMs  = Get-Random -Minimum 0 -Maximum 250
            $delayMs   = [int]$backoffMs + $jitterMs
            Write-Log -Level 'Warn' -Message ('Transient REST error. Retry {0}/{1} in {2} ms.' -f ($attempt + 1), $RetryMaxAttempts, $delayMs)
            Start-Sleep -Milliseconds $delayMs
            $attempt++
            Assert-NotCancelled
        }
    }
}

function Get-AdoRestPagedResults {
    <#
    .SYNOPSIS
    Follows x-ms-continuationtoken pagination and returns all items from a
    paged Azure DevOps REST endpoint.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseUri,

        [Parameter(Mandatory = $false)]
        [string]$ValueProperty = 'value'
    )

    $allItems = New-Object System.Collections.Generic.List[object]
    $continuationToken = $null

    do {
        Assert-NotCancelled

        $uri = $BaseUri
        if (-not [string]::IsNullOrWhiteSpace($continuationToken)) {
            $sep = if ($uri -match '\?') { '&' } else { '?' }
            $uri = '{0}{1}continuationToken={2}' -f $uri, $sep, [Uri]::EscapeDataString($continuationToken)
        }

        $attempt     = 1
        $rawResponse = $null

        while ($true) {
            Write-Log -Level 'Debug' -Message ('REST GET (paged): {0}' -f $uri)
            try {
                $rawResponse = Invoke-AdoWebRequestGet -Uri $uri
                break
            }
            catch {
                $statusCode = $null
                if ($_.Exception.Response) {
                    try { $statusCode = [int]$_.Exception.Response.StatusCode } catch { }
                }

                $looksTransient = ($statusCode -in @(429, 502, 503, 504)) -or
                    ($_.Exception.Message -match '(?i)timeout|timed out|connection reset|temporarily unavailable|try again|throttl')

                $canRetry = $EnableRetry.IsPresent -and $looksTransient -and $attempt -lt $RetryMaxAttempts
                if (-not $canRetry) {
                    throw ('REST GET (paged) failed: {0}' -f $_.Exception.Message)
                }

                $backoffMs = [Math]::Min(30000, $RetryBaseDelayMs * [Math]::Pow(2, ($attempt - 1)))
                $jitterMs  = Get-Random -Minimum 0 -Maximum 250
                $delayMs   = [int]$backoffMs + $jitterMs
                Write-Log -Level 'Warn' -Message ('Transient REST error (paged). Retry {0}/{1} in {2} ms.' -f ($attempt + 1), $RetryMaxAttempts, $delayMs)
                Start-Sleep -Milliseconds $delayMs
                $attempt++
                Assert-NotCancelled
            }
        }

        $parsed = $rawResponse.Content | ConvertFrom-Json

        $items = @()
        if ($null -ne $parsed.$ValueProperty) {
            $items = @($parsed.$ValueProperty)
        }
        elseif ($parsed -is [array]) {
            $items = @($parsed)
        }
        foreach ($item in $items) { [void]$allItems.Add($item) }

        # Extract continuation token (case-insensitive header lookup for PS5.1 compatibility).
        $continuationToken = $null
        try {
            if ($rawResponse.Headers) {
                $tokenKey = @($rawResponse.Headers.Keys) |
                    Where-Object { $_ -ieq 'x-ms-continuationtoken' } |
                    Select-Object -First 1
                if ($tokenKey) { $continuationToken = $rawResponse.Headers[$tokenKey] }
            }
        } catch { }

    } while (-not [string]::IsNullOrWhiteSpace($continuationToken))

    return $allItems.ToArray()
}

function Get-HttpStatusCodeFromError {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    if (-not $ErrorRecord -or -not $ErrorRecord.Exception -or -not $ErrorRecord.Exception.Response) {
        return $null
    }

    try {
        return [int]$ErrorRecord.Exception.Response.StatusCode
    }
    catch {
        return $null
    }
}

function Test-AdoEndpointStatus {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri
    )

    try {
        $authOptions = New-AdoWebRequestAuthOptions
        [void](Invoke-WebRequest -Uri $Uri @authOptions -Method Get -UseBasicParsing -ErrorAction Stop)
        return '200 OK'
    }
    catch {
        $code = Get-HttpStatusCodeFromError -ErrorRecord $_
        if ($null -ne $code) {
            return ('{0} {1}' -f $code, $_.Exception.Message)
        }
        return $_.Exception.Message
    }
}

function Write-AdoSubjectEndpointDiagnostics {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OrgUrl
    )

    $uris = @(
        ('{0}/_apis/graph/groups?api-version=5.1-preview.1' -f $OrgUrl),
        ('{0}/_apis/graph/users?api-version=5.1-preview.1' -f $OrgUrl),
        ('{0}/_apis/identities?api-version=5.0' -f $OrgUrl),
        ('{0}/_apis/identities?searchFilter=General&api-version=5.0' -f $OrgUrl),
        ('{0}/_apis/identities?searchFilter=General&filterValue=*&api-version=5.0' -f $OrgUrl)
    )

    foreach ($uri in $uris) {
        $status = Test-AdoEndpointStatus -Uri $uri
        Write-Log -Level 'Warn' -Message ('Endpoint probe: {0} => {1}' -f $uri, $status)
    }
}

function Get-AdoGraphBaseUrls {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OrgUrl
    )

    $baseUrls = New-Object System.Collections.Generic.List[string]

    # Preferred candidate: collection URL as provided by caller.
    [void]$baseUrls.Add($OrgUrl.TrimEnd('/'))

    try {
        $uri = [System.Uri]$OrgUrl
        $hostRoot = ('{0}://{1}' -f $uri.Scheme, $uri.Authority).TrimEnd('/')

        # Some Server deployments expose Graph endpoints at deployment scope.
        [void]$baseUrls.Add($hostRoot)

        $segments = @(($uri.AbsolutePath.Trim('/') -split '/') | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        })

        # For /tfs/{collection}, also try /tfs as a Graph service root.
        if ($segments.Count -ge 2 -and $segments[0] -ieq 'tfs') {
            [void]$baseUrls.Add(('{0}/tfs' -f $hostRoot))
        }
    }
    catch {
        # Keep original URL only when parsing fails.
    }

    $seen = @{}
    $unique = New-Object System.Collections.Generic.List[string]
    foreach ($url in $baseUrls) {
        if ([string]::IsNullOrWhiteSpace($url)) { continue }
        $k = $url.ToLowerInvariant()
        if (-not $seen.ContainsKey($k)) {
            $seen[$k] = $true
            [void]$unique.Add($url)
        }
    }

    return $unique.ToArray()
}

function Get-AdoGraphApiVersions {
    $versions = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($Script:AdoGraphApiVersion)) {
        [void]$versions.Add($Script:AdoGraphApiVersion)
    }

    # Compatibility fallbacks used by different Server versions/patch levels.
    [void]$versions.Add('5.1-preview.1')
    [void]$versions.Add('6.0-preview.1')
    [void]$versions.Add('7.1-preview.1')

    $seen = @{}
    $unique = New-Object System.Collections.Generic.List[string]
    foreach ($v in $versions) {
        if ([string]::IsNullOrWhiteSpace($v)) { continue }
        $k = $v.ToLowerInvariant()
        if (-not $seen.ContainsKey($k)) {
            $seen[$k] = $true
            [void]$unique.Add($v)
        }
    }

    return $unique.ToArray()
}

function Get-AdoGraphPagedResults {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OrgUrl,

        [Parameter(Mandatory = $true)]
        [string]$Resource
    )

    $attemptedUris = New-Object System.Collections.Generic.List[string]
    $lastError = $null

    $baseUrls = @(Get-AdoGraphBaseUrls -OrgUrl $OrgUrl)
    $versions = @(Get-AdoGraphApiVersions)

    foreach ($baseUrl in $baseUrls) {
        foreach ($apiVersion in $versions) {
            $uri = ('{0}/_apis/graph/{1}?api-version={2}' -f $baseUrl.TrimEnd('/'), $Resource, $apiVersion)
            [void]$attemptedUris.Add($uri)
            try {
                return @(Get-AdoRestPagedResults -BaseUri $uri)
            }
            catch {
                $lastError = $_
                $statusCode = Get-HttpStatusCodeFromError -ErrorRecord $_
                $message = if ($_.Exception) { [string]$_.Exception.Message } else { '' }
                $isEndpointCandidateFailure = ($statusCode -in @(401, 403, 404)) -or
                    ($message -match '(?i)\b401\b|\b403\b|\b404\b|unauthorized|forbidden|not\s+found')
                if ($isEndpointCandidateFailure) {
                    Write-Log -Level 'Debug' -Message ('Graph candidate failed, trying next endpoint: {0} | {1}' -f $uri, $message)
                    continue
                }
                throw
            }
        }
    }

    $attemptedText = ($attemptedUris | Select-Object -First 8) -join ' | '
    $moreCount = [Math]::Max(0, $attemptedUris.Count - 8)
    if ($moreCount -gt 0) {
        $attemptedText = '{0} | ... (+{1} more)' -f $attemptedText, $moreCount
    }

    $lastMessage = if ($lastError) { $lastError.Exception.Message } else { 'No response.' }
    throw ('Graph endpoint probe failed for resource [{0}] on this server (not found or unauthorized). Tried: {1}. Last error: {2}' -f
        $Resource, $attemptedText, $lastMessage)
}

function Invoke-AdoGraphGet {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OrgUrl,

        [Parameter(Mandatory = $true)]
        [string]$RelativePath
    )

    $attemptedUris = New-Object System.Collections.Generic.List[string]
    $lastError = $null

    $baseUrls = @(Get-AdoGraphBaseUrls -OrgUrl $OrgUrl)
    $versions = @(Get-AdoGraphApiVersions)

    foreach ($baseUrl in $baseUrls) {
        foreach ($apiVersion in $versions) {
            $sep = if ($RelativePath -match '\?') { '&' } else { '?' }
            $uri = ('{0}/_apis/graph/{1}{2}api-version={3}' -f
                $baseUrl.TrimEnd('/'),
                $RelativePath.TrimStart('/'),
                $sep,
                $apiVersion)
            [void]$attemptedUris.Add($uri)
            try {
                return (Invoke-AdoRestGet -Uri $uri)
            }
            catch {
                $lastError = $_
                $statusCode = Get-HttpStatusCodeFromError -ErrorRecord $_
                $message = if ($_.Exception) { [string]$_.Exception.Message } else { '' }
                $isEndpointCandidateFailure = ($statusCode -in @(401, 403, 404)) -or
                    ($message -match '(?i)\b401\b|\b403\b|\b404\b|unauthorized|forbidden|not\s+found')
                if ($isEndpointCandidateFailure) {
                    Write-Log -Level 'Debug' -Message ('Graph candidate failed, trying next endpoint: {0} | {1}' -f $uri, $message)
                    continue
                }
                throw
            }
        }
    }

    $attemptedText = ($attemptedUris | Select-Object -First 8) -join ' | '
    $moreCount = [Math]::Max(0, $attemptedUris.Count - 8)
    if ($moreCount -gt 0) {
        $attemptedText = '{0} | ... (+{1} more)' -f $attemptedText, $moreCount
    }

    $lastMessage = if ($lastError) { $lastError.Exception.Message } else { 'No response.' }
    throw ('Graph endpoint probe failed for path [{0}] on this server (not found or unauthorized). Tried: {1}. Last error: {2}' -f
        $RelativePath, $attemptedText, $lastMessage)
}

function Get-AdoIdentitySubjectsFallback {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OrgUrl,

        [Parameter(Mandatory = $true)]
        [bool]$LoadUsers
    )

    # Server fallback when Graph endpoints are unavailable/unauthorized.
    $identities = @()
    $lastError = $null

    $candidateUris = @(
        ('{0}/_apis/identities?api-version=5.0' -f $OrgUrl),
        ('{0}/_apis/identities?searchFilter=General&filterValue=*&api-version=5.0' -f $OrgUrl),
        ('{0}/_apis/identities?searchFilter=General&api-version=5.0' -f $OrgUrl)
    )

    foreach ($candidateUri in $candidateUris) {
        try {
            # Try paged/value payload first.
            $paged = @(Get-AdoRestPagedResults -BaseUri $candidateUri -ValueProperty 'value')
            if ($paged.Count -gt 0) {
                $identities = $paged
                break
            }
        }
        catch {
            $lastError = $_
            Write-Log -Level 'Debug' -Message ('Identity fallback (value) failed for {0}: {1}' -f $candidateUri, $_.Exception.Message)
        }

        try {
            # Some server versions return the collection under "identities".
            $paged = @(Get-AdoRestPagedResults -BaseUri $candidateUri -ValueProperty 'identities')
            if ($paged.Count -gt 0) {
                $identities = $paged
                break
            }
        }
        catch {
            $lastError = $_
            Write-Log -Level 'Debug' -Message ('Identity fallback (identities) failed for {0}: {1}' -f $candidateUri, $_.Exception.Message)
        }

        try {
            # Last attempt without pagination assumptions.
            $response = Invoke-AdoRestGet -Uri $candidateUri
            $items = @()
            if ($null -ne $response.value) {
                $items = @($response.value)
            }
            elseif ($null -ne $response.identities) {
                $items = @($response.identities)
            }
            elseif ($response -is [array]) {
                $items = @($response)
            }

            if ($items.Count -gt 0) {
                $identities = $items
                break
            }
        }
        catch {
            $lastError = $_
            Write-Log -Level 'Debug' -Message ('Identity fallback (single call) failed for {0}: {1}' -f $candidateUri, $_.Exception.Message)
        }
    }

    if ($identities.Count -eq 0 -and $lastError) {
        throw ('Identity fallback failed: {0}' -f $lastError.Exception.Message)
    }

    $subjects = New-Object System.Collections.Generic.List[object]
    $seenDescriptors = @{}

    foreach ($identity in $identities) {
        Assert-NotCancelled

        $descriptor = [string]$identity.descriptor
        if ([string]::IsNullOrWhiteSpace($descriptor)) { continue }
        if ($seenDescriptors.ContainsKey($descriptor)) { continue }
        $seenDescriptors[$descriptor] = $true

        $subjectKind = [string]$identity.subjectKind
        $isContainer = $false
        if ($null -ne $identity.isContainer) {
            try { $isContainer = [bool]$identity.isContainer } catch { }
        }

        $isGroup = $isContainer -or ($subjectKind -match '(?i)group')
        if (-not $LoadUsers -and -not $isGroup) { continue }

        $subjectType = if ($isGroup) { 'Group' } else { 'User' }

        $displayName = [string]$identity.displayName
        if ([string]::IsNullOrWhiteSpace($displayName)) {
            $displayName = [string]$identity.providerDisplayName
        }

        $principalName = [string]$identity.properties.Account.value
        if ([string]::IsNullOrWhiteSpace($principalName)) {
            $principalName = [string]$identity.customDisplayName
        }

        $origin = [string]$identity.providerDisplayName
        $originId = [string]$identity.id

        $raw = [PSCustomObject]@{
            displayName   = $displayName
            principalName = $principalName
            descriptor    = $descriptor
            origin        = $origin
            originId      = $originId
        }

        [void]$subjects.Add((New-Subject -SubjectType $subjectType -Raw $raw))
    }

    return $subjects.ToArray()
}

function Get-AdoSubjectsFromAclDescriptors {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OrgUrl,

        [Parameter(Mandatory = $true)]
        [bool]$LoadUsers
    )

    # Last-resort fallback for Server instances where Graph and Identities are blocked.
    # We infer subjects from ACL descriptor keys found on Git repository tokens.
    $descriptorMap = @{}
    $projects = @(Get-Projects -OrgUrl $OrgUrl -TargetProjectName $null)

    foreach ($project in $projects) {
        Assert-NotCancelled
        $repos = @(Get-Repositories -OrgUrl $OrgUrl -Project $project)

        # First try project-level token recursively to capture inherited + repo ACLs.
        $projectLevelUris = @(
            ('{0}/_apis/accesscontrollists/{1}?token={2}&recurse=true&includeExtendedInfo=false&api-version=5.0' -f
                $OrgUrl,
                $Script:GitNamespaceId,
                [Uri]::EscapeDataString(('repoV2/{0}' -f $project.id))),
            ('{0}/_apis/accesscontrollists/{1}?token={2}&recurse=true&includeExtendedInfo=true&api-version=5.0' -f
                $OrgUrl,
                $Script:GitNamespaceId,
                [Uri]::EscapeDataString(('repoV2/{0}' -f $project.id)))
        )

        foreach ($uri in $projectLevelUris) {
            try {
                $response = Invoke-AdoRestGet -Uri $uri
                foreach ($acl in @($response.value)) {
                    if (-not $acl -or -not $acl.acesDictionary) { continue }

                    foreach ($property in @($acl.acesDictionary.PSObject.Properties)) {
                        $descriptor = [string]$property.Name
                        if ([string]::IsNullOrWhiteSpace($descriptor)) { continue }
                        $descriptorMap[$descriptor] = $true
                    }
                }
            }
            catch {
                Write-Log -Level 'Debug' -Message ('ACL descriptor fallback (project recurse) failed for [{0}]: {1}' -f $project.name, $_.Exception.Message)
            }
        }

        foreach ($repo in $repos) {
            Assert-NotCancelled
            $token = 'repoV2/{0}/{1}' -f $project.id, $repo.id
            $repoUris = @(
                ('{0}/_apis/accesscontrollists/{1}?token={2}&includeExtendedInfo=false&api-version=5.0' -f
                    $OrgUrl,
                    $Script:GitNamespaceId,
                    [Uri]::EscapeDataString($token)),
                ('{0}/_apis/accesscontrollists/{1}?token={2}&includeExtendedInfo=true&api-version=5.0' -f
                    $OrgUrl,
                    $Script:GitNamespaceId,
                    [Uri]::EscapeDataString($token))
            )

            foreach ($uri in $repoUris) {
                try {
                    $response = Invoke-AdoRestGet -Uri $uri
                    foreach ($acl in @($response.value)) {
                        if (-not $acl -or -not $acl.acesDictionary) { continue }

                        foreach ($property in @($acl.acesDictionary.PSObject.Properties)) {
                            $descriptor = [string]$property.Name
                            if ([string]::IsNullOrWhiteSpace($descriptor)) { continue }
                            $descriptorMap[$descriptor] = $true
                        }
                    }
                }
                catch {
                    Write-Log -Level 'Debug' -Message ('ACL descriptor fallback failed for repo [{0}/{1}]: {2}' -f $project.name, $repo.name, $_.Exception.Message)
                }
            }
        }
    }

    $subjects = New-Object System.Collections.Generic.List[object]
    foreach ($descriptor in @($descriptorMap.Keys | Sort-Object)) {
        Assert-NotCancelled
        $isGroup = $descriptor -match '^(?i)vssgp\.'
        if (-not $LoadUsers -and -not $isGroup) { continue }

        $subjectType = if ($isGroup) { 'Group' } else { 'User' }
        $raw = [PSCustomObject]@{
            displayName   = $descriptor
            principalName = ''
            descriptor    = $descriptor
            origin        = 'ACLDescriptor'
            originId      = ''
        }

        [void]$subjects.Add((New-Subject -SubjectType $subjectType -Raw $raw))
    }

    Write-Log -Level 'Info' -Message ('ACL descriptor fallback discovered subjects: {0}' -f $subjects.Count)
    return $subjects.ToArray()
}

function Get-AdoCliSubjectsFallback {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OrgUrl,

        [Parameter(Mandatory = $true)]
        [bool]$LoadUsers
    )

    if (-not (Get-Command az -CommandType Application -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI (az) is not available for CLI subject fallback.'
    }

    $subjects = New-Object System.Collections.Generic.List[object]
    $seenDescriptors = @{}

    $groupsOutput = Invoke-Expression ('az devops security group list --organization "{0}" --scope organization --output json' -f $OrgUrl) 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ('CLI groups fallback failed: {0}' -f (($groupsOutput | Out-String).Trim()))
    }

    $groupsResponse = $null
    if (-not [string]::IsNullOrWhiteSpace(($groupsOutput | Out-String))) {
        $groupsResponse = (($groupsOutput | Out-String) | ConvertFrom-Json)
    }

    $groups = @()
    if ($groupsResponse -and $groupsResponse.graphGroups) {
        $groups = @($groupsResponse.graphGroups)
    }
    elseif ($groupsResponse -and $groupsResponse.value) {
        $groups = @($groupsResponse.value)
    }

    foreach ($g in $groups) {
        $descriptor = [string]$g.descriptor
        if ([string]::IsNullOrWhiteSpace($descriptor)) { continue }
        if ($seenDescriptors.ContainsKey($descriptor)) { continue }
        $seenDescriptors[$descriptor] = $true
        [void]$subjects.Add((New-Subject -SubjectType 'Group' -Raw $g))
    }

    if ($LoadUsers) {
        $usersOutput = Invoke-Expression ('az devops invoke --organization "{0}" --area Graph --resource Users --api-version {1} --output json' -f $OrgUrl, $Script:AdoGraphApiVersion) 2>&1
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace(($usersOutput | Out-String))) {
            $usersResponse = (($usersOutput | Out-String) | ConvertFrom-Json)
            $users = @()
            if ($usersResponse.value) { $users = @($usersResponse.value) }

            foreach ($u in $users) {
                $descriptor = [string]$u.descriptor
                if ([string]::IsNullOrWhiteSpace($descriptor)) { continue }
                if ($seenDescriptors.ContainsKey($descriptor)) { continue }
                $seenDescriptors[$descriptor] = $true
                [void]$subjects.Add((New-Subject -SubjectType 'User' -Raw $u))
            }
        }
    }

    return $subjects.ToArray()
}

# ---------------------------------------------------------------------------
# Override: Invoke-AdoValidation  (replaces ado.client.ps1)
# ---------------------------------------------------------------------------

function Invoke-AdoValidation {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OrgUrl
    )

    Start-Step -Name 'Validation: Azure DevOps Server connectivity'
    try {
        [void](Invoke-AdoRestGet -Uri ('{0}/_apis/projects?$top=1&api-version=5.0' -f $OrgUrl))
    }
    catch {
        throw ('Cannot reach Azure DevOps Server. ' +
               'Verify the URL, network access, and PAT scopes: ' +
               'Code (Read), Graph (Read), Security (Read or Read & manage). ' +
               'Details: {0}' -f $_.Exception.Message)
    }
    Stop-Step -Result 'OK'

    if ($EnableParallel.IsPresent) {
        Write-Log -Level 'Warn' -Message ('Parallel mode (-EnableParallel) is not supported in REST/Server mode. ' +
                                          'Falling back to sequential.')
        $script:EnableParallel = $false
    }
}

# ---------------------------------------------------------------------------
# Override: Get-Projects  (replaces ado.client.ps1)
# ---------------------------------------------------------------------------

function Get-Projects {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OrgUrl,

        [Parameter(Mandatory = $false)]
        [string]$TargetProjectName
    )

    if (-not [string]::IsNullOrWhiteSpace($TargetProjectName)) {
        $project = Invoke-AdoRestGet -Uri ('{0}/_apis/projects/{1}?api-version=5.0' -f
            $OrgUrl, [Uri]::EscapeDataString($TargetProjectName))
        return @($project)
    }

    return @(Get-AdoRestPagedResults -BaseUri ('{0}/_apis/projects?$top=200&api-version=5.0' -f $OrgUrl))
}

# ---------------------------------------------------------------------------
# Override: Get-Subjects  (replaces ado.client.ps1)
# ---------------------------------------------------------------------------

function Get-Subjects {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OrgUrl,

        [Parameter(Mandatory = $true)]
        [bool]$LoadUsers
    )

    $subjects = New-Object System.Collections.Generic.List[object]

    $usedIdentityFallback = $false

    Start-Step -Name 'Load groups'
    $groups = @()
    try {
        $groups = @(Get-AdoGraphPagedResults -OrgUrl $OrgUrl -Resource 'groups')
        foreach ($g in $groups) {
            Assert-NotCancelled
            if ([string]::IsNullOrWhiteSpace($g.descriptor)) { continue }
            [void]$subjects.Add((New-Subject -SubjectType 'Group' -Raw $g))
        }
        Stop-Step -Result ('Count={0}' -f $groups.Count)
    }
    catch {
        Write-Log -Level 'Warn' -Message ('Graph groups endpoint unavailable; trying CLI fallback: {0}' -f $_.Exception.Message)
        Write-AdoSubjectEndpointDiagnostics -OrgUrl $OrgUrl
        $fallbackSubjects = @()
        try {
            $fallbackSubjects = @(Get-AdoCliSubjectsFallback -OrgUrl $OrgUrl -LoadUsers $LoadUsers)
            if ($fallbackSubjects.Count -gt 0) {
                Write-Log -Level 'Info' -Message ('CLI subject fallback discovered subjects: {0}' -f $fallbackSubjects.Count)
            }
        }
        catch {
            Write-Log -Level 'Warn' -Message ('CLI fallback unavailable; trying Identities fallback: {0}' -f $_.Exception.Message)
            try {
                $fallbackSubjects = @(Get-AdoIdentitySubjectsFallback -OrgUrl $OrgUrl -LoadUsers $LoadUsers)
            }
            catch {
                Write-Log -Level 'Warn' -Message ('Identities fallback unavailable; trying ACL descriptor fallback: {0}' -f $_.Exception.Message)
                $fallbackSubjects = @(Get-AdoSubjectsFromAclDescriptors -OrgUrl $OrgUrl -LoadUsers $LoadUsers)
            }
        }

        if ($fallbackSubjects.Count -eq 0) {
            Write-Log -Level 'Warn' -Message 'No subject endpoints available on this server. Continuing with direct ACL audit mode.'
            Stop-Step -Result 'Count=0 (direct-acl-mode)'
            return @()
        }

        foreach ($subject in $fallbackSubjects) {
            [void]$subjects.Add($subject)
        }
        $usedIdentityFallback = $true

        $groupCount = @($fallbackSubjects | Where-Object { $_.SubjectType -eq 'Group' }).Count
        Stop-Step -Result ('Count={0} (fallback=identities-or-acl)' -f $groupCount)

        if ($LoadUsers) {
            $userCount = @($fallbackSubjects | Where-Object { $_.SubjectType -eq 'User' }).Count
            Start-Step -Name 'Load users'
            Stop-Step -Result ('Count={0} (fallback=identities-or-acl)' -f $userCount)
        }
    }

    if ($LoadUsers -and -not $usedIdentityFallback) {
        Start-Step -Name 'Load users'
        $users = @(Get-AdoGraphPagedResults -OrgUrl $OrgUrl -Resource 'users')
        foreach ($u in $users) {
            Assert-NotCancelled
            if ([string]::IsNullOrWhiteSpace($u.descriptor)) { continue }
            [void]$subjects.Add((New-Subject -SubjectType 'User' -Raw $u))
        }
        Stop-Step -Result ('Count={0}' -f $users.Count)
    }

    return $subjects
}

# ---------------------------------------------------------------------------
# Override: Get-Repositories  (replaces ado.client.ps1)
# ---------------------------------------------------------------------------

function Get-Repositories {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OrgUrl,

        [Parameter(Mandatory = $true)]
        [object]$Project
    )

    $response = Invoke-AdoRestGet -Uri ('{0}/{1}/_apis/git/repositories?api-version=5.0' -f
        $OrgUrl, [Uri]::EscapeDataString($Project.name))
    return @($response.value)
}

function Get-RepositoryFileCount {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OrgUrl,

        [Parameter(Mandatory = $true)]
        [object]$Project,

        [Parameter(Mandatory = $true)]
        [object]$Repository
    )

    try {
        $uri = '{0}/{1}/_apis/git/repositories/{2}/items?scopePath=/&recursionLevel=Full&includeContentMetadata=true&api-version=5.0' -f
            $OrgUrl,
            [Uri]::EscapeDataString([string]$Project.name),
            [Uri]::EscapeDataString([string]$Repository.id)

        $items = @(Get-AdoRestPagedResults -BaseUri $uri -ValueProperty 'value')
        if (-not $items -or $items.Count -eq 0) {
            return [Nullable[long]]$null
        }

        $files = @($items | Where-Object {
            ($_.gitObjectType -eq 'blob') -or
            ($null -ne $_.isFolder -and -not [bool]$_.isFolder)
        })

        return [long]$files.Count
    }
    catch {
        Write-Log -Level 'Debug' -Message ('Repository file count unavailable for [{0}/{1}]: {2}' -f $Project.name, $Repository.name, $_.Exception.Message)
        return [Nullable[long]]$null
    }
}

# ---------------------------------------------------------------------------
# Override: Get-PermissionEntry  (replaces ado.permissions.ps1)
# Uses the accesscontrollists REST endpoint which returns the same ACL
# structure the rest of the audit code already expects.
# ---------------------------------------------------------------------------

function Get-PermissionEntry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OrgUrl,

        [Parameter(Mandatory = $true)]
        [string]$Token,

        [Parameter(Mandatory = $true)]
        [object]$Subject
    )

    $uri = '{0}/_apis/accesscontrollists/{1}?token={2}&includeExtendedInfo=true&descriptors={3}&api-version=5.0' -f
        $OrgUrl,
        $Script:GitNamespaceId,
        [Uri]::EscapeDataString($Token),
        [Uri]::EscapeDataString($Subject.Descriptor)

    $response = Invoke-AdoRestGet -Uri $uri

    $acl = @($response.value) | Select-Object -First 1
    if (-not $acl -or -not $acl.acesDictionary) { return $null }

    $ace = @($acl.acesDictionary.PSObject.Properties.Value) | Select-Object -First 1
    if (-not $ace) { return $null }

    $effectiveAllowBits = $null
    $effectiveDenyBits  = $null
    $inheritedAllowBits = $null
    $inheritedDenyBits  = $null

    if ($ace.extendedInfo) {
        if ($null -ne $ace.extendedInfo.effectiveAllow) { $effectiveAllowBits = [long]$ace.extendedInfo.effectiveAllow }
        if ($null -ne $ace.extendedInfo.effectiveDeny)  { $effectiveDenyBits  = [long]$ace.extendedInfo.effectiveDeny  }
        if ($null -ne $ace.extendedInfo.inheritedAllow) { $inheritedAllowBits = [long]$ace.extendedInfo.inheritedAllow }
        if ($null -ne $ace.extendedInfo.inheritedDeny)  { $inheritedDenyBits  = [long]$ace.extendedInfo.inheritedDeny  }
    }

    return [PSCustomObject]@{
        InheritanceEnabled = [bool]$acl.inheritPermissions
        AllowBits          = [long]$ace.allow
        DenyBits           = [long]$ace.deny
        EffectiveAllowBits = $effectiveAllowBits
        EffectiveDenyBits  = $effectiveDenyBits
        InheritedAllowBits = $inheritedAllowBits
        InheritedDenyBits  = $inheritedDenyBits
    }
}

# ---------------------------------------------------------------------------
# Override: Get-GroupMemberships  (replaces ado.membership.ps1)
# Uses the Graph memberships endpoint; resolves display names from the
# already-loaded $Subjects list to avoid extra API calls per member.
# ---------------------------------------------------------------------------

function Get-GroupMemberships {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OrgUrl,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Subjects
    )

    $rows = New-Object System.Collections.Generic.List[object]
    if (-not $Subjects -or @($Subjects).Count -eq 0) {
        Write-Log -Level 'Info' -Message 'No subjects loaded; skipping group membership resolution.'
        return $rows.ToArray()
    }

    $groups = @($Subjects | Where-Object {
        $_.SubjectType -eq 'Group' -and -not [string]::IsNullOrWhiteSpace($_.Descriptor)
    })

    # Build a descriptor-to-subject map for fast display name resolution.
    $subjectMap = @{}
    foreach ($s in $Subjects) {
        if (-not [string]::IsNullOrWhiteSpace($s.Descriptor)) {
            $subjectMap[$s.Descriptor] = $s
        }
    }

    Write-Log -Level 'Info' -Message ('Resolving membership for {0} groups.' -f $groups.Count)

    foreach ($group in $groups) {
        Assert-NotCancelled

        $memberships = @()
        try {
            $response = Invoke-AdoGraphGet -OrgUrl $OrgUrl -RelativePath (
                'memberships/{0}?direction=Down' -f [Uri]::EscapeDataString($group.Descriptor))
            if ($response.value) { $memberships = @($response.value) }
        }
        catch {
            Write-Log -Level 'Warn' -Message ('Membership list failed for [{0}]: {1}' -f $group.DisplayName, $_.Exception.Message)
            continue
        }

        if ($memberships.Count -eq 0) {
            [void]$rows.Add([PSCustomObject]@{
                GroupDisplayName    = [string]$group.DisplayName
                GroupPrincipalName  = [string]$group.PrincipalName
                GroupDescriptor     = [string]$group.Descriptor
                MemberType          = ''
                MemberDisplayName   = '(empty group)'
                MemberPrincipalName = ''
                MemberDescriptor    = ''
                MemberOrigin        = ''
            })
            continue
        }

        foreach ($membership in $memberships) {
            $memberDesc = [string]$membership.memberDescriptor
            # vssgp. prefix = group; vssds./aad. = user
            $memberType = if ($memberDesc -match '^vssgp\.') { 'Group' } else { 'User' }

            # Resolve display name from already-loaded subjects (no extra API call).
            $resolved      = $subjectMap[$memberDesc]
            $displayName   = if ($resolved) { [string]$resolved.DisplayName }   else { '' }
            $principalName = if ($resolved) { [string]$resolved.PrincipalName } else { '' }
            $origin        = if ($resolved) { [string]$resolved.Origin }        else { '' }

            [void]$rows.Add([PSCustomObject]@{
                GroupDisplayName    = [string]$group.DisplayName
                GroupPrincipalName  = [string]$group.PrincipalName
                GroupDescriptor     = [string]$group.Descriptor
                MemberType          = $memberType
                MemberDisplayName   = $displayName
                MemberPrincipalName = $principalName
                MemberDescriptor    = $memberDesc
                MemberOrigin        = $origin
            })
        }
    }

    return $rows.ToArray()
}

# ---------------------------------------------------------------------------
# Override: Get-BranchPolicies  (replaces ado.policies.ps1)
# ---------------------------------------------------------------------------

function Get-BranchPolicies {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OrgUrl,

        [Parameter(Mandatory = $true)]
        [object[]]$Projects
    )

    $rows = New-Object System.Collections.Generic.List[object]

    foreach ($project in $Projects) {
        Assert-NotCancelled
        Write-Log -Level 'Debug' -Message ('Loading branch policies for project: {0}' -f $project.name)

        $policies = @()
        try {
            $response = Invoke-AdoRestGet -Uri ('{0}/{1}/_apis/policy/configurations?api-version=5.1' -f
                $OrgUrl, [Uri]::EscapeDataString($project.name))
            if ($response.value) { $policies = @($response.value) }
        }
        catch {
            Write-Log -Level 'Warn' -Message ('Branch policy list failed for [{0}]: {1}' -f $project.name, $_.Exception.Message)
            continue
        }

        foreach ($policy in $policies) {
            $typeDisplay = [string]$policy.type.displayName
            if ([string]::IsNullOrWhiteSpace($typeDisplay)) { $typeDisplay = [string]$policy.type.id }

            $scopes = @()
            if ($policy.settings -and $policy.settings.scope) { $scopes = @($policy.settings.scope) }

            if ($scopes.Count -eq 0) {
                [void]$rows.Add((New-PolicyRow -Project $project -Policy $policy -TypeDisplay $typeDisplay -Scope $null))
            }
            else {
                foreach ($scope in $scopes) {
                    [void]$rows.Add((New-PolicyRow -Project $project -Policy $policy -TypeDisplay $typeDisplay -Scope $scope))
                }
            }
        }
    }

    return $rows.ToArray()
}

# ---------------------------------------------------------------------------
# Override: Invoke-Audit (replaces ado.audit.ps1 for Server mode)
# Enumerates ACE entries directly from ACLs so audit can run even when
# Graph/Identities endpoints are unavailable.
# ---------------------------------------------------------------------------

function Invoke-Audit {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OrgUrl,

        [Parameter(Mandatory = $true)]
        [object[]]$Projects,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Subjects
    )

    $allRows = New-Object System.Collections.Generic.List[object]
    $rowsByProject = @{}
    $includeAllRows = $false
    if ($null -ne (Get-Variable -Name IncludeNotSetRows -Scope Script -ErrorAction SilentlyContinue)) {
        $includeAllRows = [bool]$IncludeNotSetRows.IsPresent
    }

    $subjectMap = @{}
    foreach ($subject in @($Subjects)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$subject.Descriptor)) {
            $subjectMap[[string]$subject.Descriptor] = $subject
        }
    }

    foreach ($project in $Projects) {
        Assert-NotCancelled
        Start-Step -Name ('Project: {0}' -f $project.name)

        $repos = @(Get-Repositories -OrgUrl $OrgUrl -Project $project)
        Write-Log -Level 'Info' -Message ('Repositories loaded: {0}' -f $repos.Count)

        $projectRows = New-Object System.Collections.Generic.List[object]

        foreach ($repo in $repos) {
            Assert-NotCancelled

            $token = 'repoV2/{0}/{1}' -f $project.id, $repo.id
            $repoFileCount = Get-RepositoryFileCount -OrgUrl $OrgUrl -Project $project -Repository $repo
            $uri = '{0}/_apis/accesscontrollists/{1}?token={2}&includeExtendedInfo=true&api-version=5.0' -f
                $OrgUrl,
                $Script:GitNamespaceId,
                [Uri]::EscapeDataString($token)

            $response = $null
            try {
                $response = Invoke-AdoRestGet -Uri $uri
            }
            catch {
                throw ('ACL query failed for Project="{0}", Repo="{1}". Details: {2}' -f $project.name, $repo.name, $_.Exception.Message)
            }

            foreach ($acl in @($response.value)) {
                if (-not $acl -or -not $acl.acesDictionary) { continue }

                foreach ($aceProp in @($acl.acesDictionary.PSObject.Properties)) {
                    Assert-NotCancelled

                    $descriptor = [string]$aceProp.Name
                    if ([string]::IsNullOrWhiteSpace($descriptor)) { continue }

                    $ace = $aceProp.Value
                    if (-not $ace) { continue }

                    $effectiveAllowBits = $null
                    $effectiveDenyBits  = $null
                    $inheritedAllowBits = $null
                    $inheritedDenyBits  = $null
                    if ($ace.extendedInfo) {
                        if ($null -ne $ace.extendedInfo.effectiveAllow) { $effectiveAllowBits = [long]$ace.extendedInfo.effectiveAllow }
                        if ($null -ne $ace.extendedInfo.effectiveDeny)  { $effectiveDenyBits  = [long]$ace.extendedInfo.effectiveDeny  }
                        if ($null -ne $ace.extendedInfo.inheritedAllow) { $inheritedAllowBits = [long]$ace.extendedInfo.inheritedAllow }
                        if ($null -ne $ace.extendedInfo.inheritedDeny)  { $inheritedDenyBits  = [long]$ace.extendedInfo.inheritedDeny  }
                    }

                    $entry = [PSCustomObject]@{
                        InheritanceEnabled = [bool]$acl.inheritPermissions
                        AllowBits          = [long]$ace.allow
                        DenyBits           = [long]$ace.deny
                        EffectiveAllowBits = $effectiveAllowBits
                        EffectiveDenyBits  = $effectiveDenyBits
                        InheritedAllowBits = $inheritedAllowBits
                        InheritedDenyBits  = $inheritedDenyBits
                    }

                    if (-not (Test-ExportEntry -Entry $entry -IncludeAll $includeAllRows)) {
                        continue
                    }

                    $subject = $subjectMap[$descriptor]
                    if (-not $subject) {
                        $subject = [PSCustomObject]@{
                            SubjectType   = if ($descriptor -match '^(?i)vssgp\.') { 'Group' } else { 'User' }
                            DisplayName   = $descriptor
                            PrincipalName = ''
                            Descriptor    = $descriptor
                            Origin        = 'ACLDescriptor'
                            OriginId      = ''
                        }
                    }

                    $row = New-AuditRow -OrgUrl $OrgUrl -Project $project -Repository $repo -Token $token -Subject $subject -Entry $entry -RepositoryFileCount $repoFileCount
                    [void]$projectRows.Add($row)
                    [void]$allRows.Add($row)
                }
            }
        }

        $projectKey = [string]$project.name
        if ([string]::IsNullOrWhiteSpace($projectKey)) {
            $projectKey = [string]$project.id
        }

        $rowsByProject[$projectKey] = $projectRows.ToArray()
        Stop-Step -Result ('Rows={0}' -f $projectRows.Count)
    }

    return [PSCustomObject]@{
        AllRows       = $allRows
        RowsByProject = $rowsByProject
    }
}
