function Compare-Snapshots {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Source,

        [Parameter(Mandatory = $true)]
        [object]$Destination
    )

    Write-Log -Level 'Info' -Message 'Comparing repositories...'
    $repoChanges = @(Compare-Repositories -Source $Source -Destination $Destination)

    Write-Log -Level 'Info' -Message 'Comparing subjects (groups and users)...'
    $groupChanges = @(Compare-Groups -Source $Source -Destination $Destination)

    Write-Log -Level 'Info' -Message 'Comparing permissions...'
    $permissionChanges = @(Compare-Permissions -Source $Source -Destination $Destination)

    $membershipChanges = @()
    if ((@($Source.MembershipRows).Count -gt 0) -or (@($Destination.MembershipRows).Count -gt 0)) {
        Write-Log -Level 'Info' -Message 'Comparing group membership...'
        $membershipChanges = @(Compare-Memberships -Source $Source -Destination $Destination)
    }

    $policyChanges = @()
    if ((@($Source.PolicyRows).Count -gt 0) -or (@($Destination.PolicyRows).Count -gt 0)) {
        Write-Log -Level 'Info' -Message 'Comparing branch policies...'
        $policyChanges = @(Compare-Policies -Source $Source -Destination $Destination)
    }

    $buildChanges = @()
    if ((@($Source.BuildRows).Count -gt 0) -or (@($Destination.BuildRows).Count -gt 0)) {
        Write-Log -Level 'Info' -Message 'Comparing build permissions...'
        $buildChanges = @(Compare-BuildPermissions -Source $Source -Destination $Destination)
    }

    # ---- counts side-by-side ----
    $srcRepoCount = @($Source.AllRows | ForEach-Object { ('{0}|{1}' -f $_.ProjectName, $_.RepositoryName).ToLowerInvariant() } | Sort-Object -Unique).Count
    $dstRepoCount = @($Destination.AllRows | ForEach-Object { ('{0}|{1}' -f $_.ProjectName, $_.RepositoryName).ToLowerInvariant() } | Sort-Object -Unique).Count

    $countsRows = @(
        [PSCustomObject]@{ Metric = 'Projects';              Source = @($Source.Projects).Count;        Destination = @($Destination.Projects).Count;        Delta = @($Destination.Projects).Count        - @($Source.Projects).Count }
        [PSCustomObject]@{ Metric = 'Repositories';          Source = $srcRepoCount;                     Destination = $dstRepoCount;                         Delta = $dstRepoCount - $srcRepoCount }
        [PSCustomObject]@{ Metric = 'Groups';                Source = @($Source.Subjects).Count;         Destination = @($Destination.Subjects).Count;         Delta = @($Destination.Subjects).Count        - @($Source.Subjects).Count }
        [PSCustomObject]@{ Metric = 'PermissionRows';        Source = @($Source.AllRows).Count;          Destination = @($Destination.AllRows).Count;          Delta = @($Destination.AllRows).Count         - @($Source.AllRows).Count }
        [PSCustomObject]@{ Metric = 'BuildPermissionRows';   Source = @($Source.BuildRows).Count;        Destination = @($Destination.BuildRows).Count;        Delta = @($Destination.BuildRows).Count       - @($Source.BuildRows).Count }
        [PSCustomObject]@{ Metric = 'MembershipRows';        Source = @($Source.MembershipRows).Count;   Destination = @($Destination.MembershipRows).Count;   Delta = @($Destination.MembershipRows).Count  - @($Source.MembershipRows).Count }
        [PSCustomObject]@{ Metric = 'PolicyRows';            Source = @($Source.PolicyRows).Count;       Destination = @($Destination.PolicyRows).Count;       Delta = @($Destination.PolicyRows).Count      - @($Source.PolicyRows).Count }
    )

    $addedRepos    = @($repoChanges       | Where-Object { $_.DiffStatus -eq 'Added' }).Count
    $removedRepos  = @($repoChanges       | Where-Object { $_.DiffStatus -eq 'Removed' }).Count
    $addedGroups   = @($groupChanges      | Where-Object { $_.DiffStatus -eq 'Added' }).Count
    $removedGroups = @($groupChanges      | Where-Object { $_.DiffStatus -eq 'Removed' }).Count
    $addedPerms    = @($permissionChanges | Where-Object { $_.DiffStatus -eq 'Added' }).Count
    $removedPerms  = @($permissionChanges | Where-Object { $_.DiffStatus -eq 'Removed' }).Count
    $changedPerms  = @($permissionChanges | Where-Object { $_.DiffStatus -eq 'Changed' }).Count

    $migrationStatus = if ($removedRepos -eq 0 -and $removedGroups -eq 0 -and $removedPerms -eq 0 -and $changedPerms -eq 0 -and
        (@($buildChanges | Where-Object { $_.DiffStatus -eq 'Removed' -or $_.DiffStatus -eq 'Changed' }).Count -eq 0)) {
        'Clean'
    }

    $migrationChecks = @(New-MigrationChecksRows -Source $Source -Destination $Destination -ComparisonSummary @{
            RemovedRepositories = $removedRepos
            RemovedGroups       = $removedGroups
            RemovedPermissions  = $removedPerms
            ChangedPermissions  = $changedPerms
            ChangedPolicies     = @($policyChanges | Where-Object { $_.DiffStatus -ne 'Matched' }).Count
        })
    elseif ($changedPerms -gt 0 -or $removedPerms -gt 0 -or
        (@($buildChanges | Where-Object { $_.DiffStatus -eq 'Removed' -or $_.DiffStatus -eq 'Changed' }).Count -gt 0)) {
        'PermissionDrift'
    }
    else {
        'StructuralChanges'
    }

    return [PSCustomObject]@{
        SourceOrganizationUrl      = $Source.OrganizationUrl
        DestinationOrganizationUrl = $Destination.OrganizationUrl
        SourceCapturedAt           = $Source.CapturedAt
        DestinationCapturedAt      = $Destination.CapturedAt
        ComparedAt                 = (Get-Date -Format 'o')
        MigrationStatus            = $migrationStatus
        Summary                    = [PSCustomObject]@{
            AddedRepositories   = $addedRepos
            RemovedRepositories = $removedRepos
            AddedGroups         = $addedGroups
            RemovedGroups       = $removedGroups
            AddedPermissions    = $addedPerms
            RemovedPermissions  = $removedPerms
            ChangedPermissions  = $changedPerms
            AddedBuildPerms     = @($buildChanges | Where-Object { $_.DiffStatus -eq 'Added' }).Count
            RemovedBuildPerms   = @($buildChanges | Where-Object { $_.DiffStatus -eq 'Removed' }).Count
            ChangedBuildPerms   = @($buildChanges | Where-Object { $_.DiffStatus -eq 'Changed' }).Count
            ChangedMemberships  = @($membershipChanges | Where-Object { $_.DiffStatus -ne 'Matched' }).Count
            ChangedPolicies     = @($policyChanges     | Where-Object { $_.DiffStatus -ne 'Matched' }).Count
        }
        Counts             = $countsRows
        MigrationChecks    = $migrationChecks
        RepoChanges        = $repoChanges
        GroupChanges       = $groupChanges
        PermissionChanges  = $permissionChanges
        BuildPermissionChanges = $buildChanges
        MembershipChanges  = $membershipChanges
        PolicyChanges      = $policyChanges
    }
}

