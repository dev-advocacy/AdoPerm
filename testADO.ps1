param(
    [Parameter(Mandatory = $true)]
    [string]$OrganizationUrl,

    [Parameter(Mandatory = $false)]
    [string]$Pat,

    [Parameter(Mandatory = $false)]
    [Security.SecureString]$PatSecureString,

    [Parameter(Mandatory = $false)]
    [string]$ProjectName,

    [Parameter(Mandatory = $false)]
    [ValidateSet('json', 'xlsx', 'both')]
    [string]$OutputFormat = 'both',

    [Parameter(Mandatory = $false)]
    [string]$DesktopFolderName = 'ADO-Permissions-Audit'

    ,
    [Parameter(Mandatory = $false)]
    [switch]$EnableRetry,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 10)]
    [int]$RetryMaxAttempts = 3,

    [Parameter(Mandatory = $false)]
    [ValidateRange(100, 10000)]
    [int]$RetryBaseDelayMs = 500,

    [Parameter(Mandatory = $false)]
    [switch]$EnableParallel,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 64)]
    [int]$ParallelThrottleLimit = 4
)

$ErrorActionPreference = 'Stop'

# Git Repositories security namespace (fixed GUID in Azure DevOps).
$GitNamespaceId = '2e9eb7ed-3c0a-47d4-87c1-0ffdd275fd87'

function Resolve-AdoContext {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputOrganizationUrl,

        [Parameter(Mandatory = $false)]
        [string]$InputProjectName
    )

    $orgUrl = $InputOrganizationUrl.Trim().TrimEnd('/')
    $derivedProjectName = $InputProjectName

    try {
        $uri = [System.Uri]$orgUrl
        $segments = @(($uri.AbsolutePath.Trim('/') -split '/') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

        if ($uri.Host -match '(^|\.)dev\.azure\.com$') {
            if ($segments.Count -ge 1) {
                $orgSegment = $segments[0]
                $orgUrl = "{0}://{1}/{2}" -f $uri.Scheme, $uri.Host, $orgSegment
            }

            if ([string]::IsNullOrWhiteSpace($derivedProjectName) -and $segments.Count -ge 2) {
                $derivedProjectName = [System.Uri]::UnescapeDataString($segments[1])
            }
        }
    }
    catch {
        # Keep original values when parsing fails.
    }

    return [PSCustomObject]@{
        OrganizationUrl = $orgUrl
        ProjectName     = $derivedProjectName
    }
}

function Invoke-AdoCliJson {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command
    )

    $attempt = 1
    while ($true) {
        $output = Invoke-Expression $Command 2>&1
        if ($LASTEXITCODE -eq 0) {
            if ([string]::IsNullOrWhiteSpace($output)) {
                return $null
            }

            return ($output | Out-String | ConvertFrom-Json)
        }

        $outputText = ($output | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($outputText)) {
            $outputText = 'No command output was returned.'
        }

        $looksTransient = (
            $outputText -match '(?i)429|too many requests|temporar|timeout|timed out|connection reset|connection aborted|service unavailable|503|502|504|resource temporarily unavailable|try again|throttl'
        )

        $canRetry = $EnableRetry.IsPresent -and $looksTransient -and $attempt -lt $RetryMaxAttempts
        if (-not $canRetry) {
            throw "Command failed after $attempt attempt(s): $Command`n$outputText"
        }

        $backoffMs = [Math]::Min(30000, $RetryBaseDelayMs * [Math]::Pow(2, ($attempt - 1)))
        $jitterMs = Get-Random -Minimum 0 -Maximum 250
        $delayMs = [int]$backoffMs + $jitterMs
        Write-Warning ("Transient error detected for command. Retry {0}/{1} in {2} ms." -f ($attempt + 1), $RetryMaxAttempts, $delayMs)
        Start-Sleep -Milliseconds $delayMs
        $attempt++
    }
}

