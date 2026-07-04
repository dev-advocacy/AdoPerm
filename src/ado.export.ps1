function Export-ProjectJson {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OutputRoot,

        [Parameter(Mandatory = $true)]
        [object]$Project,

        [Parameter(Mandatory = $true)]
        [object[]]$Rows
    )

    $safeProjectName = ($Project.name -replace '[\\/:*?"<>|]', '_')
    $path = Join-Path $OutputRoot ('{0}.permissions.json' -f $safeProjectName)
    $Rows | ConvertTo-Json -Depth 12 | Set-Content -Path $path -Encoding UTF8
    Write-Log -Level 'Info' -Message ('JSON written: {0}' -f $path)
}

function Get-WorkbookVisibleColumns {
    return @(
        'Organization',
        'ProjectName',
        'RepositoryName',
        'SubjectType',
        'SubjectDisplayName',
        'SubjectPrincipalName',
        'InheritanceEnabled',
        'AllowPermissions',
        'DenyPermissions',
        'EffectiveAllowDisplay',
        'EffectiveDenyDisplay',
        'InheritedAllowDisplay',
        'InheritedDenyDisplay'
    )
}

function Get-WorkbookTechnicalColumns {
    return @(
        'ProjectId',
        'RepositoryId',
        'Token',
        'SubjectDescriptor',
        'SubjectOrigin',
        'SubjectOriginId',
        'AllowBits',
        'DenyBits',
        'EffectiveAllowBits',
        'EffectiveDenyBits',
        'InheritedAllowBits',
        'InheritedDenyBits',
        'EffectiveAllowPerms',
        'EffectiveDenyPerms',
        'InheritedAllowPerms',
        'InheritedDenyPerms'
    )
}

function Get-WorkbookStateColumns {
    $columns = New-Object System.Collections.Generic.List[string]
    foreach ($bit in $Script:GitPermissionBits.Keys) {
        [void]$columns.Add((Get-GitPermissionStateColumnName -Bit ([long]$bit)))
    }

    return $columns
}

function New-WorkbookLegendRows {
    return @(
        [PSCustomObject]@{ Item = 'Allow'; Meaning = 'Permission granted'; Color = 'LightGreen' },
        [PSCustomObject]@{ Item = 'Deny'; Meaning = 'Permission explicitly denied'; Color = 'LightSalmon' },
        [PSCustomObject]@{ Item = 'NotSet'; Meaning = 'No explicit permission set'; Color = 'LightGray' },
        [PSCustomObject]@{ Item = 'NotSetInherited'; Meaning = 'No explicit permission; inherited context'; Color = 'Khaki' }
    )
}

function Get-WorkbookSubjectsColumns {
    return @(
        'SubjectType',
        'SubjectDisplayName',
        'SubjectPrincipalName',
        'SubjectOrigin',
        'ProjectCount',
        'RepositoryCount',
        'AllowAssignments',
        'DenyAssignments',
        'CombinedEffectiveAllowDisplay',
        'CombinedEffectiveDenyDisplay',
        'SubjectDescriptor',
        'CombinedEffectiveAllowBits',
        'CombinedEffectiveDenyBits'
    )
}

function New-WorkbookSubjectsRows {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[object]]$AllRows
    )

    $subjectRows = New-Object System.Collections.Generic.List[object]

    $grouped = $AllRows | Group-Object -Property SubjectDescriptor, SubjectPrincipalName, SubjectDisplayName

    foreach ($group in $grouped) {
        $rows = @($group.Group)
        $first = $rows | Select-Object -First 1

        $projects = @($rows | ForEach-Object { $_.ProjectName } |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique)
        $repos = @($rows | ForEach-Object { $_.RepositoryId } |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique)

        $combinedEffectiveAllow = [long]0
        $combinedEffectiveDeny = [long]0
        foreach ($row in $rows) {
            if ($null -ne $row.EffectiveAllowBits) { $combinedEffectiveAllow = $combinedEffectiveAllow -bor [long]$row.EffectiveAllowBits }
            if ($null -ne $row.EffectiveDenyBits)  { $combinedEffectiveDeny  = $combinedEffectiveDeny  -bor [long]$row.EffectiveDenyBits  }
        }

        [void]$subjectRows.Add([PSCustomObject]@{
            SubjectType                   = [string]$first.SubjectType
            SubjectDisplayName            = [string]$first.SubjectDisplayName
            SubjectPrincipalName          = [string]$first.SubjectPrincipalName
            SubjectDescriptor             = [string]$first.SubjectDescriptor
            SubjectOrigin                 = [string]$first.SubjectOrigin
            ProjectCount                  = $projects.Count
            RepositoryCount               = $repos.Count
            AllowAssignments              = @($rows | Where-Object { $_.AllowBits -ne 0 }).Count
            DenyAssignments               = @($rows | Where-Object { $_.DenyBits -ne 0 }).Count
            CombinedEffectiveAllowBits    = $combinedEffectiveAllow
            CombinedEffectiveDenyBits     = $combinedEffectiveDeny
            CombinedEffectiveAllowDisplay = Format-GitPermissionBitsDisplay -Bits $combinedEffectiveAllow
            CombinedEffectiveDenyDisplay  = Format-GitPermissionBitsDisplay -Bits $combinedEffectiveDeny
        })
    }

    return @($subjectRows | Sort-Object SubjectType, SubjectDisplayName)
}

