function New-A365TrustReceipt {
    param(
        [string[]]$Scopes, [string]$TenantTarget, [string]$ClientId, [string]$DelegatedClientId,
        [bool]$FixtureMode, [object]$Policy, [object]$Allowlist
    )
    foreach ($scope in $Scopes) {
        if ($scope -notin $Policy.maximumRequestedScopes) { throw "Scope exceeds the published permission boundary: $scope" }
    }
    $boundary = @{
        'Organization.Read.All' = @('Tenant and subscription metadata', 'Read organization properties, not only licensing aggregates.')
        'User.Read.All' = @('Count enabled service-plan assignments', 'Read all users full profiles. The grant is not restricted to license counts.')
        'RoleManagement.Read.Directory' = @('Read active management role assignments', 'Read directory role-management settings and assignments across the directory.')
        'RoleEligibilitySchedule.Read.Directory' = @('Read PIM eligibility when selected', 'Read directory role eligibility schedules, not only Agent 365 roles.')
        'ServiceHealth.Read.All' = @('Read service health', 'Read tenant service-health information.')
        'CopilotPackages.Read.All' = @('Summarize the package catalog', 'Read Copilot package catalog metadata beyond this summary.')
        'AgentIdentityBlueprint.Read.All' = @('Summarize blueprints and owners', 'Read agent identity blueprints across the directory, not only pilot agents.')
        'Application.Read.All' = @('Read blueprint sponsors', 'Read applications and service principals across the directory.')
        'Policy.Read.All' = @('Read security defaults and Conditional Access', 'Read organization policies beyond those used by this tool.')
        'ThreatHunting.Read.All' = @('Run aggregate-only hunting queries', 'Run advanced hunting and read results available to the account. The permission is not limited to aggregates.')
        'AuditLogsQuery.Read.All' = @('Create and read an aggregate audit query', 'Query audit logs across supported workloads. The grant is not limited to these operations or the local counts.')
    }
    $context = $null
    if (-not $FixtureMode -and (Get-Command Get-MgContext -ErrorAction SilentlyContinue)) {
        $context = Get-MgContext -ErrorAction Stop
    }
    $requestedClient = if ($ClientId) { $ClientId } elseif ($DelegatedClientId) { $DelegatedClientId } else { 'SDK default; actual identity is recorded after authentication' }
    $applicationName = if ($ClientId) { 'Operator-supplied certificate application; verify the registration with your administrator' } elseif ($DelegatedClientId) { 'Operator-supplied delegated application; verify in the consent dialog' } else { 'Microsoft Graph PowerShell SDK default client; verify in the consent dialog' }
    $plannedReuse = -not $ClientId -and $context -and (Test-A365ReusableDelegatedContext -Context $context -Scopes $Scopes -TenantId $TenantTarget -DelegatedClientId $DelegatedClientId)
    if ($plannedReuse) {
        $requestedClient = Get-A365Property $context ClientId $requestedClient
        $applicationName = Get-A365Property $context AppName $applicationName
    }
    [pscustomobject][ordered]@{
        Version = '2.0'
        Classification = 'Local unsigned execution disclosure, not a signed attestation'
        Mode = if ($FixtureMode) { 'Offline fixture' } elseif ($ClientId) { 'CertificateAppOnly' } else { 'InteractiveDelegated' }
        TenantTarget = $TenantTarget
        ClientId = $requestedClient
        ApplicationName = $applicationName
        Account = Get-A365Property $context Account
        ContextScope = 'Process'
        ReusedContext = [bool]$plannedReuse
        Grants = 'Existing versus newly established tenant grants: unknown. A local token scope list is not a tenant consent inventory.'
        Permissions = @(
            foreach ($scope in $Scopes) {
                [pscustomobject]@{ Scope = $scope; Purpose = $boundary[$scope][0]; MaximumBoundary = $boundary[$scope][1] }
            }
        )
        AllowedGraphGetPaths = @($Allowlist.graph.GET)
        AllowedQueryPostPaths = @($Allowlist.graph.POST)
        AllowedWorkloadCommands = $Allowlist.modules
        QueryPersistence = 'Defender hunting uses POST to execute aggregate queries. Purview Audit Search POST creates a server-side query job, which may continue after timeout and is retained by the service. This tool does not delete query jobs.'
        Consent = 'No tenant configuration remediation. Interactive consent can establish persistent application grants. Read permissions are broader than the data this tool retains.'
        LocalArtifacts = 'Full HTML/JSON, optional sharing copies, a resume helper and operator-exported answer bundles. No raw prompts, messages, files, audit records or hunting rows are persisted.'
        TokenCaveat = 'Process context limits SDK session reuse. WAM, browser and broker sign-in state can outlive this process. Ending the process does not revoke tenant consent.'
        Offboarding = 'Disconnect-MgGraph or end the process; handle local reports and answers under your retention policy; clear this report site storage; optionally remove unused modules; ask an admin to review grants. Never automatically revoke shared Graph SDK client grants.'
        Sources = @('https://learn.microsoft.com/powershell/microsoftgraph/authentication-commands', 'https://learn.microsoft.com/graph/permissions-reference')
    }
}

function Write-A365TrustReceipt {
    param([Parameter(Mandatory)][object]$Receipt)
    Write-Host ''
    Write-Host 'Trust receipt | before consent' -ForegroundColor Cyan
    Write-Host "Client: $($Receipt.ApplicationName) [$($Receipt.ClientId)]"
    Write-Host "Tenant target: $($Receipt.TenantTarget) | Mode: $($Receipt.Mode) | Context: $($Receipt.ContextScope)"
    Write-Host $Receipt.Grants
    foreach ($permission in $Receipt.Permissions) {
        Write-Host "$($permission.Scope): $($permission.Purpose)"
        Write-Host "  Maximum grant boundary: $($permission.MaximumBoundary)"
    }
    Write-Host $Receipt.Consent
    Write-Host $Receipt.QueryPersistence
    Write-Host $Receipt.LocalArtifacts
    Write-Host $Receipt.TokenCaveat
    Write-Host 'Allowed Graph GET endpoint patterns (selected collectors use the relevant subset):'
    $Receipt.AllowedGraphGetPaths | ForEach-Object { Write-Host "  $_" }
    Write-Host 'Only allowed POST operations: /v1.0/security/runHuntingQuery; /v1.0/security/auditLog/queries.'
    Write-Host 'Optional preconnected workload commands: Get-DlpCompliancePolicy, Get-RetentionCompliancePolicy, Get-Label and Get-SPOSite. These use separately authorized module sessions.'
    Write-Host $Receipt.Offboarding
}
