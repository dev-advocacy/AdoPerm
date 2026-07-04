<#
.SYNOPSIS
Audits Azure DevOps Git repository permissions, group membership, branch policies, and risk flags.
Supports both Azure DevOps Services (cloud) and Azure DevOps Server (on-premises).

.DESCRIPTION
Collects repository ACL permissions (explicit, effective, inherited), resolves group membership,
enumerates branch policies, identifies high-risk permission assignments, exports JSON/XLSX reports
with a workbook Summary, Subjects, RiskFlags, optional GroupMembership and BranchPolicies sheets,
plus per-project detail sheets. Tracks elapsed time per step and supports safe cancellation via stop file.

The platform type (Cloud or Server) is detected automatically from the OrganizationUrl:
  - https://dev.azure.com/{org}         -> Cloud (Azure DevOps Services, modern)
  - https://{org}.visualstudio.com      -> Cloud (Azure DevOps Services, legacy)
  - https://{server}/{collection}        -> Server (Azure DevOps Server on-premises)
  - https://{server}/tfs/{collection}    -> Server (Azure DevOps Server on-premises)

.PARAMETER OrganizationUrl
Azure DevOps organization or collection URL.
  Cloud examples  : https://dev.azure.com/your-org
                    https://your-org.visualstudio.com
  Server examples : https://myserver/tfs/DefaultCollection
                    https://myserver/MyCollection

.PARAMETER PatSecureString
Personal Access Token as SecureString. If omitted, current az login context is used.
A PAT is required for Azure DevOps Server (on-premises) when az login is not applicable.

.PARAMETER ProjectName
Optional project filter. If omitted, all projects are processed.

.PARAMETER OutputFormat
Report output format: json, xlsx, or both.

.PARAMETER IncludeUsers
Includes user subjects in addition to groups.

.PARAMETER IncludeNotSetRows
Includes rows even when all permission bits are not set.

.PARAMETER IncludeGroupMembership
Resolves the members of every group and exports a GroupMembership sheet and JSON file.

.PARAMETER IncludeBranchPolicies
Enumerates branch policies for every project and exports a BranchPolicies sheet and JSON file.

.PARAMETER EnableParallel
Enables repository-level parallel collection (PowerShell 7+).

.PARAMETER ParallelThrottleLimit
Maximum number of parallel workers when -EnableParallel is used.

.PARAMETER StopFilePath
Path to cancellation file. When the file exists, script stops gracefully.

.EXAMPLE
# Azure DevOps Services (cloud) - modern URL
$pat = Read-Host "PAT" -AsSecureString
./ado_Information.ps1 -Org "https://dev.azure.com/your-org" -PatSecureString $pat

.EXAMPLE
# Azure DevOps Services (cloud) - legacy visualstudio.com URL
$pat = Read-Host "PAT" -AsSecureString
./ado_Information.ps1 -Org "https://your-org.visualstudio.com" -PatSecureString $pat

.EXAMPLE
# Azure DevOps Server (on-premises)
$pat = Read-Host "PAT" -AsSecureString
./ado_Information.ps1 -Org "https://myserver/tfs/DefaultCollection" -PatSecureString $pat

.EXAMPLE
# Full audit: users, membership, branch policies, parallel collection
./ado_Information.ps1 -Org "https://dev.azure.com/your-org" -Users -Membership -Policies -Parallel -Throttle 8 -Out both

.NOTES
Use Get-Help .\ado_Information.ps1 -Detailed for full usage.
Recommended PAT scopes for this script:
- Code (Read)
- Graph (Read)
- Security (Read) or Security (Read & manage), depending org policy.

Azure DevOps Server compatibility: 2019 and later (API version 5.1+).
#>
param(
    [Parameter(Mandatory = $true)]
    [Alias('Org')]
    [string]$OrganizationUrl,

    [Parameter(Mandatory = $false)]
    [Security.SecureString]$PatSecureString,

    [Parameter(Mandatory = $false)]
    [Alias('Project')]
    [string]$ProjectName,

    [Parameter(Mandatory = $false)]
    [Alias('Out')]
    [ValidateSet('json', 'xlsx', 'both')]
    [string]$OutputFormat = 'both',

    [Parameter(Mandatory = $false)]
    [string]$DesktopFolderName = 'ADO-Permissions-Audit',

    [Parameter(Mandatory = $false)]
    [switch]$EnableRetry,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 10)]
    [int]$RetryMaxAttempts = 3,

    [Parameter(Mandatory = $false)]
    [ValidateRange(100, 10000)]
    [int]$RetryBaseDelayMs = 500,

    [Parameter(Mandatory = $false)]
    [Alias('Users')]
    [switch]$IncludeUsers,

    [Parameter(Mandatory = $false)]
    [Alias('AllRows')]
    [switch]$IncludeNotSetRows,

    [Parameter(Mandatory = $false)]
    [Alias('Membership')]
    [switch]$IncludeGroupMembership,

    [Parameter(Mandatory = $false)]
    [Alias('Policies')]
    [switch]$IncludeBranchPolicies,

    [Parameter(Mandatory = $false)]
    [Alias('Parallel')]
    [switch]$EnableParallel,

    [Parameter(Mandatory = $false)]
    [Alias('Throttle')]
    [ValidateRange(1, 64)]
    [int]$ParallelThrottleLimit = 4,

    [Parameter(Mandatory = $false)]
    [ValidateSet('Info', 'Debug')]
    [string]$LogLevel = 'Info',

    [Parameter(Mandatory = $false)]
    [Alias('Stop')]
    [string]$StopFilePath
)