function Export-SubjectsJson {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OutputRoot,

        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[object]]$AllRows
    )

    $rows = @(New-WorkbookSubjectsRows -AllRows $AllRows)
    $path = Join-Path $OutputRoot 'subjects.permissions.json'
    $rows | ConvertTo-Json -Depth 12 | Set-Content -Path $path -Encoding UTF8
    Write-Log -Level 'Info' -Message ('Subjects JSON written: {0}' -f $path)
}

function Export-MembershipJson {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OutputRoot,

        [Parameter(Mandatory = $true)]
        [object[]]$MembershipRows
    )

    $path = Join-Path $OutputRoot 'group.membership.json'
    $MembershipRows | ConvertTo-Json -Depth 12 | Set-Content -Path $path -Encoding UTF8
    Write-Log -Level 'Info' -Message ('Membership JSON written: {0}' -f $path)
}

function Export-PoliciesJson {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OutputRoot,

        [Parameter(Mandatory = $true)]
        [object[]]$PolicyRows
    )

    $path = Join-Path $OutputRoot 'branch.policies.json'
    $PolicyRows | ConvertTo-Json -Depth 12 | Set-Content -Path $path -Encoding UTF8
    Write-Log -Level 'Info' -Message ('Branch policies JSON written: {0}' -f $path)
}

function Export-RiskJson {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OutputRoot,

        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[object]]$AllRows
    )

    $rows = @(Get-RiskFlagRows -AllRows $AllRows)
    $path = Join-Path $OutputRoot 'risk.flags.json'
    $rows | ConvertTo-Json -Depth 12 | Set-Content -Path $path -Encoding UTF8
    Write-Log -Level 'Info' -Message ('Risk flags JSON written: {0}' -f $path)
}

function ConvertTo-SafeExcelTableName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $safeName = [string]$Name
    if ([string]::IsNullOrWhiteSpace($safeName)) {
        return 'T_Table'
    }

    $safeName = $safeName -replace '[^A-Za-z0-9_]', '_'
    if (-not ($safeName -match '^[A-Za-z_]')) {
        $safeName = 'T_{0}' -f $safeName
    }

    if ($safeName.Length -gt 255) {
        $safeName = $safeName.Substring(0, 255)
    }

    return $safeName
}

function Get-WorkbookSummaryColumns {
    return @(
        'Organization',
        'ProjectName',
        'ProjectId',
        'RepositoryCount',
        'SubjectCount',
        'UserCount',
        'GroupCount',
        'AuditRows',
        'RowsWithAllowBits',
        'RowsWithDenyBits',
        'RowsWithAnyPermissionBits',
        'RowsWithInheritanceEnabled'
    )
}

