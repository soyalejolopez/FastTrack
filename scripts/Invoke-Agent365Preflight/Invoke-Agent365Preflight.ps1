#requires -Version 7.0

<#
.SYNOPSIS
Runs a read-only Microsoft Agent 365 technical pre-flight.

.DESCRIPTION
Collects customer-controlled tenant evidence using approved read-only operations, evaluates a
versioned public rule set, and writes self-contained HTML and JSON reports. The tool does not
configure the tenant and does not provide a security or compliance certification.

.PARAMETER Profile
Selects optional workload profiles. ControlPlane is always included.

.PARAMETER Collector
Selects evidence adapters and derives the Microsoft Graph scope list. TenantFoundation is always
included. All collectors are selected by default.

.PARAMETER Stage
Selects Pilot or Production verdict wording.

.PARAMETER OutputPath
Directory for full HTML and JSON output and optional sanitized copies.

.PARAMETER AnswersPath
Path to customer-reviewed manual attestation answers. Do not use the synthetic sample as real
customer evidence.

.PARAMETER PreviousResultPath
Path to a previous full JSON report for status drift comparison.

.PARAMETER FixturePath
Path to synthetic offline evidence. Fixture mode does not authenticate or call a tenant.

.PARAMETER SharePointSiteUrl
One or more intended pilot site URLs for optional SharePoint target-site checks.

.PARAMETER AuditWindowDays
Purview Audit Search lookback from 1 through 90 days.

.PARAMETER AuditQueryTimeoutSeconds
Overall Purview Audit Search query timeout from 30 through 900 seconds. Defaults to 300 seconds.

.PARAMETER IncludeSanitizedCopy
Writes redacted HTML and JSON support copies beside the full reports.

.PARAMETER InstallDependencies
Explicitly opts in to CurrentUser installation of Microsoft.Graph.Authentication when missing.

.PARAMETER IncludeBeta
Records beta opt-in. The current v1 rules do not call a beta endpoint.

.PARAMETER TenantId
Tenant GUID or verified domain. By itself, pins interactive delegated sign-in and enables a
post-connect tenant assertion. With app-only parameters, identifies the app's tenant.

.PARAMETER ClientId
Application client ID for Graph-only certificate app authentication. Supplying it selects app-only
mode and requires TenantId and CertificateThumbprint.

.PARAMETER CertificateThumbprint
Certificate thumbprint for Graph-only app authentication. Supplying it selects app-only mode and
requires TenantId and ClientId. Client secrets are not supported.

.EXAMPLE
.\Invoke-Agent365Preflight.ps1 `
    -TenantId "contoso.onmicrosoft.com" `
    -Collector TenantFoundation,Licensing,Roles,Registry,AgentIdentity `
    -Stage Pilot `
    -OutputPath C:\Temp\Agent365Preflight

Runs a focused first live collection. The script prints the derived scopes before sign-in.

.EXAMPLE
.\Invoke-Agent365Preflight.ps1 -FixturePath .\fixtures\commercial-ready.json `
    -AnswersPath .\samples\answers.sample.json `
    -IncludeSanitizedCopy `
    -OutputPath .\out

Generates full and sanitized demonstration reports without tenant access.

.EXAMPLE
.\Invoke-Agent365Preflight.ps1 `
    -Profile CopilotStudio,AgentBuilder,SharePointAgents `
    -Collector TenantFoundation,Licensing,Roles,Registry,AgentIdentity,ConditionalAccess,SharePoint `
    -SharePointSiteUrl https://contoso.sharepoint.com/sites/agent-pilot `
    -AnswersPath .\answers.customer.json `
    -IncludeSanitizedCopy `
    -OutputPath C:\Temp\Agent365Preflight

Runs a recommended pilot collection after the answers file has been reviewed by customer owners.

.EXAMPLE
.\Invoke-Agent365Preflight.ps1 `
    -PreviousResultPath C:\Temp\Previous\Agent365Preflight.json `
    -OutputPath C:\Temp\Current

Adds regressions, resolved blockers, and other status changes to the current report.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateSet(
        'ControlPlane',
        'CopilotStudio',
        'AgentBuilder',
        'SharePointAgents',
        'Foundry',
        'CustomProCode',
        'ExternalRegistrySync',
        'LocalAgents',
        'WorkIQ',
        'AITeammate'
    )]
    [string[]]$Profile = @('ControlPlane'),

    [Parameter()]
    [ValidateSet(
        'TenantFoundation',
        'Licensing',
        'Roles',
        'ServiceHealth',
        'Registry',
        'AgentIdentity',
        'ConditionalAccess',
        'Defender',
        'Purview',
        'SharePoint'
    )]
    [string[]]$Collector = @(
        'TenantFoundation',
        'Licensing',
        'Roles',
        'ServiceHealth',
        'Registry',
        'AgentIdentity',
        'ConditionalAccess',
        'Defender',
        'Purview',
        'SharePoint'
    ),

    [Parameter()]
    [ValidateSet('Pilot', 'Production')]
    [string]$Stage = 'Pilot',

    [Parameter()]
    [string]$OutputPath = (Join-Path $PWD 'Agent365PreflightOutput'),

    [Parameter()]
    [string]$AnswersPath,

    [Parameter()]
    [string]$PreviousResultPath,

    [Parameter()]
    [string]$FixturePath,

    [Parameter()]
    [string[]]$SharePointSiteUrl = @(),

    [Parameter()]
    [ValidateRange(1, 90)]
    [int]$AuditWindowDays = 7,

    [Parameter()]
    [ValidateRange(30, 900)]
    [int]$AuditQueryTimeoutSeconds = 300,

    [Parameter()]
    [switch]$IncludeSanitizedCopy,

    [Parameter()]
    [switch]$InstallDependencies,

    [Parameter()]
    [switch]$IncludeBeta,

    [Parameter()]
    [string]$TenantId,

    [Parameter()]
    [string]$ClientId,

    [Parameter()]
    [string]$CertificateThumbprint
)

$modulePath = Join-Path $PSScriptRoot 'Agent365Preflight.psd1'

try {
    Import-Module $modulePath -Force -ErrorAction Stop
    $outcome = Invoke-Agent365Preflight @PSBoundParameters

    Write-Host ''
    Write-Host "Verdict: $($outcome.Report.Verdict.Label)"
    Write-Host "HTML:    $($outcome.Paths.Html)"
    Write-Host "JSON:    $($outcome.Paths.Json)"
    if ($outcome.Paths.SanitizedHtml) {
        Write-Host "Support: $($outcome.Paths.SanitizedHtml)"
    }

    exit $outcome.ExitCode
}
catch {
    Write-Error "Agent 365 pre-flight could not run: $($_.Exception.Message)"
    exit 3
}
