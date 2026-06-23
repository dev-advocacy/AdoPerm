# Azure DevOps Repository Permissions Audit

This project provides a PowerShell script that audits Azure DevOps group permissions on Git repositories.

Script file:
- testADO.ps1

The script can:
- Enumerate organization groups.
- Read Git repository ACL entries per project and repository.
- Capture explicit and inherited permissions.
- Export one JSON file per project.
- Export one Excel workbook with one worksheet per project.

## Prerequisites

Install and configure the following:

1. PowerShell 7+ (recommended)
2. Azure CLI
3. Azure DevOps Azure CLI extension
4. Access to the target Azure DevOps organization
5. Optional: ImportExcel PowerShell module (auto-installed by script when XLSX output is requested)

Minimum Azure DevOps access:
- Project and repository read access
- Security permission read access
- Graph/group read access

Authentication options:
- Interactive login with az login
- Personal Access Token (PAT) passed to the script as plain text (`-Pat`) or secure string (`-PatSecureString`)

## Files

- testADO.ps1: Main audit script
- README.md: Usage documentation

## Script Parameters

- OrganizationUrl (required): Azure DevOps organization URL
  - Example: https://dev.azure.com/your-org
- Pat (optional): Personal Access Token for Azure DevOps (plain text)
- PatSecureString (optional): Personal Access Token for Azure DevOps as `SecureString`
  - Recommended over `-Pat` when running from an interactive PowerShell session
  - If both `-Pat` and `-PatSecureString` are provided, `-PatSecureString` is used
- ProjectName (optional): If provided, limits execution to one project
- OutputFormat (optional): json, xlsx, or both (default: both)
- DesktopFolderName (optional): Output root folder name created on Windows Desktop (default: ADO-Permissions-Audit)
- EnableRetry (optional): Enables retry with exponential backoff for transient Azure CLI/API failures
- RetryMaxAttempts (optional): Max attempts when retry is enabled (default: 3)
- RetryBaseDelayMs (optional): Base delay in milliseconds for exponential backoff (default: 500)
- EnableParallel (optional): Enables parallel repository processing (PowerShell 7+)
- ParallelThrottleLimit (optional): Max parallel workers when parallel mode is enabled (default: 4)

## Basic Usage

Run for all projects, output JSON and XLSX (recommended secure method):

```powershell
$securePat = Read-Host "Enter Azure DevOps PAT" -AsSecureString
./testADO.ps1 -OrganizationUrl "https://dev.azure.com/your-org" -PatSecureString $securePat -OutputFormat both
```

Run for one project only:

```powershell
$securePat = Read-Host "Enter Azure DevOps PAT" -AsSecureString
./testADO.ps1 -OrganizationUrl "https://dev.azure.com/your-org" -PatSecureString $securePat -ProjectName "MyProject" -OutputFormat both
```

Run with interactive Azure CLI authentication (no PAT argument):

```powershell
az login
./testADO.ps1 -OrganizationUrl "https://dev.azure.com/your-org" -OutputFormat json
```

Run with PAT as SecureString (recommended):

```powershell
$securePat = Read-Host "Enter Azure DevOps PAT" -AsSecureString
./testADO.ps1 -OrganizationUrl "https://dev.azure.com/your-org" -PatSecureString $securePat -OutputFormat both
```

Run with retry and parallel processing:

```powershell
$securePat = Read-Host "Enter Azure DevOps PAT" -AsSecureString
./testADO.ps1 -OrganizationUrl "https://dev.azure.com/your-org" -PatSecureString $securePat -OutputFormat both -EnableRetry -RetryMaxAttempts 3 -RetryBaseDelayMs 500 -EnableParallel -ParallelThrottleLimit 4
```

## Command-Line Examples

Run with custom desktop output folder name:

```powershell
$securePat = Read-Host "Enter Azure DevOps PAT" -AsSecureString
./testADO.ps1 -OrganizationUrl "https://dev.azure.com/your-org" -PatSecureString $securePat -DesktopFolderName "ADO-Audit-Weekly"
```

Run only JSON export (faster):

```powershell
$securePat = Read-Host "Enter Azure DevOps PAT" -AsSecureString
./testADO.ps1 -OrganizationUrl "https://dev.azure.com/your-org" -PatSecureString $securePat -OutputFormat json
```

Run only XLSX export:

```powershell
$securePat = Read-Host "Enter Azure DevOps PAT" -AsSecureString
./testADO.ps1 -OrganizationUrl "https://dev.azure.com/your-org" -PatSecureString $securePat -OutputFormat xlsx
```

Run for one specific project:

```powershell
$securePat = Read-Host "Enter Azure DevOps PAT" -AsSecureString
./testADO.ps1 -OrganizationUrl "https://dev.azure.com/your-org" -PatSecureString $securePat -ProjectName "Platform-Core" -OutputFormat both
```