function New-WorkbookSummaryRows {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OrgUrl,

        [Parameter(Mandatory = $true)]
        [object[]]$Projects,

        [Parameter(Mandatory = $true)]
        [hashtable]$RowsByProject
    )

    $summaryRows = New-Object System.Collections.Generic.List[object]

    foreach ($project in $Projects) {
        $projectKey = [string]$project.name
        if ([string]::IsNullOrWhiteSpace($projectKey)) {
            $projectKey = [string]$project.id
        }

        $projectRows = @()
        if ($RowsByProject.ContainsKey($projectKey)) {
            $projectRows = @($RowsByProject[$projectKey])
        }

        $repositoryIds = @(
            $projectRows |
                ForEach-Object { $_.RepositoryId } |
                Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
                Sort-Object -Unique
        )

        $subjectKeys = @(
            $projectRows |
                ForEach-Object {
                    if (-not [string]::IsNullOrWhiteSpace([string]$_.SubjectDescriptor)) {
                        return [string]$_.SubjectDescriptor
                    }

                    if (-not [string]::IsNullOrWhiteSpace([string]$_.SubjectPrincipalName)) {
                        return [string]$_.SubjectPrincipalName
                    }

                    return [string]$_.SubjectDisplayName
                } |
                Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
                Sort-Object -Unique
        )

        $rowsWithAllowBits = @($projectRows | Where-Object { $_.AllowBits -ne 0 }).Count
        $rowsWithDenyBits = @($projectRows | Where-Object { $_.DenyBits -ne 0 }).Count
        $rowsWithAnyPermissionBits = @($projectRows | Where-Object {
            $_.AllowBits -ne 0 -or
            $_.DenyBits -ne 0 -or
            ($null -ne $_.EffectiveAllowBits -and $_.EffectiveAllowBits -ne 0) -or
            ($null -ne $_.EffectiveDenyBits -and $_.EffectiveDenyBits -ne 0) -or
            ($null -ne $_.InheritedAllowBits -and $_.InheritedAllowBits -ne 0) -or
            ($null -ne $_.InheritedDenyBits -and $_.InheritedDenyBits -ne 0)
        }).Count
        $rowsWithInheritanceEnabled = @($projectRows | Where-Object { $_.InheritanceEnabled }).Count

        [void]$summaryRows.Add([PSCustomObject]@{
            Organization               = $OrgUrl
            ProjectName                = [string]$project.name
            ProjectId                  = [string]$project.id
            RepositoryCount            = $repositoryIds.Count
            SubjectCount               = $subjectKeys.Count
            UserCount                  = @($projectRows | Where-Object { $_.SubjectType -eq 'User' }).Count
            GroupCount                 = @($projectRows | Where-Object { $_.SubjectType -eq 'Group' }).Count
            AuditRows                  = $projectRows.Count
            RowsWithAllowBits          = $rowsWithAllowBits
            RowsWithDenyBits           = $rowsWithDenyBits
            RowsWithAnyPermissionBits  = $rowsWithAnyPermissionBits
            RowsWithInheritanceEnabled = $rowsWithInheritanceEnabled
        })
    }

    return $summaryRows.ToArray()
}

function Get-WorkbookRepositoryMatrixColumns {
    return @(
        'Organization',
        'ProjectName',
        'RepositoryName',
        'RepositoryId',
        'SubjectAssignments',
        'DistinctSubjects',
        'UserSubjects',
        'GroupSubjects',
        'AllowAssignments',
        'DenyAssignments',
        'RowsWithAnyPermissionBits',
        'RowsWithInheritanceEnabled'
    )
}

function New-WorkbookRepositoryMatrixRows {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OrgUrl,

        [Parameter(Mandatory = $true)]
        [object]$Project,

        [Parameter(Mandatory = $true)]
        [object[]]$ProjectRows
    )

    $matrixRows = New-Object System.Collections.Generic.List[object]

    $repositoryGroups = $ProjectRows | Group-Object -Property RepositoryId, RepositoryName
    foreach ($group in $repositoryGroups) {
        $repoRows = @($group.Group)
        $firstRow = $repoRows | Select-Object -First 1

        $distinctSubjects = @(
            $repoRows |
                ForEach-Object {
                    if (-not [string]::IsNullOrWhiteSpace([string]$_.SubjectDescriptor)) {
                        return [string]$_.SubjectDescriptor
                    }

                    if (-not [string]::IsNullOrWhiteSpace([string]$_.SubjectPrincipalName)) {
                        return [string]$_.SubjectPrincipalName
                    }

                    return [string]$_.SubjectDisplayName
                } |
                Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
                Sort-Object -Unique
        )

        [void]$matrixRows.Add([PSCustomObject]@{
            Organization              = $OrgUrl
            ProjectName               = [string]$project.name
            RepositoryName            = [string]$firstRow.RepositoryName
            RepositoryId              = [string]$firstRow.RepositoryId
            SubjectAssignments        = $repoRows.Count
            DistinctSubjects          = $distinctSubjects.Count
            UserSubjects              = @($repoRows | Where-Object { $_.SubjectType -eq 'User' } | ForEach-Object { $_.SubjectDescriptor } | Sort-Object -Unique).Count
            GroupSubjects             = @($repoRows | Where-Object { $_.SubjectType -eq 'Group' } | ForEach-Object { $_.SubjectDescriptor } | Sort-Object -Unique).Count
            AllowAssignments          = @($repoRows | Where-Object { $_.AllowBits -ne 0 }).Count
            DenyAssignments           = @($repoRows | Where-Object { $_.DenyBits -ne 0 }).Count
            RowsWithAnyPermissionBits = @($repoRows | Where-Object {
                $_.AllowBits -ne 0 -or
                $_.DenyBits -ne 0 -or
                ($null -ne $_.EffectiveAllowBits -and $_.EffectiveAllowBits -ne 0) -or
                ($null -ne $_.EffectiveDenyBits -and $_.EffectiveDenyBits -ne 0) -or
                ($null -ne $_.InheritedAllowBits -and $_.InheritedAllowBits -ne 0) -or
                ($null -ne $_.InheritedDenyBits -and $_.InheritedDenyBits -ne 0)
            }).Count
            RowsWithInheritanceEnabled = @($repoRows | Where-Object { $_.InheritanceEnabled }).Count
        })
    }

    return $matrixRows.ToArray()
}

