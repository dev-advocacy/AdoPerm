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
                $orgUrl = '{0}://{1}/{2}' -f $uri.Scheme, $uri.Host, $segments[0]
            }

            if ([string]::IsNullOrWhiteSpace($derivedProjectName) -and $segments.Count -ge 2) {
                $derivedProjectName = [System.Uri]::UnescapeDataString($segments[1])
            }
        }
    }
    catch {
        # Keep original values when URL parsing fails.
    }

    return [PSCustomObject]@{
        OrganizationUrl = $orgUrl
        ProjectName     = $derivedProjectName
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

function Initialize-Output {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootFolderName
    )

    $desktopPath = [Environment]::GetFolderPath('Desktop')
    $runStamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $Script:OutputRoot = Join-Path $desktopPath ('{0}\{1}' -f $RootFolderName, $runStamp)
    New-Item -ItemType Directory -Path $Script:OutputRoot -Force | Out-Null

    if ([string]::IsNullOrWhiteSpace($Script:StopFilePath)) {
        $Script:StopFilePath = Join-Path $Script:OutputRoot 'STOP'
    }

    $Script:LogFilePath = Join-Path $Script:OutputRoot 'audit.log'
    New-Item -ItemType File -Path $Script:LogFilePath -Force | Out-Null
}
