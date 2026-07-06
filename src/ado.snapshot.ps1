function Invoke-Snapshot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OrgUrl,

        [Parameter(Mandatory = $true)]
        [string]$PlatformType,

        [Parameter(Mandatory = $true)]
        [object[]]$Projects,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Subjects,

        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[object]]$AllRows,

        [Parameter(Mandatory = $false)]
        [object[]]$MembershipRows = @(),

        [Parameter(Mandatory = $false)]
        [object[]]$PolicyRows = @(),

        [Parameter(Mandatory = $false)]
        [object[]]$BuildRows = @()
    )

    return [PSCustomObject]@{
        OrganizationUrl = $OrgUrl
        PlatformType    = $PlatformType
        CapturedAt      = (Get-Date -Format 'o')
        Projects        = $Projects
        Subjects        = $Subjects
        AllRows         = $AllRows
        MembershipRows  = $MembershipRows
        PolicyRows      = $PolicyRows
        BuildRows       = $BuildRows
    }
}

function Save-Snapshot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OutputPath,

        [Parameter(Mandatory = $true)]
        [object]$Snapshot
    )

    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

    @{
        OrganizationUrl    = [string]$Snapshot.OrganizationUrl
        PlatformType       = [string]$Snapshot.PlatformType
        CapturedAt         = [string]$Snapshot.CapturedAt
        HasMembership      = ($null -ne $Snapshot.MembershipRows -and @($Snapshot.MembershipRows).Count -gt 0)
        HasPolicies        = ($null -ne $Snapshot.PolicyRows -and @($Snapshot.PolicyRows).Count -gt 0)
        HasBuildPermissions = ($null -ne $Snapshot.BuildRows -and @($Snapshot.BuildRows).Count -gt 0)
        ProjectCount       = @($Snapshot.Projects).Count
        SubjectCount       = @($Snapshot.Subjects).Count
        PermissionRowCount = @($Snapshot.AllRows).Count
        BuildRowCount      = @($Snapshot.BuildRows).Count
    } | ConvertTo-Json -Depth 3 | Set-Content -Path (Join-Path $OutputPath 'snapshot.meta.json') -Encoding UTF8

    @($Snapshot.Projects) | ConvertTo-Json -Depth 8 |
        Set-Content -Path (Join-Path $OutputPath 'snapshot.projects.json') -Encoding UTF8

    @($Snapshot.Subjects) | ConvertTo-Json -Depth 8 |
        Set-Content -Path (Join-Path $OutputPath 'snapshot.subjects.json') -Encoding UTF8

    @($Snapshot.AllRows) | ConvertTo-Json -Depth 12 |
        Set-Content -Path (Join-Path $OutputPath 'snapshot.permissions.json') -Encoding UTF8

    if ($Snapshot.MembershipRows -and @($Snapshot.MembershipRows).Count -gt 0) {
        @($Snapshot.MembershipRows) | ConvertTo-Json -Depth 8 |
            Set-Content -Path (Join-Path $OutputPath 'snapshot.membership.json') -Encoding UTF8
    }

    if ($Snapshot.PolicyRows -and @($Snapshot.PolicyRows).Count -gt 0) {
        @($Snapshot.PolicyRows) | ConvertTo-Json -Depth 8 |
            Set-Content -Path (Join-Path $OutputPath 'snapshot.policies.json') -Encoding UTF8
    }

    if ($Snapshot.BuildRows -and @($Snapshot.BuildRows).Count -gt 0) {
        @($Snapshot.BuildRows) | ConvertTo-Json -Depth 8 |
            Set-Content -Path (Join-Path $OutputPath 'snapshot.build.json') -Encoding UTF8
    }

    Write-Log -Level 'Info' -Message ('Snapshot saved to: {0} ({1} rows, {2} subjects)' -f $OutputPath, @($Snapshot.AllRows).Count, @($Snapshot.Subjects).Count)
}

function Import-Snapshot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SnapshotPath
    )

    if (-not (Test-Path $SnapshotPath)) {
        throw ('Snapshot path not found: {0}' -f $SnapshotPath)
    }

    $metaPath = Join-Path $SnapshotPath 'snapshot.meta.json'
    if (-not (Test-Path $metaPath)) {
        throw ('snapshot.meta.json not found in: {0}' -f $SnapshotPath)
    }

    $meta     = Get-Content $metaPath -Raw | ConvertFrom-Json
    $projects = @(Get-Content (Join-Path $SnapshotPath 'snapshot.projects.json') -Raw | ConvertFrom-Json)
    $subjects = @(Get-Content (Join-Path $SnapshotPath 'snapshot.subjects.json') -Raw | ConvertFrom-Json)

    $allRows = [System.Collections.Generic.List[object]]::new()
    $permPath = Join-Path $SnapshotPath 'snapshot.permissions.json'
    if (Test-Path $permPath) {
        @(Get-Content $permPath -Raw | ConvertFrom-Json) | ForEach-Object { [void]$allRows.Add($_) }
    }

    $membershipRows = @()
    $memberPath = Join-Path $SnapshotPath 'snapshot.membership.json'
    if (Test-Path $memberPath) {
        $membershipRows = @(Get-Content $memberPath -Raw | ConvertFrom-Json)
    }

    $policyRows = @()
    $policyPath = Join-Path $SnapshotPath 'snapshot.policies.json'
    if (Test-Path $policyPath) {
        $policyRows = @(Get-Content $policyPath -Raw | ConvertFrom-Json)
    }

    $buildRows = @()
    $buildPath = Join-Path $SnapshotPath 'snapshot.build.json'
    if (Test-Path $buildPath) {
        $buildRows = @(Get-Content $buildPath -Raw | ConvertFrom-Json)
    }

    Write-Log -Level 'Info' -Message ('Snapshot loaded: {0} (org: {1}, captured: {2}, rows: {3})' -f $SnapshotPath, $meta.OrganizationUrl, $meta.CapturedAt, $allRows.Count)

    return [PSCustomObject]@{
        OrganizationUrl = [string]$meta.OrganizationUrl
        PlatformType    = [string]$meta.PlatformType
        CapturedAt      = [string]$meta.CapturedAt
        Projects        = $projects
        Subjects        = $subjects
        AllRows         = $allRows
        MembershipRows  = $membershipRows
        PolicyRows      = $policyRows
        BuildRows       = $buildRows
    }
}
