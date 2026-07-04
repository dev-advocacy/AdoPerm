<#
.SYNOPSIS
Compares Azure DevOps permissions before and after a migration.
Supports cloud-to-cloud, on-prem-to-cloud, cloud-to-on-prem, and on-prem-to-on-prem scenarios.

.DESCRIPTION
Operates in three modes:
  - Snapshot : Capture permissions/membership/policies from a source and/or destination org.
  - Compare  : Load two previously saved snapshots and produce a diff report.
  - Full     : Capture source snapshot, capture destination snapshot, then compare (default).

The platform type (Cloud or Server) is detected automatically from each URL:
  - https://dev.azure.com/{org}         -> Cloud (Azure DevOps Services, modern)
  - https://{org}.visualstudio.com      -> Cloud (Azure DevOps Services, legacy)
  - https://{server}/{collection}        -> Server (Azure DevOps Server on-premises)
  - https://{server}/tfs/{collection}    -> Server (Azure DevOps Server on-premises)

Output (per run):
  - source-snapshot/    : JSON snapshot files for the source organization
  - dest-snapshot/      : JSON snapshot files for the destination organization
  - migration-diff.json : Full diff result
  - migration-diff.xlsx : Excel workbook with diff sheets

.PARAMETER Mode
Execution mode: Snapshot, Compare, or Full (default: Full).

.PARAMETER SourceOrganizationUrl
Source Azure DevOps organization or collection URL.

.PARAMETER SourcePat
PAT for the source organization as SecureString.

.PARAMETER DestinationOrganizationUrl
Destination Azure DevOps organization or collection URL.

.PARAMETER DestinationPat
PAT for the destination organization as SecureString.

.PARAMETER ProjectName
Optional project name to scope both source and destination to the same project.

.PARAMETER SourceSnapshotPath
Path to an existing source snapshot folder (used in Compare mode).

.PARAMETER DestinationSnapshotPath
Path to an existing destination snapshot folder (used in Compare mode).

.PARAMETER IncludeGroupMembership
Resolves group members and includes them in snapshots and the diff.

.PARAMETER IncludeBranchPolicies
Collects branch policies and includes them in snapshots and the diff.

.PARAMETER OutputFormat
Report output format: json, xlsx, or both (default: both).

.PARAMETER DesktopFolderName
Output root folder name created on Windows Desktop (default: ADO-Migration-Audit).

.EXAMPLE
# Full migration comparison: on-prem -> cloud
$srcPat = Read-Host "Source PAT" -AsSecureString
$dstPat = Read-Host "Destination PAT" -AsSecureString
./ado_Migration.ps1 -Mode Full `
    -SourceOrganizationUrl "https://myserver/tfs/DefaultCollection" -SourcePat $srcPat `
    -DestinationOrganizationUrl "https://dev.azure.com/my-new-org" -DestinationPat $dstPat `
    -Membership -Policies -Out both

.EXAMPLE
# Snapshot only (source)
$srcPat = Read-Host "Source PAT" -AsSecureString
./ado_Migration.ps1 -Mode Snapshot `
    -SourceOrganizationUrl "https://myserver/tfs/DefaultCollection" -SourcePat $srcPat

.EXAMPLE
# Compare two existing snapshots
./ado_Migration.ps1 -Mode Compare `
    -SourceSnapshotPath "C:\ADO-Migration-Audit\20260704_090000\source-snapshot" `
    -DestinationSnapshotPath "C:\ADO-Migration-Audit\20260705_090000\dest-snapshot"