function ConvertFrom-SecureStringToPlainText {
    param(
        [Parameter(Mandatory = $true)]
        [Security.SecureString]$Value
    )

    $bstr = [IntPtr]::Zero
    try {
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}

function Decode-GitPermissionBits {
    param(
        [Parameter(Mandatory = $true)]
        [long]$Bits
    )

    $map = [ordered]@{
        1     = 'Administer'
        2     = 'Read'
        4     = 'Contribute'
        8     = 'ForcePush'
        16    = 'CreateBranch'
        32    = 'CreateTag'
        64    = 'ManageNote'
        128   = 'PolicyExempt'
        256   = 'CreateRepository'
        512   = 'DeleteRepository'
        1024  = 'RenameRepository'
        2048  = 'EditPolicies'
        4096  = 'RemoveOthersLocks'
        8192  = 'ManagePermissions'
        16384 = 'PullRequestContribute'
        32768 = 'BypassPoliciesWhenCompletingPR'
        65536 = 'ViewAdvSecAlerts'
        131072 = 'DismissAdvSecAlerts'
        262144 = 'ManageAdvSecScanning'
        524288 = 'ManageEnterpriseLiveMigrations'
    }

    $names = New-Object System.Collections.Generic.List[string]
    foreach ($bit in $map.Keys) {
        if (($Bits -band $bit) -ne 0) {
            $name = [string]$map[$bit]
            if (-not [string]::IsNullOrWhiteSpace($name)) {
                [void]$names.Add($name)
            }
        }
    }

    return ($names -join ';')
}

function Format-GitPermissionBitsDisplay {
    param(
        [Parameter(Mandatory = $false)]
        [Nullable[long]]$Bits
    )

    if ($null -eq $Bits) {
        return ''
    }

    $decoded = Decode-GitPermissionBits -Bits $Bits
    if ([string]::IsNullOrWhiteSpace($decoded)) {
        return ("{0} (None)" -f $Bits)
    }

    return ("{0} ({1})" -f $Bits, $decoded)
}

function New-PermissionAuditRow {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OrganizationUrl,

        [Parameter(Mandatory = $true)]
        [object]$Project,

        [Parameter(Mandatory = $true)]
        [object]$Repository,

        [Parameter(Mandatory = $true)]
        [string]$Token,

        [Parameter(Mandatory = $true)]
        [object]$Group,

        [Parameter(Mandatory = $true)]
        [bool]$InheritanceEnabled,

        [Parameter(Mandatory = $true)]
        [long]$AllowBits,

        [Parameter(Mandatory = $true)]
        [long]$DenyBits,

        [Parameter(Mandatory = $false)]
        [Nullable[long]]$EffectiveAllowBits,

        [Parameter(Mandatory = $false)]
        [Nullable[long]]$EffectiveDenyBits,

        [Parameter(Mandatory = $false)]
        [Nullable[long]]$InheritedAllowBits,

        [Parameter(Mandatory = $false)]
        [Nullable[long]]$InheritedDenyBits
    )

    return [PSCustomObject]@{
        Organization          = $OrganizationUrl
        ProjectName           = $project.name
        ProjectId             = $project.id
        RepositoryName        = $Repository.name
        RepositoryId          = $Repository.id
        Token                 = $Token
        GroupDisplayName      = $Group.DisplayName
        GroupPrincipalName    = $Group.PrincipalName
        GroupDescriptor       = $Group.Descriptor
        GroupOrigin           = $Group.Origin
        InheritanceEnabled    = $InheritanceEnabled
        AllowBits             = $AllowBits
        DenyBits              = $DenyBits
        AllowPermissions      = Decode-GitPermissionBits -Bits $AllowBits
        DenyPermissions       = Decode-GitPermissionBits -Bits $DenyBits
        EffectiveAllowBits    = $EffectiveAllowBits
        EffectiveDenyBits     = $EffectiveDenyBits
        InheritedAllowBits    = $InheritedAllowBits
        InheritedDenyBits     = $InheritedDenyBits
        EffectiveAllowPerms   = if ($null -ne $EffectiveAllowBits) { Decode-GitPermissionBits -Bits $EffectiveAllowBits } else { '' }
        EffectiveDenyPerms    = if ($null -ne $EffectiveDenyBits) { Decode-GitPermissionBits -Bits $EffectiveDenyBits } else { '' }
        InheritedAllowPerms   = if ($null -ne $InheritedAllowBits) { Decode-GitPermissionBits -Bits $InheritedAllowBits } else { '' }
        InheritedDenyPerms    = if ($null -ne $InheritedDenyBits) { Decode-GitPermissionBits -Bits $InheritedDenyBits } else { '' }
        EffectiveAllowDisplay = Format-GitPermissionBitsDisplay -Bits $EffectiveAllowBits
        EffectiveDenyDisplay  = Format-GitPermissionBitsDisplay -Bits $EffectiveDenyBits
        InheritedAllowDisplay = Format-GitPermissionBitsDisplay -Bits $InheritedAllowBits
        InheritedDenyDisplay  = Format-GitPermissionBitsDisplay -Bits $InheritedDenyBits
    }
}

