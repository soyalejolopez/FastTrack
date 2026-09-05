#requires -Version 7.0
<#
.SYNOPSIS
Opt-in contract canary for an explicitly approved Commercial TEST tenant.
.DESCRIPTION
Disabled unless EnableLiveCanary is supplied. No reports, raw responses, customer content or
tenant identifiers are written to disk. Do not run under a transcript. Never schedule this script.
Defender/Purview require separate query-job approval. This is not part of offline release tests.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [switch]$EnableLiveCanary,
    [string]$ApprovedTestTenantId,
    [ValidateSet('TenantFoundation', 'Licensing', 'Roles', 'ServiceHealth', 'Registry', 'AgentIdentity', 'ConditionalAccess', 'Defender', 'Purview')]
    [string[]]$Collector = @('TenantFoundation', 'Licensing', 'Registry'),
    [switch]$ApproveQueryJobs,
    [string]$DelegatedClientId
)

$ErrorActionPreference = 'Stop'
if (-not $EnableLiveCanary) { throw 'Live canary is disabled. Explicit approval of a test tenant is required.' }
$tenantGuid = [Guid]::Empty
if (-not [Guid]::TryParse($ApprovedTestTenantId, [ref]$tenantGuid)) { throw 'Supply the GUID of the approved test tenant, not a production tenant.' }
if (@($Collector | Where-Object { $_ -in @('Defender', 'Purview') }).Count -gt 0 -and -not $ApproveQueryJobs) {
    throw 'Defender/Purview canaries require -ApproveQueryJobs for the disclosed POST operations.'
}
if (-not $PSCmdlet.ShouldProcess($ApprovedTestTenantId, 'Run read-only API contract probes in this approved TEST tenant; no evidence files')) { return }
$module = Import-Module (Join-Path $PSScriptRoot '..\Agent365Preflight.psd1') -Force -PassThru
& $module {
    param($Tenant, $Collectors, $Client)
    $scopes = @(Get-Agent365RequiredScopes -Collector $Collectors)
    $allowlist = Read-A365Json $script:AllowlistPath Allowlist
    $policy = Read-A365Json (Join-Path $script:ModuleRoot 'config\assessment-policy.v2.json') Policy
    Write-A365TrustReceipt (New-A365TrustReceipt -Scopes $scopes -TenantTarget $Tenant -DelegatedClientId $Client -Policy $policy -Allowlist $allowlist)
    $issues = [Collections.Generic.List[object]]::new()
    $evidence = Get-A365LiveEvidence -Profiles ControlPlane -Collectors $Collectors -Scopes $scopes -SkuCatalog (Read-A365Json $script:SkuCatalogPath Catalog) -Allowlist $allowlist -Issues $issues -TenantId $Tenant -DelegatedClientId $Client
    [pscustomobject]@{
        ContractVersion = '2.0'
        CheckedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        Collectors = $Collectors
        IssueCategories = @($issues | Group-Object Category | ForEach-Object { [pscustomobject]@{ Category = $_.Name; Count = $_.Count } })
        PassedContracts = $issues.Count -eq 0 -and
            $evidence.tenant.commercialAvailability -eq $true -and
            @($Collectors | Where-Object { $_ -notin @($evidence.collectorsRan) }).Count -eq 0
        PersistedEvidenceFiles = 0
    }
    $evidence = $null
} $ApprovedTestTenantId @(@('TenantFoundation') + $Collector | Select-Object -Unique) $DelegatedClientId
