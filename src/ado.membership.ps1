function Get-GroupMemberships {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OrgUrl,

        [Parameter(Mandatory = $true)]
        [object[]]$Subjects
    )

    $rows = New-Object System.Collections.Generic.List[object]
    $groups = @($Subjects | Where-Object {
        $_.SubjectType -eq 'Group' -and -not [string]::IsNullOrWhiteSpace($_.Descriptor)
    })
    Write-Log -Level 'Info' -Message ('Resolving membership for {0} groups.' -f $groups.Count)

    foreach ($group in $groups) {
        Assert-NotCancelled

        $response = $null
        try {
            $response = Invoke-AdoCliJson -Command (
                'az devops security group membership list --organization "{0}" --id "{1}" --relationship members --output json' -f $OrgUrl, $group.Descriptor
            )
        }
        catch {
            Write-Log -Level 'Warn' -Message ('Membership list failed for [{0}]: {1}' -f $group.DisplayName, $_.Exception.Message)
            continue
        }

        $members = @()
        if ($response -and $response.PSObject.Properties.Name.Count -gt 0) {
            $members = @($response.PSObject.Properties.Value)
        }

        if ($members.Count -eq 0) {
            [void]$rows.Add([PSCustomObject]@{
                GroupDisplayName    = [string]$group.DisplayName
                GroupPrincipalName  = [string]$group.PrincipalName
                GroupDescriptor     = [string]$group.Descriptor
                MemberType          = ''
                MemberDisplayName   = '(empty group)'
                MemberPrincipalName = ''
                MemberDescriptor    = ''
                MemberOrigin        = ''
            })
            continue
        }

        foreach ($member in $members) {
            $memberType = if ([string]$member.subjectKind -eq 'group') { 'Group' } else { 'User' }
            [void]$rows.Add([PSCustomObject]@{
                GroupDisplayName    = [string]$group.DisplayName
                GroupPrincipalName  = [string]$group.PrincipalName
                GroupDescriptor     = [string]$group.Descriptor
                MemberType          = $memberType
                MemberDisplayName   = [string]$member.displayName
                MemberPrincipalName = [string]$member.principalName
                MemberDescriptor    = [string]$member.descriptor
                MemberOrigin        = [string]$member.origin
            })
        }
    }

    return $rows
}