## Output Structure

The script creates this folder:

- Desktop/<DesktopFolderName>/<timestamp>

Example:

- Desktop/ADO-Permissions-Audit/20260617_153000

Generated files:

1. JSON (one file per project)
- <ProjectName>.permissions.json

2. Excel (single workbook)
- ADO_Repo_Group_Permissions.xlsx
- One worksheet per project
- Worksheet name derived from project name (sanitized and truncated to Excel limits)

## Exported Data Fields

Typical fields include:

- Organization
- ProjectName
- ProjectId
- RepositoryName
- RepositoryId
- GroupDisplayName
- GroupPrincipalName
- GroupDescriptor
- GroupOrigin
- InheritanceEnabled
- AllowBits / DenyBits
- AllowPermissions / DenyPermissions
- EffectiveAllowBits / EffectiveDenyBits
- EffectiveAllowPerms / EffectiveDenyPerms
- InheritedAllowBits / InheritedDenyBits
- InheritedAllowPerms / InheritedDenyPerms
- EffectiveAllowDisplay / EffectiveDenyDisplay (human-readable `Bits (Permissions)` format)
- InheritedAllowDisplay / InheritedDenyDisplay (human-readable `Bits (Permissions)` format)

## Notes on Inheritance

Inheritance is represented in multiple ways:

- InheritanceEnabled: Indicates whether ACL inheritance is enabled at the token level.
- Inherited* fields: Show inherited permission values when returned by Azure DevOps.
- Effective* fields: Show final effective values after inheritance is applied.

## Expected Runtime and API Limits

Execution time depends mainly on:

- Number of projects
- Number of repositories per project
- Number of ACL entries per repository token
- Azure DevOps API response time and throttling behavior

Typical guidance:

- Small organization (1-5 projects, <50 repos): usually a few minutes
- Medium organization (5-20 projects, 50-300 repos): often 5-20 minutes
- Large organization (20+ projects, 300+ repos): can take 20+ minutes

Current script behavior:

- Calls Azure DevOps APIs sequentially for reliability and simpler troubleshooting
- Produces complete data per project before moving to the next one
- May slow down when APIs return throttling responses or when network latency is high

Recommendations for large organizations:

1. Start with one project using ProjectName to estimate runtime.
2. Use OutputFormat json for faster runs when Excel output is not required.
3. Run during off-peak hours to reduce throttling risk.
4. If needed, split runs by project groups and merge outputs later.

Potential throttling indicators:

- Intermittent failures from az devops invoke
- Increased response latency over time
- Retry-like behavior required to complete all projects

If throttling becomes frequent, consider adding retry logic with exponential backoff around az devops invoke calls.

## Troubleshooting

1. Command failed: Cannot query Azure DevOps
- Verify login: az login
- Verify organization URL
- If using PAT, verify token validity and scopes

2. Azure DevOps extension not found
- Install manually: az extension add --name azure-devops

3. XLSX export fails
- Check Internet access for ImportExcel module installation
- Install manually:

```powershell
Install-Module ImportExcel -Scope CurrentUser -Force -AllowClobber
```

4. Empty output for a project
- Verify repository existence and permissions
- Verify group visibility in Graph API

## Runtime Monitoring (dotnet-counters)

You can monitor the PowerShell process used to run the script and track actual CPU usage vs available CPU count.

1. Get the process id (PID) of your running PowerShell process.
2. Start dotnet-counters with the following metrics:

```powershell
dotnet-counters monitor --counters System.Runtime[dotnet.process.cpu.usage,dotnet.process.cpu.count,dotnet.thread_pool.thread.count,dotnet.thread_pool.queue.length,dotnet.thread_pool.work_item.count] -p <PID>
```

How to read these metrics:

- `dotnet.process.cpu.usage`: real CPU usage consumed by the process (percentage).
- `dotnet.process.cpu.count`: number of logical CPUs available to the process (capacity indicator, not usage).
- `dotnet.thread_pool.thread.count`: current number of thread pool worker threads.
- `dotnet.thread_pool.queue.length`: current queued work items waiting to run.
- `dotnet.thread_pool.work_item.count`: cumulative number of work items processed since process start.

Important interpretation note:

- `queue.length = 0` with a high `work_item.count` means work has been processed and there is no backlog at the sampling moment.

## Security Recommendations

- Prefer secure secret handling for PAT values (for example, environment variables or secret vaults).
- Avoid hardcoding PAT values in scripts or source control.
- Rotate PATs regularly.

## Quick Start Checklist

1. Open PowerShell
2. Go to the project directory
3. Authenticate (az login) or prepare PAT
4. Run testADO.ps1
5. Open output files from Desktop folder