function Export-Xlsx {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OutputRoot,

        [Parameter(Mandatory = $true)]
        [object[]]$Projects,

        [Parameter(Mandatory = $true)]
        [hashtable]$RowsByProject,

        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[object]]$AllRows,

        [Parameter(Mandatory = $true)]
        [string]$OrgUrl,

        [Parameter(Mandatory = $false)]
        [object[]]$MembershipRows = @(),

        [Parameter(Mandatory = $false)]
        [object[]]$PolicyRows = @()
    )

    if (-not (Get-Module -ListAvailable -Name ImportExcel)) {
        Write-Log -Level 'Warn' -Message 'ImportExcel module not found. Installing for current user...'
        Install-Module ImportExcel -Scope CurrentUser -Force -AllowClobber
    }

    Import-Module ImportExcel -ErrorAction Stop

    $xlsxPath = Join-Path $OutputRoot 'ADO_Repo_Permissions.xlsx'
    if (Test-Path $xlsxPath) {
        Remove-Item $xlsxPath -Force
    }

    $summaryColumns = Get-WorkbookSummaryColumns
    $summaryRows = @(New-WorkbookSummaryRows -OrgUrl $OrgUrl -Projects $Projects -RowsByProject $RowsByProject)
    if (-not $summaryRows -or $summaryRows.Count -eq 0) {
        $summaryRows = @([PSCustomObject]@{
            Organization               = $OrgUrl
            ProjectName                = ''
            ProjectId                  = ''
            RepositoryCount            = 0
            SubjectCount               = 0
            UserCount                  = 0
            GroupCount                 = 0
            AuditRows                  = 0
            RowsWithAllowBits          = 0
            RowsWithDenyBits           = 0
            RowsWithAnyPermissionBits  = 0
            RowsWithInheritanceEnabled = 0
        })
    }

    $visibleColumns = Get-WorkbookVisibleColumns
    $stateColumns = Get-WorkbookStateColumns
    $technicalColumns = Get-WorkbookTechnicalColumns
    $orderedColumns = @($visibleColumns + $stateColumns + $technicalColumns)
    $matrixColumns = Get-WorkbookRepositoryMatrixColumns

    $legendRows = New-WorkbookLegendRows
    $statusStyles = @(
        @{ Text = 'Allow'; BackgroundColor = 'LightGreen'; FontColor = 'DarkGreen' },
        @{ Text = 'Deny'; BackgroundColor = 'LightPink'; FontColor = 'DarkRed' },
        @{ Text = 'NotSet'; BackgroundColor = 'LightGray'; FontColor = 'DimGray' },
        @{ Text = 'NotSetInherited'; BackgroundColor = 'Khaki'; FontColor = 'SaddleBrown' }
    )

    $sheetNameSet = @{}
    $excelPackage = $null

    $summarySheet = 'Summary'
    if ($sheetNameSet.ContainsKey($summarySheet)) {
        $summarySheet = 'Summary_1'
    }
    $sheetNameSet[$summarySheet] = $true

    $summaryTableName = ConvertTo-SafeExcelTableName -Name 'SummaryTable'
    $excelPackage = $summaryRows | Export-Excel -Path $xlsxPath -WorksheetName $summarySheet -TableName $summaryTableName -AutoSize -FreezeTopRow -BoldTopRow -TableStyle Medium2 -PassThru

    $summaryColumnWidths = @{
        Organization               = 28
        ProjectName                = 24
        ProjectId                  = 24
        RepositoryCount            = 16
        SubjectCount               = 14
        UserCount                  = 12
        GroupCount                 = 12
        AuditRows                  = 12
        RowsWithAllowBits          = 18
        RowsWithDenyBits           = 17
        RowsWithAnyPermissionBits  = 22
        RowsWithInheritanceEnabled = 22
    }

    foreach ($summaryColumn in $summaryColumns) {
        if ($summaryColumnWidths.ContainsKey($summaryColumn)) {
            $summaryIndex = [Array]::IndexOf($summaryColumns, $summaryColumn) + 1
            if ($summaryIndex -gt 0) {
                Set-ExcelColumn -ExcelPackage $excelPackage -Worksheetname $summarySheet -Column $summaryIndex -Width $summaryColumnWidths[$summaryColumn]
            }
        }
    }

    # ---- Subjects sheet (groups and users with aggregated permissions) ----
    $subjectsSheet = 'Subjects'
    if ($sheetNameSet.ContainsKey($subjectsSheet)) { $subjectsSheet = 'Subjects_1' }
    $sheetNameSet[$subjectsSheet] = $true

    $subjectsColumns       = Get-WorkbookSubjectsColumns
    $subjectsVisibleCols   = @('SubjectType','SubjectDisplayName','SubjectPrincipalName','SubjectOrigin',
                                'ProjectCount','RepositoryCount','AllowAssignments','DenyAssignments',
                                'CombinedEffectiveAllowDisplay','CombinedEffectiveDenyDisplay')
    $subjectsTechnicalCols = @('SubjectDescriptor','CombinedEffectiveAllowBits','CombinedEffectiveDenyBits')

    $subjectsRows = @(New-WorkbookSubjectsRows -AllRows $AllRows)
    if (-not $subjectsRows -or $subjectsRows.Count -eq 0) {
        $subjectsRows = @([PSCustomObject]@{
            SubjectType                   = ''
            SubjectDisplayName            = ''
            SubjectPrincipalName          = ''
            SubjectDescriptor             = ''
            SubjectOrigin                 = ''
            ProjectCount                  = 0
            RepositoryCount               = 0
            AllowAssignments              = 0
            DenyAssignments               = 0
            CombinedEffectiveAllowBits    = 0
            CombinedEffectiveDenyBits     = 0
            CombinedEffectiveAllowDisplay = ''
            CombinedEffectiveDenyDisplay  = ''
        })
    }

    $subjectsTableName = ConvertTo-SafeExcelTableName -Name 'SubjectsTable'
    $excelPackage = $subjectsRows | Export-Excel -ExcelPackage $excelPackage -WorksheetName $subjectsSheet `
        -TableName $subjectsTableName -AutoSize -FreezeTopRow -BoldTopRow -TableStyle Medium2 -PassThru

    foreach ($techCol in $subjectsTechnicalCols) {
        $techIdx = [Array]::IndexOf($subjectsColumns, $techCol) + 1
        if ($techIdx -gt 0) {
            Set-ExcelColumn -ExcelPackage $excelPackage -Worksheetname $subjectsSheet -Column $techIdx -Hide
        }
    }

    $subjectsColumnWidths = @{
        SubjectType                   = 12
        SubjectDisplayName            = 32
        SubjectPrincipalName          = 36
        SubjectOrigin                 = 14
        ProjectCount                  = 14
        RepositoryCount               = 16
        AllowAssignments              = 18
        DenyAssignments               = 16
        CombinedEffectiveAllowDisplay = 42
        CombinedEffectiveDenyDisplay  = 42
    }

    foreach ($col in $subjectsVisibleCols) {
        if ($subjectsColumnWidths.ContainsKey($col)) {
            $colIdx = [Array]::IndexOf($subjectsColumns, $col) + 1
            if ($colIdx -gt 0) {
                Set-ExcelColumn -ExcelPackage $excelPackage -Worksheetname $subjectsSheet -Column $colIdx -Width $subjectsColumnWidths[$col]
            }
        }
    }
    # ---- end Subjects sheet ----

    foreach ($project in $Projects) {
        Assert-NotCancelled

        $projectKey = [string]$project.name
        if ([string]::IsNullOrWhiteSpace($projectKey)) {
            $projectKey = [string]$project.id
        }

        $projectRows = @()
        if ($RowsByProject.ContainsKey($projectKey)) {
            $projectRows = @($RowsByProject[$projectKey])
        }

        $matrixRows = @(New-WorkbookRepositoryMatrixRows -OrgUrl $OrgUrl -Project $project -ProjectRows $projectRows)
        if (-not $matrixRows -or $matrixRows.Count -eq 0) {
            $matrixRows = @([PSCustomObject]@{
                Organization               = $OrgUrl
                ProjectName                = [string]$project.name
                RepositoryName             = ''
                RepositoryId               = ''
                SubjectAssignments         = 0
                DistinctSubjects           = 0
                UserSubjects               = 0
                GroupSubjects              = 0
                AllowAssignments           = 0
                DenyAssignments            = 0
                RowsWithAnyPermissionBits  = 0
                RowsWithInheritanceEnabled = 0
            })
        }

        $matrixBaseSheetName = ('Matrix_{0}' -f $project.name) -replace '[\u0000-\u001f\\/\[\]\:\*\?]', '_'
        if ($matrixBaseSheetName.Length -gt 31) {
            $matrixBaseSheetName = $matrixBaseSheetName.Substring(0, 31)
        }
        if ([string]::IsNullOrWhiteSpace($matrixBaseSheetName)) {
            $matrixBaseSheetName = 'Matrix'
        }

        $matrixSheetName = $matrixBaseSheetName
        $i = 1
        while ($sheetNameSet.ContainsKey($matrixSheetName)) {
            $suffix = '_{0}' -f $i
            $maxBase = 31 - $suffix.Length
            $trimmed = if ($matrixBaseSheetName.Length -gt $maxBase) { $matrixBaseSheetName.Substring(0, $maxBase) } else { $matrixBaseSheetName }
            $matrixSheetName = '{0}{1}' -f $trimmed, $suffix
            $i++
        }

        $sheetNameSet[$matrixSheetName] = $true

        $matrixTableName = ConvertTo-SafeExcelTableName -Name ('Matrix_{0}' -f $project.id)
        $excelPackage = $matrixRows | Export-Excel -ExcelPackage $excelPackage -WorksheetName $matrixSheetName -TableName $matrixTableName -AutoSize -FreezeTopRow -BoldTopRow -TableStyle Medium2 -PassThru

        $matrixColumnWidths = @{
            Organization               = 28
            ProjectName                = 24
            RepositoryName             = 28
            RepositoryId               = 24
            SubjectAssignments         = 16
            DistinctSubjects           = 16
            UserSubjects               = 12
            GroupSubjects              = 12
            AllowAssignments           = 16
            DenyAssignments            = 15
            RowsWithAnyPermissionBits  = 22
            RowsWithInheritanceEnabled = 22
        }

        foreach ($matrixColumn in $matrixColumns) {
            if ($matrixColumnWidths.ContainsKey($matrixColumn)) {
                $matrixIndex = [Array]::IndexOf($matrixColumns, $matrixColumn) + 1
                if ($matrixIndex -gt 0) {
                    Set-ExcelColumn -ExcelPackage $excelPackage -Worksheetname $matrixSheetName -Column $matrixIndex -Width $matrixColumnWidths[$matrixColumn]
                }
            }
        }
    }

    foreach ($project in $Projects) {
        Assert-NotCancelled

        $projectData = @($AllRows | Where-Object { $_.ProjectName -eq $project.name })
        if (-not $projectData -or $projectData.Count -eq 0) {
            $projectData = @([PSCustomObject]@{
                Organization       = $OrgUrl
                ProjectName        = $project.name
                RepositoryName     = ''
                SubjectType        = ''
                SubjectDisplayName = ''
            })
        }

        $projectData = @($projectData | Select-Object $orderedColumns)

        $baseSheetName = $project.name -replace '[\[\]\:\*\?\/\\]', '_'
        if ($baseSheetName.Length -gt 31) {
            $baseSheetName = $baseSheetName.Substring(0, 31)
        }
        if ([string]::IsNullOrWhiteSpace($baseSheetName)) {
            $baseSheetName = 'Project'
        }

        $sheetName = $baseSheetName
        $i = 1
        while ($sheetNameSet.ContainsKey($sheetName)) {
            $suffix = '_{0}' -f $i
            $maxBase = 31 - $suffix.Length
            $trimmed = if ($baseSheetName.Length -gt $maxBase) { $baseSheetName.Substring(0, $maxBase) } else { $baseSheetName }
            $sheetName = '{0}{1}' -f $trimmed, $suffix
            $i++
        }

        $sheetNameSet[$sheetName] = $true

        $sheetConditionalRules = New-Object System.Collections.Generic.List[object]
        foreach ($stateColumn in $stateColumns) {
            $columnIndex = [Array]::IndexOf($orderedColumns, $stateColumn) + 1
            if ($columnIndex -le 0) {
                continue
            }

            $columnLetter = (Get-ExcelColumnName $columnIndex).ColumnName
            $range = '{0}2:{0}1048576' -f $columnLetter
            foreach ($style in $statusStyles) {
                [void]$sheetConditionalRules.Add((New-ConditionalText -Text $style.Text -ConditionalType Equal -ConditionalTextColor $style.FontColor -BackgroundColor $style.BackgroundColor -Range $range))
            }
        }

        $tableName = ConvertTo-SafeExcelTableName -Name ('T_{0}' -f $sheetName)

        if ($null -eq $excelPackage) {
            $excelPackage = $projectData | Export-Excel -Path $xlsxPath -WorksheetName $sheetName -TableName $tableName -AutoSize -FreezeTopRow -BoldTopRow -TableStyle Medium2 -ConditionalText $sheetConditionalRules -PassThru
        }
        else {
            $excelPackage = $projectData | Export-Excel -ExcelPackage $excelPackage -WorksheetName $sheetName -TableName $tableName -AutoSize -FreezeTopRow -BoldTopRow -TableStyle Medium2 -ConditionalText $sheetConditionalRules -PassThru
        }

        foreach ($technicalColumn in $technicalColumns) {
            $techIndex = [Array]::IndexOf($orderedColumns, $technicalColumn) + 1
            if ($techIndex -gt 0) {
                Set-ExcelColumn -ExcelPackage $excelPackage -Worksheetname $sheetName -Column $techIndex -Hide
            }
        }

        $columnWidths = @{
            Organization          = 28
            ProjectName           = 24
            RepositoryName        = 28
            SubjectType           = 12
            SubjectDisplayName    = 28
            SubjectPrincipalName  = 34
            InheritanceEnabled    = 14
            AllowPermissions      = 28
            DenyPermissions       = 28
            EffectiveAllowDisplay = 28
            EffectiveDenyDisplay  = 28
            InheritedAllowDisplay = 28
            InheritedDenyDisplay  = 28
        }

        foreach ($visibleColumn in $visibleColumns) {
            if ($columnWidths.ContainsKey($visibleColumn)) {
                $visibleIndex = [Array]::IndexOf($orderedColumns, $visibleColumn) + 1
                if ($visibleIndex -gt 0) {
                    Set-ExcelColumn -ExcelPackage $excelPackage -Worksheetname $sheetName -Column $visibleIndex -Width $columnWidths[$visibleColumn]
                }
            }
        }

        foreach ($stateColumn in $stateColumns) {
            $stateIndex = [Array]::IndexOf($orderedColumns, $stateColumn) + 1
            if ($stateIndex -gt 0) {
                Set-ExcelColumn -ExcelPackage $excelPackage -Worksheetname $sheetName -Column $stateIndex -Width 18 -WrapText -Hide
            }
        }
    }

    # ---- Risk Flags sheet (always generated from existing permission rows) ----
    $riskSheet = 'RiskFlags'
    if ($sheetNameSet.ContainsKey($riskSheet)) { $riskSheet = 'RiskFlags_1' }
    $sheetNameSet[$riskSheet] = $true

    $riskAllCols = @('RiskLevel','SubjectType','SubjectDisplayName','SubjectPrincipalName',
                      'ProjectName','RepositoryName','HighRiskPermissions','SubjectDescriptor')
    $riskRows = @(Get-RiskFlagRows -AllRows $AllRows)
    if (-not $riskRows -or $riskRows.Count -eq 0) {
        $riskRows = @([PSCustomObject]@{
            RiskLevel=''; SubjectType=''; SubjectDisplayName=''; SubjectPrincipalName='';
            ProjectName=''; RepositoryName=''; HighRiskPermissions=''; SubjectDescriptor=''
        })
    }
    $riskTableName = ConvertTo-SafeExcelTableName -Name 'RiskFlagsTable'
    $excelPackage = $riskRows | Export-Excel -ExcelPackage $excelPackage -WorksheetName $riskSheet `
        -TableName $riskTableName -AutoSize -FreezeTopRow -BoldTopRow -TableStyle Medium6 -PassThru

    $riskTechIdx = [Array]::IndexOf($riskAllCols, 'SubjectDescriptor') + 1
    if ($riskTechIdx -gt 0) {
        Set-ExcelColumn -ExcelPackage $excelPackage -Worksheetname $riskSheet -Column $riskTechIdx -Hide
    }
    $riskColWidths = @{
        RiskLevel           = 12; SubjectType        = 10; SubjectDisplayName  = 32
        SubjectPrincipalName = 36; ProjectName       = 24; RepositoryName     = 28
        HighRiskPermissions  = 50
    }
    foreach ($col in $riskColWidths.Keys) {
        $idx = [Array]::IndexOf($riskAllCols, $col) + 1
        if ($idx -gt 0) { Set-ExcelColumn -ExcelPackage $excelPackage -Worksheetname $riskSheet -Column $idx -Width $riskColWidths[$col] }
    }
    # ---- end Risk Flags sheet ----

    # ---- Group Membership sheet (optional, populated with -IncludeGroupMembership) ----
    if ($MembershipRows -and $MembershipRows.Count -gt 0) {
        $memberSheet = 'GroupMembership'
        if ($sheetNameSet.ContainsKey($memberSheet)) { $memberSheet = 'GroupMembership_1' }
        $sheetNameSet[$memberSheet] = $true

        $memberAllCols = @('GroupDisplayName','GroupPrincipalName','GroupDescriptor',
                            'MemberType','MemberDisplayName','MemberPrincipalName','MemberDescriptor','MemberOrigin')
        $memberTableName = ConvertTo-SafeExcelTableName -Name 'MembershipTable'
        $excelPackage = $MembershipRows | Export-Excel -ExcelPackage $excelPackage -WorksheetName $memberSheet `
            -TableName $memberTableName -AutoSize -FreezeTopRow -BoldTopRow -TableStyle Medium2 -PassThru

        foreach ($techCol in @('GroupDescriptor','MemberDescriptor')) {
            $idx = [Array]::IndexOf($memberAllCols, $techCol) + 1
            if ($idx -gt 0) { Set-ExcelColumn -ExcelPackage $excelPackage -Worksheetname $memberSheet -Column $idx -Hide }
        }
        $memberColWidths = @{
            GroupDisplayName    = 32; GroupPrincipalName  = 36; MemberType         = 10
            MemberDisplayName   = 32; MemberPrincipalName = 36; MemberOrigin       = 14
        }
        foreach ($col in $memberColWidths.Keys) {
            $idx = [Array]::IndexOf($memberAllCols, $col) + 1
            if ($idx -gt 0) { Set-ExcelColumn -ExcelPackage $excelPackage -Worksheetname $memberSheet -Column $idx -Width $memberColWidths[$col] }
        }
    }
    # ---- end Group Membership sheet ----

    # ---- Branch Policies sheet (optional, populated with -IncludeBranchPolicies) ----
    if ($PolicyRows -and $PolicyRows.Count -gt 0) {
        $policySheet = 'BranchPolicies'
        if ($sheetNameSet.ContainsKey($policySheet)) { $policySheet = 'BranchPolicies_1' }
        $sheetNameSet[$policySheet] = $true

        $policyAllCols = @('ProjectName','ProjectId','PolicyId','PolicyType','IsEnabled','IsBlocking','IsDeleted',
                            'RepositoryId','BranchFilter','MatchKind','MinimumReviewerCount',
                            'RequireResolvedComments','AllowDownvotes','CreatorVoteCounts','BuildDefinitionId')
        $policyTableName = ConvertTo-SafeExcelTableName -Name 'BranchPoliciesTable'
        $excelPackage = $PolicyRows | Export-Excel -ExcelPackage $excelPackage -WorksheetName $policySheet `
            -TableName $policyTableName -AutoSize -FreezeTopRow -BoldTopRow -TableStyle Medium2 -PassThru

        foreach ($techCol in @('ProjectId','RepositoryId','PolicyId','BuildDefinitionId')) {
            $idx = [Array]::IndexOf($policyAllCols, $techCol) + 1
            if ($idx -gt 0) { Set-ExcelColumn -ExcelPackage $excelPackage -Worksheetname $policySheet -Column $idx -Hide }
        }
        $policyColWidths = @{
            ProjectName             = 24; PolicyType              = 36; IsEnabled              = 10
            IsBlocking              = 12; IsDeleted               = 10; BranchFilter           = 32
            MatchKind               = 12; MinimumReviewerCount    = 18; RequireResolvedComments = 22
            AllowDownvotes          = 14; CreatorVoteCounts       = 18
        }
        foreach ($col in $policyColWidths.Keys) {
            $idx = [Array]::IndexOf($policyAllCols, $col) + 1
            if ($idx -gt 0) { Set-ExcelColumn -ExcelPackage $excelPackage -Worksheetname $policySheet -Column $idx -Width $policyColWidths[$col] }
        }
    }
    # ---- end Branch Policies sheet ----

    $legendSheet = 'Legend'
    $legendData = @($legendRows)
    if ($sheetNameSet.ContainsKey($legendSheet)) {
        $legendSheet = 'Legend_1'
    }

    $legendTableName = ConvertTo-SafeExcelTableName -Name 'LegendTable'
    $excelPackage = $legendData | Export-Excel -ExcelPackage $excelPackage -WorksheetName $legendSheet -TableName $legendTableName -AutoSize -FreezeTopRow -BoldTopRow -TableStyle Medium2 -PassThru

    Close-ExcelPackage -ExcelPackage $excelPackage

    Write-Log -Level 'Info' -Message ('XLSX written: {0}' -f $xlsxPath)
}
