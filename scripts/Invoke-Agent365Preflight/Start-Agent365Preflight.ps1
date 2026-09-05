#requires -Version 7.0

<#
.SYNOPSIS
Starts the guided Microsoft Agent 365 pre-flight customer journey.

.DESCRIPTION
Checks local prerequisites, explains the read-only evidence flow, guides authentication, runs the
pre-flight in the current PowerShell process, opens the full local working report, and supports a
report-linked resume workflow. Use Invoke-Agent365Preflight.ps1 for unattended or advanced
automation.

.PARAMETER Mode
Guided prompts for a mode. Sample uses fixture data. Recommended runs the standard Control Plane
collectors. Resume uses a previous full report. Advanced accepts explicit profiles and collectors.

.PARAMETER Authentication
Auto recommends normal interactive authentication in a native Windows terminal and device code on
other platforms or embedded hosts. Interactive and DeviceCode explicitly select a flow.

.PARAMETER OpenReport
Ask prompts before opening the full report, Always opens it, and Never leaves it closed.

.EXAMPLE
.\Start-Agent365Preflight.ps1

Starts the complete guided customer journey.

.EXAMPLE
.\Start-Agent365Preflight.ps1 -Mode Sample -OpenReport Always

Generates and opens a safe fixture report without tenant authentication.

