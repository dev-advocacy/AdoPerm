function Get-GitPermissionNamesFromBits {
    param(
        [Parameter(Mandatory = $true)]
        [long]$Bits
    )

    $names = New-Object System.Collections.Generic.List[string]
    foreach ($bit in $Script:GitPermissionBits.Keys) {
        if (($Bits -band $bit) -ne 0) {
            $permissionName = [string]$Script:GitPermissionBits[$bit]
            if (-not [string]::IsNullOrWhiteSpace($permissionName)) {
                [void]$names.Add($permissionName.Trim())
            }
        }
    }

    return (($names | Select-Object -Unique) -join ';')
}

function Format-GitPermissionBitsDisplay {
    param(
        [Parameter(Mandatory = $false)]
        [Nullable[long]]$Bits
    )

    if ($null -eq $Bits) {
        return ''
    }

    $decoded = Get-GitPermissionNamesFromBits -Bits $Bits
    if ([string]::IsNullOrWhiteSpace($decoded)) {
        return 'None'
    }

    return $decoded
}

function Get-PermissionState {
    param(
        [Parameter(Mandatory = $true)]
        [long]$AllowBits,

        [Parameter(Mandatory = $true)]
        [long]$DenyBits,

        [Parameter(Mandatory = $true)]
        [long]$PermissionBit,

        [Parameter(Mandatory = $true)]
        [bool]$InheritanceEnabled
    )

    if (($DenyBits -band $PermissionBit) -ne 0) {
        return 'Deny'
    }

    if (($AllowBits -band $PermissionBit) -ne 0) {
        return 'Allow'
    }

    if ($InheritanceEnabled) {
        return 'NotSetInherited'
    }

    return 'NotSet'
}

function Get-GitPermissionStateColumnName {
    param(
        [Parameter(Mandatory = $true)]
        [long]$Bit
    )

    $permissionName = [string]$Script:GitPermissionBits[$Bit]
    if ([string]::IsNullOrWhiteSpace($permissionName)) {
        $permissionName = ('Bit_{0}' -f $Bit)
    }

    return ('State_{0}' -f $permissionName)
}

function New-PermissionStateColumns {
    param(
        [Parameter(Mandatory = $true)]
        [long]$AllowBits,

        [Parameter(Mandatory = $true)]
        [long]$DenyBits,

        [Parameter(Mandatory = $true)]
        [bool]$InheritanceEnabled
    )

    $result = [ordered]@{}
    foreach ($bit in $Script:GitPermissionBits.Keys) {
        $columnName = Get-GitPermissionStateColumnName -Bit ([long]$bit)
        $result[$columnName] = Get-PermissionState -AllowBits $AllowBits -DenyBits $DenyBits -PermissionBit ([long]$bit) -InheritanceEnabled $InheritanceEnabled
    }

    return $result
}

function Get-PermissionEntry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OrgUrl,

        [Parameter(Mandatory = $true)]
        [string]$Token,

        [Parameter(Mandatory = $true)]
        [object]$Subject
    )

    $permissionResponse = Invoke-AdoCliJson -Command (
        'az devops security permission show --organization "{0}" --id {1} --subject "{2}" --token "{3}" --output json' -f $OrgUrl, $Script:GitNamespaceId, $Subject.Descriptor, $Token
    )

    $acl = @($permissionResponse) | Select-Object -First 1
    if (-not $acl -or -not $acl.acesDictionary) {
        return $null
    }

    $ace = @($acl.acesDictionary.PSObject.Properties.Value) | Select-Object -First 1
    if (-not $ace) {
        return $null
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

    return [PSCustomObject]@{
        InheritanceEnabled = [bool]$acl.inheritPermissions
        AllowBits          = [long]$ace.allow
        DenyBits           = [long]$ace.deny
        EffectiveAllowBits = $effectiveAllowBits
        EffectiveDenyBits  = $effectiveDenyBits
        InheritedAllowBits = $inheritedAllowBits
        InheritedDenyBits  = $inheritedDenyBits
    }
}

