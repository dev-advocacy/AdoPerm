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
    Builds an HTTP Basic Authorization header from $env:AZURE_DEVOPS_EXT_PAT.
    Returns an empty hashtable when no PAT is set (falls through to Windows auth).
    #>
    $pat = $env:AZURE_DEVOPS_EXT_PAT
    if (-not [string]::IsNullOrWhiteSpace($pat)) {
        $encoded = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(':' + $pat))
        return @{ Authorization = ('Basic {0}' -f $encoded) }
    }
    return @{}
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

    $headers = New-AdoBasicAuthHeader
    $attempt = 1

    while ($true) {
        Write-Log -Level 'Debug' -Message ('REST GET: {0}' -f $Uri)
        try {
            $raw = Invoke-WebRequest -Uri $Uri -Headers $headers -Method Get `
                -UseBasicParsing -ErrorAction Stop
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

        $headers     = New-AdoBasicAuthHeader
        $attempt     = 1
        $rawResponse = $null

        while ($true) {
            Write-Log -Level 'Debug' -Message ('REST GET (paged): {0}' -f $uri)
            try {
                $rawResponse = Invoke-WebRequest -Uri $uri -Headers $headers -Method Get `
                    -UseBasicParsing -ErrorAction Stop
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

    return @($allItems)
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

    Start-Step -Name 'Load groups'
    $groups = @(Get-AdoRestPagedResults -BaseUri ('{0}/_apis/graph/groups?api-version=5.1-preview.1' -f $OrgUrl))
    foreach ($g in $groups) {
        Assert-NotCancelled
        if ([string]::IsNullOrWhiteSpace($g.descriptor)) { continue }
        [void]$subjects.Add((New-Subject -SubjectType 'Group' -Raw $g))
    }
    Stop-Step -Result ('Count={0}' -f $groups.Count)

    if ($LoadUsers) {
        Start-Step -Name 'Load users'
        $users = @(Get-AdoRestPagedResults -BaseUri ('{0}/_apis/graph/users?api-version=5.1-preview.1' -f $OrgUrl))
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
        [object[]]$Subjects
    )

    $rows = New-Object System.Collections.Generic.List[object]
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
            $response = Invoke-AdoRestGet -Uri (
                '{0}/_apis/graph/memberships/{1}?direction=Down&api-version=5.1-preview.1' -f
                $OrgUrl, [Uri]::EscapeDataString($group.Descriptor))
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

    return $rows
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

    return $rows
}