$ErrorActionPreference = 'Stop'

# Git repository security namespace in Azure DevOps.
$Script:GitNamespaceId = '2e9eb7ed-3c0a-47d4-87c1-0ffdd275fd87'

# Canonical map of Git permission bits.
$Script:GitPermissionBits = [ordered]@{
    1      = 'Administer'
    2      = 'Read'
    4      = 'Contribute'
    8      = 'ForcePush'
    16     = 'CreateBranch'
    32     = 'CreateTag'
    64     = 'ManageNote'
    128    = 'PolicyExempt'
    256    = 'CreateRepository'
    512    = 'DeleteOrDisableRepository'
    1024   = 'RenameRepository'
    2048   = 'EditPolicies'
    4096   = 'RemoveOthersLocks'
    8192   = 'ManagePermissions'
    16384  = 'ContributeToPullRequests'
    32768  = 'BypassPoliciesWhenCompletingPR'
    65536  = 'AdvancedSecurityViewAlerts'
    131072 = 'AdvancedSecurityManageDismissAlerts'
    262144 = 'AdvancedSecurityManageSettings'
    524288 = 'ManageEnterpriseLiveMigrations'
}

$Script:RunStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$Script:StepStopwatch = [System.Diagnostics.Stopwatch]::new()
$Script:CurrentStepName = ''
$Script:LogFilePath = $null
$Script:OutputRoot = $null
$Script:StopFilePath = $StopFilePath
$Script:AdoPlatform = 'Cloud'
$Script:AdoGraphApiVersion = '7.1-preview.1'
$Script:MembershipRows = @()
$Script:PolicyRows     = @()

