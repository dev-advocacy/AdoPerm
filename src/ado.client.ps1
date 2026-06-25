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
        $groupsResponse = Invoke-AdoCliJson -Command ('az devops invoke --organization "{0}" --area Graph --resource Groups --api-version 7.1-preview.1 --output json' -f $OrgUrl)
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
        $usersResponse = Invoke-AdoCliJson -Command ('az devops invoke --organization "{0}" --area Graph --resource Users --api-version 7.1-preview.1 --output json' -f $OrgUrl)
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