function Get-RepoMigrationStats {
    param([object]$Snapshot)

    $rows = @($Snapshot.AllRows)
    $repoMap = @{}

    foreach ($row in $rows) {
        $projectName = [string]$row.ProjectName
        $repoName = [string]$row.RepositoryName
        if ([string]::IsNullOrWhiteSpace($projectName) -or [string]::IsNullOrWhiteSpace($repoName)) {
            continue
        }

        $key = ('{0}|{1}' -f $projectName, $repoName).ToLowerInvariant()
        if (-not $repoMap.ContainsKey($key)) {
            $repoMap[$key] = [PSCustomObject]@{
                ProjectName         = $projectName
                RepositoryName      = $repoName
                RepositoryId        = [string]$row.RepositoryId
                BranchCount         = $null
                TagCount            = $null
                RepositoryFileCount = $null
                DefaultBranch       = ''
                HeadCommitId        = ''
            }
        }

        $entry = $repoMap[$key]

        if ($null -eq $entry.RepositoryFileCount -and $null -ne $row.RepositoryFileCount -and "$($row.RepositoryFileCount)" -ne '') {
            $entry.RepositoryFileCount = [long]$row.RepositoryFileCount
        }
        if ($null -eq $entry.BranchCount -and $null -ne $row.BranchCount -and "$($row.BranchCount)" -ne '') {
            $entry.BranchCount = [long]$row.BranchCount
        }
        if ($null -eq $entry.TagCount -and $null -ne $row.TagCount -and "$($row.TagCount)" -ne '') {
            $entry.TagCount = [long]$row.TagCount
        }
        if ([string]::IsNullOrWhiteSpace($entry.DefaultBranch) -and -not [string]::IsNullOrWhiteSpace([string]$row.DefaultBranch)) {
            $entry.DefaultBranch = [string]$row.DefaultBranch
        }
        if ([string]::IsNullOrWhiteSpace($entry.HeadCommitId) -and -not [string]::IsNullOrWhiteSpace([string]$row.HeadCommitId)) {
            $entry.HeadCommitId = [string]$row.HeadCommitId
        }
    }

    return $repoMap
}

