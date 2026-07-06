function Invoke-Audit {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OrgUrl,

        [Parameter(Mandatory = $true)]
        [object[]]$Projects,

        [Parameter(Mandatory = $true)]
        [object[]]$Subjects
    )

    $allRows = New-Object System.Collections.Generic.List[object]
    $rowsByProject = @{}

    foreach ($project in $Projects) {
        Assert-NotCancelled
        Start-Step -Name ('Project: {0}' -f $project.name)

        $repos = Get-Repositories -OrgUrl $OrgUrl -Project $project
        Write-Log -Level 'Info' -Message ('Repositories loaded: {0}' -f $repos.Count)

        $projectRows = New-Object System.Collections.Generic.List[object]

        if ($EnableParallel.IsPresent -and $PSVersionTable.PSVersion.Major -ge 7) {
            Write-Log -Level 'Info' -Message ('Parallel collection enabled for project {0} (throttle={1})' -f $project.name, $ParallelThrottleLimit)

            $subjectData = @($Subjects | ForEach-Object {
                [PSCustomObject]@{
                    SubjectType   = $_.SubjectType
                    DisplayName   = $_.DisplayName
                    PrincipalName = $_.PrincipalName
                    Descriptor    = $_.Descriptor
                    Origin        = $_.Origin
                    OriginId      = $_.OriginId
                }
            })

            $stopFilePathForWorkers = $Script:StopFilePath
            $gitNamespaceIdForWorkers = $Script:GitNamespaceId
            $enableRetryForWorkers = $EnableRetry.IsPresent
            $includeNotSetRowsForWorkers = $IncludeNotSetRows.IsPresent

            $repoResults = @($repos | ForEach-Object -Parallel {
                $repo = $_

                function Test-CancelledLocal {
                    param([string]$Path)
                    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
                    return (Test-Path -LiteralPath $Path)
                }

                function Invoke-AdoCliJsonLocal {
                    param(
                        [string]$Command,
                        [bool]$UseRetry,
                        [int]$MaxAttempts,
                        [int]$BaseDelayMs,
                        [string]$CancelFile
                    )

                    $attempt = 1
                    while ($true) {
                        if (Test-CancelledLocal -Path $CancelFile) {
                            throw ('Execution cancelled by user request. Stop file found: {0}' -f $CancelFile)
                        }

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

                        $canRetry = $UseRetry -and $looksTransient -and $attempt -lt $MaxAttempts
                        if (-not $canRetry) {
                            throw ('Command failed after {0} attempt(s): {1}`n{2}' -f $attempt, $Command, $outputText)
                        }

                        $backoffMs = [Math]::Min(30000, $BaseDelayMs * [Math]::Pow(2, ($attempt - 1)))
                        $jitterMs = Get-Random -Minimum 0 -Maximum 250
                        Start-Sleep -Milliseconds ([int]$backoffMs + $jitterMs)
                        $attempt++
                    }
                }

                $repoRows = New-Object System.Collections.Generic.List[object]
                $token = 'repoV2/{0}/{1}' -f $using:project.id, $repo.id

                foreach ($subject in $using:subjectData) {
                    if (Test-CancelledLocal -Path $using:stopFilePathForWorkers) {
                        throw ('Execution cancelled by user request. Stop file found: {0}' -f $using:stopFilePathForWorkers)
                    }

                    $permissionResponse = Invoke-AdoCliJsonLocal -Command (
                        'az devops security permission show --organization "{0}" --id {1} --subject "{2}" --token "{3}" --output json' -f $using:OrgUrl, $using:gitNamespaceIdForWorkers, $subject.Descriptor, $token
                    ) -UseRetry $using:enableRetryForWorkers -MaxAttempts $using:RetryMaxAttempts -BaseDelayMs $using:RetryBaseDelayMs -CancelFile $using:stopFilePathForWorkers

                    $acl = @($permissionResponse) | Select-Object -First 1
                    if (-not $acl -or -not $acl.acesDictionary) {
                        continue
                    }

                    $ace = @($acl.acesDictionary.PSObject.Properties.Value) | Select-Object -First 1
                    if (-not $ace) {
                        continue
                    }

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

                    $entry = [PSCustomObject]@{
                        InheritanceEnabled = [bool]$acl.inheritPermissions
                        AllowBits          = [long]$ace.allow
                        DenyBits           = [long]$ace.deny
                        EffectiveAllowBits = $effectiveAllowBits
                        EffectiveDenyBits  = $effectiveDenyBits
                        InheritedAllowBits = $inheritedAllowBits
                        InheritedDenyBits  = $inheritedDenyBits
                    }

                    $hasMeaningful = (
                        $entry.AllowBits -ne 0 -or
                        $entry.DenyBits -ne 0 -or
                        ($null -ne $entry.EffectiveAllowBits -and $entry.EffectiveAllowBits -ne 0) -or
                        ($null -ne $entry.EffectiveDenyBits -and $entry.EffectiveDenyBits -ne 0) -or
                        ($null -ne $entry.InheritedAllowBits -and $entry.InheritedAllowBits -ne 0) -or
                        ($null -ne $entry.InheritedDenyBits -and $entry.InheritedDenyBits -ne 0)
                    )

                    if (-not $using:includeNotSetRowsForWorkers -and -not $hasMeaningful) {
                        continue
                    }

                    [void]$repoRows.Add([PSCustomObject]@{
                        RepositoryName      = $repo.name
                        RepositoryId        = $repo.id
                        Token               = $token
                        SubjectType         = $subject.SubjectType
                        SubjectDisplayName  = $subject.DisplayName
                        SubjectPrincipalName = $subject.PrincipalName
                        SubjectDescriptor   = $subject.Descriptor
                        SubjectOrigin       = $subject.Origin
                        SubjectOriginId     = $subject.OriginId
                        Entry               = $entry
                    })
                }

                $repoRows
            } -ThrottleLimit $ParallelThrottleLimit)

            foreach ($result in $repoResults) {
                if ($null -eq $result) {
                    continue
                }

                $subject = [PSCustomObject]@{
                    SubjectType   = $result.SubjectType
                    DisplayName   = $result.SubjectDisplayName
                    PrincipalName = $result.SubjectPrincipalName
                    Descriptor    = $result.SubjectDescriptor
                    Origin        = $result.SubjectOrigin
                    OriginId      = $result.SubjectOriginId
                }

                $repoInfo = [PSCustomObject]@{
                    name = $result.RepositoryName
                    id   = $result.RepositoryId
                }

                $row = New-AuditRow -OrgUrl $OrgUrl -Project $project -Repository $repoInfo -Token $result.Token -Subject $subject -Entry $result.Entry
                [void]$projectRows.Add($row)
                [void]$allRows.Add($row)
            }
        }
        else {
            foreach ($repo in $repos) {
                Assert-NotCancelled
                $token = 'repoV2/{0}/{1}' -f $project.id, $repo.id
                $repoFileCount = Get-RepositoryFileCount -OrgUrl $OrgUrl -Project $project -Repository $repo

                foreach ($subject in $Subjects) {
                    Assert-NotCancelled
                    try {
                        $entry = Get-PermissionEntry -OrgUrl $OrgUrl -Token $token -Subject $subject
                        if ($null -eq $entry) {
                            continue
                        }

                        if (-not (Test-ExportEntry -Entry $entry -IncludeAll $IncludeNotSetRows.IsPresent)) {
                            continue
                        }

                        $row = New-AuditRow -OrgUrl $OrgUrl -Project $project -Repository $repo -Token $token -Subject $subject -Entry $entry -RepositoryFileCount $repoFileCount
                        [void]$projectRows.Add($row)
                        [void]$allRows.Add($row)
                    }
                    catch {
                        throw ('Permission collection failed for Project="{0}", Repo="{1}", Subject="{2}" ({3}). Details: {4}' -f $project.name, $repo.name, $subject.DisplayName, $subject.Descriptor, $_.Exception.Message)
                    }
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
