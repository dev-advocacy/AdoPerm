function Invoke-AdoCliJson {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command
    )

    Assert-NotCancelled

    $attempt = 1
    while ($true) {
        Write-Log -Level 'Debug' -Message ('Executing command: {0}' -f $Command)
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
            throw ('Command failed after {0} attempt(s): {1}`n{2}' -f $attempt, $Command, $outputText)
        }

        $backoffMs = [Math]::Min(30000, $RetryBaseDelayMs * [Math]::Pow(2, ($attempt - 1)))
        $jitterMs = Get-Random -Minimum 0 -Maximum 250
        $delayMs = [int]$backoffMs + $jitterMs
        Write-Log -Level 'Warn' -Message ('Transient error. Retry {0}/{1} in {2} ms.' -f ($attempt + 1), $RetryMaxAttempts, $delayMs)
        Start-Sleep -Milliseconds $delayMs
        $attempt++
        Assert-NotCancelled
    }
}

function Invoke-AdoValidation {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OrgUrl
    )

    Start-Step -Name 'Validation: Azure CLI installation'
    if (-not (Get-Command az -CommandType Application -ErrorAction SilentlyContinue)) {
        Write-Log -Level 'Warn' -Message 'Azure CLI (az) not found in PATH. Attempting automatic installation...'

        # Elevation check — MSI install requires administrator rights.
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
        if (-not $isAdmin) {
            throw ('Azure CLI is not installed and automatic installation requires administrator rights. ' +
                   'Please run PowerShell as Administrator or install manually from https://aka.ms/installazurecliwindows, ' +
                   'then restart PowerShell and retry.')
        }

        $installerPath = Join-Path $env:TEMP 'azure-cli-install.msi'
        try {
            Write-Log -Level 'Info' -Message 'Downloading Azure CLI installer from https://aka.ms/installazurecliwindows ...'
            Invoke-WebRequest -Uri 'https://aka.ms/installazurecliwindows' -OutFile $installerPath -UseBasicParsing
            Write-Log -Level 'Info' -Message ('Installer downloaded: {0}' -f $installerPath)

            Write-Log -Level 'Info' -Message 'Installing Azure CLI silently (this may take a minute)...'
            $proc = Start-Process msiexec.exe -ArgumentList ('/i "{0}" /quiet /norestart' -f $installerPath) -Wait -PassThru
            if ($proc.ExitCode -ne 0) {
                throw ('MSI installer exited with code {0}.' -f $proc.ExitCode)
            }

            # Refresh PATH in the current session without restarting PowerShell.
            $machinePath = [System.Environment]::GetEnvironmentVariable('PATH', 'Machine')
            $userPath    = [System.Environment]::GetEnvironmentVariable('PATH', 'User')
            $env:PATH    = (@($machinePath, $userPath) | Where-Object { $_ }) -join ';'

            # Fallback: add default Azure CLI install location if still not found.
            if (-not (Get-Command az -CommandType Application -ErrorAction SilentlyContinue)) {
                $azDefault = 'C:\Program Files (x86)\Microsoft SDKs\Azure\CLI2\wbin'
                if (Test-Path (Join-Path $azDefault 'az.cmd')) {
                    $env:PATH = $azDefault + ';' + $env:PATH
                    Write-Log -Level 'Info' -Message ('Added Azure CLI to PATH: {0}' -f $azDefault)
                }
            }
        }
        catch {
            throw ('Azure CLI is not installed and automatic installation failed: {0} ' +
                   'Please install manually from https://aka.ms/installazurecliwindows, ' +
                   'then restart PowerShell and retry.' -f $_.Exception.Message)
        }
        finally {
            if (Test-Path $installerPath) { Remove-Item $installerPath -Force -ErrorAction SilentlyContinue }
        }

        if (-not (Get-Command az -CommandType Application -ErrorAction SilentlyContinue)) {
            throw ('Azure CLI was installed but az is still not available in PATH. ' +
                   'Please restart PowerShell and retry.')
        }

        Write-Log -Level 'Info' -Message 'Azure CLI installed successfully.'
    }
    Stop-Step -Result 'OK'

    Start-Step -Name 'Validation: Azure DevOps CLI extension'
    az extension add --name azure-devops --only-show-errors 1>$null 2>$null
    Stop-Step -Result 'OK'

    Start-Step -Name 'Validation: Azure DevOps access'
    try {
        [void](Invoke-AdoCliJson -Command ('az devops project list --organization "{0}" --top 1 --output json' -f $OrgUrl))
    }
    catch {
        throw ('Cannot query Azure DevOps. Verify az login or PAT scopes: Code (Read), Graph (Read), Security (Read or Read & manage). Details: {0}' -f $_.Exception.Message)
    }
    Stop-Step -Result 'OK'

    if ($EnableParallel.IsPresent) {
        Start-Step -Name 'Validation: Parallel prerequisites'
        if ($PSVersionTable.PSVersion.Major -lt 7) {
            Write-Log -Level 'Warn' -Message 'Parallel mode requires PowerShell 7+. Falling back to sequential mode.'
            $script:EnableParallel = $false
        }
        Stop-Step -Result 'OK'
    }
}