function New-MigrationChecksRows {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Source,

        [Parameter(Mandatory = $true)]
        [object]$Destination,

        [Parameter(Mandatory = $true)]
        [hashtable]$ComparisonSummary
    )

    $rows = New-Object System.Collections.Generic.List[object]

    function Add-CheckRow {
        param(
            [string]$Category,
            [string]$Check,
            [object]$SourceValue,
            [object]$DestinationValue,
            [string]$Status,
            [string]$Details
        )

        [void]$rows.Add([PSCustomObject]@{
            Category         = $Category
            Check            = $Check
            SourceValue      = [string]$SourceValue
            DestinationValue = [string]$DestinationValue
            Delta            = Get-DeltaDisplay -SourceValue $SourceValue -DestinationValue $DestinationValue
            Status           = $Status
            Details          = $Details
        })
    }

    $srcProjectCount = @($Source.Projects).Count
    $dstProjectCount = @($Destination.Projects).Count
    Add-CheckRow -Category 'Structure' -Check 'Project count' -SourceValue $srcProjectCount -DestinationValue $dstProjectCount `
        -Status (if ($srcProjectCount -eq $dstProjectCount) { 'OK' } else { 'Fail' }) -Details ''

    $srcRepos = Get-RepoMigrationStats -Snapshot $Source
    $dstRepos = Get-RepoMigrationStats -Snapshot $Destination
    $srcRepoCount = @($srcRepos.Keys).Count
    $dstRepoCount = @($dstRepos.Keys).Count
    Add-CheckRow -Category 'Structure' -Check 'Repository count' -SourceValue $srcRepoCount -DestinationValue $dstRepoCount `
        -Status (if ($srcRepoCount -eq $dstRepoCount) { 'OK' } else { 'Fail' }) -Details ''

    $allRepoKeys = @(($srcRepos.Keys + $dstRepos.Keys) | Sort-Object -Unique)

    $matchedRepoCount = @($allRepoKeys | Where-Object { $srcRepos.ContainsKey($_) -and $dstRepos.ContainsKey($_) }).Count
    $structuralMatchPct = if ($srcRepoCount -gt 0) { [math]::Round(($matchedRepoCount / [double]$srcRepoCount) * 100, 2) } else { 100 }
    Add-CheckRow -Category 'Score' -Check 'StructuralMatchPct' -SourceValue '100' -DestinationValue $structuralMatchPct `
        -Status (if ($structuralMatchPct -eq 100) { 'OK' } elseif ($structuralMatchPct -ge 95) { 'Warn' } else { 'Fail' }) -Details ''

    $branchMismatch = 0
    $tagMismatch = 0
    $fileCountMismatch = 0
    $defaultBranchMismatch = 0
    $headMismatch = 0
    $branchCompared = 0
    $tagCompared = 0
    $fileCompared = 0
    $defaultCompared = 0
    $headCompared = 0

    foreach ($repoKey in $allRepoKeys) {
        if (-not ($srcRepos.ContainsKey($repoKey) -and $dstRepos.ContainsKey($repoKey))) {
            continue
        }

        $src = $srcRepos[$repoKey]
        $dst = $dstRepos[$repoKey]

        if ($null -ne $src.BranchCount -and $null -ne $dst.BranchCount) {
            $branchCompared++
            if ([long]$src.BranchCount -ne [long]$dst.BranchCount) { $branchMismatch++ }
        }

        if ($null -ne $src.TagCount -and $null -ne $dst.TagCount) {
            $tagCompared++
            if ([long]$src.TagCount -ne [long]$dst.TagCount) { $tagMismatch++ }
        }

        if ($null -ne $src.RepositoryFileCount -and $null -ne $dst.RepositoryFileCount) {
            $fileCompared++
            if ([long]$src.RepositoryFileCount -ne [long]$dst.RepositoryFileCount) { $fileCountMismatch++ }
        }

        if (-not [string]::IsNullOrWhiteSpace($src.DefaultBranch) -and -not [string]::IsNullOrWhiteSpace($dst.DefaultBranch)) {
            $defaultCompared++
            if ($src.DefaultBranch -ne $dst.DefaultBranch) { $defaultBranchMismatch++ }
        }

        if (-not [string]::IsNullOrWhiteSpace($src.HeadCommitId) -and -not [string]::IsNullOrWhiteSpace($dst.HeadCommitId)) {
            $headCompared++
            if ($src.HeadCommitId -ne $dst.HeadCommitId) { $headMismatch++ }
        }
    }

    Add-CheckRow -Category 'Content' -Check 'Branch count mismatches' -SourceValue $branchCompared -DestinationValue $branchMismatch `
        -Status (if ($branchCompared -eq 0) { 'Warn' } elseif ($branchMismatch -eq 0) { 'OK' } else { 'Warn' }) -Details 'Compared repos with branch count present in source+destination.'
    Add-CheckRow -Category 'Content' -Check 'Tag count mismatches' -SourceValue $tagCompared -DestinationValue $tagMismatch `
        -Status (if ($tagCompared -eq 0) { 'Warn' } elseif ($tagMismatch -eq 0) { 'OK' } else { 'Warn' }) -Details 'Compared repos with tag count present in source+destination.'
    Add-CheckRow -Category 'Content' -Check 'Repository file count mismatches' -SourceValue $fileCompared -DestinationValue $fileCountMismatch `
        -Status (if ($fileCompared -eq 0) { 'Warn' } elseif ($fileCountMismatch -eq 0) { 'OK' } else { 'Warn' }) -Details 'Compared repos with file count present in source+destination.'
    Add-CheckRow -Category 'Content' -Check 'Default branch mismatches' -SourceValue $defaultCompared -DestinationValue $defaultBranchMismatch `
        -Status (if ($defaultCompared -eq 0) { 'Warn' } elseif ($defaultBranchMismatch -eq 0) { 'OK' } else { 'Warn' }) -Details 'Compared repos with default branch present in source+destination.'
    Add-CheckRow -Category 'Content' -Check 'HEAD commit mismatches' -SourceValue $headCompared -DestinationValue $headMismatch `
        -Status (if ($headCompared -eq 0) { 'Warn' } elseif ($headMismatch -eq 0) { 'OK' } else { 'Warn' }) -Details 'Compared repos with HEAD commit present in source+destination.'

    $permissionDriftCount = [int]$ComparisonSummary.RemovedPermissions + [int]$ComparisonSummary.ChangedPermissions
    Add-CheckRow -Category 'Security' -Check 'PermissionDriftCount' -SourceValue 0 -DestinationValue $permissionDriftCount `
        -Status (if ($permissionDriftCount -eq 0) { 'OK' } else { 'Fail' }) -Details 'Removed + changed repository permission assignments.'

    $policyDriftCount = [int]$ComparisonSummary.ChangedPolicies
    Add-CheckRow -Category 'Security' -Check 'PolicyDriftCount' -SourceValue 0 -DestinationValue $policyDriftCount `
        -Status (if ($policyDriftCount -eq 0) { 'OK' } else { 'Warn' }) -Details 'Branch policy differences (added/removed/changed).'

    Add-CheckRow -Category 'Structure' -Check 'Missing repositories in destination' -SourceValue 0 -DestinationValue ([int]$ComparisonSummary.RemovedRepositories) `
        -Status (if ([int]$ComparisonSummary.RemovedRepositories -eq 0) { 'OK' } else { 'Fail' }) -Details ''

    Add-CheckRow -Category 'Security' -Check 'Missing groups in destination' -SourceValue 0 -DestinationValue ([int]$ComparisonSummary.RemovedGroups) `
        -Status (if ([int]$ComparisonSummary.RemovedGroups -eq 0) { 'OK' } else { 'Warn' }) -Details ''

    return $rows.ToArray()
}