.NOTES
Recommended PAT scopes:
- Code (Read)
- Graph (Read)
- Security (Read) or Security (Read & manage)
Azure DevOps Server compatibility: 2019 and later.
#>
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet('Snapshot', 'Compare', 'Full')]
    [string]$Mode = 'Full',

    [Parameter(Mandatory = $false)]
    [Alias('SrcOrg')]
    [string]$SourceOrganizationUrl,

    [Parameter(Mandatory = $false)]
    [Alias('SrcPat')]
    [Security.SecureString]$SourcePat,

    [Parameter(Mandatory = $false)]
    [Alias('DstOrg')]
    [string]$DestinationOrganizationUrl,

    [Parameter(Mandatory = $false)]
    [Alias('DstPat')]
    [Security.SecureString]$DestinationPat,

    [Parameter(Mandatory = $false)]
    [Alias('Project')]
    [string]$ProjectName,

    [Parameter(Mandatory = $false)]
    [string]$SourceSnapshotPath,

    [Parameter(Mandatory = $false)]
    [string]$DestinationSnapshotPath,

    [Parameter(Mandatory = $false)]
    [Alias('Membership')]
    [switch]$IncludeGroupMembership,

    [Parameter(Mandatory = $false)]
    [Alias('Policies')]
    [switch]$IncludeBranchPolicies,

    [Parameter(Mandatory = $false)]
    [Alias('Build')]
    [switch]$IncludeBuildPermissions,

    [Parameter(Mandatory = $false)]
    [switch]$EnableRetry,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 10)]
    [int]$RetryMaxAttempts = 3,

    [Parameter(Mandatory = $false)]
    [ValidateRange(100, 10000)]
    [int]$RetryBaseDelayMs = 500,

    [Parameter(Mandatory = $false)]
    [Alias('Out')]
    [ValidateSet('json', 'xlsx', 'both')]
    [string]$OutputFormat = 'both',

    [Parameter(Mandatory = $false)]
    [string]$DesktopFolderName = 'ADO-Migration-Audit',

    [Parameter(Mandatory = $false)]
    [ValidateSet('Info', 'Debug')]
    [string]$LogLevel = 'Info',

    [Parameter(Mandatory = $false)]
    [Alias('Stop')]
    [string]$StopFilePath
)

$ErrorActionPreference = 'Stop'

$Script:GitNamespaceId    = '2e9eb7ed-3c0a-47d4-87c1-0ffdd275fd87'
$Script:BuildNamespaceId   = '33344d9c-fc72-4d6f-aba5-fa317101a7e8'
$Script:GitPermissionBits = [ordered]@{
    1      = 'Administer'; 2 = 'Read'; 4 = 'Contribute'; 8 = 'ForcePush'
    16     = 'CreateBranch'; 32 = 'CreateTag'; 64 = 'ManageNote'; 128 = 'PolicyExempt'
    256    = 'CreateRepository'; 512 = 'DeleteOrDisableRepository'; 1024 = 'RenameRepository'
    2048   = 'EditPolicies'; 4096 = 'RemoveOthersLocks'; 8192 = 'ManagePermissions'
    16384  = 'ContributeToPullRequests'; 32768 = 'BypassPoliciesWhenCompletingPR'
    65536  = 'AdvancedSecurityViewAlerts'; 131072 = 'AdvancedSecurityManageDismissAlerts'
    262144 = 'AdvancedSecurityManageSettings'; 524288 = 'ManageEnterpriseLiveMigrations'
}

$Script:RunStopwatch      = [System.Diagnostics.Stopwatch]::StartNew()
$Script:StepStopwatch     = [System.Diagnostics.Stopwatch]::new()
$Script:CurrentStepName   = ''
$Script:LogFilePath       = $null
$Script:OutputRoot        = $null
$Script:StopFilePath      = $StopFilePath
$Script:AdoPlatform       = 'Cloud'
$Script:AdoGraphApiVersion = '7.1-preview.1'
$Script:HighRiskGitBits   = @()

$scriptDir = Split-Path -Parent $PSCommandPath
. (Join-Path $scriptDir 'src/ado.logging.ps1')
. (Join-Path $scriptDir 'src/ado.context.ps1')
. (Join-Path $scriptDir 'src/ado.client.ps1')
. (Join-Path $scriptDir 'src/ado.permissions.ps1')
. (Join-Path $scriptDir 'src/ado.export.ps1')
. (Join-Path $scriptDir 'src/ado.audit.ps1')
. (Join-Path $scriptDir 'src/ado.membership.ps1')
. (Join-Path $scriptDir 'src/ado.policies.ps1')
. (Join-Path $scriptDir 'src/ado.snapshot.ps1')
. (Join-Path $scriptDir 'src/ado.compare.ps1')