function Get-Projects {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OrgUrl,

        [Parameter(Mandatory = $false)]
        [string]$TargetProjectName
    )

    if (-not [string]::IsNullOrWhiteSpace($TargetProjectName)) {
        $project = Invoke-AdoCliJson -Command ('az devops project show --organization "{0}" --project "{1}" --output json' -f $OrgUrl, $TargetProjectName)
        return @($project)
    }

    $projectsResponse = Invoke-AdoCliJson -Command ('az devops project list --organization "{0}" --output json' -f $OrgUrl)
    return @($projectsResponse.value)
}

function New-Subject {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubjectType,

        [Parameter(Mandatory = $true)]
        [object]$Raw
    )

    return [PSCustomObject]@{
        SubjectType   = $SubjectType
        DisplayName   = [string]$Raw.displayName
        PrincipalName = [string]$Raw.principalName
        Descriptor    = [string]$Raw.descriptor
        Origin        = [string]$Raw.origin
        OriginId      = [string]$Raw.originId
    }
}

function Get-Subjects {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OrgUrl,

        [Parameter(Mandatory = $true)]
        [bool]$LoadUsers
    )

    $subjects = New-Object System.Collections.Generic.List[object]

    Start-Step -Name 'Load groups'
    $groupsResponse = $null
    try {
        $groupsResponse = Invoke-AdoCliJson -Command ('az devops security group list --organization "{0}" --scope organization --output json' -f $OrgUrl)
    }
    catch {
        Write-Log -Level 'Warn' -Message ('Primary group listing failed, fallback to Graph API: {0}' -f $_.Exception.Message)
        $groupsResponse = Invoke-AdoCliJson -Command ('az devops invoke --organization "{0}" --area Graph --resource Groups --api-version {1} --output json' -f $OrgUrl, $Script:AdoGraphApiVersion)
    }

    $groups = @()
    if ($groupsResponse.graphGroups) {
        $groups = @($groupsResponse.graphGroups)
    }
    elseif ($groupsResponse.value) {
        $groups = @($groupsResponse.value)
    }

    foreach ($g in $groups) {
        Assert-NotCancelled
        if ([string]::IsNullOrWhiteSpace($g.descriptor)) {
            continue
        }

        [void]$subjects.Add((New-Subject -SubjectType 'Group' -Raw $g))
    }
    Stop-Step -Result ('Count={0}' -f $groups.Count)

    if ($LoadUsers) {
        Start-Step -Name 'Load users'
        $usersResponse = Invoke-AdoCliJson -Command ('az devops invoke --organization "{0}" --area Graph --resource Users --api-version {1} --output json' -f $OrgUrl, $Script:AdoGraphApiVersion)
        $users = @()
        if ($usersResponse.value) {
            $users = @($usersResponse.value)
        }

        foreach ($u in $users) {
            Assert-NotCancelled
            if ([string]::IsNullOrWhiteSpace($u.descriptor)) {
                continue
            }

            [void]$subjects.Add((New-Subject -SubjectType 'User' -Raw $u))
        }
        Stop-Step -Result ('Count={0}' -f $users.Count)
    }

    return $subjects
}