function Get-DeltaDisplay {
    param([object]$SourceValue, [object]$DestinationValue)

    $srcNumber = 0.0
    $dstNumber = 0.0
    $canParseSrc = [double]::TryParse([string]$SourceValue, [ref]$srcNumber)
    $canParseDst = [double]::TryParse([string]$DestinationValue, [ref]$dstNumber)

    if ($canParseSrc -and $canParseDst) {
        $delta = $dstNumber - $srcNumber
        if ($delta -gt 0) { return ('+{0}' -f $delta) }
        return [string]$delta
    }

    if ([string]$SourceValue -eq [string]$DestinationValue) {
        return '0'
    }

    return 'n/a'
}

function Compare-Repositories {
    param([object]$Source, [object]$Destination)

    $srcMap = @{}
    $dstMap = @{}

    foreach ($row in $Source.AllRows) {
        $key = ('{0}|{1}' -f [string]$row.ProjectName, [string]$row.RepositoryName).ToLowerInvariant()
        if (-not $srcMap.ContainsKey($key)) {
            $srcMap[$key] = [PSCustomObject]@{ ProjectName = [string]$row.ProjectName; RepositoryName = [string]$row.RepositoryName }
        }
    }
    foreach ($row in $Destination.AllRows) {
        $key = ('{0}|{1}' -f [string]$row.ProjectName, [string]$row.RepositoryName).ToLowerInvariant()
        if (-not $dstMap.ContainsKey($key)) {
            $dstMap[$key] = [PSCustomObject]@{ ProjectName = [string]$row.ProjectName; RepositoryName = [string]$row.RepositoryName }
        }
    }

    $result = New-Object System.Collections.Generic.List[object]
    foreach ($key in $srcMap.Keys) {
        $status = if ($dstMap.ContainsKey($key)) { 'Matched' } else { 'Removed' }
        [void]$result.Add([PSCustomObject]@{
            DiffStatus     = $status
            ProjectName    = $srcMap[$key].ProjectName
            RepositoryName = $srcMap[$key].RepositoryName
        })
    }
    foreach ($key in $dstMap.Keys) {
        if (-not $srcMap.ContainsKey($key)) {
            [void]$result.Add([PSCustomObject]@{
                DiffStatus     = 'Added'
                ProjectName    = $dstMap[$key].ProjectName
                RepositoryName = $dstMap[$key].RepositoryName
            })
        }
    }
    return @($result | Sort-Object DiffStatus, ProjectName, RepositoryName)
}

function Compare-Groups {
    param([object]$Source, [object]$Destination)

    $srcMap = @{}
    $dstMap = @{}

    foreach ($s in $Source.Subjects) {
        $key = ([string]$s.PrincipalName).ToLowerInvariant()
        if (-not [string]::IsNullOrWhiteSpace($key) -and -not $srcMap.ContainsKey($key)) {
            $srcMap[$key] = $s
        }
    }
    foreach ($s in $Destination.Subjects) {
        $key = ([string]$s.PrincipalName).ToLowerInvariant()
        if (-not [string]::IsNullOrWhiteSpace($key) -and -not $dstMap.ContainsKey($key)) {
            $dstMap[$key] = $s
        }
    }

    $result = New-Object System.Collections.Generic.List[object]
    foreach ($key in $srcMap.Keys) {
        $status = if ($dstMap.ContainsKey($key)) { 'Matched' } else { 'Removed' }
        [void]$result.Add([PSCustomObject]@{
            DiffStatus           = $status
            SubjectType          = [string]$srcMap[$key].SubjectType
            SubjectDisplayName   = [string]$srcMap[$key].DisplayName
            SubjectPrincipalName = [string]$srcMap[$key].PrincipalName
        })
    }
    foreach ($key in $dstMap.Keys) {
        if (-not $srcMap.ContainsKey($key)) {
            [void]$result.Add([PSCustomObject]@{
                DiffStatus           = 'Added'
                SubjectType          = [string]$dstMap[$key].SubjectType
                SubjectDisplayName   = [string]$dstMap[$key].DisplayName
                SubjectPrincipalName = [string]$dstMap[$key].PrincipalName
            })
        }
    }
    return @($result | Sort-Object DiffStatus, SubjectType, SubjectDisplayName)
}