# ------------------------------------------------------------------
# Helper: collect all data for one organization and return a snapshot
# ------------------------------------------------------------------
function Invoke-SnapshotCollection {
    param(
        [string]$OrgUrl,
        [Security.SecureString]$Pat,
        [string]$ProjectFilter
    )

    # Resolve context and detect platform
    $ctx = Resolve-AdoContext -InputOrganizationUrl $OrgUrl -InputProjectName $ProjectFilter
    $Script:AdoPlatform        = $ctx.PlatformType
    $Script:AdoGraphApiVersion = if ($ctx.PlatformType -eq 'Cloud') { '7.1-preview.1' } else { '5.1-preview.1' }

    Write-Log -Level 'Info' -Message ('Platform: {0} | URL: {1}' -f $ctx.PlatformType, $ctx.OrganizationUrl)

    # Authenticate
    if ($Pat) {
        $env:AZURE_DEVOPS_EXT_PAT = ConvertFrom-SecureStringToPlainText -Value $Pat
        Write-Log -Level 'Info' -Message 'Authentication: PAT provided.'
    }
    else {
        Write-Log -Level 'Info' -Message 'Authentication: using current az login context.'
    }

    Start-Step -Name ('Validate: {0}' -f $ctx.OrganizationUrl)
    Invoke-AdoValidation -OrgUrl $ctx.OrganizationUrl
    Stop-Step -Result 'OK'

    Start-Step -Name 'Load projects'
    $projects = Get-Projects -OrgUrl $ctx.OrganizationUrl -TargetProjectName $ctx.ProjectName
    if (-not $projects -or $projects.Count -eq 0) { throw 'No projects found.' }
    Stop-Step -Result ('Count={0}' -f $projects.Count)

    $subjects = Get-Subjects -OrgUrl $ctx.OrganizationUrl -LoadUsers $false
    Write-Log -Level 'Info' -Message ('Subjects loaded: {0}' -f $subjects.Count)

    Start-Step -Name 'Collect permissions'
    $audit = Invoke-Audit -OrgUrl $ctx.OrganizationUrl -Projects $projects -Subjects $subjects
    Stop-Step -Result ('Rows={0}' -f $audit.AllRows.Count)

    $membershipRows = @()
    if ($IncludeGroupMembership.IsPresent) {
        Start-Step -Name 'Collect group membership'
        $membershipRows = @(Get-GroupMemberships -OrgUrl $ctx.OrganizationUrl -Subjects $subjects)
        Stop-Step -Result ('Rows={0}' -f $membershipRows.Count)
    }

    $policyRows = @()
    if ($IncludeBranchPolicies.IsPresent) {
        Start-Step -Name 'Collect branch policies'
        $policyRows = @(Get-BranchPolicies -OrgUrl $ctx.OrganizationUrl -Projects $projects)
        Stop-Step -Result ('Rows={0}' -f $policyRows.Count)
    }

    $buildRows = @()
    if ($IncludeBuildPermissions.IsPresent) {
        Start-Step -Name 'Collect build permissions'
        $buildRows = @(Get-BuildPermissions -OrgUrl $ctx.OrganizationUrl -Projects $projects -Subjects $subjects)
        Stop-Step -Result ('Rows={0}' -f $buildRows.Count)
    }

    return Invoke-Snapshot -OrgUrl $ctx.OrganizationUrl -PlatformType $ctx.PlatformType `
        -Projects $projects -Subjects $subjects -AllRows $audit.AllRows `
        -MembershipRows $membershipRows -PolicyRows $policyRows -BuildRows $buildRows
}