function Get-Repositories {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OrgUrl,

        [Parameter(Mandatory = $true)]
        [object]$Project
    )

    return @(Invoke-AdoCliJson -Command ('az repos list --organization "{0}" --project "{1}" --output json' -f $OrgUrl, $Project.name))
}

function Get-BuildPermissionNames {
    param([long]$Bits)

    $buildBits = [ordered]@{
        1     = 'ViewBuilds';               2    = 'EditBuildQuality'
        4     = 'RetainIndefinitely';        8    = 'DeleteBuilds'
        16    = 'ManageBuildQualities';      32   = 'DestroyBuilds'
        64    = 'UpdateBuildInformation';    128  = 'QueueBuilds'
        256   = 'ManageBuildQueue';          512  = 'StopBuilds'
        1024  = 'ViewBuildDefinition';       2048 = 'EditBuildDefinition'
        4096  = 'DeleteBuildDefinition';     8192 = 'OverrideBuildCheckInValidation'
        16384 = 'AdministerBuildPermissions'
    }

    $names = @(foreach ($bit in $buildBits.Keys) {
        if (($Bits -band [long]$bit) -ne 0) { $buildBits[$bit] }
    })
    if ($names.Count -eq 0) { return '' }
    return $names -join ';'
}

function Get-BuildPermissions {
    <#
    .SYNOPSIS
    Collects project-level build (pipeline) permissions for every subject using the
    Azure DevOps Build security namespace (33344d9c-fc72-4d6f-aba5-fa317101a7e8).
    The token is the project GUID, which covers the project-wide build scope.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$OrgUrl,

        [Parameter(Mandatory = $true)]
        [object[]]$Projects,

        [Parameter(Mandatory = $true)]
        [object[]]$Subjects
    )

    $buildNamespaceId = '33344d9c-fc72-4d6f-aba5-fa317101a7e8'
    $rows = New-Object System.Collections.Generic.List[object]

    foreach ($project in $Projects) {
        Assert-NotCancelled
        $token = [string]$project.id   # project-level build token

        foreach ($subject in $Subjects) {
            Assert-NotCancelled
            if ([string]::IsNullOrWhiteSpace($subject.Descriptor)) { continue }

            $response = $null
            try {
                $response = Invoke-AdoCliJson -Command (
                    'az devops security permission show --organization "{0}" --id {1} --subject "{2}" --token "{3}" --output json' -f
                    $OrgUrl, $buildNamespaceId, $subject.Descriptor, $token
                )
            }
            catch {
                Write-Log -Level 'Debug' -Message ('Build permission query skipped for [{0}/{1}]: {2}' -f $project.name, $subject.DisplayName, $_.Exception.Message)
                continue
            }

            $acl = @($response) | Select-Object -First 1
            if (-not $acl -or -not $acl.acesDictionary) { continue }

            $ace = @($acl.acesDictionary.PSObject.Properties.Value) | Select-Object -First 1
            if (-not $ace) { continue }

            # Skip rows where nothing is set
            if ($ace.allow -eq 0 -and $ace.deny -eq 0) { continue }

            [void]$rows.Add([PSCustomObject]@{
                ProjectName          = [string]$project.name
                ProjectId            = [string]$project.id
                Token                = $token
                SubjectType          = [string]$subject.SubjectType
                SubjectDisplayName   = [string]$subject.DisplayName
                SubjectPrincipalName = [string]$subject.PrincipalName
                SubjectDescriptor    = [string]$subject.Descriptor
                SubjectOrigin        = [string]$subject.Origin
                InheritanceEnabled   = [bool]$acl.inheritPermissions
                AllowBits            = [long]$ace.allow
                DenyBits             = [long]$ace.deny
                AllowPermissions     = (Get-BuildPermissionNames -Bits ([long]$ace.allow))
                DenyPermissions      = (Get-BuildPermissionNames -Bits ([long]$ace.deny))
            })
        }
    }

    return $rows
}
