# High-risk Git permission bits used for risk flag detection.
$Script:HighRiskGitBits = @(
    [PSCustomObject]@{ Bit = 1;     Name = 'Administer' },
    [PSCustomObject]@{ Bit = 8;     Name = 'ForcePush' },
    [PSCustomObject]@{ Bit = 128;   Name = 'PolicyExempt' },
    [PSCustomObject]@{ Bit = 512;   Name = 'DeleteOrDisableRepository' },
    [PSCustomObject]@{ Bit = 8192;  Name = 'ManagePermissions' },
    [PSCustomObject]@{ Bit = 32768; Name = 'BypassPoliciesWhenCompletingPR' }
)

function Get-BranchPolicies {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OrgUrl,

        [Parameter(Mandatory = $true)]
        [object[]]$Projects
    )

    $rows = New-Object System.Collections.Generic.List[object]

    foreach ($project in $Projects) {
        Assert-NotCancelled
        Write-Log -Level 'Debug' -Message ('Loading branch policies for project: {0}' -f $project.name)

        $policies = $null
        try {
            $policies = Invoke-AdoCliJson -Command (
                'az pipelines policy list --organization "{0}" --project "{1}" --output json' -f $OrgUrl, $project.name
            )
        }
        catch {
            Write-Log -Level 'Warn' -Message ('Branch policy list failed for [{0}]: {1}' -f $project.name, $_.Exception.Message)
            continue
        }

        $policyList = @()
        if ($policies -is [array])          { $policyList = $policies }
        elseif ($policies -and $policies.value) { $policyList = @($policies.value) }

        foreach ($policy in $policyList) {
            $typeDisplay = [string]$policy.type.displayName
            if ([string]::IsNullOrWhiteSpace($typeDisplay)) { $typeDisplay = [string]$policy.type.id }

            $scopes = @()
            if ($policy.settings -and $policy.settings.scope) {
                $scopes = @($policy.settings.scope)
            }

            if ($scopes.Count -eq 0) {
                [void]$rows.Add((New-PolicyRow -Project $project -Policy $policy -TypeDisplay $typeDisplay -Scope $null))
            }
            else {
                foreach ($scope in $scopes) {
                    [void]$rows.Add((New-PolicyRow -Project $project -Policy $policy -TypeDisplay $typeDisplay -Scope $scope))
                }
            }
        }
    }

    return $rows
}

function New-PolicyRow {
    param(
        [object]$Project,
        [object]$Policy,
        [string]$TypeDisplay,
        [object]$Scope
    )

    $repoId = if ($Scope) { [string]$Scope.repositoryId } else { '' }
    $branch  = if ($Scope) { [string]$Scope.refName }      else { '' }
    $match   = if ($Scope) { [string]$Scope.matchKind }    else { '' }

    $minReviewers            = ''
    $requireResolvedComments = ''
    $allowDownvotes          = ''
    $creatorVote             = ''
    $buildDefinitionId       = ''

    if ($Policy.settings) {
        if ($null -ne $Policy.settings.minimumApproverCount)    { $minReviewers            = [string]$Policy.settings.minimumApproverCount }
        if ($null -ne $Policy.settings.allowDownvotes)          { $allowDownvotes           = [string]$Policy.settings.allowDownvotes }
        if ($null -ne $Policy.settings.creatorVoteCounts)       { $creatorVote              = [string]$Policy.settings.creatorVoteCounts }
        if ($null -ne $Policy.settings.requireCommentResolution){ $requireResolvedComments  = [string]$Policy.settings.requireCommentResolution }
        if ($null -ne $Policy.settings.buildDefinitionId)       { $buildDefinitionId        = [string]$Policy.settings.buildDefinitionId }
    }

    return [PSCustomObject]@{
        ProjectName             = [string]$Project.name
        ProjectId               = [string]$Project.id
        PolicyId                = [string]$Policy.id
        PolicyType              = $TypeDisplay
        IsEnabled               = [bool]$Policy.isEnabled
        IsBlocking              = [bool]$Policy.isBlocking
        IsDeleted               = [bool]$Policy.isDeleted
        RepositoryId            = $repoId
        BranchFilter            = $branch
        MatchKind               = $match
        MinimumReviewerCount    = $minReviewers
        RequireResolvedComments = $requireResolvedComments
        AllowDownvotes          = $allowDownvotes
        CreatorVoteCounts       = $creatorVote
        BuildDefinitionId       = $buildDefinitionId
    }
}

function Get-RiskFlagRows {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[object]]$AllRows
    )

    $riskRows = New-Object System.Collections.Generic.List[object]

    foreach ($row in $AllRows) {
        $effectiveBits = if ($null -ne $row.EffectiveAllowBits -and $row.EffectiveAllowBits -ne 0) {
            [long]$row.EffectiveAllowBits
        }
        else {
            [long]$row.AllowBits
        }

        $flaggedNames = New-Object System.Collections.Generic.List[string]
        foreach ($riskBit in $Script:HighRiskGitBits) {
            if (($effectiveBits -band [long]$riskBit.Bit) -ne 0) {
                [void]$flaggedNames.Add($riskBit.Name)
            }
        }

        if ($flaggedNames.Count -eq 0) { continue }

        $riskLevel = 'Medium'
        if ($flaggedNames -contains 'Administer' -or $flaggedNames -contains 'ManagePermissions') {
            $riskLevel = 'Critical'
        }
        elseif ($flaggedNames -contains 'BypassPoliciesWhenCompletingPR' -or $flaggedNames -contains 'PolicyExempt') {
            $riskLevel = 'High'
        }

        [void]$riskRows.Add([PSCustomObject]@{
            RiskLevel            = $riskLevel
            SubjectType          = [string]$row.SubjectType
            SubjectDisplayName   = [string]$row.SubjectDisplayName
            SubjectPrincipalName = [string]$row.SubjectPrincipalName
            ProjectName          = [string]$row.ProjectName
            RepositoryName       = [string]$row.RepositoryName
            HighRiskPermissions  = ($flaggedNames | Sort-Object) -join ';'
            SubjectDescriptor    = [string]$row.SubjectDescriptor
        })
    }

    return @($riskRows | Sort-Object RiskLevel, SubjectDisplayName)
}
