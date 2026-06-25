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
        [string]$OrgUrl
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