function Test-ExportEntry {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Entry,

        [Parameter(Mandatory = $true)]
        [bool]$IncludeAll
    )

    if ($IncludeAll) {
        return $true
    }

    return (
        $Entry.AllowBits -ne 0 -or
        $Entry.DenyBits -ne 0 -or
        ($null -ne $Entry.EffectiveAllowBits -and $Entry.EffectiveAllowBits -ne 0) -or
        ($null -ne $Entry.EffectiveDenyBits -and $Entry.EffectiveDenyBits -ne 0) -or
        ($null -ne $Entry.InheritedAllowBits -and $Entry.InheritedAllowBits -ne 0) -or
        ($null -ne $Entry.InheritedDenyBits -and $Entry.InheritedDenyBits -ne 0)
    )
}

function New-AuditRow {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OrgUrl,

        [Parameter(Mandatory = $true)]
        [object]$Project,

        [Parameter(Mandatory = $true)]
        [object]$Repository,

        [Parameter(Mandatory = $true)]
        [string]$Token,

        [Parameter(Mandatory = $true)]
        [object]$Subject,

        [Parameter(Mandatory = $true)]
        [object]$Entry
    )

    $row = [ordered]@{
        Organization          = $OrgUrl
        ProjectName           = $Project.name
        ProjectId             = $Project.id
        RepositoryName        = $Repository.name
        RepositoryId          = $Repository.id
        Token                 = $Token
        SubjectType           = $Subject.SubjectType
        SubjectDisplayName    = $Subject.DisplayName
        SubjectPrincipalName  = $Subject.PrincipalName
        SubjectDescriptor     = $Subject.Descriptor
        SubjectOrigin         = $Subject.Origin
        SubjectOriginId       = $Subject.OriginId
        InheritanceEnabled    = $Entry.InheritanceEnabled
        AllowBits             = $Entry.AllowBits
        DenyBits              = $Entry.DenyBits
        AllowPermissions      = Get-GitPermissionNamesFromBits -Bits $Entry.AllowBits
        DenyPermissions       = Get-GitPermissionNamesFromBits -Bits $Entry.DenyBits
        EffectiveAllowBits    = $Entry.EffectiveAllowBits
        EffectiveDenyBits     = $Entry.EffectiveDenyBits
        InheritedAllowBits    = $Entry.InheritedAllowBits
        InheritedDenyBits     = $Entry.InheritedDenyBits
        EffectiveAllowPerms   = if ($null -ne $Entry.EffectiveAllowBits) { Get-GitPermissionNamesFromBits -Bits $Entry.EffectiveAllowBits } else { '' }
        EffectiveDenyPerms    = if ($null -ne $Entry.EffectiveDenyBits) { Get-GitPermissionNamesFromBits -Bits $Entry.EffectiveDenyBits } else { '' }
        InheritedAllowPerms   = if ($null -ne $Entry.InheritedAllowBits) { Get-GitPermissionNamesFromBits -Bits $Entry.InheritedAllowBits } else { '' }
        InheritedDenyPerms    = if ($null -ne $Entry.InheritedDenyBits) { Get-GitPermissionNamesFromBits -Bits $Entry.InheritedDenyBits } else { '' }
        EffectiveAllowDisplay = Format-GitPermissionBitsDisplay -Bits $Entry.EffectiveAllowBits
        EffectiveDenyDisplay  = Format-GitPermissionBitsDisplay -Bits $Entry.EffectiveDenyBits
        InheritedAllowDisplay = Format-GitPermissionBitsDisplay -Bits $Entry.InheritedAllowBits
        InheritedDenyDisplay  = Format-GitPermissionBitsDisplay -Bits $Entry.InheritedDenyBits
    }

    $stateColumns = New-PermissionStateColumns -AllowBits $Entry.AllowBits -DenyBits $Entry.DenyBits -InheritanceEnabled $Entry.InheritanceEnabled
    foreach ($key in $stateColumns.Keys) {
        $row[$key] = $stateColumns[$key]
    }

    return [PSCustomObject]$row
}