function Compare-Permissions {
    param([object]$Source, [object]$Destination)

    $srcMap = @{}
    $dstMap = @{}

    foreach ($row in $Source.AllRows) {
        $key = ('{0}|{1}|{2}' -f [string]$row.ProjectName, [string]$row.RepositoryName, [string]$row.SubjectPrincipalName).ToLowerInvariant()
        $srcMap[$key] = $row
    }
    foreach ($row in $Destination.AllRows) {
        $key = ('{0}|{1}|{2}' -f [string]$row.ProjectName, [string]$row.RepositoryName, [string]$row.SubjectPrincipalName).ToLowerInvariant()
        $dstMap[$key] = $row
    }

    $result = New-Object System.Collections.Generic.List[object]
    $allKeys = @(($srcMap.Keys + $dstMap.Keys) | Sort-Object -Unique)

    foreach ($key in $allKeys) {
        $inSrc = $srcMap.ContainsKey($key)
        $inDst = $dstMap.ContainsKey($key)

        $status = if ($inSrc -and $inDst) {
            $allowMatch = ([long]$srcMap[$key].AllowBits) -eq ([long]$dstMap[$key].AllowBits)
            $denyMatch  = ([long]$srcMap[$key].DenyBits)  -eq ([long]$dstMap[$key].DenyBits)
            if ($allowMatch -and $denyMatch) { 'Matched' } else { 'Changed' }
        }
        elseif ($inSrc) { 'Removed' }
        else             { 'Added' }

        $changes = ''
        if ($status -eq 'Changed') {
            $sa = [long]$srcMap[$key].AllowBits; $da = [long]$dstMap[$key].AllowBits
            $sd = [long]$srcMap[$key].DenyBits;  $dd = [long]$dstMap[$key].DenyBits
            $parts = @()
            if ($sa -ne $da) { $parts += ('Allow: {0} -> {1}' -f $sa, $da) }
            if ($sd -ne $dd) { $parts += ('Deny: {0} -> {1}'  -f $sd, $dd) }
            $changes = $parts -join '; '
        }

        $ref    = if ($inSrc) { $srcMap[$key] } else { $dstMap[$key] }
        $srcRow = if ($inSrc) { $srcMap[$key] } else { $null }
        $dstRow = if ($inDst) { $dstMap[$key] } else { $null }

        [void]$result.Add([PSCustomObject]@{
            DiffStatus           = $status
            ProjectName          = [string]$ref.ProjectName
            RepositoryName       = [string]$ref.RepositoryName
            SubjectType          = [string]$ref.SubjectType
            SubjectDisplayName   = [string]$ref.SubjectDisplayName
            SubjectPrincipalName = [string]$ref.SubjectPrincipalName
            SourceAllowBits      = if ($srcRow) { [long]$srcRow.AllowBits }        else { '' }
            SourceDenyBits       = if ($srcRow) { [long]$srcRow.DenyBits }         else { '' }
            SourceAllowDisplay   = if ($srcRow) { [string]$srcRow.AllowPermissions } else { '' }
            DestAllowBits        = if ($dstRow) { [long]$dstRow.AllowBits }        else { '' }
            DestDenyBits         = if ($dstRow) { [long]$dstRow.DenyBits }         else { '' }
            DestAllowDisplay     = if ($dstRow) { [string]$dstRow.AllowPermissions } else { '' }
            Changes              = $changes
        })
    }
    return @($result | Where-Object { $_.DiffStatus -ne 'Matched' } | Sort-Object DiffStatus, ProjectName, RepositoryName, SubjectDisplayName)
}

function Compare-Memberships {
    param([object]$Source, [object]$Destination)

    $srcMap = @{}
    $dstMap = @{}

    foreach ($row in $Source.MembershipRows) {
        $key = ('{0}|{1}' -f [string]$row.GroupPrincipalName, [string]$row.MemberPrincipalName).ToLowerInvariant()
        $srcMap[$key] = $row
    }
    foreach ($row in $Destination.MembershipRows) {
        $key = ('{0}|{1}' -f [string]$row.GroupPrincipalName, [string]$row.MemberPrincipalName).ToLowerInvariant()
        $dstMap[$key] = $row
    }

    $result = New-Object System.Collections.Generic.List[object]
    $allKeys = @(($srcMap.Keys + $dstMap.Keys) | Sort-Object -Unique)

    foreach ($key in $allKeys) {
        $inSrc  = $srcMap.ContainsKey($key)
        $inDst  = $dstMap.ContainsKey($key)
        $status = if ($inSrc -and $inDst) { 'Matched' } elseif ($inSrc) { 'Removed' } else { 'Added' }
        if ($status -eq 'Matched') { continue }

        $ref = if ($inSrc) { $srcMap[$key] } else { $dstMap[$key] }
        [void]$result.Add([PSCustomObject]@{
            DiffStatus          = $status
            GroupDisplayName    = [string]$ref.GroupDisplayName
            GroupPrincipalName  = [string]$ref.GroupPrincipalName
            MemberType          = [string]$ref.MemberType
            MemberDisplayName   = [string]$ref.MemberDisplayName
            MemberPrincipalName = [string]$ref.MemberPrincipalName
        })
    }
    return @($result | Sort-Object DiffStatus, GroupDisplayName, MemberDisplayName)
}