function ConvertTo-SafeFileName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $invalid = [System.IO.Path]::GetInvalidFileNameChars()
    $safe = $Name
    foreach ($c in $invalid) {
        $safe = $safe.Replace($c, '_')
    }

    return $safe
}

function ConvertTo-SafeWorksheetName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    # Excel worksheet names cannot exceed 31 chars and cannot contain []:*?/\
    $safe = $Name -replace '[\[\]\:\*\?\/\\]', '_'
    if ($safe.Length -gt 31) {
        $safe = $safe.Substring(0, 31)
    }

    if ([string]::IsNullOrWhiteSpace($safe)) {
        return 'Project'
    }

    return $safe
}

Write-Host 'Checking Azure DevOps CLI extension...' -ForegroundColor Cyan
az extension add --name azure-devops --only-show-errors 1>$null 2>$null

$resolvedContext = Resolve-AdoContext -InputOrganizationUrl $OrganizationUrl -InputProjectName $ProjectName
$OrganizationUrl = $resolvedContext.OrganizationUrl
$ProjectName = $resolvedContext.ProjectName

Write-Host ("Using organization URL: {0}" -f $OrganizationUrl) -ForegroundColor DarkCyan
if (-not [string]::IsNullOrWhiteSpace($ProjectName)) {
    Write-Host ("Using project filter: {0}" -f $ProjectName) -ForegroundColor DarkCyan
}

$patPlainText = $null
if ($PatSecureString) {
    $patPlainText = ConvertFrom-SecureStringToPlainText -Value $PatSecureString
}
elseif (-not [string]::IsNullOrWhiteSpace($Pat)) {
    # Backward compatibility for existing command lines.
    $patPlainText = $Pat
}

if (-not [string]::IsNullOrWhiteSpace($patPlainText)) {
    # PAT is read by azure-devops extension from this env var.
    $env:AZURE_DEVOPS_EXT_PAT = $patPlainText
}