$scriptDir = Split-Path -Parent $PSCommandPath
. (Join-Path $scriptDir 'src/ado.logging.ps1')
. (Join-Path $scriptDir 'src/ado.context.ps1')
. (Join-Path $scriptDir 'src/ado.client.ps1')
. (Join-Path $scriptDir 'src/ado.permissions.ps1')
. (Join-Path $scriptDir 'src/ado.export.ps1')
. (Join-Path $scriptDir 'src/ado.audit.ps1')
. (Join-Path $scriptDir 'src/ado.membership.ps1')
. (Join-Path $scriptDir 'src/ado.policies.ps1')
try {
    $resolved = Resolve-AdoContext -InputOrganizationUrl $OrganizationUrl -InputProjectName $ProjectName
    $OrganizationUrl = $resolved.OrganizationUrl
    $ProjectName = $resolved.ProjectName
    $Script:AdoPlatform = $resolved.PlatformType
    $Script:AdoGraphApiVersion = if ($Script:AdoPlatform -eq 'Cloud') { '7.1-preview.1' } else { '5.1-preview.1' }

    Initialize-Output -RootFolderName $DesktopFolderName

    Write-Log -Level 'Info' -Message ('Platform type: {0}' -f $Script:AdoPlatform)
    Write-Log -Level 'Info' -Message ('Using organization URL: {0}' -f $OrganizationUrl)
    if (-not [string]::IsNullOrWhiteSpace($ProjectName)) {
        Write-Log -Level 'Info' -Message ('Using project filter: {0}' -f $ProjectName)
    }
    Write-Log -Level 'Info' -Message ('Stop file path: {0} (create this file to cancel run)' -f $Script:StopFilePath)
    Write-Log -Level 'Info' -Message ('Output folder: {0}' -f $Script:OutputRoot)

    if ($PatSecureString) {
        $env:AZURE_DEVOPS_EXT_PAT = ConvertFrom-SecureStringToPlainText -Value $PatSecureString
        Write-Log -Level 'Info' -Message 'Authentication configured with PatSecureString.'
    }
    else {
        Write-Log -Level 'Info' -Message 'Authentication configured with current az login context.'
    }

    Invoke-AdoValidation -OrgUrl $OrganizationUrl

    Start-Step -Name 'Load projects'
    $projects = Get-Projects -OrgUrl $OrganizationUrl -TargetProjectName $ProjectName
    if (-not $projects -or $projects.Count -eq 0) {
        throw 'No projects found for this organization/query.'
    }
    Stop-Step -Result ('Count={0}' -f $projects.Count)

    $subjects = Get-Subjects -OrgUrl $OrganizationUrl -LoadUsers $IncludeUsers.IsPresent
    if (-not $subjects -or $subjects.Count -eq 0) {
        throw 'No subjects found to audit.'
    }
    Write-Log -Level 'Info' -Message ('Subjects loaded: {0}' -f $subjects.Count)

    Start-Step -Name 'Collect permissions'
    $audit = Invoke-Audit -OrgUrl $OrganizationUrl -Projects $projects -Subjects $subjects
    Stop-Step -Result ('Rows={0}' -f $audit.AllRows.Count)

    if ($IncludeGroupMembership.IsPresent) {
        Start-Step -Name 'Collect group membership'
        $Script:MembershipRows = @(Get-GroupMemberships -OrgUrl $OrganizationUrl -Subjects $subjects)
        Stop-Step -Result ('Rows={0}' -f $Script:MembershipRows.Count)
    }

    if ($IncludeBranchPolicies.IsPresent) {
        Start-Step -Name 'Collect branch policies'
        $Script:PolicyRows = @(Get-BranchPolicies -OrgUrl $OrganizationUrl -Projects $projects)
        Stop-Step -Result ('Rows={0}' -f $Script:PolicyRows.Count)
    }

    if ($OutputFormat -in @('json', 'both')) {
        Start-Step -Name 'Export JSON'
        foreach ($project in $projects) {
            Assert-NotCancelled
            $projectKey = [string]$project.name
            if ([string]::IsNullOrWhiteSpace($projectKey)) {
                $projectKey = [string]$project.id
            }

            Export-ProjectJson -OutputRoot $Script:OutputRoot -Project $project -Rows $audit.RowsByProject[$projectKey]
        }
        Export-SubjectsJson -OutputRoot $Script:OutputRoot -AllRows $audit.AllRows
        Export-RiskJson     -OutputRoot $Script:OutputRoot -AllRows $audit.AllRows
        if ($IncludeGroupMembership.IsPresent) {
            Export-MembershipJson -OutputRoot $Script:OutputRoot -MembershipRows $Script:MembershipRows
        }
        if ($IncludeBranchPolicies.IsPresent) {
            Export-PoliciesJson -OutputRoot $Script:OutputRoot -PolicyRows $Script:PolicyRows
        }
        Stop-Step -Result 'OK'
    }

    if ($OutputFormat -in @('xlsx', 'both')) {
        Start-Step -Name 'Export XLSX'
        Export-Xlsx -OutputRoot $Script:OutputRoot -Projects $projects -RowsByProject $audit.RowsByProject `
            -AllRows $audit.AllRows -OrgUrl $OrganizationUrl `
            -MembershipRows $Script:MembershipRows -PolicyRows $Script:PolicyRows
        Stop-Step -Result 'OK'
    }

    Write-Log -Level 'Info' -Message 'Done.'
    Write-Log -Level 'Info' -Message ('Projects processed: {0}' -f $projects.Count)
    Write-Log -Level 'Info' -Message ('Rows exported: {0}' -f $audit.AllRows.Count)
    Write-Log -Level 'Info' -Message ('Output folder: {0}' -f $Script:OutputRoot)
    Write-Log -Level 'Info' -Message ('Log file: {0}' -f $Script:LogFilePath)
}
catch {
    Stop-Step -Result 'FAILED'
    $errorType = if ($_.Exception -and $_.Exception.GetType()) { $_.Exception.GetType().FullName } else { 'UnknownException' }
    $stack = if ($_.ScriptStackTrace) { $_.ScriptStackTrace } else { 'N/A' }
    Write-Log -Level 'Error' -Message ('Execution failed: {0} | Type: {1} | Stack: {2}' -f $_.Exception.Message, $errorType, $stack)
    if (-not [string]::IsNullOrWhiteSpace($Script:LogFilePath)) {
        Write-Log -Level 'Error' -Message ('Log file: {0}' -f $Script:LogFilePath)
    }
    throw
}
finally {
    if ($Script:RunStopwatch.IsRunning) {
        $Script:RunStopwatch.Stop()
    }
}