function Compare-Policies {
    param([object]$Source, [object]$Destination)

    $srcMap = @{}
    $dstMap = @{}

    foreach ($row in $Source.PolicyRows) {
        $key = ('{0}|{1}|{2}|{3}' -f [string]$row.ProjectName, [string]$row.RepositoryId, [string]$row.BranchFilter, [string]$row.PolicyType).ToLowerInvariant()
        $srcMap[$key] = $row
    }
    foreach ($row in $Destination.PolicyRows) {
        $key = ('{0}|{1}|{2}|{3}' -f [string]$row.ProjectName, [string]$row.RepositoryId, [string]$row.BranchFilter, [string]$row.PolicyType).ToLowerInvariant()
        $dstMap[$key] = $row
    }

    $result = New-Object System.Collections.Generic.List[object]
    $allKeys = @(($srcMap.Keys + $dstMap.Keys) | Sort-Object -Unique)

    foreach ($key in $allKeys) {
        $inSrc = $srcMap.ContainsKey($key)
        $inDst = $dstMap.ContainsKey($key)

        $changes = ''
        $status  = if ($inSrc -and $inDst) {
            $s = $srcMap[$key]; $d = $dstMap[$key]
            $parts = @()
            if ([string]$s.IsEnabled            -ne [string]$d.IsEnabled)            { $parts += ('IsEnabled: {0} -> {1}' -f $s.IsEnabled, $d.IsEnabled) }
            if ([string]$s.IsBlocking           -ne [string]$d.IsBlocking)           { $parts += ('IsBlocking: {0} -> {1}' -f $s.IsBlocking, $d.IsBlocking) }
            if ([string]$s.MinimumReviewerCount -ne [string]$d.MinimumReviewerCount) { $parts += ('MinReviewers: {0} -> {1}' -f $s.MinimumReviewerCount, $d.MinimumReviewerCount) }
            if ($parts.Count -gt 0) { $changes = $parts -join '; '; 'Changed' } else { 'Matched' }
        }
        elseif ($inSrc) { 'Removed' }
        else             { 'Added' }

        if ($status -eq 'Matched') { continue }

        $ref = if ($inSrc) { $srcMap[$key] } else { $dstMap[$key] }
        [void]$result.Add([PSCustomObject]@{
            DiffStatus           = $status
            ProjectName          = [string]$ref.ProjectName
            PolicyType           = [string]$ref.PolicyType
            BranchFilter         = [string]$ref.BranchFilter
            MatchKind            = [string]$ref.MatchKind
            SourceIsEnabled      = if ($inSrc) { [string]$srcMap[$key].IsEnabled }             else { '' }
            SourceIsBlocking     = if ($inSrc) { [string]$srcMap[$key].IsBlocking }            else { '' }
            SourceMinReviewers   = if ($inSrc) { [string]$srcMap[$key].MinimumReviewerCount }  else { '' }
            DestIsEnabled        = if ($inDst) { [string]$dstMap[$key].IsEnabled }             else { '' }
            DestIsBlocking       = if ($inDst) { [string]$dstMap[$key].IsBlocking }            else { '' }
            DestMinReviewers     = if ($inDst) { [string]$dstMap[$key].MinimumReviewerCount }  else { '' }
            Changes              = $changes
        })
    }
    return @($result | Sort-Object DiffStatus, ProjectName, PolicyType, BranchFilter)
}

function Compare-BuildPermissions {
    param([object]$Source, [object]$Destination)

    $srcMap = @{}
    $dstMap = @{}

    foreach ($row in $Source.BuildRows) {
        $key = ('{0}|{1}' -f [string]$row.ProjectName, [string]$row.SubjectPrincipalName).ToLowerInvariant()
        $srcMap[$key] = $row
    }
    foreach ($row in $Destination.BuildRows) {
        $key = ('{0}|{1}' -f [string]$row.ProjectName, [string]$row.SubjectPrincipalName).ToLowerInvariant()
        $dstMap[$key] = $row
    }

    $result = New-Object System.Collections.Generic.List[object]
    $allKeys = @(($srcMap.Keys + $dstMap.Keys) | Sort-Object -Unique)

    foreach ($key in $allKeys) {
        $inSrc = $srcMap.ContainsKey($key)
        $inDst = $dstMap.ContainsKey($key)

        $status = if ($inSrc -and $inDst) {
            $allowMatch = ([long]$srcMap[$key].AllowBits) -eq ([long]$dstMap[$key].AllowBits)
            $denyMatch  = ([long]$srcMap[$key].DenyBits)  -eq ([long]$dstMap[$key].DenyBits)
            if ($allowMatch -and $denyMatch) { 'Matched' } else { 'Changed' }
        }
        elseif ($inSrc) { 'Removed' }
        else             { 'Added' }

        if ($status -eq 'Matched') { continue }

        $changes = ''
        if ($status -eq 'Changed') {
            $parts = @()
            $sa = [long]$srcMap[$key].AllowBits; $da = [long]$dstMap[$key].AllowBits
            $sd = [long]$srcMap[$key].DenyBits;  $dd = [long]$dstMap[$key].DenyBits
            if ($sa -ne $da) { $parts += ('Allow: {0} -> {1}' -f $sa, $da) }
            if ($sd -ne $dd) { $parts += ('Deny: {0} -> {1}'  -f $sd, $dd) }
            $changes = $parts -join '; '
        }

        $ref    = if ($inSrc) { $srcMap[$key] } else { $dstMap[$key] }
        $srcRow = if ($inSrc) { $srcMap[$key] } else { $null }
        $dstRow = if ($inDst) { $dstMap[$key] } else { $null }

        [void]$result.Add([PSCustomObject]@{
            DiffStatus           = $status
            ProjectName          = [string]$ref.ProjectName
            SubjectType          = [string]$ref.SubjectType
            SubjectDisplayName   = [string]$ref.SubjectDisplayName
            SubjectPrincipalName = [string]$ref.SubjectPrincipalName
            SourceAllowBits      = if ($srcRow) { [long]$srcRow.AllowBits }         else { '' }
            SourceDenyBits       = if ($srcRow) { [long]$srcRow.DenyBits }          else { '' }
            SourceAllowDisplay   = if ($srcRow) { [string]$srcRow.AllowPermissions } else { '' }
            DestAllowBits        = if ($dstRow) { [long]$dstRow.AllowBits }         else { '' }
            DestDenyBits         = if ($dstRow) { [long]$dstRow.DenyBits }          else { '' }
            DestAllowDisplay     = if ($dstRow) { [string]$dstRow.AllowPermissions } else { '' }
            Changes              = $changes
        })
    }
    return @($result | Sort-Object DiffStatus, ProjectName, SubjectDisplayName)
}