Write-Host 'Validating Azure DevOps access...' -ForegroundColor Cyan
try {
    [void](Invoke-AdoCliJson -Command (
        "az devops project list --organization `"$OrganizationUrl`" --top 1 --output json"
    ))
}
catch {
    throw 'Cannot query Azure DevOps. Run az login or provide a valid PAT.'
}

if ($EnableRetry.IsPresent) {
    Write-Host ("Retry mode enabled: max attempts={0}, base delay={1} ms" -f $RetryMaxAttempts, $RetryBaseDelayMs) -ForegroundColor DarkCyan
}

if ($EnableParallel.IsPresent) {
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        Write-Warning 'Parallel mode requires PowerShell 7+. Falling back to sequential mode.'
        $EnableParallel = $false
    }
    else {
        Write-Host ("Parallel mode enabled: throttle limit={0}" -f $ParallelThrottleLimit) -ForegroundColor DarkCyan
    }
}

# Create output folder on Windows Desktop.
$desktopPath = [Environment]::GetFolderPath('Desktop')
$runStamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$outputRoot = Join-Path $desktopPath "$DesktopFolderName\$runStamp"
New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null

Write-Host "Output folder: $outputRoot" -ForegroundColor Green

Write-Host 'Loading organization groups...' -ForegroundColor Cyan
$groupsResponse = $null
try {
    # Native command is generally more stable than graph invoke for group listing.
    $groupsResponse = Invoke-AdoCliJson -Command (
        "az devops security group list --organization `"$OrganizationUrl`" --scope organization --output json"
    )
}
catch {
    Write-Warning ("Primary group listing failed. Falling back to graph invoke. Details: {0}" -f $_.Exception.Message)
    $groupsResponse = Invoke-AdoCliJson -Command (
        "az devops invoke --organization `"$OrganizationUrl`" --area Graph --resource Groups --api-version 7.1-preview.1 --output json"
    )
}

$groupByDescriptor = @{}
if ($groupsResponse) {
    $groups = @()
    if ($groupsResponse.graphGroups) {
        $groups = @($groupsResponse.graphGroups)
    }
    elseif ($groupsResponse.value) {
        $groups = @($groupsResponse.value)
    }

    foreach ($g in $groups) {
        if (-not [string]::IsNullOrWhiteSpace($g.descriptor)) {
            $groupByDescriptor[$g.descriptor] = [PSCustomObject]@{
                DisplayName   = $g.displayName
                PrincipalName = $g.principalName
                Descriptor    = $g.descriptor
                Origin        = $g.origin
            }
        }
    }
}

Write-Host 'Loading projects...' -ForegroundColor Cyan
if (-not [string]::IsNullOrWhiteSpace($ProjectName)) {
    $project = Invoke-AdoCliJson -Command (
        "az devops project show --organization `"$OrganizationUrl`" --project `"$ProjectName`" --output json"
    )
    $projects = @($project)
}
else {
    $projectsResponse = Invoke-AdoCliJson -Command (
        "az devops project list --organization `"$OrganizationUrl`" --output json"
    )
    $projects = @($projectsResponse.value)
}

if (-not $projects -or $projects.Count -eq 0) {
    throw 'No projects found for this organization/query.'
}

$allRows = New-Object System.Collections.Generic.List[object]

foreach ($project in $projects) {
    Write-Host ("Processing project: {0}" -f $project.name) -ForegroundColor Yellow

    $repos = Invoke-AdoCliJson -Command (
        "az repos list --organization `"$OrganizationUrl`" --project `"$($project.name)`" --output json"
    )

    $projectRows = New-Object System.Collections.Generic.List[object]
    $groupEntries = @($groupByDescriptor.GetEnumerator())

    if ($EnableParallel.IsPresent) {
        $repoRows = @($repos) | ForEach-Object -Parallel {
            $repo = $_
            $token = "repoV2/$($using:project.id)/$($repo.id)"

            function Decode-GitPermissionBitsLocal {
                param([long]$Bits)

                $map = [ordered]@{
                    1     = 'Administer'
                    2     = 'Read'
                    4     = 'Contribute'
                    8     = 'ForcePush'
                    16    = 'CreateBranch'
                    32    = 'CreateTag'
                    64    = 'ManageNote'
                    128   = 'PolicyExempt'
                    256   = 'CreateRepository'
                    512   = 'DeleteRepository'
                    1024  = 'RenameRepository'
                    2048  = 'EditPolicies'
                    4096  = 'RemoveOthersLocks'
                    8192  = 'ManagePermissions'
                    16384 = 'PullRequestContribute'
                    32768 = 'BypassPoliciesWhenCompletingPR'
                    65536 = 'ViewAdvSecAlerts'
                    131072 = 'DismissAdvSecAlerts'
                    262144 = 'ManageAdvSecScanning'
                    524288 = 'ManageEnterpriseLiveMigrations'
                }

                $names = New-Object System.Collections.Generic.List[string]
                foreach ($bit in $map.Keys) {
                    if (($Bits -band $bit) -ne 0) {
                        $name = [string]$map[$bit]
                        if (-not [string]::IsNullOrWhiteSpace($name)) {
                            [void]$names.Add($name)
                        }
                    }
                }

                return ($names -join ';')
            }

            function Format-GitPermissionBitsDisplayLocal {
                param([Nullable[long]]$Bits)
                if ($null -eq $Bits) { return '' }
                $decoded = Decode-GitPermissionBitsLocal -Bits $Bits
                if ([string]::IsNullOrWhiteSpace($decoded)) {
                    return ("{0} (None)" -f $Bits)
                }
                return ("{0} ({1})" -f $Bits, $decoded)
            }

            function Invoke-AdoCliJsonLocal {
                param(
                    [string]$Command,
                    [bool]$EnableRetry,
                    [int]$RetryMaxAttempts,
                    [int]$RetryBaseDelayMs
                )

                $attempt = 1
                while ($true) {
                    $output = Invoke-Expression $Command 2>&1
                    if ($LASTEXITCODE -eq 0) {
                        if ([string]::IsNullOrWhiteSpace($output)) { return $null }
                        return ($output | Out-String | ConvertFrom-Json)
                    }

                    $outputText = ($output | Out-String).Trim()
                    if ([string]::IsNullOrWhiteSpace($outputText)) {
                        $outputText = 'No command output was returned.'
                    }

                    $looksTransient = (
                        $outputText -match '(?i)429|too many requests|temporar|timeout|timed out|connection reset|connection aborted|service unavailable|503|502|504|resource temporarily unavailable|try again|throttl'
                    )

                    $canRetry = $EnableRetry -and $looksTransient -and $attempt -lt $RetryMaxAttempts
                    if (-not $canRetry) {
                        throw "Command failed after $attempt attempt(s): $Command`n$outputText"
                    }

                    $backoffMs = [Math]::Min(30000, $RetryBaseDelayMs * [Math]::Pow(2, ($attempt - 1)))
                    $jitterMs = Get-Random -Minimum 0 -Maximum 250
                    Start-Sleep -Milliseconds ([int]$backoffMs + $jitterMs)
                    $attempt++
                }
            }

            $rows = New-Object System.Collections.Generic.List[object]
            foreach ($groupEntry in $using:groupEntries) {
                $groupDescriptor = $groupEntry.Key
                $group = $groupEntry.Value

                $permissionResponse = Invoke-AdoCliJsonLocal -Command (
                    "az devops security permission show --organization `"$($using:OrganizationUrl)`" --id $($using:GitNamespaceId) --subject `"$groupDescriptor`" --token `"$token`" --output json"
                ) -EnableRetry $using:EnableRetry.IsPresent -RetryMaxAttempts $using:RetryMaxAttempts -RetryBaseDelayMs $using:RetryBaseDelayMs

                $acl = @($permissionResponse) | Select-Object -First 1
                if (-not $acl -or -not $acl.acesDictionary) { continue }

                $ace = @($acl.acesDictionary.PSObject.Properties.Value) | Select-Object -First 1
                if (-not $ace) { continue }

                $inheritEnabled = $acl.inheritPermissions
                $allowBits = [long]$ace.allow
                $denyBits = [long]$ace.deny

                $effectiveAllowBits = $null
                $effectiveDenyBits = $null
                $inheritedAllowBits = $null
                $inheritedDenyBits = $null

                if ($ace.extendedInfo) {
                    if ($null -ne $ace.extendedInfo.effectiveAllow) { $effectiveAllowBits = [long]$ace.extendedInfo.effectiveAllow }
                    if ($null -ne $ace.extendedInfo.effectiveDeny) { $effectiveDenyBits = [long]$ace.extendedInfo.effectiveDeny }
                    if ($null -ne $ace.extendedInfo.inheritedAllow) { $inheritedAllowBits = [long]$ace.extendedInfo.inheritedAllow }
                    if ($null -ne $ace.extendedInfo.inheritedDeny) { $inheritedDenyBits = [long]$ace.extendedInfo.inheritedDeny }
                }

                $hasMeaningfulPermission = (
                    $allowBits -ne 0 -or
                    $denyBits -ne 0 -or
                    ($null -ne $effectiveAllowBits -and $effectiveAllowBits -ne 0) -or
                    ($null -ne $effectiveDenyBits -and $effectiveDenyBits -ne 0) -or
                    ($null -ne $inheritedAllowBits -and $inheritedAllowBits -ne 0) -or
                    ($null -ne $inheritedDenyBits -and $inheritedDenyBits -ne 0)
                )
                if (-not $hasMeaningfulPermission) { continue }

                $row = [PSCustomObject]@{
                    Organization          = $using:OrganizationUrl
                    ProjectName           = $using:project.name
                    ProjectId             = $using:project.id
                    RepositoryName        = $repo.name
                    RepositoryId          = $repo.id
                    Token                 = $token
                    GroupDisplayName      = $group.DisplayName
                    GroupPrincipalName    = $group.PrincipalName
                    GroupDescriptor       = $group.Descriptor
                    GroupOrigin           = $group.Origin
                    InheritanceEnabled    = $inheritEnabled
                    AllowBits             = $allowBits
                    DenyBits              = $denyBits
                    AllowPermissions      = Decode-GitPermissionBitsLocal -Bits $allowBits
                    DenyPermissions       = Decode-GitPermissionBitsLocal -Bits $denyBits
                    EffectiveAllowBits    = $effectiveAllowBits
                    EffectiveDenyBits     = $effectiveDenyBits
                    InheritedAllowBits    = $inheritedAllowBits
                    InheritedDenyBits     = $inheritedDenyBits
                    EffectiveAllowPerms   = if ($null -ne $effectiveAllowBits) { Decode-GitPermissionBitsLocal -Bits $effectiveAllowBits } else { '' }
                    EffectiveDenyPerms    = if ($null -ne $effectiveDenyBits) { Decode-GitPermissionBitsLocal -Bits $effectiveDenyBits } else { '' }
                    InheritedAllowPerms   = if ($null -ne $inheritedAllowBits) { Decode-GitPermissionBitsLocal -Bits $inheritedAllowBits } else { '' }
                    InheritedDenyPerms    = if ($null -ne $inheritedDenyBits) { Decode-GitPermissionBitsLocal -Bits $inheritedDenyBits } else { '' }
                    EffectiveAllowDisplay = Format-GitPermissionBitsDisplayLocal -Bits $effectiveAllowBits
                    EffectiveDenyDisplay  = Format-GitPermissionBitsDisplayLocal -Bits $effectiveDenyBits
                    InheritedAllowDisplay = Format-GitPermissionBitsDisplayLocal -Bits $inheritedAllowBits
                    InheritedDenyDisplay  = Format-GitPermissionBitsDisplayLocal -Bits $inheritedDenyBits
                }

                [void]$rows.Add($row)
            }

            $rows
        } -ThrottleLimit $ParallelThrottleLimit

        foreach ($row in @($repoRows)) {
            if ($null -eq $row) { continue }
            [void]$projectRows.Add($row)
            [void]$allRows.Add($row)
        }
    }
    else {
        foreach ($repo in @($repos)) {
            $token = "repoV2/$($project.id)/$($repo.id)"

            foreach ($groupEntry in $groupEntries) {
                $groupDescriptor = $groupEntry.Key
                $group = $groupEntry.Value

                $permissionResponse = Invoke-AdoCliJson -Command (
                    "az devops security permission show --organization `"$OrganizationUrl`" --id $GitNamespaceId --subject `"$groupDescriptor`" --token `"$token`" --output json"
                )

                $acl = @($permissionResponse) | Select-Object -First 1
                if (-not $acl -or -not $acl.acesDictionary) {
                    continue
                }

                $ace = @($acl.acesDictionary.PSObject.Properties.Value) | Select-Object -First 1
                if (-not $ace) {
                    continue
                }

                $inheritEnabled = $acl.inheritPermissions
                $allowBits = [long]$ace.allow
                $denyBits = [long]$ace.deny

                $effectiveAllowBits = $null
                $effectiveDenyBits = $null
                $inheritedAllowBits = $null
                $inheritedDenyBits = $null

                if ($ace.extendedInfo) {
                    if ($null -ne $ace.extendedInfo.effectiveAllow) { $effectiveAllowBits = [long]$ace.extendedInfo.effectiveAllow }
                    if ($null -ne $ace.extendedInfo.effectiveDeny) { $effectiveDenyBits = [long]$ace.extendedInfo.effectiveDeny }
                    if ($null -ne $ace.extendedInfo.inheritedAllow) { $inheritedAllowBits = [long]$ace.extendedInfo.inheritedAllow }
                    if ($null -ne $ace.extendedInfo.inheritedDeny) { $inheritedDenyBits = [long]$ace.extendedInfo.inheritedDeny }
                }

                $hasMeaningfulPermission = (
                    $allowBits -ne 0 -or
                    $denyBits -ne 0 -or
                    ($null -ne $effectiveAllowBits -and $effectiveAllowBits -ne 0) -or
                    ($null -ne $effectiveDenyBits -and $effectiveDenyBits -ne 0) -or
                    ($null -ne $inheritedAllowBits -and $inheritedAllowBits -ne 0) -or
                    ($null -ne $inheritedDenyBits -and $inheritedDenyBits -ne 0)
                )

                if (-not $hasMeaningfulPermission) {
                    continue
                }

                $row = New-PermissionAuditRow -OrganizationUrl $OrganizationUrl -Project $project -Repository $repo -Token $token -Group $group -InheritanceEnabled $inheritEnabled -AllowBits $allowBits -DenyBits $denyBits -EffectiveAllowBits $effectiveAllowBits -EffectiveDenyBits $effectiveDenyBits -InheritedAllowBits $inheritedAllowBits -InheritedDenyBits $inheritedDenyBits

                [void]$projectRows.Add($row)
                [void]$allRows.Add($row)
            }
        }
    }

    # One JSON output file per project.
    if ($OutputFormat -in @('json', 'both')) {
        $safeProjectName = ConvertTo-SafeFileName -Name $project.name
        $projectJsonPath = Join-Path $outputRoot ("{0}.permissions.json" -f $safeProjectName)
        $projectRows | ConvertTo-Json -Depth 8 | Set-Content -Path $projectJsonPath -Encoding UTF8
        Write-Host ("  JSON written: {0}" -f $projectJsonPath) -ForegroundColor Green
    }
}

if ($OutputFormat -in @('xlsx', 'both')) {
    if (-not (Get-Module -ListAvailable -Name ImportExcel)) {
        Write-Warning 'ImportExcel module not found. Installing for current user...'
        Install-Module ImportExcel -Scope CurrentUser -Force -AllowClobber
    }

    Import-Module ImportExcel -ErrorAction Stop

    $xlsxPath = Join-Path $outputRoot 'ADO_Repo_Group_Permissions.xlsx'
    if (Test-Path $xlsxPath) {
        Remove-Item $xlsxPath -Force
    }

    $sheetNameSet = @{}

    foreach ($project in $projects) {
        $projectData = $allRows | Where-Object { $_.ProjectName -eq $project.name }
        if (-not $projectData -or $projectData.Count -eq 0) {
            # Create an empty row so the worksheet is still present.
            $projectData = @([PSCustomObject]@{
                Organization       = $OrganizationUrl
                ProjectName        = $project.name
                RepositoryName     = ''
                GroupDisplayName   = ''
                InheritanceEnabled = ''
                AllowPermissions   = ''
                DenyPermissions    = ''
            })
        }

        $baseSheetName = ConvertTo-SafeWorksheetName -Name $project.name
        $sheetName = $baseSheetName
        $i = 1
        while ($sheetNameSet.ContainsKey($sheetName)) {
            $suffix = "_$i"
            $maxBaseLen = 31 - $suffix.Length
            $trimmed = if ($baseSheetName.Length -gt $maxBaseLen) { $baseSheetName.Substring(0, $maxBaseLen) } else { $baseSheetName }
            $sheetName = "$trimmed$suffix"
            $i++
        }
        $sheetNameSet[$sheetName] = $true

        $projectData |
            Select-Object Organization, ProjectName, ProjectId, RepositoryName, RepositoryId, GroupDisplayName, GroupPrincipalName, GroupDescriptor, GroupOrigin, InheritanceEnabled, AllowBits, DenyBits, AllowPermissions, DenyPermissions, EffectiveAllowBits, EffectiveAllowDisplay, EffectiveDenyBits, EffectiveDenyDisplay, EffectiveAllowPerms, EffectiveDenyPerms, InheritedAllowBits, InheritedAllowDisplay, InheritedDenyBits, InheritedDenyDisplay, InheritedAllowPerms, InheritedDenyPerms |
            Export-Excel -Path $xlsxPath -WorksheetName $sheetName -AutoSize -FreezeTopRow -BoldTopRow
    }

    Write-Host ("XLSX written: {0}" -f $xlsxPath) -ForegroundColor Green
}

Write-Host ''
Write-Host 'Done.' -ForegroundColor Cyan
Write-Host ("Projects processed: {0}" -f $projects.Count) -ForegroundColor Cyan
Write-Host ("Rows exported: {0}" -f $allRows.Count) -ForegroundColor Cyan
Write-Host ("Output folder: {0}" -f $outputRoot) -ForegroundColor Cyan