.EXAMPLE
.\Start-Agent365Preflight.ps1 -Mode Resume `
    -PreviousResultPath C:\Agent365Preflight\Agent365Preflight-20260904-120000.json

Discovers the report-linked answers file and reruns with the previous scope and settings.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateSet('Guided', 'Sample', 'Recommended', 'Resume', 'Advanced')]
    [string]$Mode = 'Guided',

    [Parameter()]
    [ValidateSet('Auto', 'Interactive', 'DeviceCode')]
    [string]$Authentication = 'Auto',

    [Parameter()]
    [ValidateSet('Pilot', 'Production')]
    [string]$Stage = 'Pilot',

    [Parameter()]
    [string]$TenantId,

    [Parameter()]
    [ValidateSet(
        'ControlPlane', 'CopilotStudio', 'AgentBuilder', 'SharePointAgents', 'Foundry',
        'CustomProCode', 'ExternalRegistrySync', 'LocalAgents', 'WorkIQ', 'AITeammate'
    )]
    [string[]]$Profile = @('ControlPlane'),

    [Parameter()]
    [ValidateSet(
        'TenantFoundation', 'Licensing', 'Roles', 'ServiceHealth', 'Registry',
        'AgentIdentity', 'ConditionalAccess', 'Defender', 'Purview', 'SharePoint'
    )]
    [string[]]$Collector,

    [Parameter()]
    [string[]]$SharePointSiteUrl = @(),

    [Parameter()]
    [string]$OutputPath = (Join-Path $PWD 'Agent365PreflightOutput'),

    [Parameter()]
    [string]$PreviousResultPath,

    [Parameter()]
    [string]$AnswersPath,

    [Parameter()]
    [ValidateRange(1, 90)]
    [int]$AuditWindowDays = 7,

    [Parameter()]
    [ValidateRange(30, 900)]
    [int]$AuditQueryTimeoutSeconds = 300,

    [Parameter()]
    [switch]$UseDeviceCode,

    [Parameter()]
    [switch]$IncludeSanitizedCopy = $true,

    [Parameter()]
    [switch]$InstallDependencies,

    [Parameter()]
    [string]$ClientId,

    [Parameter()]
    [string]$CertificateThumbprint,

    [Parameter()]
    [ValidateSet('Ask', 'Always', 'Never')]
    [string]$OpenReport = 'Ask',

    [Parameter()]
    [switch]$NonInteractive,

    [Parameter()]
    [switch]$PassThru,

    [string]$DelegatedClientId,
    [ValidateSet('ActiveRoles', 'PIM')][string]$RolePolicy = 'ActiveRoles',
    [string[]]$ExcludeRequirement = @(),
    [string]$ScopeJustification,
    [ValidateSet('Commercial', 'USGov', 'China')][string]$Cloud = 'Commercial',
    [switch]$AutomatedOnly,
    [string]$DownloadsPath
)

$script:A365LauncherRoot = $PSScriptRoot
$script:A365EnginePath = Join-Path $PSScriptRoot 'Invoke-Agent365Preflight.ps1'
$script:A365ModulePath = Join-Path $PSScriptRoot 'Agent365Preflight.psd1'
$script:A365AnswerSchemaPath = Join-Path $PSScriptRoot 'schema\agent365-preflight-answers.schema.json'
$script:A365MinimumGraphVersion = [version]'2.20.0'
$script:A365RecommendedCollectors = @(
    'TenantFoundation', 'Licensing', 'Roles', 'ServiceHealth', 'Registry',
    'AgentIdentity', 'ConditionalAccess', 'Defender', 'Purview'
)
$script:A365AllowedProfiles = @(
    'ControlPlane', 'CopilotStudio', 'AgentBuilder', 'SharePointAgents', 'Foundry',
    'CustomProCode', 'ExternalRegistrySync', 'LocalAgents', 'WorkIQ', 'AITeammate'
)
$script:A365AllowedCollectors = @(
    'TenantFoundation', 'Licensing', 'Roles', 'ServiceHealth', 'Registry',
    'AgentIdentity', 'ConditionalAccess', 'Defender', 'Purview', 'SharePoint'
)

function Write-A365JourneyHeading {
    param([Parameter(Mandatory)][string]$Text)

    Write-Host ''
    Write-Host $Text -ForegroundColor Cyan
    Write-Host ('-' * $Text.Length) -ForegroundColor DarkGray
}

function Read-A365JourneyChoice {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][string[]]$Choices,
        [int]$Default = 1
    )

    while ($true) {
        Write-Host ''
        for ($index = 0; $index -lt $Choices.Count; $index++) {
            Write-Host ("  {0}. {1}" -f ($index + 1), $Choices[$index])
        }
        $answer = Read-Host "$Prompt [$Default]"
        if ([string]::IsNullOrWhiteSpace($answer)) {
            return $Default
        }
        $selection = 0
        if ([int]::TryParse($answer, [ref]$selection) -and $selection -ge 1 -and $selection -le $Choices.Count) {
            return $selection
        }
        Write-Warning "Enter a number from 1 through $($Choices.Count)."
    }
}

function Read-A365JourneyYesNo {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [bool]$Default = $true
    )

    $suffix = if ($Default) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        $answer = (Read-Host "$Prompt $suffix").Trim()
        if (-not $answer) { return $Default }
        if ($answer -match '^(?i)y(?:es)?$') { return $true }
        if ($answer -match '^(?i)n(?:o)?$') { return $false }
        Write-Warning 'Enter Y or N.'
    }
}

function Test-A365TenantTargetFormat {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    $candidate = $Value.Trim()
    $guid = [guid]::Empty
    if ([guid]::TryParse($candidate, [ref]$guid)) { return $true }
    return $candidate -match '^(?=.{3,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$'
}

function Get-A365LauncherHostAssessment {
    $runningOnWindows = $IsWindows -or $env:OS -eq 'Windows_NT'
    $embeddedSignals = @(
        $env:VSCODE_PID
        $env:GITHUB_ACTIONS
        $env:TF_BUILD
        $env:CI
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
    $termProgram = [string]$env:TERM_PROGRAM
    $isEmbedded = $embeddedSignals.Count -gt 0 -or $termProgram -match '(?i)vscode|cursor|embedded'
    $isWindowsTerminal = -not [string]::IsNullOrWhiteSpace([string]$env:WT_SESSION)
    $isInteractive = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected

    return [pscustomobject]@{
        IsWindows = $runningOnWindows
        IsWindowsTerminal = $isWindowsTerminal
        IsLikelyEmbedded = $isEmbedded
        IsInteractive = $isInteractive
        RecommendInteractive = $runningOnWindows -and $isInteractive -and (-not $isEmbedded)
        Reason = if (-not $runningOnWindows) {
            'Device code is the portable delegated sign-in option on this platform.'
        }
        elseif ($isEmbedded) {
            'This host appears embedded or backgrounded and might not provide the parent window required by WAM.'
        }
        elseif (-not $isInteractive) {
            'This process does not appear to have an interactive console, so device code is the safer fallback.'
        }
        elseif ($isWindowsTerminal) {
            'Windows Terminal provides the native window used by normal interactive WAM sign-in.'
        }
        else {
            'This appears to be an interactive Windows console. Normal interactive sign-in is recommended.'
        }
    }
}

function Test-A365LauncherGraphReachability {
    $client = [System.Net.Http.HttpClient]::new()
    try {
        $client.Timeout = [TimeSpan]::FromSeconds(10)
        $request = [System.Net.Http.HttpRequestMessage]::new(
            [System.Net.Http.HttpMethod]::Head,
            'https://graph.microsoft.com/'
        )
        $response = $client.Send($request)
        return $null -ne $response
    }
    catch {
        return $false
    }
    finally {
        $client.Dispose()
    }
}

function Get-A365LauncherEnvironment {
    param([Parameter(Mandatory)][string]$OutputPath, [switch]$Offline)

    $graphModule = Get-Module -ListAvailable -Name Microsoft.Graph.Authentication |
        Sort-Object Version -Descending |
        Select-Object -First 1
    $resolvedOutput = $null
    $writeError = $null
    try {
        if (-not (Test-Path -LiteralPath $OutputPath -PathType Container)) {
            $null = New-Item -ItemType Directory -Path $OutputPath -Force -ErrorAction Stop
        }
        $resolvedOutput = (Resolve-Path -LiteralPath $OutputPath -ErrorAction Stop).Path
        $probe = Join-Path $resolvedOutput ".agent365-write-$([guid]::NewGuid().ToString('N')).tmp"
        [System.IO.File]::WriteAllText($probe, 'write-test', [System.Text.UTF8Encoding]::new($false))
        Remove-Item -LiteralPath $probe -Force
    }
    catch {
        $writeError = $_.Exception.Message
    }

    return [pscustomobject]@{
        PowerShellReady = $PSVersionTable.PSVersion.Major -ge 7
        PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        GraphModuleReady = $null -ne $graphModule -and $graphModule.Version -ge $script:A365MinimumGraphVersion
        GraphModuleVersion = if ($graphModule) { $graphModule.Version.ToString() } else { $null }
        GraphModule = $graphModule
        GraphReachable = if ($Offline) { $null } else { Test-A365LauncherGraphReachability }
        OutputWritable = $null -eq $writeError
        OutputPath = $resolvedOutput
        OutputError = $writeError
    }
}

function Install-A365LauncherGraphModule {
    Install-Module Microsoft.Graph.Authentication `
        -MinimumVersion $script:A365MinimumGraphVersion `
        -Scope CurrentUser `
        -Repository PSGallery `
        -Force `
        -AllowClobber `
        -ErrorAction Stop
}

function Test-A365LauncherReusableContext {
    param(
        [AllowNull()][object]$Context,
        [Parameter(Mandatory)][string[]]$Scopes,
        [AllowNull()][string]$TenantId,
        [string]$DelegatedClientId
    )

    if ($null -eq $Context -or [string]::IsNullOrWhiteSpace([string]$Context.TenantId)) { return $false }
    if ($Context.ContextScope -ne 'Process' -or $Context.Environment -notin @('Global', 'GlobalV2')) { return $false }
    if ($DelegatedClientId -and $Context.ClientId -ne $DelegatedClientId) { return $false }
    if ([string]$Context.AuthType -match '(?i)appOnly|clientCredential') { return $false }
    if ([string]::IsNullOrWhiteSpace([string]$Context.Account)) { return $false }
    foreach ($scope in $Scopes) {
        if (@($Context.Scopes | Where-Object { [string]::Equals([string]$_, $scope, [StringComparison]::OrdinalIgnoreCase) }).Count -eq 0) {
            return $false
        }
    }
    if ($TenantId) {
        $guid = [guid]::Empty
        if ([guid]::TryParse($TenantId.Trim(), [ref]$guid) -and
            -not [string]::Equals($guid.ToString(), [string]$Context.TenantId, [StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }
    }
    return $true
}

function Get-A365AuthenticationFailureKind {
    param([Parameter(Mandatory)][string]$Message)

    if ($Message -match '(?i)window.?handle|parent window|windows authentication manager|\bWAM\b|broker') {
        return 'WamWindow'
    }
    if ($Message -match '(?i)timed out|timeout|expired|device.?code') {
        return 'DeviceTimeout'
    }
    return 'Authentication'
}

function Write-A365ScopeExplanation {
    param([Parameter(Mandatory)][string[]]$Scopes)

    $descriptions = @{
        'Organization.Read.All' = 'Tenant identity, cloud, subscribed SKUs, and organization metadata.'
        'User.Read.All' = 'Aggregate per-user service-plan assignment; user details are not persisted.'
        'RoleManagement.Read.Directory' = 'Visible active Agent 365 management role assignments.'
        'RoleEligibilitySchedule.Read.Directory' = 'PIM eligibility when the signed-in account can read it.'
        'ServiceHealth.Read.All' = 'Microsoft 365 service-health status relevant to the pre-flight.'
        'CopilotPackages.Read.All' = 'Agent package catalog summary.'
        'AgentIdentityBlueprint.Read.All' = 'Agent identity blueprint, owner, credential, and permission aggregates.'
        'Application.Read.All' = 'Blueprint sponsor evidence where authorized.'
        'Policy.Read.All' = 'Security defaults and Conditional Access policy inventory.'
        'ThreatHunting.Read.All' = 'Aggregate-only Defender advanced-hunting probes.'
        'AuditLogsQuery.Read.All' = 'Aggregate Purview Audit Search query evidence.'
    }
    foreach ($scope in $Scopes) {
        $description = if ($descriptions.ContainsKey($scope)) { $descriptions[$scope] } else { 'Read-only evidence required by the selected collector.' }
        Write-Host "  $scope"
        Write-Host "    $description" -ForegroundColor DarkGray
    }
}

function Invoke-A365LauncherAuthentication {
    param(
        [Parameter(Mandatory)][string[]]$Scopes,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][ValidateSet('Interactive', 'DeviceCode')][string]$Method,
        [switch]$NonInteractive,
        [string]$DelegatedClientId
    )

    Import-Module Microsoft.Graph.Authentication -MinimumVersion $script:A365MinimumGraphVersion -Force -ErrorAction Stop
    $existing = Get-MgContext -ErrorAction SilentlyContinue
    if (Test-A365LauncherReusableContext -Context $existing -Scopes $Scopes -TenantId $TenantId -DelegatedClientId $DelegatedClientId) {
        Write-Host "Reusing the delegated Microsoft Graph context for $($existing.Account)." -ForegroundColor Green
        return [pscustomobject]@{ Reused = $true; Method = 'ExistingContext'; Context = $existing }
    }

    $currentMethod = $Method
    $attempt = 0
    while ($true) {
        $attempt++
        if ($attempt -gt 5) { throw 'Authentication did not complete after five attempts. Restart the launcher after resolving the sign-in problem.' }
        if ($currentMethod -eq 'DeviceCode') {
            Write-Warning 'Device-code sign-in can provide about 120 seconds in recent Microsoft.Graph.Authentication versions.'
            Write-Host 'Be ready to open https://microsoft.com/devicelogin, enter the displayed code, and finish consent immediately.'
            if (-not $NonInteractive -and -not (Read-A365JourneyYesNo -Prompt 'Ready to start device-code sign-in?' -Default $true)) {
                throw 'Device-code sign-in was cancelled before authentication.'
            }
        }

        $parameters = @{
            TenantId = $TenantId
            Scopes = $Scopes
            ContextScope = 'Process'
            NoWelcome = $true
            ErrorAction = 'Stop'
        }
        if ($currentMethod -eq 'DeviceCode') {
            $parameters.UseDeviceCode = $true
        }
        if ($DelegatedClientId) { $parameters.ClientId = $DelegatedClientId }

        try {
            $null = Connect-MgGraph @parameters
            $context = Get-MgContext -ErrorAction Stop
            if (-not (Test-A365LauncherReusableContext -Context $context -Scopes $Scopes -TenantId $TenantId -DelegatedClientId $DelegatedClientId)) {
                throw 'Microsoft Graph sign-in completed, but the resulting delegated context does not contain the requested tenant and scopes.'
            }
            return [pscustomobject]@{ Reused = $false; Method = $currentMethod; Context = $context }
        }
        catch {
            $kind = Get-A365AuthenticationFailureKind -Message $_.Exception.Message
            if ($NonInteractive) {
                throw
            }
            if ($kind -eq 'WamWindow') {
                Write-Warning 'Interactive WAM sign-in needs a real native window.'
                Write-Host 'Open Windows Terminal or PowerShell directly, then rerun. Embedded/background terminals cannot host WAM.'
                $choice = Read-A365JourneyChoice -Prompt 'Choose the next step' -Choices @(
                    'Try device-code sign-in now',
                    'Retry normal interactive sign-in',
                    'Stop and reopen in Windows Terminal'
                )
                if ($choice -eq 1) { $currentMethod = 'DeviceCode'; continue }
                if ($choice -eq 2) { $currentMethod = 'Interactive'; continue }
                throw 'Authentication stopped. Reopen Windows Terminal or PowerShell directly and rerun the launcher.'
            }
            if ($kind -eq 'DeviceTimeout') {
                Write-Warning 'The device-code window expired before sign-in and consent completed.'
                if (Read-A365JourneyYesNo -Prompt 'Try again now?' -Default $true) {
                    $currentMethod = 'DeviceCode'
                    continue
                }
                throw 'Device-code sign-in timed out.'
            }
            Write-Warning "Microsoft Graph sign-in failed: $($_.Exception.Message)"
            if (Read-A365JourneyYesNo -Prompt 'Try sign-in again?' -Default $true) {
                continue
            }
            throw
        }
    }
}

function Test-A365AnswerFile {
    param([Parameter(Mandatory)][string]$Path, [object]$Previous)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Answers file was not found: $Path"
    }
    if ((Get-Item -LiteralPath $Path).Length -gt 2MB) { throw 'Answer bundle exceeds the 2 MB local safety limit.' }
    $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    $schema = Get-Content -LiteralPath $script:A365AnswerSchemaPath -Raw -ErrorAction Stop
    if (-not ($raw | Test-Json -Schema $schema -ErrorAction Stop)) {
        throw "Answers file does not match the public schema: $Path"
    }
    if ($Previous) {
        Import-Module $script:A365ModulePath -ErrorAction Stop
        & (Get-A365LauncherModule) { param($Path, $Report) Test-A365AnswerBundle -Bundle (Read-A365Json $Path Answers) -Previous $Report } $Path $Previous
    }
    return (Resolve-Path -LiteralPath $Path).Path
}

function Read-A365FullReport {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Previous report was not found: $Path"
    }
    $resolved = (Resolve-Path -LiteralPath $Path).Path
    if ([IO.Path]::GetExtension($resolved) -ne '.json') {
        throw 'Resume requires the previous full JSON report.'
    }
    Import-Module $script:A365ModulePath -ErrorAction Stop
    $report = & (Get-A365LauncherModule) { param($Path) Read-A365Json $Path Report } $resolved
    if ([bool]$report.Sanitized -or [IO.Path]::GetFileName($resolved) -match '(?i)-sanitized\.json$') {
        throw 'Resume requires the full local report JSON, not the sanitized sharing copy.'
    }
    if ([string]$report.SchemaVersion -ne '2.0' -or -not $report.RunSpecification) {
        throw 'Faithful resume requires a full v2 report with RunSpecification. Start a new assessment for a legacy report.'
    }
    if ([string]$report.Stage -notin @('Pilot', 'Production')) {
        throw 'Previous report contains an invalid stage.'
    }
    [object[]]$profiles = @($report.Profiles | ForEach-Object { [string]$_ })
    [object[]]$collectors = @($report.Collectors | ForEach-Object { [string]$_ })
    if ($profiles.Count -eq 0 -or @($profiles | Where-Object { $_ -notin $script:A365AllowedProfiles }).Count -gt 0) {
        throw 'Previous report contains an unsupported profile.'
    }
    if ($collectors.Count -eq 0 -or @($collectors | Where-Object { $_ -notin $script:A365AllowedCollectors }).Count -gt 0) {
        throw 'Previous report contains an unsupported collector.'
    }
    $auditWindow = [int]$report.Runtime.AuditWindowDays
    $auditTimeout = [int]$report.Runtime.AuditQueryTimeoutSeconds
    if ($auditWindow -lt 1 -or $auditWindow -gt 90 -or $auditTimeout -lt 30 -or $auditTimeout -gt 900) {
        throw 'Previous report contains unsupported audit settings.'
    }
    $spec = $report.RunSpecification
    if ($spec.Version -ne '2.0' -or $spec.AuthenticationMode -notin @('InteractiveDelegated', 'CertificateAppOnly') -or $spec.Cloud -ne 'Commercial') {
        throw 'Previous RunSpecification has unsupported version, authentication, or cloud.'
    }
    if ($spec.Stage -ne $report.Stage -or ($spec.Profiles -join ',') -ne ($report.Profiles -join ',') -or
        ($spec.Collectors -join ',') -ne ($report.Collectors -join ',')) { throw 'Report scope and RunSpecification disagree.' }
    if ([int]$spec.AuditWindowDays -ne $auditWindow -or [int]$spec.AuditQueryTimeoutSeconds -ne $auditTimeout) { throw 'Report audit settings and RunSpecification disagree.' }

    return [pscustomobject]@{
        Path = $resolved
        Report = $report
        Directory = Split-Path -Parent $resolved
        HtmlPath = [IO.Path]::ChangeExtension($resolved, '.html')
    }
}

function Get-A365AnswerCandidates {
    param(
        [Parameter(Mandatory)][object]$Previous,
        [AllowNull()][string]$ExplicitAnswersPath,
        [string]$DownloadsPath
    )

    if ($ExplicitAnswersPath) {
        return @([pscustomobject]@{
            Path = Test-A365AnswerFile -Path $ExplicitAnswersPath -Previous $Previous.Report
            LastWriteTime = (Get-Item -LiteralPath $ExplicitAnswersPath).LastWriteTime
            Source = 'Explicit'
        })
    }

    $report = $Previous.Report
    $answerFileName = [string]$report.Resume.AnswerFileName
    if ([string]::IsNullOrWhiteSpace($answerFileName)) {
        $reportId = if ($report.ReportId) { [string]$report.ReportId } else { [IO.Path]::GetFileNameWithoutExtension($Previous.Path) }
        $answerFileName = "$reportId-answers.json"
    }
    if ($answerFileName -notmatch '^Agent365Preflight-[0-9]{8}-[0-9]{6}-[a-f0-9]{8}-answers\.json$') {
        throw 'Previous report contains an invalid report-linked answers filename.'
    }

    Import-Module $script:A365ModulePath -ErrorAction Stop
    $downloads = if ($DownloadsPath) { $DownloadsPath } else { & (Get-A365LauncherModule) { Get-A365DownloadsPath } }
    $candidatePaths = @(
        foreach ($directory in @($Previous.Directory, $downloads) | Where-Object { $_ } | Select-Object -Unique) {
            if (Test-Path -LiteralPath $directory -PathType Container) {
                Get-ChildItem -LiteralPath $directory -Filter '*-answers*.json' -File |
                    Where-Object { $_.Length -le 2MB } | Select-Object -ExpandProperty FullName
            }
        }
    )

    $candidates = [System.Collections.Generic.List[object]]::new()
    foreach ($candidatePath in @($candidatePaths | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $candidatePath -PathType Leaf)) { continue }
        try {
            $header = & (Get-A365LauncherModule) { param($Path) Read-A365Json $Path Answers } $candidatePath
            if (-not $header.PSObject.Properties['sourceReportId'] -or $header.sourceReportId -cne $report.ReportId) { continue }
            $validPath = Test-A365AnswerFile -Path $candidatePath -Previous $report
            $item = Get-Item -LiteralPath $validPath
            $candidates.Add([pscustomobject]@{
                Path = $validPath
                LastWriteTime = $item.LastWriteTime
                ModifiedAtUtc = $header.modifiedAtUtc
                ContentHash = $header.contentHash
                Source = if ($item.DirectoryName -eq $Previous.Directory) { 'OutputFolder' } else { 'Downloads' }
            })
        }
        catch {
            Write-Warning "Ignoring malformed matching answers file: $candidatePath. $($_.Exception.Message)"
        }
    }
    return $candidates.ToArray()
}

function Select-A365AnswerCandidate {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Candidates,
        [switch]$NonInteractive
    )

    if ($Candidates.Count -eq 0) { return $null }
    if ($Candidates.Count -eq 1) { return $Candidates[0].Path }
    if ($NonInteractive) {
        throw 'Multiple matching answers files were found. Supply -AnswersPath to choose one.'
    }
    $labels = @($Candidates | ForEach-Object {
        "$($_.Path) (file modified $($_.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')); bundle modified $($_.ModifiedAtUtc); SHA256 $($_.ContentHash))"
    })
    $choice = Read-A365JourneyChoice -Prompt 'Choose the answers file' -Choices $labels
    return $Candidates[$choice - 1].Path
}

function Get-A365ResumePlan {
    param(
        [Parameter(Mandatory)][string]$PreviousResultPath,
        [AllowNull()][string]$AnswersPath,
        [switch]$NonInteractive,
        [switch]$AutomatedOnly,
        [string]$DownloadsPath
    )

    $previous = Read-A365FullReport -Path $PreviousResultPath
    [object[]]$candidates = @(if (-not $AutomatedOnly) { Get-A365AnswerCandidates -Previous $previous -ExplicitAnswersPath $AnswersPath -DownloadsPath $DownloadsPath })
    $selectedAnswers = Select-A365AnswerCandidate -Candidates $candidates -NonInteractive:$NonInteractive
    if (-not $selectedAnswers -and -not $AutomatedOnly) {
        $expected = [string]$previous.Report.Resume.AnswerFileName
        if ($NonInteractive) {
            throw "No matching answers file was found. Download $expected from the full report or supply -AnswersPath."
        }
        Write-Warning "No matching answers file was found in the report folder or Downloads."
        Write-Host "Open the full report, use Answers Builder, and download: $expected"
        if ((Test-Path -LiteralPath $previous.HtmlPath -PathType Leaf) -and
            (Read-A365JourneyYesNo -Prompt 'Open the previous full working report now?' -Default $true)) {
            Open-A365FullReport -Path $previous.HtmlPath
        }
        $manualPath = Read-Host 'Paste the answers JSON path (redirected Downloads or another folder), or leave blank to search again'
        $candidates = @(Get-A365AnswerCandidates -Previous $previous -ExplicitAnswersPath $manualPath -DownloadsPath $DownloadsPath)
        $selectedAnswers = Select-A365AnswerCandidate -Candidates $candidates -NonInteractive:$NonInteractive
        if (-not $selectedAnswers) {
            throw "The report-linked answers file is still not available: $expected"
        }
    }

    $report = $previous.Report
    $spec = $report.RunSpecification
    $tenantTarget = [string]$spec.TenantTarget
    if (-not $report.FixtureMode -and -not (Test-A365TenantTargetFormat -Value $tenantTarget)) {
        throw 'Previous report does not contain a valid tenant target for a live resume.'
    }
    return [pscustomobject]@{
        Mode = 'Resume'
        FixturePath = if ($report.FixtureMode) { $spec.FixturePath } else { $null }
        TenantId = $tenantTarget
        Stage = [string]$report.Stage
        Profiles = @($report.Profiles)
        Collectors = @($report.Collectors)
        AuditWindowDays = [int]$spec.AuditWindowDays
        AuditQueryTimeoutSeconds = [int]$spec.AuditQueryTimeoutSeconds
        IncludeSanitizedCopy = [bool]$spec.IncludeSanitizedCopy
        UseDeviceCode = [bool]$spec.UseDeviceCode
        AnswersPath = $selectedAnswers
        PreviousResultPath = $previous.Path
        OutputPath = $previous.Directory
        PreviousHtmlPath = $previous.HtmlPath
        IsFirstRun = $false
        TargetSites = @($spec.TargetSites)
        AuthenticationMode = $spec.AuthenticationMode
        ClientId = $spec.ClientId
        DelegatedClientId = $spec.DelegatedClientId
        RolePolicy = $spec.AssessmentScope.RolePolicy
        ExcludeRequirement = @($spec.AssessmentScope.ExcludedRequirements)
        ScopeJustification = $spec.AssessmentScope.Justification
    }
}

function Open-A365FullReport {
    param([Parameter(Mandatory)][string]$Path)

    Start-Process -FilePath $Path -ErrorAction Stop
}

function Invoke-A365JourneyEngine {
    param([Parameter(Mandatory)][hashtable]$Parameters)

    return Invoke-Agent365Preflight @Parameters
}

function Get-A365LauncherModule {
    $expectedPath = Join-Path $script:A365LauncherRoot 'Agent365Preflight.psm1'
    $module = Get-Module Agent365Preflight | Where-Object Path -eq $expectedPath | Select-Object -First 1
    if (-not $module) { throw "The module belonging to this launcher is not loaded: $expectedPath" }
    return $module
}

function Invoke-A365CustomerJourney {
    [CmdletBinding()]
    param(
        [ValidateSet('Guided', 'Sample', 'Recommended', 'Resume', 'Advanced')][string]$Mode = 'Guided',
        [ValidateSet('Auto', 'Interactive', 'DeviceCode')][string]$Authentication = 'Auto',
        [ValidateSet('Pilot', 'Production')][string]$Stage = 'Pilot',
        [string]$TenantId,
        [string[]]$Profile = @('ControlPlane'),
        [string[]]$Collector,
        [string[]]$SharePointSiteUrl = @(),
        [string]$OutputPath = (Join-Path $PWD 'Agent365PreflightOutput'),
        [string]$PreviousResultPath,
        [string]$AnswersPath,
        [int]$AuditWindowDays = 7,
        [int]$AuditQueryTimeoutSeconds = 300,
        [switch]$UseDeviceCode,
        [switch]$IncludeSanitizedCopy = $true,
        [switch]$InstallDependencies,
        [string]$ClientId,
        [string]$CertificateThumbprint,
        [ValidateSet('Ask', 'Always', 'Never')][string]$OpenReport = 'Ask',
        [switch]$NonInteractive,
        [string]$DelegatedClientId,
        [ValidateSet('ActiveRoles', 'PIM')][string]$RolePolicy = 'ActiveRoles',
        [string[]]$ExcludeRequirement = @(),
        [string]$ScopeJustification,
        [ValidateSet('Commercial', 'USGov', 'China')][string]$Cloud = 'Commercial',
        [switch]$AutomatedOnly,
        [string]$DownloadsPath
    )

    Write-Host ''
    Write-Host 'Microsoft Agent 365 pre-flight' -ForegroundColor Cyan
    if ($Cloud -ne 'Commercial') { throw 'Commercial cloud only. Unsupported cloud selected; no tenant request or sign-in was made.' }
    if ($DelegatedClientId -and ($ClientId -or $CertificateThumbprint)) { throw 'DelegatedClientId cannot be combined with certificate app-only parameters.' }
    if ($ExcludeRequirement.Count -gt 0 -and $Mode -notin @('Advanced', 'Resume')) { throw 'Only Advanced mode can explicitly narrow the assessment scope.' }
    Write-Host 'Commercial cloud only. Community/as-is tool; not a certification or a Microsoft support entitlement.'
    Write-Host 'Read operations plus disclosed query-job POSTs. No tenant configuration remediation. Interactive consent may establish persistent grants.'
    Write-Host 'The full report stays local and is the remediation workspace. The sanitized copy is only for sharing.'
    Write-Host 'Arrange roles, admin consent, target scope and evidence owners before running; organizational approval can take days.'
    Write-Host 'Execution is usually minutes, but tenant size, throttling and audit timeout affect duration.'

    if ($Mode -eq 'Guided') {
        if ($NonInteractive) { throw 'NonInteractive runs must choose Sample, Recommended, Resume, or Advanced.' }
        $selection = Read-A365JourneyChoice -Prompt 'What do you want to do?' -Choices @(
            'Try safely with sample data',
            'Run the recommended Control Plane pre-flight',
            'Resume from a full report',
            'Advanced/custom run'
        )
        $Mode = @('Sample', 'Recommended', 'Resume', 'Advanced')[$selection - 1]
    }

    if ($Mode -eq 'Resume') {
        if (-not $PreviousResultPath) {
            if ($NonInteractive) { throw 'Resume mode requires -PreviousResultPath.' }
            $PreviousResultPath = Read-Host 'Path to the previous full report JSON'
        }
        $plan = Get-A365ResumePlan -PreviousResultPath $PreviousResultPath -AnswersPath $AnswersPath -NonInteractive:$NonInteractive -AutomatedOnly:$AutomatedOnly -DownloadsPath $DownloadsPath
        $OutputPath = $plan.OutputPath
        $SharePointSiteUrl = @($plan.TargetSites)
        $RolePolicy = $plan.RolePolicy
        $ExcludeRequirement = @($plan.ExcludeRequirement)
        $ScopeJustification = $plan.ScopeJustification
        if ($plan.AuthenticationMode -eq 'CertificateAppOnly') {
            if ($DelegatedClientId -or $UseDeviceCode -or $Authentication -ne 'Auto') { throw 'App-only resume cannot switch to delegated authentication.' }
            if (-not $ClientId) { $ClientId = $plan.ClientId }
            if (-not $ClientId -or -not $CertificateThumbprint -or $ClientId -ne $plan.ClientId) {
                throw 'App-only resume requires the original ClientId and a securely re-supplied -CertificateThumbprint. No delegated fallback is allowed.'
            }
        }
        else {
            if ($ClientId -or $CertificateThumbprint) { throw 'Delegated resume cannot switch to app-only authentication.' }
            if ($DelegatedClientId -and $DelegatedClientId -ne $plan.DelegatedClientId) { throw 'Delegated resume must retain its original client identity.' }
            $DelegatedClientId = $plan.DelegatedClientId
        }
    }
    else {
        if ($Mode -eq 'Sample') {
            $plan = [pscustomobject]@{
                Mode = 'Sample'
                FixturePath = Join-Path $script:A365LauncherRoot 'fixtures\commercial-ready.json'
                TenantId = $null
                Stage = $Stage
                Profiles = @('ControlPlane')
                Collectors = @($script:A365RecommendedCollectors)
                AuditWindowDays = $AuditWindowDays
                AuditQueryTimeoutSeconds = $AuditQueryTimeoutSeconds
                IncludeSanitizedCopy = $true
                UseDeviceCode = $false
                AnswersPath = $AnswersPath
                PreviousResultPath = $null
                OutputPath = $OutputPath
                IsFirstRun = $true
            }
        }
        else {
            if (-not $TenantId) {
                if ($NonInteractive) { throw "$Mode mode requires -TenantId." }
                $TenantId = Read-Host 'Tenant verified domain or GUID'
            }
            if (-not (Test-A365TenantTargetFormat -Value $TenantId)) {
                throw "TenantId must be a tenant GUID or verified domain: $TenantId"
            }
            if (-not $NonInteractive) {
                $stageChoice = Read-A365JourneyChoice -Prompt 'Select the deployment stage' -Choices @('Pilot', 'Production') -Default $(if ($Stage -eq 'Production') { 2 } else { 1 })
                $Stage = @('Pilot', 'Production')[$stageChoice - 1]
            }

            if ($Mode -eq 'Recommended') {
                $Profile = @('ControlPlane')
                $Collector = @($script:A365RecommendedCollectors)
            }
            elseif ($Mode -eq 'Advanced' -and -not $NonInteractive) {
                $profileText = Read-Host "Profiles, comma-separated [$($Profile -join ',')]"
                if ($profileText) { $Profile = @($profileText -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
                $defaultCollectors = if ($Collector) { $Collector } else { $script:A365RecommendedCollectors }
                $collectorText = Read-Host "Collectors, comma-separated [$($defaultCollectors -join ',')]"
                $Collector = if ($collectorText) { @($collectorText -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } else { @($defaultCollectors) }
            }
            elseif (-not $Collector) {
                $Collector = @($script:A365RecommendedCollectors)
            }
            if (@($Profile | Where-Object { $_ -notin $script:A365AllowedProfiles }).Count -gt 0) { throw 'One or more profiles are unsupported.' }
            if (@($Collector | Where-Object { $_ -notin $script:A365AllowedCollectors }).Count -gt 0) { throw 'One or more collectors are unsupported.' }

            $plan = [pscustomobject]@{
                Mode = $Mode
                FixturePath = $null
                TenantId = $TenantId.Trim()
                Stage = $Stage
                Profiles = @($Profile)
                Collectors = @($Collector)
                AuditWindowDays = $AuditWindowDays
                AuditQueryTimeoutSeconds = $AuditQueryTimeoutSeconds
                IncludeSanitizedCopy = [bool]$IncludeSanitizedCopy
                UseDeviceCode = [bool]$UseDeviceCode
                AnswersPath = $AnswersPath
                PreviousResultPath = $null
                OutputPath = $OutputPath
                IsFirstRun = -not $AnswersPath
            }
        }
    }

    Write-A365JourneyHeading 'Environment check'
    $environment = Get-A365LauncherEnvironment -OutputPath $plan.OutputPath -Offline:([bool]$plan.FixturePath)
    Write-Host "PowerShell $($environment.PowerShellVersion): $(if ($environment.PowerShellReady) { 'Ready' } else { 'PowerShell 7 is required' })"
    if ($plan.FixturePath) {
        Write-Host 'Graph dependencies, sign-in and endpoint checks: not needed for offline sample mode.'
    } else {
        Write-Host "Microsoft.Graph.Authentication: $(if ($environment.GraphModuleReady) { "Ready ($($environment.GraphModuleVersion))" } else { 'Missing or older than 2.20.0' })"
        Write-Host "Microsoft Graph endpoint: $(if ($environment.GraphReachable) { 'Reachable' } else { 'Not reachable' })"
    }
    Write-Host "Output folder: $(if ($environment.OutputWritable) { $environment.OutputPath } else { "Not writable: $($environment.OutputError)" })"
    if (-not $environment.PowerShellReady) { throw 'PowerShell 7 or later is required.' }
    if (-not $environment.OutputWritable) { throw "Output folder is not writable: $($environment.OutputError)" }
    if (-not $plan.FixturePath -and -not $environment.GraphModuleReady) {
        $install = [bool]$InstallDependencies
        if (-not $install -and -not $NonInteractive) {
            $install = Read-A365JourneyYesNo -Prompt "Install Microsoft.Graph.Authentication $($script:A365MinimumGraphVersion) or later for CurrentUser?" -Default $true
        }
        if ($install) {
            Install-A365LauncherGraphModule
            $environment = Get-A365LauncherEnvironment -OutputPath $plan.OutputPath
        }
        elseif (-not $plan.FixturePath) {
            throw 'A live run requires Microsoft.Graph.Authentication 2.20.0 or later.'
        }
    }
    elseif ((Get-A365LauncherHostAssessment).IsWindows -and
        [version]$environment.GraphModuleVersion -ge [version]'2.34.0') {
        Write-Host 'Microsoft.Graph.Authentication 2.34 or later uses WAM for normal Windows interactive sign-in. Use Windows Terminal or PowerShell directly so a parent window is available.' -ForegroundColor DarkGray
    }
    if (-not $environment.GraphReachable -and -not $plan.FixturePath) {
        throw 'Microsoft Graph is not reachable. Review proxy, firewall, DNS, and TLS inspection settings.'
    }

    Import-Module $script:A365ModulePath -Force -ErrorAction Stop
    [object[]]$scopes = @(Get-Agent365RequiredScopes -Profile $plan.Profiles -Collector $plan.Collectors -RolePolicy $RolePolicy)
    $reviewedScope = & (Get-A365LauncherModule) {
        param($Stage, $Profiles, $Targets, $RolePolicy, $Exclusions, $Justification)
        New-A365AssessmentScope -Rules (Read-A365Json $script:RulesPath Rules) -Stage $Stage -Profiles $Profiles -SharePointSiteUrl $Targets -RolePolicy $RolePolicy -ExcludeRequirement $Exclusions -ScopeJustification $Justification
    } $plan.Stage $plan.Profiles $SharePointSiteUrl $RolePolicy $ExcludeRequirement $ScopeJustification
    $plan.Profiles = @($reviewedScope.Profiles)

    Write-A365JourneyHeading 'Planned run'
    Write-Host "Mode:       $($plan.Mode)"
    Write-Host "Stage:      $($plan.Stage)"
    Write-Host "Profiles:   $($plan.Profiles -join ', ')"
    Write-Host "Collectors: $($plan.Collectors -join ', ')"
    Write-Host "Assessment: $(@($reviewedScope.Requirements | Where-Object Applicable).Count) applicable requirements; fingerprint $($reviewedScope.Fingerprint)"
    Write-Host 'Omitting a collector does not remove its requirements. Uncollected requirements prevent passing.'
    if ($ExcludeRequirement.Count -gt 0) { Write-Warning "Explicitly excluded: $($ExcludeRequirement -join ', '). Justification: $ScopeJustification" }
    if ($plan.TenantId) { Write-Host "Tenant:     $($plan.TenantId)" }
    if ($plan.PreviousResultPath) { Write-Host "Baseline:   $($plan.PreviousResultPath)" }
    if ($plan.PSObject.Properties['PreviousHtmlPath'] -and $plan.PreviousHtmlPath) { Write-Host "Working report: $($plan.PreviousHtmlPath)" }
    if ($plan.AnswersPath) { Write-Host "Answers:    $($plan.AnswersPath)" }
    if ($plan.IsFirstRun -and -not $plan.AnswersPath) {
        Write-Host ''
        Write-Host 'Incomplete is expected on the first run. The full report will guide evidence and remediation.' -ForegroundColor Yellow
    }

    if (-not $plan.FixturePath -and -not ($ClientId -or $CertificateThumbprint)) {
        Write-A365JourneyHeading 'Sign-in and consent'
        Write-Host 'The requested scopes are derived from the selected read-only collectors:'
        Write-A365ScopeExplanation -Scopes $scopes
        Write-Host ''
        Write-Host 'Tenant consent permits the application scope. Your directory and workload roles separately determine which evidence you can read.'
        Write-Host 'No custom app registration is required for normal interactive first use.'
        & (Get-A365LauncherModule) {
            param($Scopes, $Tenant, $DelegatedClient)
            $receipt = New-A365TrustReceipt -Scopes $Scopes -TenantTarget $Tenant -DelegatedClientId $DelegatedClient -Policy (Read-A365Json (Join-Path $script:ModuleRoot 'config\assessment-policy.v2.json') Policy) -Allowlist (Read-A365Json $script:AllowlistPath Allowlist)
            Write-A365TrustReceipt $receipt
        } $scopes $plan.TenantId $DelegatedClientId

        $hostAssessment = Get-A365LauncherHostAssessment
        $method = if ($UseDeviceCode -or $plan.UseDeviceCode -or $Authentication -eq 'DeviceCode') {
            'DeviceCode'
        }
        elseif ($Authentication -eq 'Interactive') {
            'Interactive'
        }
        elseif ($hostAssessment.RecommendInteractive) {
            'Interactive'
        }
        else {
            'DeviceCode'
        }
        Write-Host "Recommended sign-in: $method. $($hostAssessment.Reason)"
        if (-not $NonInteractive) {
            $authDefault = if ($method -eq 'Interactive') { 1 } else { 2 }
            $authChoice = Read-A365JourneyChoice -Prompt 'Choose authentication' -Choices @(
                'Normal interactive sign-in (recommended in native Windows Terminal)',
                'Device-code sign-in (short completion window; portable fallback)'
            ) -Default $authDefault
            $method = @('Interactive', 'DeviceCode')[$authChoice - 1]
            if (-not (Read-A365JourneyYesNo -Prompt 'Continue to Microsoft Graph sign-in with these scopes?' -Default $true)) {
                throw 'Sign-in was cancelled before authentication.'
            }
        }
        $authResult = Invoke-A365LauncherAuthentication -Scopes $scopes -TenantId $plan.TenantId -Method $method -NonInteractive:$NonInteractive -DelegatedClientId $DelegatedClientId
        $plan.UseDeviceCode = $authResult.Method -eq 'DeviceCode'
    }

    Write-A365JourneyHeading 'Start collection'
    if (-not $NonInteractive -and -not (Read-A365JourneyYesNo -Prompt 'Run the read-only pre-flight now?' -Default $true)) {
        throw 'Pre-flight was cancelled before collection.'
    }

    $engineParameters = @{
        Profile = @($plan.Profiles)
        Collector = @($plan.Collectors)
        Stage = $plan.Stage
        OutputPath = $plan.OutputPath
        AuditWindowDays = $plan.AuditWindowDays
        AuditQueryTimeoutSeconds = $plan.AuditQueryTimeoutSeconds
        IncludeSanitizedCopy = [bool]$plan.IncludeSanitizedCopy
        RolePolicy = $RolePolicy
        ExcludeRequirement = @($ExcludeRequirement)
        ScopeJustification = $ScopeJustification
    }
    if ($plan.FixturePath) { $engineParameters.FixturePath = $plan.FixturePath }
    if ($plan.TenantId) { $engineParameters.TenantId = $plan.TenantId }
    if ($plan.AnswersPath) { $engineParameters.AnswersPath = $plan.AnswersPath }
    if ($plan.PreviousResultPath) { $engineParameters.PreviousResultPath = $plan.PreviousResultPath }
    if ($plan.UseDeviceCode) { $engineParameters.UseDeviceCode = $true }
    if ($SharePointSiteUrl.Count -gt 0) { $engineParameters.SharePointSiteUrl = $SharePointSiteUrl }
    if ($ClientId) { $engineParameters.ClientId = $ClientId }
    if ($CertificateThumbprint) { $engineParameters.CertificateThumbprint = $CertificateThumbprint }
    if ($DelegatedClientId) { $engineParameters.DelegatedClientId = $DelegatedClientId }

    $outcome = Invoke-A365JourneyEngine -Parameters $engineParameters
    Write-A365JourneyHeading 'Result'
    Write-Host "Verdict: $($outcome.Report.Verdict.Label)"
    Write-Host $outcome.Report.Verdict.Summary
    Write-Host "Full report:   $($outcome.Paths.Html)"
    Write-Host "Resume helper: $($outcome.Paths.Resume)"
    if ($outcome.Paths.SanitizedHtml) {
        Write-Host "Sharing copy:  $($outcome.Paths.SanitizedHtml)"
        Write-Host 'Use the full report for remediation. The sanitized report is only a sharing copy.'
    }
    if ($plan.Mode -eq 'Resume') {
        Write-Host "Resolved required actions: $(@($outcome.Report.Drift.ResolvedRequiredActions).Count)"
        Write-Host "Resolved blockers:         $(@($outcome.Report.Drift.ResolvedBlockers).Count)"
        Write-Host "Remaining required work:   $(@($outcome.Report.PathToReady.Items | Where-Object { $_.Status -ne 'Advisory' }).Count)"
    }

    $opened = $false
    $shouldOpen = $OpenReport -eq 'Always'
    if ($OpenReport -eq 'Ask' -and -not $NonInteractive) {
        $shouldOpen = Read-A365JourneyYesNo -Prompt 'Open the full local working report now?' -Default $true
    }
    if ($shouldOpen) {
        Open-A365FullReport -Path $outcome.Paths.Html
        $opened = $true
    }
    if (-not $NonInteractive) {
        $null = Read-Host 'Press Enter to finish'
    }

    return [pscustomobject]@{
        ExitCode = $outcome.ExitCode
        Outcome = $outcome
        Plan = $plan
        Environment = $environment
        OpenedFullReport = $opened
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $journeyParameters = @{} + $PSBoundParameters
        $null = $journeyParameters.Remove('PassThru')
        $result = Invoke-A365CustomerJourney @journeyParameters
        if ($PassThru) {
            $result
        }
        else {
            exit $result.ExitCode
        }
    }
    catch {
        Write-Error "Agent 365 pre-flight launcher stopped: $($_.Exception.Message)"
        if (-not $NonInteractive) {
            $null = Read-Host 'Press Enter to finish'
        }
        exit 3
    }
}