# ------------------------------------------------------------------
# Main execution
# ------------------------------------------------------------------
try {
    # Validate parameter combinations
    if ($Mode -in @('Full', 'Snapshot') -and [string]::IsNullOrWhiteSpace($SourceOrganizationUrl)) {
        throw 'SourceOrganizationUrl is required for Snapshot and Full modes.'
    }
    if ($Mode -eq 'Full' -and [string]::IsNullOrWhiteSpace($DestinationOrganizationUrl)) {
        throw 'DestinationOrganizationUrl is required for Full mode.'
    }
    if ($Mode -eq 'Compare' -and ([string]::IsNullOrWhiteSpace($SourceSnapshotPath) -or [string]::IsNullOrWhiteSpace($DestinationSnapshotPath))) {
        throw 'SourceSnapshotPath and DestinationSnapshotPath are required for Compare mode.'
    }

    # Initialize output folder
    $desktopPath = [Environment]::GetFolderPath('Desktop')
    $runStamp    = Get-Date -Format 'yyyyMMdd_HHmmss'
    $Script:OutputRoot = Join-Path $desktopPath ('{0}\{1}' -f $DesktopFolderName, $runStamp)
    New-Item -ItemType Directory -Path $Script:OutputRoot -Force | Out-Null

    if ([string]::IsNullOrWhiteSpace($Script:StopFilePath)) {
        $Script:StopFilePath = Join-Path $Script:OutputRoot 'STOP'
    }

    $Script:LogFilePath = Join-Path $Script:OutputRoot 'migration.log'
    New-Item -ItemType File -Path $Script:LogFilePath -Force | Out-Null

    Write-Log -Level 'Info' -Message ('Mode: {0}' -f $Mode)
    Write-Log -Level 'Info' -Message ('Output folder: {0}' -f $Script:OutputRoot)

    $sourceSnapshot      = $null
    $destinationSnapshot = $null

    # ---------- SNAPSHOT PHASE ----------
    if ($Mode -in @('Full', 'Snapshot')) {
        Write-Log -Level 'Info' -Message '--- Source snapshot ---'
        $sourceSnapshot = Invoke-SnapshotCollection -OrgUrl $SourceOrganizationUrl -Pat $SourcePat -ProjectFilter $ProjectName
        $srcPath = Join-Path $Script:OutputRoot 'source-snapshot'
        Save-Snapshot -OutputPath $srcPath -Snapshot $sourceSnapshot
    }

    if ($Mode -eq 'Full') {
        Write-Log -Level 'Info' -Message '--- Destination snapshot ---'
        $destinationSnapshot = Invoke-SnapshotCollection -OrgUrl $DestinationOrganizationUrl -Pat $DestinationPat -ProjectFilter $ProjectName
        $dstPath = Join-Path $Script:OutputRoot 'dest-snapshot'
        Save-Snapshot -OutputPath $dstPath -Snapshot $destinationSnapshot
    }

    # ---------- LOAD PHASE (Compare mode) ----------
    if ($Mode -eq 'Compare') {
        Write-Log -Level 'Info' -Message 'Loading source snapshot...'
        $sourceSnapshot = Import-Snapshot -SnapshotPath $SourceSnapshotPath

        Write-Log -Level 'Info' -Message 'Loading destination snapshot...'
        $destinationSnapshot = Import-Snapshot -SnapshotPath $DestinationSnapshotPath
    }

    # ---------- COMPARE PHASE ----------
    if ($Mode -in @('Full', 'Compare')) {
        Assert-NotCancelled

        Start-Step -Name 'Compare snapshots'
        $comparison = Compare-Snapshots -Source $sourceSnapshot -Destination $destinationSnapshot
        Stop-Step -Result ('Status={0}' -f $comparison.MigrationStatus)

        Write-Log -Level 'Info' -Message ('Migration status : {0}' -f $comparison.MigrationStatus)
        Write-Log -Level 'Info' -Message ('Repo changes     : +{0} / -{1}' -f $comparison.Summary.AddedRepositories, $comparison.Summary.RemovedRepositories)
        Write-Log -Level 'Info' -Message ('Group changes    : +{0} / -{1}' -f $comparison.Summary.AddedGroups, $comparison.Summary.RemovedGroups)
        Write-Log -Level 'Info' -Message ('Permission drift : +{0} / -{1} / ~{2}' -f $comparison.Summary.AddedPermissions, $comparison.Summary.RemovedPermissions, $comparison.Summary.ChangedPermissions)

        if ($OutputFormat -in @('json', 'both')) {
            Start-Step -Name 'Export diff JSON'
            Export-ComparisonJson -OutputRoot $Script:OutputRoot -Comparison $comparison
            Stop-Step -Result 'OK'
        }

        if ($OutputFormat -in @('xlsx', 'both')) {
            Start-Step -Name 'Export diff XLSX'
            Export-ComparisonXlsx -OutputRoot $Script:OutputRoot -Comparison $comparison
            Stop-Step -Result 'OK'
        }
    }

    Write-Log -Level 'Info' -Message 'Done.'
    Write-Log -Level 'Info' -Message ('Output folder : {0}' -f $Script:OutputRoot)
    Write-Log -Level 'Info' -Message ('Log file      : {0}' -f $Script:LogFilePath)
}
catch {
    Stop-Step -Result 'FAILED'
    $errorType = if ($_.Exception -and $_.Exception.GetType()) { $_.Exception.GetType().FullName } else { 'UnknownException' }
    $stack     = if ($_.ScriptStackTrace) { $_.ScriptStackTrace } else { 'N/A' }
    Write-Log -Level 'Error' -Message ('Execution failed: {0} | Type: {1} | Stack: {2}' -f $_.Exception.Message, $errorType, $stack)
    if (-not [string]::IsNullOrWhiteSpace($Script:LogFilePath)) {
        Write-Log -Level 'Error' -Message ('Log file: {0}' -f $Script:LogFilePath)
    }
    throw
}
finally {
    if ($Script:RunStopwatch.IsRunning) { $Script:RunStopwatch.Stop() }
    # Clear PAT from environment to avoid leakage
    if ($env:AZURE_DEVOPS_EXT_PAT) { $env:AZURE_DEVOPS_EXT_PAT = $null }
}