function Export-ComparisonJson {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OutputRoot,

        [Parameter(Mandatory = $true)]
        [object]$Comparison
    )

    $path = Join-Path $OutputRoot 'migration-diff.json'
    $Comparison | ConvertTo-Json -Depth 12 | Set-Content -Path $path -Encoding UTF8
    Write-Log -Level 'Info' -Message ('Migration diff JSON written: {0}' -f $path)
}

function Export-ComparisonXlsx {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OutputRoot,

        [Parameter(Mandatory = $true)]
        [object]$Comparison
    )

    if (-not (Get-Module -ListAvailable -Name ImportExcel)) {
        Write-Log -Level 'Warn' -Message 'ImportExcel module not found. Installing for current user...'
        Install-Module ImportExcel -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module ImportExcel -ErrorAction Stop

    $xlsxPath = Join-Path $OutputRoot 'migration-diff.xlsx'
    if (Test-Path $xlsxPath) { Remove-Item $xlsxPath -Force }

    $diffConditionals = @(
        (New-ConditionalText -Text 'Added'   -ConditionalType ContainsText -ConditionalTextColor 'DarkGreen'  -BackgroundColor 'LightGreen'),
        (New-ConditionalText -Text 'Removed' -ConditionalType ContainsText -ConditionalTextColor 'DarkRed'    -BackgroundColor 'LightSalmon'),
        (New-ConditionalText -Text 'Changed' -ConditionalType ContainsText -ConditionalTextColor '#7B3700'    -BackgroundColor 'LightYellow'),
        (New-ConditionalText -Text 'Clean'           -ConditionalType ContainsText -ConditionalTextColor 'DarkGreen' -BackgroundColor 'LightGreen'),
        (New-ConditionalText -Text 'PermissionDrift' -ConditionalType ContainsText -ConditionalTextColor 'DarkRed'  -BackgroundColor 'LightSalmon'),
        (New-ConditionalText -Text 'StructuralChanges' -ConditionalType ContainsText -ConditionalTextColor '#7B3700' -BackgroundColor 'LightYellow')
    )

    # -- Summary sheet --
    $summaryRows = @([PSCustomObject]@{
        SourceOrganizationUrl      = $Comparison.SourceOrganizationUrl
        DestinationOrganizationUrl = $Comparison.DestinationOrganizationUrl
        SourceCapturedAt           = $Comparison.SourceCapturedAt
        DestinationCapturedAt      = $Comparison.DestinationCapturedAt
        ComparedAt                 = $Comparison.ComparedAt
        MigrationStatus            = $Comparison.MigrationStatus
        AddedRepositories          = $Comparison.Summary.AddedRepositories
        RemovedRepositories        = $Comparison.Summary.RemovedRepositories
        AddedGroups                = $Comparison.Summary.AddedGroups
        RemovedGroups              = $Comparison.Summary.RemovedGroups
        AddedPermissions           = $Comparison.Summary.AddedPermissions
        RemovedPermissions         = $Comparison.Summary.RemovedPermissions
        ChangedPermissions         = $Comparison.Summary.ChangedPermissions
        AddedBuildPerms            = $Comparison.Summary.AddedBuildPerms
        RemovedBuildPerms          = $Comparison.Summary.RemovedBuildPerms
        ChangedBuildPerms          = $Comparison.Summary.ChangedBuildPerms
        ChangedMemberships         = $Comparison.Summary.ChangedMemberships
        ChangedPolicies            = $Comparison.Summary.ChangedPolicies
    })
    $excelPackage = $summaryRows | Export-Excel -Path $xlsxPath -WorksheetName 'Summary' -TableName 'SummaryTable' `
        -AutoSize -FreezeTopRow -BoldTopRow -TableStyle Medium2 -ConditionalText $diffConditionals -PassThru

    # -- Counts sheet (side-by-side source vs destination) --
    $countConditionals = @(
        (New-ConditionalText -Text '-' -ConditionalType ContainsText -ConditionalTextColor 'DarkRed'   -BackgroundColor 'LightSalmon'),
        (New-ConditionalText -Text '+' -ConditionalType ContainsText -ConditionalTextColor 'DarkGreen' -BackgroundColor 'LightGreen')
    )
    $countsDisplay = @($Comparison.Counts | ForEach-Object {
        [PSCustomObject]@{
            Metric      = $_.Metric
            Source      = $_.Source
            Destination = $_.Destination
            Delta       = if ($_.Delta -gt 0) { "+$($_.Delta)" } elseif ($_.Delta -lt 0) { "$($_.Delta)" } else { '0' }
        }
    })
    $excelPackage = $countsDisplay | Export-Excel -ExcelPackage $excelPackage -WorksheetName 'Counts' -TableName 'CountsTable' `
        -AutoSize -FreezeTopRow -BoldTopRow -TableStyle Medium2 -ConditionalText $countConditionals -PassThru

    # -- Migration checks sheet --
    $checkConditionals = @(
        (New-ConditionalText -Text 'OK' -ConditionalType ContainsText -ConditionalTextColor 'DarkGreen' -BackgroundColor 'LightGreen'),
        (New-ConditionalText -Text 'Warn' -ConditionalType ContainsText -ConditionalTextColor '#7B3700' -BackgroundColor 'LightYellow'),
        (New-ConditionalText -Text 'Fail' -ConditionalType ContainsText -ConditionalTextColor 'DarkRed' -BackgroundColor 'LightSalmon')
    )
    $checkRows = @($Comparison.MigrationChecks)
    if (-not $checkRows -or $checkRows.Count -eq 0) {
        $checkRows = @([PSCustomObject]@{ Category = ''; Check = '(no checks)'; SourceValue = ''; DestinationValue = ''; Delta = ''; Status = ''; Details = '' })
    }
    $excelPackage = $checkRows | Export-Excel -ExcelPackage $excelPackage -WorksheetName 'MigrationChecks' -TableName 'MigrationChecksTable' `
        -AutoSize -FreezeTopRow -BoldTopRow -TableStyle Medium2 -ConditionalText $checkConditionals -PassThru

    # -- Repo changes sheet --
    $repoRows = @($Comparison.RepoChanges | Where-Object { $_.DiffStatus -ne 'Matched' })
    if (-not $repoRows -or $repoRows.Count -eq 0) {
        $repoRows = @([PSCustomObject]@{ DiffStatus = '(no changes)'; ProjectName = ''; RepositoryName = '' })
    }
    $excelPackage = $repoRows | Export-Excel -ExcelPackage $excelPackage -WorksheetName 'RepoChanges' -TableName 'RepoChangesTable' `
        -AutoSize -FreezeTopRow -BoldTopRow -TableStyle Medium2 -ConditionalText $diffConditionals -PassThru

    # -- Group changes sheet --
    $groupRows = @($Comparison.GroupChanges | Where-Object { $_.DiffStatus -ne 'Matched' })
    if (-not $groupRows -or $groupRows.Count -eq 0) {
        $groupRows = @([PSCustomObject]@{ DiffStatus = '(no changes)'; SubjectType = ''; SubjectDisplayName = ''; SubjectPrincipalName = '' })
    }
    $excelPackage = $groupRows | Export-Excel -ExcelPackage $excelPackage -WorksheetName 'GroupChanges' -TableName 'GroupChangesTable' `
        -AutoSize -FreezeTopRow -BoldTopRow -TableStyle Medium2 -ConditionalText $diffConditionals -PassThru

    # -- Permission changes sheet --
    $permRows = @($Comparison.PermissionChanges)
    if (-not $permRows -or $permRows.Count -eq 0) {
        $permRows = @([PSCustomObject]@{ DiffStatus = '(no changes)'; ProjectName = ''; RepositoryName = ''; SubjectDisplayName = '' })
    }
    $excelPackage = $permRows | Export-Excel -ExcelPackage $excelPackage -WorksheetName 'PermissionChanges' -TableName 'PermissionChangesTable' `
        -AutoSize -FreezeTopRow -BoldTopRow -TableStyle Medium2 -ConditionalText $diffConditionals -PassThru

    # -- Build permission changes sheet (always generated when BuildRows exist in either snapshot) --
    $buildRows = @($Comparison.BuildPermissionChanges)
    if (-not $buildRows -or $buildRows.Count -eq 0) {
        $buildRows = @([PSCustomObject]@{ DiffStatus = '(no changes)'; ProjectName = ''; SubjectDisplayName = '' })
    }
    $excelPackage = $buildRows | Export-Excel -ExcelPackage $excelPackage -WorksheetName 'BuildPermissions' -TableName 'BuildPermissionsTable' `
        -AutoSize -FreezeTopRow -BoldTopRow -TableStyle Medium2 -ConditionalText $diffConditionals -PassThru

    # -- Membership changes sheet (optional) --
    if ($Comparison.MembershipChanges -and $Comparison.MembershipChanges.Count -gt 0) {
        $excelPackage = $Comparison.MembershipChanges | Export-Excel -ExcelPackage $excelPackage -WorksheetName 'MembershipChanges' -TableName 'MembershipChangesTable' `
            -AutoSize -FreezeTopRow -BoldTopRow -TableStyle Medium2 -ConditionalText $diffConditionals -PassThru
    }

    # -- Policy changes sheet (optional) --
    if ($Comparison.PolicyChanges -and $Comparison.PolicyChanges.Count -gt 0) {
        $excelPackage = $Comparison.PolicyChanges | Export-Excel -ExcelPackage $excelPackage -WorksheetName 'PolicyChanges' -TableName 'PolicyChangesTable' `
            -AutoSize -FreezeTopRow -BoldTopRow -TableStyle Medium2 -ConditionalText $diffConditionals -PassThru
    }

    Close-ExcelPackage -ExcelPackage $excelPackage
    Write-Log -Level 'Info' -Message ('Migration diff XLSX written: {0}' -f $xlsxPath)
}
