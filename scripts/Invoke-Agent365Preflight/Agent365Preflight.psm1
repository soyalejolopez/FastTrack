Set-StrictMode -Version Latest

$script:ToolVersion = '1.4.1'
$script:ModuleRoot = $PSScriptRoot
$script:RulesPath = Join-Path $PSScriptRoot 'config\rules.v1.json'
$script:GuidancePath = Join-Path $PSScriptRoot 'config\guidance.v1.json'
$script:SkuCatalogPath = Join-Path $PSScriptRoot 'config\sku-catalog.v1.json'
$script:AllowlistPath = Join-Path $PSScriptRoot 'config\operation-allowlist.v1.json'

. (Join-Path $PSScriptRoot 'Private\ReportRenderer.ps1')

function Get-A365Property {
    param(
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory)]
        [string]$Name,

        [AllowNull()]
        [object]$Default = $null
    )

    if ($null -eq $InputObject) {
        return $Default
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return $Default
    }

    return $property.Value
}

function Read-A365Json {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Description
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Description was not found: $Path"
    }

    try {
        return Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -Depth 100 -ErrorAction Stop
    }
    catch {
        throw "$Description is not valid JSON: $Path. $($_.Exception.Message)"
    }
}

function Write-A365JsonFile {
    param(
        [Parameter(Mandatory)]
        [object]$InputObject,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $json = $InputObject | ConvertTo-Json -Depth 100
    [System.IO.File]::WriteAllText($Path, $json, [System.Text.UTF8Encoding]::new($false))
    return (Resolve-Path -LiteralPath $Path).Path
}

function Get-Agent365RequiredScopes {
    [CmdletBinding()]
    param(
        [Parameter()]
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
        )
    )

    $null = $Profile
    $collectors = @(
        @('TenantFoundation') + @($Collector | Where-Object { $_ -ne 'TenantFoundation' }) |
            Select-Object -Unique
    )
    $scopeMap = @{
        TenantFoundation = @('Organization.Read.All')
        Licensing = @('Organization.Read.All', 'User.Read.All')
        Roles = @('RoleManagement.Read.Directory', 'RoleEligibilitySchedule.Read.Directory')
        ServiceHealth = @('ServiceHealth.Read.All')
        Registry = @('CopilotPackages.Read.All')
        AgentIdentity = @('AgentIdentityBlueprint.Read.All', 'Application.Read.All')
        ConditionalAccess = @('Policy.Read.All')
        Defender = @('ThreatHunting.Read.All')
        Purview = @('AuditLogsQuery.Read.All')
        SharePoint = @()
    }

    return @(
        foreach ($collectorName in $collectors) {
            @($scopeMap[$collectorName])
        }
    ) | Sort-Object -Unique
}

function Test-Agent365OperationAllowed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Graph', 'ExchangeOnlineManagement', 'Microsoft.Online.SharePoint.PowerShell')]
        [string]$Adapter,

        [Parameter(Mandatory)]
        [string]$Method,

        [Parameter(Mandatory)]
        [string]$Target,

        [Parameter()]
        [object]$Allowlist
    )

    if ($null -eq $Allowlist) {
        $Allowlist = Read-A365Json -Path $script:AllowlistPath -Description 'Operation allowlist'
    }

    if ($Adapter -eq 'Graph') {
        $normalizedMethod = $Method.ToUpperInvariant()
        $methodProperty = $Allowlist.graph.PSObject.Properties[$normalizedMethod]
        if ($null -eq $methodProperty) {
            return $false
        }

        try {
            $uri = if ([Uri]::IsWellFormedUriString($Target, [UriKind]::Absolute)) {
                [Uri]$Target
            }
            else {
                [Uri]("https://graph.microsoft.com/$($Target.TrimStart('/'))")
            }
        }
        catch {
            return $false
        }

        if ($Allowlist.graph.hosts -notcontains $uri.DnsSafeHost) {
            return $false
        }

        $pathAndQuery = $uri.PathAndQuery
        foreach ($pattern in @($methodProperty.Value)) {
            if ($pathAndQuery -match $pattern) {
                return $true
            }
        }

        return $false
    }

    if ($Method.ToUpperInvariant() -ne 'COMMAND') {
        return $false
    }

    $moduleProperty = $Allowlist.modules.PSObject.Properties[$Adapter]
    if ($null -eq $moduleProperty) {
        return $false
    }

    return @($moduleProperty.Value) -contains $Target
}

function Invoke-Agent365PagedRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$InitialUri,

        [Parameter(Mandatory)]
        [scriptblock]$RequestScript,

        [Parameter()]
        [ValidateRange(0, 10)]
        [int]$MaxRetryCount = 3,

        [Parameter()]
        [scriptblock]$SleepScript = { param([int]$Seconds) Start-Sleep -Seconds $Seconds }
    )

    $items = [System.Collections.Generic.List[object]]::new()
    $uri = $InitialUri

    while ($uri) {
        $attempt = 0
        $response = $null

        while ($true) {
            $response = & $RequestScript $uri
            $statusCode = Get-A365Property -InputObject $response -Name 'StatusCode' -Default 200

            if ([int]$statusCode -ne 429) {
                break
            }

            if ($attempt -ge $MaxRetryCount) {
                throw "Request remained throttled after $($attempt + 1) attempts: $uri"
            }

            $retryAfter = [int](Get-A365Property -InputObject $response -Name 'RetryAfter' -Default ([Math]::Pow(2, $attempt)))
            $null = & $SleepScript ([Math]::Max(0, $retryAfter))
            $attempt++
        }

        $body = Get-A365Property -InputObject $response -Name 'Body' -Default $response
        foreach ($item in @(Get-A365Property -InputObject $body -Name 'value' -Default @())) {
            $items.Add($item)
        }

        $uri = [string](Get-A365Property -InputObject $body -Name '@odata.nextLink' -Default '')
    }

    return $items.ToArray()
}

function Get-A365HttpError {
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $exception = $ErrorRecord.Exception
    $statusCode = Get-A365Property -InputObject $exception -Name 'ResponseStatusCode' -Default $null
    $retryAfter = $null

    if ($null -eq $statusCode) {
        $response = Get-A365Property -InputObject $exception -Name 'Response' -Default $null
        if ($null -ne $response) {
            $statusCode = Get-A365Property -InputObject $response -Name 'StatusCode' -Default $null
            $headers = Get-A365Property -InputObject $response -Name 'Headers' -Default $null
            if ($null -ne $headers) {
                $retryHeader = Get-A365Property -InputObject $headers -Name 'RetryAfter' -Default $null
                if ($null -ne $retryHeader) {
                    $delta = Get-A365Property -InputObject $retryHeader -Name 'Delta' -Default $null
                    if ($null -ne $delta) {
                        $retryAfter = [int][Math]::Ceiling($delta.TotalSeconds)
                    }
                }
            }
        }
    }

    if ($null -ne $statusCode -and $statusCode.PSObject.Properties['value__']) {
        $statusCode = $statusCode.value__
    }

    return [pscustomobject]@{
        StatusCode = if ($null -eq $statusCode) { $null } else { [int]$statusCode }
        RetryAfter = $retryAfter
        Message = $exception.Message
    }
}

function Resolve-A365IssueCategory {
    param(
        [AllowNull()]
        [int]$StatusCode,

        [Parameter(Mandatory)]
        [string]$Message,

        [Parameter(Mandatory)]
        [string]$RequiredPermission
    )

    if ($StatusCode -eq 401) {
        return 'Authentication'
    }

    if ($StatusCode -eq 403) {
        if ($Message -match '(?i)consent') {
            return 'TenantConsent'
        }
        if ($RequiredPermission -and $RequiredPermission -ne 'None') {
            return 'PermissionOrRole'
        }
        return 'Authorization'
    }

    if ($StatusCode -eq 404) {
        return 'WorkloadAvailability'
    }

    if ($StatusCode -eq 429) {
        return 'Throttling'
    }

    if ($Message -match '(?i)(schema|column|table|property.*not found|invalid.*query)') {
        return 'SchemaOrApi'
    }

    if ($Message -match '(?i)(license|subscription)') {
        return 'License'
    }

    if ($Message -match '(?i)(timed out|timeout)') {
        return 'Timeout'
    }

    return 'Api'
}

function New-A365CollectionIssue {
    param(
        [Parameter(Mandatory)]
        [string]$Adapter,

        [Parameter(Mandatory)]
        [string]$Operation,

        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord,

        [Parameter()]
        [string]$RequiredPermission = 'None',

        [Parameter()]
        [string]$DocsUrl = 'https://learn.microsoft.com/microsoft-agent-365/'
    )

    $http = Get-A365HttpError -ErrorRecord $ErrorRecord
    return [pscustomobject][ordered]@{
        Adapter = $Adapter
        Operation = $Operation
        Category = Resolve-A365IssueCategory -StatusCode $http.StatusCode -Message $http.Message -RequiredPermission $RequiredPermission
        StatusCode = $http.StatusCode
        Message = $http.Message
        RequiredPermission = $RequiredPermission
        DocsUrl = $DocsUrl
    }
}

function Invoke-A365GraphRequest {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('GET', 'POST')]
        [string]$Method,

        [Parameter(Mandatory)]
        [string]$Uri,

        [AllowNull()]
        [object]$Body,

        [Parameter(Mandatory)]
        [object]$Allowlist,

        [Parameter()]
        [int]$MaxRetryCount = 3
    )

    if (-not (Test-Agent365OperationAllowed -Adapter Graph -Method $Method -Target $Uri -Allowlist $Allowlist)) {
        throw "Blocked operation outside the Agent 365 pre-flight allowlist: $Method $Uri"
    }

    $attempt = 0
    while ($true) {
        try {
            $parameters = @{
                Method = $Method
                Uri = $Uri
                OutputType = 'PSObject'
                ErrorAction = 'Stop'
            }
            if ($null -ne $Body) {
                $parameters.Body = ($Body | ConvertTo-Json -Depth 20 -Compress)
                $parameters.ContentType = 'application/json'
            }

            return Invoke-MgGraphRequest @parameters
        }
        catch {
            $http = Get-A365HttpError -ErrorRecord $_
            if ($http.StatusCode -ne 429 -or $attempt -ge $MaxRetryCount) {
                throw
            }

            $seconds = if ($null -ne $http.RetryAfter) {
                $http.RetryAfter
            }
            else {
                [int][Math]::Pow(2, $attempt)
            }
            Start-Sleep -Seconds ([Math]::Max(1, $seconds))
            $attempt++
        }
    }
}

function Get-A365RetryAfterSeconds {
    param(
        [AllowNull()]
        [object]$Response
    )

    foreach ($propertyName in @('retryAfterSeconds', 'retryAfter', 'Retry-After')) {
        $value = Get-A365Property -InputObject $Response -Name $propertyName -Default $null
        if ($null -eq $value) {
            continue
        }

        $seconds = 0
        if ([int]::TryParse([string]$value, [ref]$seconds) -and $seconds -gt 0) {
            return $seconds
        }
    }

    return $null
}

function Wait-A365AuditQuery {
    param(
        [Parameter(Mandatory)]
        [object]$InitialResponse,

        [Parameter(Mandatory)]
        [string]$QueryId,

        [Parameter(Mandatory)]
        [object]$Allowlist,

        [Parameter(Mandatory)]
        [ValidateRange(30, 900)]
        [int]$TimeoutSeconds,

        [Parameter()]
        [ValidateRange(1, 30)]
        [int]$PollIntervalSeconds = 5,

        [Parameter()]
        [scriptblock]$RequestScript = {
            param($RequestUri, $RequestAllowlist)
            Invoke-A365GraphRequest -Method GET -Uri $RequestUri -Allowlist $RequestAllowlist
        },

        [Parameter()]
        [scriptblock]$SleepScript = {
            param([int]$Seconds)
            Start-Sleep -Seconds $Seconds
        },

        [Parameter()]
        [scriptblock]$UtcNowScript = {
            [DateTimeOffset]::UtcNow
        }
    )

    $startedAt = [DateTimeOffset](& $UtcNowScript)
    $deadline = $startedAt.AddSeconds($TimeoutSeconds)
    $response = $InitialResponse
    $status = ([string](Get-A365Property -InputObject $response -Name 'status' -Default 'unknownFutureValue')).Trim().ToLowerInvariant()
    $pollCount = 0
    $terminalStatuses = @('succeeded', 'failed', 'cancelled')

    while ($status -notin $terminalStatuses) {
        $now = [DateTimeOffset](& $UtcNowScript)
        if ($now -ge $deadline) {
            break
        }

        $remainingSeconds = [int][Math]::Ceiling(($deadline - $now).TotalSeconds)
        $retryAfterSeconds = Get-A365RetryAfterSeconds -Response $response
        $delaySeconds = if ($null -ne $retryAfterSeconds) {
            $retryAfterSeconds
        }
        else {
            $PollIntervalSeconds
        }
        $delaySeconds = [Math]::Min($delaySeconds, $remainingSeconds)
        if ($delaySeconds -le 0) {
            break
        }

        $null = & $SleepScript $delaySeconds
        if ([DateTimeOffset](& $UtcNowScript) -ge $deadline) {
            break
        }
        $pollCount++
        $response = & $RequestScript `
            "https://graph.microsoft.com/v1.0/security/auditLog/queries/$QueryId" `
            $Allowlist
        $status = ([string](Get-A365Property -InputObject $response -Name 'status' -Default 'unknownFutureValue')).Trim().ToLowerInvariant()
    }

    $finishedAt = [DateTimeOffset](& $UtcNowScript)
    $timedOut = $status -notin $terminalStatuses -and $finishedAt -ge $deadline
    return [pscustomobject]@{
        Status = $status
        TimedOut = $timedOut
        PollCount = $pollCount
        ElapsedSeconds = [Math]::Round(($finishedAt - $startedAt).TotalSeconds, 2)
    }
}

function Invoke-A365GraphPages {
    param(
        [Parameter(Mandatory)]
        [string]$InitialUri,

        [Parameter(Mandatory)]
        [object]$Allowlist,

        [Parameter(Mandatory)]
        [scriptblock]$ProcessPage
    )

    $uri = $InitialUri
    while ($uri) {
        $page = Invoke-A365GraphRequest -Method GET -Uri $uri -Allowlist $Allowlist
        $null = & $ProcessPage $page
        $uri = [string](Get-A365Property -InputObject $page -Name '@odata.nextLink' -Default '')
        $page = $null
    }
}

function Get-A365ActiveContext {
    $context = Get-MgContext -ErrorAction SilentlyContinue
    if ($null -eq $context) {
        return $null
    }
    return $context
}

function New-A365SafeStartupException {
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    $exception = [System.InvalidOperationException]::new($Message)
    $exception.Data['Agent365SafeStartupAbort'] = $true
    return $exception
}

function Test-A365GraphEndpointReachability {
    param(
        [Parameter(Mandatory)]
        [object]$Allowlist
    )

    $httpClient = $null
    $httpRequest = $null
    $httpResponse = $null
    try {
        $metadataUri = 'https://graph.microsoft.com/v1.0/$metadata'
        if (-not (Test-Agent365OperationAllowed -Adapter Graph -Method GET -Target $metadataUri -Allowlist $Allowlist)) {
            throw 'The Microsoft Graph metadata reachability probe is not allowed by the operation allowlist.'
        }

        $httpClient = [System.Net.Http.HttpClient]::new()
        $httpClient.Timeout = [TimeSpan]::FromSeconds(15)
        $httpRequest = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $metadataUri)
        $httpResponse = $httpClient.SendAsync(
            $httpRequest,
            [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
        ).GetAwaiter().GetResult()
        return [int]$httpResponse.StatusCode -lt 500
    }
    finally {
        if ($null -ne $httpResponse) { $httpResponse.Dispose() }
        if ($null -ne $httpRequest) { $httpRequest.Dispose() }
        if ($null -ne $httpClient) { $httpClient.Dispose() }
    }
}

function New-A365TenantTargetAssertion {
    param(
        [AllowNull()]
        [string]$RequestedTenant,

        [AllowNull()]
        [string]$ActualTenantId
    )

    if ([string]::IsNullOrWhiteSpace($RequestedTenant)) {
        return [pscustomobject][ordered]@{
            requested = $false
            expected = $null
            method = 'NotRequested'
            matched = $null
            actualTenantId = $ActualTenantId
            matchedVerifiedDomain = $null
        }
    }

    $expected = $RequestedTenant.Trim()
    $parsedGuid = [Guid]::Empty
    if ([Guid]::TryParse($expected, [ref]$parsedGuid)) {
        $matched = [string]::Equals(
            $parsedGuid.ToString(),
            ([string]$ActualTenantId).Trim(),
            [StringComparison]::OrdinalIgnoreCase
        )
        if (-not $matched) {
            throw (New-A365SafeStartupException -Message "Tenant target mismatch. Expected tenant ID '$expected' but Microsoft Graph connected to tenant ID '$ActualTenantId'. No tenant collectors were run and no report was written.")
        }

        return [pscustomobject][ordered]@{
            requested = $true
            expected = $expected
            method = 'TenantId'
            matched = $true
            actualTenantId = $ActualTenantId
            matchedVerifiedDomain = $null
        }
    }

    return [pscustomobject][ordered]@{
        requested = $true
        expected = $expected
        method = 'VerifiedDomain'
        matched = $null
        actualTenantId = $ActualTenantId
        matchedVerifiedDomain = $null
    }
}

function Connect-A365GraphContext {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Scopes,

        [AllowNull()]
        [string]$TenantId,

        [AllowNull()]
        [string]$ClientId,

        [AllowNull()]
        [string]$CertificateThumbprint,

        [Parameter()]
        [switch]$UseDeviceCode
    )

    $hasClientId = -not [string]::IsNullOrWhiteSpace($ClientId)
    $hasCertificate = -not [string]::IsNullOrWhiteSpace($CertificateThumbprint)
    $appOnly = $hasClientId -or $hasCertificate

    if ($appOnly) {
        if ($UseDeviceCode) {
            throw (New-A365SafeStartupException -Message 'UseDeviceCode is available only for interactive delegated authentication and cannot be combined with certificate app-only parameters.')
        }

        $missing = @()
        if ([string]::IsNullOrWhiteSpace($TenantId)) { $missing += 'TenantId' }
        if (-not $hasClientId) { $missing += 'ClientId' }
        if (-not $hasCertificate) { $missing += 'CertificateThumbprint' }
        if ($missing.Count -gt 0) {
            throw (New-A365SafeStartupException -Message "Certificate app-only authentication requires TenantId, ClientId, and CertificateThumbprint together. Missing: $($missing -join ', ').")
        }
    }

    $existingContext = Get-A365ActiveContext
    if (-not $appOnly -and (Test-A365ReusableDelegatedContext -Context $existingContext -Scopes $Scopes -TenantId $TenantId)) {
        return [pscustomobject]@{
            Context = $existingContext
            AppOnly = $false
            ReusedExistingContext = $true
            UseDeviceCode = [bool]$UseDeviceCode
            TargetAssertion = New-A365TenantTargetAssertion `
                -RequestedTenant $TenantId `
                -ActualTenantId ([string](Get-A365Property -InputObject $existingContext -Name 'TenantId' -Default ''))
        }
    }

    if ($appOnly) {
        $null = Connect-MgGraph `
            -TenantId $TenantId `
            -ClientId $ClientId `
            -CertificateThumbprint $CertificateThumbprint `
            -ContextScope Process `
            -NoWelcome `
            -ErrorAction Stop
    }
    else {
        $connectParameters = @{
            Scopes = $Scopes
            ContextScope = 'Process'
            NoWelcome = $true
            ErrorAction = 'Stop'
        }
        if (-not [string]::IsNullOrWhiteSpace($TenantId)) {
            $connectParameters.TenantId = $TenantId.Trim()
        }
        if ($UseDeviceCode) {
            $connectParameters.UseDeviceCode = $true
        }
        $null = Connect-MgGraph @connectParameters
    }

    $context = Get-A365ActiveContext
    if ($null -eq $context) {
        throw 'Microsoft Graph authentication completed without an active context.'
    }

    return [pscustomobject]@{
        Context = $context
        AppOnly = $appOnly
        ReusedExistingContext = $false
        UseDeviceCode = [bool]$UseDeviceCode
        TargetAssertion = New-A365TenantTargetAssertion `
            -RequestedTenant $TenantId `
            -ActualTenantId ([string](Get-A365Property -InputObject $context -Name 'TenantId' -Default ''))
    }
}

function Test-A365ReusableDelegatedContext {
    param(
        [AllowNull()]
        [object]$Context,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Scopes,

        [AllowNull()]
        [string]$TenantId
    )

    if ($null -eq $Context) {
        return $false
    }

    $actualTenantId = [string](Get-A365Property -InputObject $Context -Name 'TenantId' -Default '')
    if ([string]::IsNullOrWhiteSpace($actualTenantId)) {
        return $false
    }

    $authType = [string](Get-A365Property -InputObject $Context -Name 'AuthType' -Default '')
    $account = [string](Get-A365Property -InputObject $Context -Name 'Account' -Default '')
    if ($authType -match '(?i)appOnly|clientCredential' -or
        ($authType -notmatch '(?i)delegated|user' -and [string]::IsNullOrWhiteSpace($account))) {
        return $false
    }

    [object[]]$existingScopes = @(
        Get-A365Property -InputObject $Context -Name 'Scopes' -Default @() |
            ForEach-Object { [string]$_ }
    )
    foreach ($scope in $Scopes) {
        $hasScope = @(
            $existingScopes |
                Where-Object {
                    [string]::Equals($_, $scope, [StringComparison]::OrdinalIgnoreCase)
                }
        ).Count -gt 0
        if (-not $hasScope) {
            return $false
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($TenantId)) {
        $parsedTenantId = [Guid]::Empty
        # Verified-domain targets are asserted against organization data after connect or reuse.
        if ([Guid]::TryParse($TenantId.Trim(), [ref]$parsedTenantId) -and
            -not [string]::Equals(
                $parsedTenantId.ToString(),
                $actualTenantId.Trim(),
                [StringComparison]::OrdinalIgnoreCase
            )) {
            return $false
        }
    }

    return $true
}

function Confirm-A365DomainTenantTarget {
    param(
        [Parameter(Mandatory)]
        [object]$TargetAssertion,

        [AllowNull()]
        [object]$Organization
    )

    if ((Get-A365Property -InputObject $TargetAssertion -Name 'method' -Default '') -ne 'VerifiedDomain') {
        return $TargetAssertion
    }

    $expectedDomain = [string](Get-A365Property -InputObject $TargetAssertion -Name 'expected' -Default '')
    $verifiedDomains = @(
        Get-A365Property -InputObject $Organization -Name 'verifiedDomains' -Default @() |
            ForEach-Object { [string](Get-A365Property -InputObject $_ -Name 'name' -Default '') }
    )
    $matchedDomain = @(
        $verifiedDomains |
            Where-Object {
                [string]::Equals(
                    $_.TrimEnd('.'),
                    $expectedDomain.TrimEnd('.'),
                    [StringComparison]::OrdinalIgnoreCase
                )
            }
    ) | Select-Object -First 1

    if (-not $matchedDomain) {
        $actualTenantId = Get-A365Property -InputObject $TargetAssertion -Name 'actualTenantId' -Default 'unknown'
        throw (New-A365SafeStartupException -Message "Tenant target mismatch. Expected verified domain '$expectedDomain', but connected tenant ID '$actualTenantId' does not list that domain. No non-foundation collectors were run and no report was written.")
    }

    $TargetAssertion.matched = $true
    $TargetAssertion.matchedVerifiedDomain = $matchedDomain
    return $TargetAssertion
}

function Get-A365OrganizationContext {
    param(
        [Parameter(Mandatory)]
        [object]$Allowlist,

        [Parameter(Mandatory)]
        [object]$TargetAssertion
    )

    $response = Invoke-A365GraphRequest `
        -Method GET `
        -Uri 'https://graph.microsoft.com/v1.0/organization?$select=id,displayName,verifiedDomains' `
        -Allowlist $Allowlist
    $organization = @(Get-A365Property -InputObject $response -Name 'value' -Default @()) |
        Select-Object -First 1
    $confirmedAssertion = Confirm-A365DomainTenantTarget `
        -TargetAssertion $TargetAssertion `
        -Organization $organization

    return [pscustomobject]@{
        Organization = $organization
        TargetAssertion = $confirmedAssertion
    }
}

function Get-A365RoleSummary {
    param(
        [Parameter(Mandatory)]
        [string]$Uri,

        [Parameter(Mandatory)]
        [object]$Allowlist
    )

    $counts = @{}
    Invoke-A365GraphPages -InitialUri $Uri -Allowlist $Allowlist -ProcessPage {
        param($Page)
        foreach ($assignment in @(Get-A365Property -InputObject $Page -Name 'value' -Default @())) {
            $definition = Get-A365Property -InputObject $assignment -Name 'roleDefinition' -Default $null
            $name = [string](Get-A365Property -InputObject $definition -Name 'displayName' -Default '')
            if (-not $name) {
                $name = [string](Get-A365Property -InputObject $assignment -Name 'roleDefinitionId' -Default 'Unknown role')
            }
            if (-not $counts.ContainsKey($name)) {
                $counts[$name] = 0
            }
            $counts[$name]++
        }
    }

    return @(
        foreach ($name in ($counts.Keys | Sort-Object)) {
            [pscustomobject]@{
                role = $name
                assignmentCount = $counts[$name]
            }
        }
    )
}

function Invoke-A365OptionalCommandCount {
    param(
        [Parameter(Mandatory)]
        [string]$Adapter,

        [Parameter(Mandatory)]
        [string]$CommandName,

        [Parameter(Mandatory)]
        [object]$Allowlist
    )

    if (-not (Test-Agent365OperationAllowed -Adapter $Adapter -Method COMMAND -Target $CommandName -Allowlist $Allowlist)) {
        throw "Blocked module command outside the Agent 365 pre-flight allowlist: $CommandName"
    }

    $command = Get-Command -Name $CommandName -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        return $null
    }

    $items = @(& $CommandName -ErrorAction Stop)
    return $items.Count
}

function Get-A365LiveEvidence {
    param(
        [Parameter(Mandatory)]
        [string[]]$Profiles,

        [Parameter(Mandatory)]
        [string[]]$Collectors,

        [Parameter(Mandatory)]
        [string[]]$Scopes,

        [Parameter(Mandatory)]
        [object]$SkuCatalog,

        [Parameter(Mandatory)]
        [object]$Allowlist,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Issues,

        [Parameter()]
        [switch]$InstallDependencies,

        [Parameter()]
        [string[]]$SharePointSiteUrl = @(),

        [Parameter()]
        [int]$AuditWindowDays = 7,

        [Parameter()]
        [ValidateRange(30, 900)]
        [int]$AuditQueryTimeoutSeconds = 300,

        [Parameter()]
        [string]$TenantId,

        [Parameter()]
        [string]$ClientId,

        [Parameter()]
        [string]$CertificateThumbprint,

        [Parameter()]
        [switch]$UseDeviceCode
    )

    $graphModule = Get-Module -ListAvailable -Name Microsoft.Graph.Authentication |
        Sort-Object Version -Descending |
        Select-Object -First 1

    if ($null -eq $graphModule -and $InstallDependencies) {
        Install-Module Microsoft.Graph.Authentication -MinimumVersion 2.20.0 -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
        $graphModule = Get-Module -ListAvailable -Name Microsoft.Graph.Authentication |
            Sort-Object Version -Descending |
            Select-Object -First 1
    }

    $local = [pscustomobject][ordered]@{
        powerShellVersion = $PSVersionTable.PSVersion.ToString()
        platform = "$($PSVersionTable.Platform) $([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture)"
        graphModuleVersion = if ($graphModule) { $graphModule.Version.ToString() } else { $null }
        graphEndpointReachable = $false
    }

    try {
        $local.graphEndpointReachable = Test-A365GraphEndpointReachability -Allowlist $Allowlist
    }
    catch {
        $Issues.Add((New-A365CollectionIssue -Adapter Local -Operation 'Graph endpoint reachability' -ErrorRecord $_ -DocsUrl 'https://learn.microsoft.com/graph/deployments'))
    }

    if ($null -eq $graphModule) {
        return [pscustomobject][ordered]@{
            generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
            local = $local
            authentication = [pscustomobject]@{
                mode = 'Unavailable'
                account = $null
                requestedScopes = $Scopes
                grantedScopes = @()
                useDeviceCode = [bool]$UseDeviceCode
                reusedExistingContext = $false
            }
            tenant = [pscustomobject]@{
                displayName = $null
                tenantId = $null
                primaryDomain = $null
                cloud = 'Unknown'
                commercialAvailability = $null
                targetAssertion = [pscustomobject]@{
                    requested = -not [string]::IsNullOrWhiteSpace($TenantId)
                    expected = $TenantId
                    method = 'Unverified'
                    matched = $false
                    actualTenantId = $null
                    matchedVerifiedDomain = $null
                }
            }
            collectionIssues = $Issues.ToArray()
        }
    }

    Import-Module Microsoft.Graph.Authentication -MinimumVersion 2.20.0 -ErrorAction Stop

    $appOnly = -not [string]::IsNullOrWhiteSpace($ClientId) -or
        -not [string]::IsNullOrWhiteSpace($CertificateThumbprint)
    $context = $null
    $connection = $null
    $targetAssertion = [pscustomobject][ordered]@{
        requested = -not [string]::IsNullOrWhiteSpace($TenantId)
        expected = $TenantId
        method = 'Unverified'
        matched = $false
        actualTenantId = $null
        matchedVerifiedDomain = $null
    }

    try {
        $connection = Connect-A365GraphContext `
            -Scopes $Scopes `
            -TenantId $TenantId `
            -ClientId $ClientId `
            -CertificateThumbprint $CertificateThumbprint `
            -UseDeviceCode:$UseDeviceCode
        $context = $connection.Context
        $appOnly = [bool]$connection.AppOnly
        $targetAssertion = $connection.TargetAssertion
    }
    catch {
        if ($_.Exception.Data['Agent365SafeStartupAbort']) {
            throw
        }
        $authenticationIssue = New-A365CollectionIssue -Adapter Graph -Operation 'Microsoft Graph authentication' -ErrorRecord $_ -RequiredPermission ($Scopes -join ', ') -DocsUrl 'https://learn.microsoft.com/powershell/microsoftgraph/authentication-commands'
        $authenticationIssue.Category = 'Authentication'
        $Issues.Add($authenticationIssue)
        return [pscustomobject][ordered]@{
            generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
            local = $local
            authentication = [pscustomobject]@{
                mode = if ($appOnly) { 'CertificateAppOnly' } else { 'InteractiveDelegated' }
                account = $null
                requestedScopes = $Scopes
                grantedScopes = @()
                useDeviceCode = [bool]$UseDeviceCode
                reusedExistingContext = $false
            }
            tenant = [pscustomobject]@{
                displayName = $null
                tenantId = $TenantId
                primaryDomain = $null
                cloud = 'Unknown'
                commercialAvailability = $null
                targetAssertion = $targetAssertion
            }
            collectionIssues = $Issues.ToArray()
        }
    }

    $grantedScopes = @($context.Scopes | Sort-Object -Unique)
    $authentication = [pscustomobject][ordered]@{
        mode = if ($appOnly) { 'CertificateAppOnly' } else { 'InteractiveDelegated' }
        account = if ($appOnly) { "Application $ClientId" } else { $context.Account }
        requestedScopes = $Scopes
        grantedScopes = $grantedScopes
        useDeviceCode = [bool]$connection.UseDeviceCode
        reusedExistingContext = [bool]$connection.ReusedExistingContext
    }

    $environment = [string](Get-A365Property -InputObject $context -Name 'Environment' -Default 'Global')
    $commercial = $environment -in @('Global', 'GlobalV2')
    $evidence = [ordered]@{
        generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        local = $local
        authentication = $authentication
        tenant = [pscustomobject][ordered]@{
            displayName = $null
            tenantId = $context.TenantId
            primaryDomain = $null
            cloud = $environment
            commercialAvailability = $commercial
            targetAssertion = $targetAssertion
        }
        licensing = $null
        roles = $null
        serviceHealth = $null
        registry = $null
        agentIdentity = $null
        conditionalAccess = $null
        defender = $null
        purview = $null
        sharePoint = $null
    }

    try {
        $organizationContext = Get-A365OrganizationContext `
            -Allowlist $Allowlist `
            -TargetAssertion $targetAssertion
        $organization = $organizationContext.Organization
        $evidence.tenant.targetAssertion = $organizationContext.TargetAssertion
        if ($organization) {
            $evidence.tenant.displayName = Get-A365Property -InputObject $organization -Name 'displayName' -Default $null
            $evidence.tenant.tenantId = Get-A365Property -InputObject $organization -Name 'id' -Default $context.TenantId
            $defaultDomain = @(Get-A365Property -InputObject $organization -Name 'verifiedDomains' -Default @()) |
                Where-Object { (Get-A365Property -InputObject $_ -Name 'isDefault' -Default $false) -eq $true } |
                Select-Object -First 1
            $evidence.tenant.primaryDomain = Get-A365Property -InputObject $defaultDomain -Name 'name' -Default $null
        }
    }
    catch {
        if ($_.Exception.Data['Agent365SafeStartupAbort']) {
            throw
        }
        if ((Get-A365Property -InputObject $targetAssertion -Name 'method' -Default '') -eq 'VerifiedDomain') {
            throw (New-A365SafeStartupException -Message "Unable to verify requested tenant domain '$TenantId' from Microsoft Graph organization data. No non-foundation collectors were run and no report was written. $($_.Exception.Message)")
        }
        $Issues.Add((New-A365CollectionIssue -Adapter Graph -Operation 'Organization context' -ErrorRecord $_ -RequiredPermission 'Organization.Read.All' -DocsUrl 'https://learn.microsoft.com/graph/api/organization-get'))
    }

    if (-not $commercial) {
        $evidence.collectionIssues = $Issues.ToArray()
        return [pscustomobject]$evidence
    }

    if ($Collectors -contains 'Licensing') {
    try {
        $skuResponse = Invoke-A365GraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/subscribedSkus?$select=skuId,skuPartNumber,capabilityStatus,consumedUnits,servicePlans' -Allowlist $Allowlist
        $subscribedSkus = @(
            foreach ($sku in @(Get-A365Property -InputObject $skuResponse -Name 'value' -Default @())) {
                [pscustomobject][ordered]@{
                    skuPartNumber = Get-A365Property -InputObject $sku -Name 'skuPartNumber' -Default 'Unknown'
                    skuId = [string](Get-A365Property -InputObject $sku -Name 'skuId' -Default '')
                    capabilityStatus = Get-A365Property -InputObject $sku -Name 'capabilityStatus' -Default 'Unknown'
                    consumedUnits = Get-A365Property -InputObject $sku -Name 'consumedUnits' -Default 0
                    servicePlans = @(
                        foreach ($plan in @(Get-A365Property -InputObject $sku -Name 'servicePlans' -Default @())) {
                            [pscustomobject]@{
                                servicePlanName = Get-A365Property -InputObject $plan -Name 'servicePlanName' -Default 'Unknown'
                                servicePlanId = [string](Get-A365Property -InputObject $plan -Name 'servicePlanId' -Default '')
                                provisioningStatus = Get-A365Property -InputObject $plan -Name 'provisioningStatus' -Default 'Unknown'
                            }
                        }
                    )
                }
            }
        )

        $qualifyingPlanIds = @($SkuCatalog.qualifyingProducts.qualifyingServicePlanId | Sort-Object -Unique)
        $licenseCounter = [pscustomobject]@{ QualifyingAssignedUsers = 0 }
        Invoke-A365GraphPages -InitialUri 'https://graph.microsoft.com/v1.0/users?$select=assignedPlans&$top=999' -Allowlist $Allowlist -ProcessPage {
            param($Page)
            foreach ($user in @(Get-A365Property -InputObject $Page -Name 'value' -Default @())) {
                $hasPlan = @(
                    Get-A365Property -InputObject $user -Name 'assignedPlans' -Default @() |
                        Where-Object {
                            ([string](Get-A365Property -InputObject $_ -Name 'servicePlanId' -Default '')) -in $qualifyingPlanIds -and
                            ([string](Get-A365Property -InputObject $_ -Name 'capabilityStatus' -Default '')) -eq 'Enabled'
                        }
                ).Count -gt 0
                if ($hasPlan) {
                    $licenseCounter.QualifyingAssignedUsers++
                }
            }
        }

        $knownSkuParts = @($SkuCatalog.qualifyingProducts.skuPartNumber)
        $unknownSkuMappings = @(
            $subscribedSkus |
                Where-Object {
                    $_.skuPartNumber -match '(?i)(AGENT.*365|365.*E7)' -and
                    $_.skuPartNumber -notin $knownSkuParts
                } |
                Select-Object -ExpandProperty skuPartNumber
        )

        $evidence.licensing = [pscustomobject][ordered]@{
            subscribedSkus = $subscribedSkus
            qualifyingAssignedUsers = $licenseCounter.QualifyingAssignedUsers
            unknownSkuMappings = $unknownSkuMappings
        }
    }
    catch {
        $Issues.Add((New-A365CollectionIssue -Adapter Graph -Operation 'Licensing and assigned service plans' -ErrorRecord $_ -RequiredPermission 'Organization.Read.All, User.Read.All' -DocsUrl 'https://learn.microsoft.com/microsoft-agent-365/overview#plans-and-licensing'))
    }
    }

    if ($Collectors -contains 'Roles') {
    [object[]]$activeRoles = @()
    try {
        $activeRoles = @(
            Get-A365RoleSummary -Uri 'https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments?$expand=roleDefinition&$top=999' -Allowlist $Allowlist
        )
    }
    catch {
        $Issues.Add((New-A365CollectionIssue -Adapter Graph -Operation 'Active directory roles' -ErrorRecord $_ -RequiredPermission 'RoleManagement.Read.Directory' -DocsUrl 'https://learn.microsoft.com/microsoft-365/admin/manage/agent-roles-perms'))
    }

    [object[]]$eligibleRoles = @()
    try {
        $eligibleRoles = @(
            Get-A365RoleSummary -Uri 'https://graph.microsoft.com/v1.0/roleManagement/directory/roleEligibilityScheduleInstances?$expand=roleDefinition&$top=999' -Allowlist $Allowlist
        )
    }
    catch {
        $Issues.Add((New-A365CollectionIssue -Adapter Graph -Operation 'Eligible directory roles' -ErrorRecord $_ -RequiredPermission 'RoleEligibilitySchedule.Read.Directory' -DocsUrl 'https://learn.microsoft.com/graph/api/rbacapplication-list-roleeligibilityscheduleinstances?view=graph-rest-1.0'))
    }
    $evidence.roles = [pscustomobject]@{
        active = $activeRoles
        eligible = $eligibleRoles
    }
    }

    if ($Collectors -contains 'ServiceHealth') {
    try {
        $healthCounter = [pscustomobject]@{ ActiveIssueCount = 0 }
        $affectedServices = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        Invoke-A365GraphPages -InitialUri 'https://graph.microsoft.com/v1.0/admin/serviceAnnouncement/healthOverviews?$expand=issues&$top=100' -Allowlist $Allowlist -ProcessPage {
            param($Page)
            foreach ($service in @(Get-A365Property -InputObject $Page -Name 'value' -Default @())) {
                $openIssues = @(
                    Get-A365Property -InputObject $service -Name 'issues' -Default @() |
                        Where-Object { -not (Get-A365Property -InputObject $_ -Name 'isResolved' -Default $false) }
                )
                if ($openIssues.Count -gt 0) {
                    $healthCounter.ActiveIssueCount += $openIssues.Count
                    $null = $affectedServices.Add([string](Get-A365Property -InputObject $service -Name 'service' -Default 'Unknown service'))
                }
            }
        }
        $evidence.serviceHealth = [pscustomobject]@{
            available = $true
            activeIssueCount = $healthCounter.ActiveIssueCount
            affectedServices = @($affectedServices | Sort-Object)
        }
    }
    catch {
        $Issues.Add((New-A365CollectionIssue -Adapter Graph -Operation 'Service health' -ErrorRecord $_ -RequiredPermission 'ServiceHealth.Read.All' -DocsUrl 'https://learn.microsoft.com/graph/service-communications-concept-overview'))
        $evidence.serviceHealth = [pscustomobject]@{ available = $false }
    }
    }

    if ($Collectors -contains 'Registry') {
    try {
        $packageGroups = @{}
        $packageCounter = [pscustomobject]@{ Count = 0 }
        Invoke-A365GraphPages -InitialUri 'https://graph.microsoft.com/v1.0/copilot/admin/catalog/packages' -Allowlist $Allowlist -ProcessPage {
            param($Page)
            foreach ($package in @(Get-A365Property -InputObject $Page -Name 'value' -Default @())) {
                $packageCounter.Count++
                $platform = [string](Get-A365Property -InputObject $package -Name 'platform' -Default 'Unknown')
                $type = [string](Get-A365Property -InputObject $package -Name 'type' -Default 'Unknown')
                $blocked = [bool](Get-A365Property -InputObject $package -Name 'isBlocked' -Default $false)
                $scope = [string](Get-A365Property -InputObject $package -Name 'deployedTo' -Default 'Unknown')
                $key = "$platform|$type|$blocked|$scope"
                if (-not $packageGroups.ContainsKey($key)) {
                    $packageGroups[$key] = [ordered]@{
                        platform = $platform
                        type = $type
                        blocked = $blocked
                        deploymentScope = $scope
                        count = 0
                    }
                }
                $packageGroups[$key].count++
            }
        }
        $evidence.registry = [pscustomobject]@{
            available = $true
            packageCount = $packageCounter.Count
            summary = @($packageGroups.Values | ForEach-Object { [pscustomobject]$_ })
        }
    }
    catch {
        $Issues.Add((New-A365CollectionIssue -Adapter Graph -Operation 'Agent package catalog' -ErrorRecord $_ -RequiredPermission 'CopilotPackages.Read.All' -DocsUrl 'https://learn.microsoft.com/microsoft-365/copilot/extensibility/api/admin-settings/package/copilotpackages-list'))
        $evidence.registry = [pscustomobject]@{ available = $false }
    }
    }

    if ($Collectors -contains 'AgentIdentity') {
    try {
        $blueprints = [System.Collections.Generic.List[object]]::new()
        Invoke-A365GraphPages -InitialUri 'https://graph.microsoft.com/v1.0/applications/microsoft.graph.agentIdentityBlueprint?$select=id,keyCredentials,passwordCredentials,requiredResourceAccess&$top=100' -Allowlist $Allowlist -ProcessPage {
            param($Page)
            foreach ($item in @(Get-A365Property -InputObject $Page -Name 'value' -Default @())) {
                $blueprints.Add($item)
            }
        }

        $missingOwnerCount = 0
        $missingSponsorCount = 0
        $ownerReadAvailable = $true
        $expiredCredentialCount = 0
        $expiringCredentialCount = 0
        $requestedResourceCount = 0
        $requestedPermissionCount = 0
        $sponsorReadAvailable = $true
        $now = (Get-Date).ToUniversalTime()

        foreach ($blueprint in $blueprints) {
            $blueprintId = [string](Get-A365Property -InputObject $blueprint -Name 'id' -Default '')
            if (-not $blueprintId) {
                throw 'Agent Identity Blueprint response did not contain an id property.'
            }

            try {
                $ownerResponse = Invoke-A365GraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/applications/$blueprintId/microsoft.graph.agentIdentityBlueprint/owners?`$select=id" -Allowlist $Allowlist
                if (@(Get-A365Property -InputObject $ownerResponse -Name 'value' -Default @()).Count -eq 0) {
                    $missingOwnerCount++
                }
            }
            catch {
                $ownerReadAvailable = $false
                $Issues.Add((New-A365CollectionIssue -Adapter Graph -Operation 'Blueprint owners' -ErrorRecord $_ -RequiredPermission 'AgentIdentityBlueprint.Read.All' -DocsUrl 'https://learn.microsoft.com/graph/api/agentidentityblueprint-list-owners?view=graph-rest-1.0'))
            }

            try {
                $sponsorResponse = Invoke-A365GraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/applications/$blueprintId/microsoft.graph.agentIdentityBlueprint/sponsors?`$select=id" -Allowlist $Allowlist
                if (@(Get-A365Property -InputObject $sponsorResponse -Name 'value' -Default @()).Count -eq 0) {
                    $missingSponsorCount++
                }
            }
            catch {
                $sponsorReadAvailable = $false
                $Issues.Add((New-A365CollectionIssue -Adapter Graph -Operation 'Blueprint sponsors' -ErrorRecord $_ -RequiredPermission 'Application.Read.All' -DocsUrl 'https://learn.microsoft.com/graph/api/agentidentityblueprint-list-sponsors?view=graph-rest-1.0'))
            }

            $credentials = @(
                @(Get-A365Property -InputObject $blueprint -Name 'keyCredentials' -Default @()) +
                @(Get-A365Property -InputObject $blueprint -Name 'passwordCredentials' -Default @())
            )
            foreach ($credential in $credentials) {
                $endText = [string](Get-A365Property -InputObject $credential -Name 'endDateTime' -Default '')
                if (-not $endText) {
                    continue
                }
                $end = [DateTimeOffset]::Parse($endText).UtcDateTime
                if ($end -lt $now) {
                    $expiredCredentialCount++
                }
                elseif ($end -lt $now.AddDays(30)) {
                    $expiringCredentialCount++
                }
            }

            foreach ($resource in @(Get-A365Property -InputObject $blueprint -Name 'requiredResourceAccess' -Default @())) {
                $requestedResourceCount++
                $requestedPermissionCount += @(Get-A365Property -InputObject $resource -Name 'resourceAccess' -Default @()).Count
            }
        }

        $evidence.agentIdentity = [pscustomobject]@{
            available = $true
            blueprintCount = $blueprints.Count
            missingOwnerCount = $missingOwnerCount
            missingSponsorCount = $missingSponsorCount
            ownerReadAvailable = $ownerReadAvailable
            expiredCredentialCount = $expiredCredentialCount
            expiringCredentialCount = $expiringCredentialCount
            requestedResourceCount = $requestedResourceCount
            requestedPermissionCount = $requestedPermissionCount
            sponsorReadAvailable = $sponsorReadAvailable
        }
    }
    catch {
        $Issues.Add((New-A365CollectionIssue -Adapter Graph -Operation 'Agent Identity Blueprints' -ErrorRecord $_ -RequiredPermission 'AgentIdentityBlueprint.Read.All' -DocsUrl 'https://learn.microsoft.com/graph/api/agentidentityblueprint-list?view=graph-rest-1.0'))
        $evidence.agentIdentity = [pscustomobject]@{ available = $false }
    }
    }

    if ($Collectors -contains 'ConditionalAccess') {
    $conditionalAccess = [ordered]@{
        securityDefaultsKnown = $false
        securityDefaultsEnabled = $null
        policyInventoryAvailable = $false
        enabledPolicyCount = 0
        reportOnlyPolicyCount = 0
        disabledPolicyCount = 0
    }
    try {
        $securityDefaults = Invoke-A365GraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/policies/identitySecurityDefaultsEnforcementPolicy' -Allowlist $Allowlist
        $conditionalAccess.securityDefaultsKnown = $true
        $conditionalAccess.securityDefaultsEnabled = [bool](Get-A365Property -InputObject $securityDefaults -Name 'isEnabled' -Default $false)
    }
    catch {
        $Issues.Add((New-A365CollectionIssue -Adapter Graph -Operation 'Security defaults' -ErrorRecord $_ -RequiredPermission 'Policy.Read.All' -DocsUrl 'https://learn.microsoft.com/graph/api/identitysecuritydefaultsenforcementpolicy-get?view=graph-rest-1.0'))
    }

    if ($conditionalAccess.securityDefaultsKnown -and -not $conditionalAccess.securityDefaultsEnabled) {
        try {
            Invoke-A365GraphPages -InitialUri 'https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies?$select=id,state&$top=999' -Allowlist $Allowlist -ProcessPage {
                param($Page)
                foreach ($policy in @(Get-A365Property -InputObject $Page -Name 'value' -Default @())) {
                    switch ([string](Get-A365Property -InputObject $policy -Name 'state' -Default 'unknown')) {
                        'enabled' { $conditionalAccess.enabledPolicyCount++ }
                        'enabledForReportingButNotEnforced' { $conditionalAccess.reportOnlyPolicyCount++ }
                        'disabled' { $conditionalAccess.disabledPolicyCount++ }
                    }
                }
            }
            $conditionalAccess.policyInventoryAvailable = $true
        }
        catch {
            $Issues.Add((New-A365CollectionIssue -Adapter Graph -Operation 'Conditional Access policy inventory' -ErrorRecord $_ -RequiredPermission 'Policy.Read.All' -DocsUrl 'https://learn.microsoft.com/entra/identity/conditional-access/agent-id'))
        }
    }
    $evidence.conditionalAccess = [pscustomobject]$conditionalAccess
    }

    if ($Collectors -contains 'Defender') {
    $defender = [ordered]@{}
    foreach ($probe in @(
        @{
            Name = 'agentsInfo'
            Query = 'AgentsInfo | summarize AgentCount=dcount(AgentId), PlatformCount=dcount(Platform), LatestEvidenceUtc=max(Timestamp)'
            CountName = 'AgentCount'
            SecondaryName = 'PlatformCount'
        },
        @{
            Name = 'behaviorInfo'
            Query = 'BehaviorInfo | summarize BehaviorCount=count(), LatestEvidenceUtc=max(Timestamp)'
            CountName = 'BehaviorCount'
            SecondaryName = $null
        }
    )) {
        try {
            $probeResponse = Invoke-A365GraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/security/runHuntingQuery' -Body @{ Query = $probe.Query; Timespan = 'P30D' } -Allowlist $Allowlist
            $row = @(Get-A365Property -InputObject $probeResponse -Name 'results' -Default @()) | Select-Object -First 1
            $probeResult = [ordered]@{
                available = $true
                latestEvidenceUtc = Get-A365Property -InputObject $row -Name 'LatestEvidenceUtc' -Default $null
            }
            if ($probe.Name -eq 'agentsInfo') {
                $probeResult.agentCount = [int](Get-A365Property -InputObject $row -Name 'AgentCount' -Default 0)
                $probeResult.platformCount = [int](Get-A365Property -InputObject $row -Name 'PlatformCount' -Default 0)
            }
            else {
                $probeResult.behaviorCount = [int](Get-A365Property -InputObject $row -Name 'BehaviorCount' -Default 0)
            }
            $defender[$probe.Name] = [pscustomobject]$probeResult
        }
        catch {
            $Issues.Add((New-A365CollectionIssue -Adapter Graph -Operation "Defender $($probe.Name) aggregate query" -ErrorRecord $_ -RequiredPermission 'ThreatHunting.Read.All' -DocsUrl 'https://learn.microsoft.com/graph/api/security-security-runhuntingquery?view=graph-rest-1.0'))
            $defender[$probe.Name] = [pscustomobject]@{ available = $false }
        }
    }
    $evidence.defender = [pscustomobject]$defender
    }

    if ($Collectors -contains 'Purview') {
    $audit = [ordered]@{
        available = $false
        queryStatus = 'notStarted'
        recordCount = 0
        windowDays = $AuditWindowDays
        queryTimeoutSeconds = $AuditQueryTimeoutSeconds
        pollingElapsedSeconds = 0
        pollCount = 0
        timedOut = $false
    }
    try {
        $end = (Get-Date).ToUniversalTime()
        $start = $end.AddDays(-$AuditWindowDays)
        $queryResponse = Invoke-A365GraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/security/auditLog/queries' -Body @{
            displayName = 'Agent365 preflight aggregate query'
            filterStartDateTime = $start.ToString('o')
            filterEndDateTime = $end.ToString('o')
            operationFilters = @('CopilotInteraction', 'ConnectedAIAppInteraction', 'AIAppInteraction')
        } -Allowlist $Allowlist
        $queryId = [string](Get-A365Property -InputObject $queryResponse -Name 'id' -Default '')
        if (-not $queryId) {
            throw 'Purview Audit Search did not return a query id.'
        }

        $pollResult = Wait-A365AuditQuery `
            -InitialResponse $queryResponse `
            -QueryId $queryId `
            -Allowlist $Allowlist `
            -TimeoutSeconds $AuditQueryTimeoutSeconds
        $audit.queryStatus = $pollResult.Status
        $audit.pollingElapsedSeconds = $pollResult.ElapsedSeconds
        $audit.pollCount = $pollResult.PollCount
        $audit.timedOut = $pollResult.TimedOut

        if ($pollResult.TimedOut) {
            throw "Purview Audit Search timed out after $($pollResult.ElapsedSeconds) seconds while status remained '$($pollResult.Status)'. The retained query job may continue server-side."
        }
        if ($pollResult.Status -in @('failed', 'cancelled')) {
            throw "Purview Audit Search query reached terminal status '$($pollResult.Status)' after $($pollResult.ElapsedSeconds) seconds."
        }
        if ($pollResult.Status -ne 'succeeded') {
            throw "Purview Audit Search returned unexpected status '$($pollResult.Status)' after $($pollResult.ElapsedSeconds) seconds."
        }

        $recordCounter = [pscustomobject]@{ Count = 0 }
        Invoke-A365GraphPages -InitialUri "https://graph.microsoft.com/v1.0/security/auditLog/queries/$queryId/records?`$select=id&`$top=1000" -Allowlist $Allowlist -ProcessPage {
            param($Page)
            $recordCounter.Count += @(Get-A365Property -InputObject $Page -Name 'value' -Default @()).Count
        }
        $audit.recordCount = $recordCounter.Count
        $audit.available = $true
    }
    catch {
        $auditIssue = New-A365CollectionIssue -Adapter Graph -Operation 'Purview Audit Search aggregate query' -ErrorRecord $_ -RequiredPermission 'AuditLogsQuery.Read.All' -DocsUrl 'https://learn.microsoft.com/graph/api/security-auditcoreroot-post-auditlogqueries?view=graph-rest-1.0'
        $auditIssue | Add-Member -NotePropertyName QueryStatus -NotePropertyValue $audit.queryStatus
        $auditIssue | Add-Member -NotePropertyName PollingElapsedSeconds -NotePropertyValue $audit.pollingElapsedSeconds
        $auditIssue | Add-Member -NotePropertyName TimedOut -NotePropertyValue $audit.timedOut
        $Issues.Add($auditIssue)
    }

    $policyMetadata = [ordered]@{
        available = $false
        dlpPolicyCount = $null
        retentionPolicyCount = $null
        labelCount = $null
    }
    $metadataCommands = @(
        @{ Name = 'Get-DlpCompliancePolicy'; Property = 'dlpPolicyCount' }
        @{ Name = 'Get-RetentionCompliancePolicy'; Property = 'retentionPolicyCount' }
        @{ Name = 'Get-Label'; Property = 'labelCount' }
    )
    $availableMetadataCommands = 0
    if (-not $appOnly) {
        foreach ($entry in $metadataCommands) {
            try {
                $count = Invoke-A365OptionalCommandCount -Adapter ExchangeOnlineManagement -CommandName $entry.Name -Allowlist $Allowlist
                if ($null -ne $count) {
                    $policyMetadata[$entry.Property] = $count
                    $availableMetadataCommands++
                }
            }
            catch {
                $Issues.Add((New-A365CollectionIssue -Adapter ExchangeOnlineManagement -Operation $entry.Name -ErrorRecord $_ -RequiredPermission 'Workload-specific read permissions' -DocsUrl 'https://learn.microsoft.com/purview/ai-agent-365'))
            }
        }
    }
    $policyMetadata.available = $availableMetadataCommands -gt 0
    $evidence.purview = [pscustomobject]@{
        audit = [pscustomobject]$audit
        policyMetadata = [pscustomobject]$policyMetadata
    }
    }

    if ($Collectors -contains 'SharePoint') {
    $sharePointEvidence = [ordered]@{
        moduleAvailable = $null -ne (Get-Command -Name Get-SPOSite -ErrorAction SilentlyContinue)
        sites = @()
    }
    if (-not $appOnly -and $Profiles -contains 'SharePointAgents' -and $SharePointSiteUrl.Count -gt 0 -and $sharePointEvidence.moduleAvailable) {
        $siteEvidence = [System.Collections.Generic.List[object]]::new()
        foreach ($siteUrl in $SharePointSiteUrl) {
            try {
                if (-not (Test-Agent365OperationAllowed -Adapter 'Microsoft.Online.SharePoint.PowerShell' -Method COMMAND -Target 'Get-SPOSite' -Allowlist $Allowlist)) {
                    throw 'Get-SPOSite is not allowed by the Agent 365 pre-flight operation allowlist.'
                }
                $site = Get-SPOSite -Identity $siteUrl -ErrorAction Stop
                $siteEvidence.Add([pscustomobject]@{
                    url = $siteUrl
                    readable = $true
                    sharingCapability = Get-A365Property -InputObject $site -Name 'SharingCapability' -Default 'Unknown'
                    restrictedAccessControl = Get-A365Property -InputObject $site -Name 'RestrictedAccessControl' -Default $null
                })
            }
            catch {
                $Issues.Add((New-A365CollectionIssue -Adapter 'Microsoft.Online.SharePoint.PowerShell' -Operation "Get-SPOSite $siteUrl" -ErrorRecord $_ -RequiredPermission 'SharePoint site read access' -DocsUrl 'https://learn.microsoft.com/microsoft-agent-365/admin/sharepoint-integration'))
                $siteEvidence.Add([pscustomobject]@{
                    url = $siteUrl
                    readable = $false
                    sharingCapability = $null
                    restrictedAccessControl = $null
                })
            }
        }
        $sharePointEvidence.sites = $siteEvidence.ToArray()
    }
    $evidence.sharePoint = [pscustomobject]$sharePointEvidence
    }
    $evidence.collectionIssues = $Issues.ToArray()
    return [pscustomobject]$evidence
}

function Get-A365Rule {
    param(
        [Parameter(Mandatory)]
        [object]$Rules,

        [Parameter(Mandatory)]
        [string]$Id
    )

    $rule = @($Rules.checks | Where-Object { $_.id -eq $Id }) | Select-Object -First 1
    if ($null -eq $rule) {
        throw "Rule was not found: $Id"
    }
    return $rule
}

function New-A365Result {
    param(
        [Parameter(Mandatory)]
        [object]$Rules,

        [Parameter(Mandatory)]
        [string]$Id,

        [Parameter(Mandatory)]
        [ValidateSet('Passed', 'Blocker', 'ActionRequired', 'Advisory', 'ManualValidation', 'NotApplicable', 'NotAuthorized', 'Error')]
        [string]$Status,

        [Parameter(Mandatory)]
        [string]$Applicability,

        [AllowNull()]
        [object]$Observed,

        [Parameter(Mandatory)]
        [string]$EvidenceMethod,

        [AllowNull()]
        [object]$Details,

        [Parameter()]
        [bool]$IsSensitive = $false,

        [Parameter(Mandatory)]
        [string]$EvidenceTimeUtc
    )

    $rule = Get-A365Rule -Rules $Rules -Id $Id
    return [pscustomobject][ordered]@{
        Id = $rule.id
        Title = $rule.title
        Pillar = $rule.pillar
        Area = $rule.area
        Profiles = @($rule.profiles)
        Applicability = $Applicability
        Status = $Status
        Expected = $rule.expected
        Observed = $Observed
        EvidenceMethod = $EvidenceMethod
        EvidenceTimeUtc = $EvidenceTimeUtc
        RequiredPermission = $rule.requiredPermission
        RequiredRole = $rule.requiredRole
        Remediation = $rule.remediation
        DocsUrl = $rule.docsUrl
        RuleReviewDate = $Rules.reviewDate
        Details = $Details
        IsSensitive = $IsSensitive
    }
}

function Test-A365RequiredPermissionMissing {
    param(
        [Parameter(Mandatory)]
        [string]$RequiredPermission,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$GrantedScopes,

        [Parameter(Mandatory)]
        [string]$AuthenticationMode
    )

    if ($AuthenticationMode -eq 'CertificateAppOnly') {
        return $false
    }

    if ($RequiredPermission -in @('None', 'Portal access', 'Workload-specific read permissions', 'SharePoint site read access')) {
        return $false
    }

    $required = @(
        $RequiredPermission -split ',' |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -match '\.' }
    )
    foreach ($permission in $required) {
        if ($GrantedScopes -notcontains $permission) {
            return $true
        }
    }
    return $false
}

function Get-A365IssueForOperation {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Issues,

        [Parameter(Mandatory)]
        [string]$OperationPattern
    )

    return @(
        $Issues |
            Where-Object { [string](Get-A365Property -InputObject $_ -Name 'Operation' -Default '') -match $OperationPattern }
    ) | Select-Object -First 1
}

function New-A365ProfileResult {
    param(
        [Parameter(Mandatory)]
        [string]$Profile,

        [Parameter(Mandatory)]
        [string]$DocsUrl,

        [Parameter(Mandatory)]
        [string]$EvidenceTimeUtc,

        [Parameter(Mandatory)]
        [string]$RuleReviewDate
    )

    return [pscustomobject][ordered]@{
        Id = Get-A365ProfileResultId -Profile $Profile
        Title = "$Profile workload boundary"
        Pillar = 'Govern'
        Area = 'Selected profiles'
        Profiles = @($Profile)
        Applicability = 'Selected'
        Status = 'ManualValidation'
        Expected = "The $Profile scenario, data boundary, identity model, connectors, tools, and deployment controls are reviewed."
        Observed = "$Profile was selected. No supported read API proves the full workload boundary."
        EvidenceMethod = 'Selected profile declaration'
        EvidenceTimeUtc = $EvidenceTimeUtc
        RequiredPermission = 'Workload-specific read access'
        RequiredRole = 'Workload owner and AI governance owner'
        Remediation = "Complete the documented $Profile workload review before deployment."
        DocsUrl = $DocsUrl
        RuleReviewDate = $RuleReviewDate
        Details = $null
        IsSensitive = $false
    }
}

function Get-A365ProfileResultId {
    param(
        [Parameter(Mandatory)]
        [string]$Profile
    )

    $stableProfileName = [System.Text.RegularExpressions.Regex]::Replace(
        $Profile.ToUpperInvariant(),
        '[^A-Z0-9]',
        ''
    )
    return "A365-PROFILE-$stableProfileName"
}

function ConvertTo-A365GuidanceModel {
    param(
        [Parameter(Mandatory)]
        [object]$Guidance
    )

    [object[]]$yesCriteria = @(Get-A365Property -InputObject $Guidance -Name 'yesCriteria' -Default @())
    [object[]]$evidenceToRetain = @(Get-A365Property -InputObject $Guidance -Name 'evidenceToRetain' -Default @())
    [object[]]$verificationSteps = @(
        @(Get-A365Property -InputObject $Guidance -Name 'verificationSteps' -Default @()) |
            ForEach-Object {
                [pscustomobject][ordered]@{
                    Order = [int](Get-A365Property -InputObject $_ -Name 'order' -Default 0)
                    Title = [string](Get-A365Property -InputObject $_ -Name 'title' -Default '')
                    Instruction = [string](Get-A365Property -InputObject $_ -Name 'instruction' -Default '')
                    Location = [string](Get-A365Property -InputObject $_ -Name 'location' -Default '')
                }
            }
    )
    [object[]]$publicSources = @(
        @(Get-A365Property -InputObject $Guidance -Name 'publicSources' -Default @()) |
            ForEach-Object {
                [pscustomobject][ordered]@{
                    Title = [string](Get-A365Property -InputObject $_ -Name 'title' -Default '')
                    Url = [string](Get-A365Property -InputObject $_ -Name 'url' -Default '')
                }
            }
    )
    $searchText = @(
        Get-A365Property -InputObject $Guidance -Name 'intent' -Default ''
        Get-A365Property -InputObject $Guidance -Name 'whyItMatters' -Default ''
        Get-A365Property -InputObject $Guidance -Name 'whoShouldAnswer' -Default ''
        $yesCriteria
        $evidenceToRetain
        $verificationSteps | ForEach-Object { "$($_.Title) $($_.Instruction) $($_.Location)" }
        Get-A365Property -InputObject $Guidance -Name 'noRemediation' -Default ''
        Get-A365Property -InputObject $Guidance -Name 'notApplicableGuidance' -Default ''
        $publicSources | ForEach-Object { $_.Title }
    ) -join ' '

    return [pscustomobject][ordered]@{
        Intent = [string](Get-A365Property -InputObject $Guidance -Name 'intent' -Default '')
        WhyItMatters = [string](Get-A365Property -InputObject $Guidance -Name 'whyItMatters' -Default '')
        WhoShouldAnswer = [string](Get-A365Property -InputObject $Guidance -Name 'whoShouldAnswer' -Default '')
        YesCriteria = $yesCriteria
        EvidenceToRetain = $evidenceToRetain
        VerificationSteps = $verificationSteps
        NoRemediation = [string](Get-A365Property -InputObject $Guidance -Name 'noRemediation' -Default '')
        NotApplicableAllowed = [bool](Get-A365Property -InputObject $Guidance -Name 'notApplicableAllowed' -Default $false)
        NotApplicableGuidance = [string](Get-A365Property -InputObject $Guidance -Name 'notApplicableGuidance' -Default '')
        PublicSources = $publicSources
        ReviewDate = [string](Get-A365Property -InputObject $Guidance -Name 'reviewDate' -Default '')
        SearchText = $searchText.Trim()
    }
}

function Test-A365GuidanceItem {
    param(
        [Parameter(Mandatory)]
        [string]$Id,

        [Parameter(Mandatory)]
        [object]$Guidance,

        [Parameter(Mandatory)]
        [bool]$AllowNotApplicable
    )

    foreach ($field in @('intent', 'whyItMatters', 'whoShouldAnswer', 'noRemediation', 'notApplicableGuidance', 'reviewDate')) {
        if ([string]::IsNullOrWhiteSpace([string](Get-A365Property -InputObject $Guidance -Name $field -Default ''))) {
            throw "Guidance for $Id is missing required field '$field'."
        }
    }

    foreach ($field in @('yesCriteria', 'evidenceToRetain', 'verificationSteps', 'publicSources')) {
        [object[]]$values = @(Get-A365Property -InputObject $Guidance -Name $field -Default @())
        if ($values.Count -eq 0) {
            throw "Guidance for $Id must contain at least one '$field' item."
        }
        if ($field -in @('yesCriteria', 'evidenceToRetain') -and
            @($values | Where-Object { [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0) {
            throw "Guidance for $Id contains an empty '$field' item."
        }
    }

    $guidanceAllowsNotApplicable = [bool](Get-A365Property -InputObject $Guidance -Name 'notApplicableAllowed' -Default $false)
    if ($guidanceAllowsNotApplicable -ne $AllowNotApplicable) {
        throw "Guidance for $Id has notApplicableAllowed=$guidanceAllowsNotApplicable but the rule allows NotApplicable=$AllowNotApplicable."
    }
    if (-not $AllowNotApplicable -and
        [string](Get-A365Property -InputObject $Guidance -Name 'notApplicableGuidance' -Default '') -notmatch '(?i)not (?:applicable|allowed)') {
        throw "Guidance for $Id must explicitly state that NotApplicable is not allowed."
    }

    $parsedDate = [datetime]::MinValue
    if (-not [datetime]::TryParseExact(
            [string](Get-A365Property -InputObject $Guidance -Name 'reviewDate' -Default ''),
            'yyyy-MM-dd',
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None,
            [ref]$parsedDate
        )) {
        throw "Guidance for $Id reviewDate must use yyyy-MM-dd."
    }

    [object[]]$steps = @(Get-A365Property -InputObject $Guidance -Name 'verificationSteps' -Default @())
    foreach ($step in $steps) {
        if ([int](Get-A365Property -InputObject $step -Name 'order' -Default 0) -lt 1 -or
            [string]::IsNullOrWhiteSpace([string](Get-A365Property -InputObject $step -Name 'title' -Default '')) -or
            [string]::IsNullOrWhiteSpace([string](Get-A365Property -InputObject $step -Name 'instruction' -Default '')) -or
            [string]::IsNullOrWhiteSpace([string](Get-A365Property -InputObject $step -Name 'location' -Default ''))) {
            throw "Guidance for $Id contains an incomplete verification step."
        }
    }

    [object[]]$sources = @(Get-A365Property -InputObject $Guidance -Name 'publicSources' -Default @())
    foreach ($source in $sources) {
        $title = [string](Get-A365Property -InputObject $source -Name 'title' -Default '')
        $url = [string](Get-A365Property -InputObject $source -Name 'url' -Default '')
        if ([string]::IsNullOrWhiteSpace($title) -or $url -notmatch '^https://learn\.microsoft\.com/') {
            throw "Guidance for $Id contains an invalid or non-public Microsoft Learn source."
        }
    }
}

function Test-A365GuidanceContract {
    param(
        [Parameter(Mandatory)]
        [object]$Rules,

        [Parameter(Mandatory)]
        [object]$Guidance
    )

    if ([string](Get-A365Property -InputObject $Guidance -Name 'schemaVersion' -Default '') -ne '1.0') {
        throw 'Guidance schemaVersion must be 1.0.'
    }
    foreach ($field in @('version', 'reviewDate', 'items', 'profiles')) {
        if ($null -eq $Guidance.PSObject.Properties[$field]) {
            throw "Guidance contract is missing required field '$field'."
        }
    }

    foreach ($manual in @($Rules.manualAttestations)) {
        $property = $Guidance.items.PSObject.Properties[[string]$manual.id]
        if ($null -eq $property) {
            throw "Guidance is missing required manually attestable item $($manual.id)."
        }
        Test-A365GuidanceItem -Id ([string]$manual.id) -Guidance $property.Value -AllowNotApplicable ([bool](Get-A365Property -InputObject $manual -Name 'allowNotApplicable' -Default $false))
    }
    foreach ($rule in @($Rules.checks)) {
        $attestation = Get-A365Property -InputObject $rule -Name 'manualAttestation' -Default $null
        if ($null -eq $attestation -or -not [bool](Get-A365Property -InputObject $attestation -Name 'allowed' -Default $false)) {
            continue
        }
        $property = $Guidance.items.PSObject.Properties[[string]$rule.id]
        if ($null -eq $property) {
            throw "Guidance is missing required manually attestable item $($rule.id)."
        }
        Test-A365GuidanceItem -Id ([string]$rule.id) -Guidance $property.Value -AllowNotApplicable ([bool](Get-A365Property -InputObject $attestation -Name 'allowNotApplicable' -Default $false))
    }
    foreach ($profile in @($Rules.profileGuidance.PSObject.Properties.Name)) {
        $property = $Guidance.profiles.PSObject.Properties[$profile]
        if ($null -eq $property) {
            throw "Guidance is missing required profile item $profile."
        }
        Test-A365GuidanceItem -Id (Get-A365ProfileResultId -Profile $profile) -Guidance $property.Value -AllowNotApplicable $false
    }
}

function Get-A365AttestationDefinitions {
    param(
        [Parameter(Mandatory)]
        [object]$Rules,

        [Parameter(Mandatory)]
        [string[]]$Profiles,

        [Parameter(Mandatory)]
        [object]$Guidance,

        [Parameter()]
        [switch]$IncludeAllProfiles
    )

    $definitions = [System.Collections.Generic.List[object]]::new()
    foreach ($manual in @($Rules.manualAttestations)) {
        $guidanceModel = ConvertTo-A365GuidanceModel -Guidance $Guidance.items.PSObject.Properties[[string]$manual.id].Value
        $definitions.Add([pscustomobject][ordered]@{
            Id = $manual.id
            Title = $manual.question
            Required = [bool]$manual.required
            AllowNotApplicable = [bool](Get-A365Property -InputObject $manual -Name 'allowNotApplicable' -Default $false)
            NoStatus = [string](Get-A365Property -InputObject $manual -Name 'noStatus' -Default 'Blocker')
            EvidenceNeeded = [string](Get-A365Property -InputObject $manual -Name 'evidenceNeeded' -Default $manual.remediation)
            DocsUrl = $manual.docsUrl
            Profiles = @($manual.profiles)
            RequiredRole = $guidanceModel.WhoShouldAnswer
            Guidance = $guidanceModel
            Source = 'ManualControl'
        })
    }

    foreach ($rule in @($Rules.checks)) {
        $attestation = Get-A365Property -InputObject $rule -Name 'manualAttestation' -Default $null
        if ($null -eq $attestation -or -not [bool](Get-A365Property -InputObject $attestation -Name 'allowed' -Default $false)) {
            continue
        }
        $guidanceModel = ConvertTo-A365GuidanceModel -Guidance $Guidance.items.PSObject.Properties[[string]$rule.id].Value
        $definitions.Add([pscustomobject][ordered]@{
            Id = $rule.id
            Title = $rule.title
            Required = [bool](Get-A365Property -InputObject $attestation -Name 'required' -Default $true)
            AllowNotApplicable = [bool](Get-A365Property -InputObject $attestation -Name 'allowNotApplicable' -Default $false)
            NoStatus = [string](Get-A365Property -InputObject $attestation -Name 'noStatus' -Default 'ActionRequired')
            EvidenceNeeded = [string](Get-A365Property -InputObject $attestation -Name 'evidenceNeeded' -Default $rule.remediation)
            DocsUrl = $rule.docsUrl
            Profiles = @($rule.profiles)
            RequiredRole = $rule.requiredRole
            Guidance = $guidanceModel
            Source = 'ApprovedRule'
        })
    }

    $profileNames = if ($IncludeAllProfiles) {
        @($Rules.profileGuidance.PSObject.Properties.Name)
    }
    else {
        @($Profiles | Where-Object { $_ -ne 'ControlPlane' })
    }
    foreach ($profile in $profileNames) {
        $docsProperty = $Rules.profileGuidance.PSObject.Properties[$profile]
        $guidanceModel = ConvertTo-A365GuidanceModel -Guidance $Guidance.profiles.PSObject.Properties[$profile].Value
        $definitions.Add([pscustomobject][ordered]@{
            Id = Get-A365ProfileResultId -Profile $profile
            Title = "$profile workload boundary"
            Required = $true
            AllowNotApplicable = $false
            NoStatus = 'ActionRequired'
            EvidenceNeeded = "Record the accountable workload owner and reference the approved $profile identity, data, tool, connector, and deployment boundary."
            DocsUrl = if ($docsProperty) { [string]$docsProperty.Value } else { 'https://learn.microsoft.com/microsoft-agent-365/' }
            Profiles = @($profile)
            RequiredRole = $guidanceModel.WhoShouldAnswer
            Guidance = $guidanceModel
            Source = 'SelectedProfile'
        })
    }

    return $definitions.ToArray()
}

function Test-A365AnswersInput {
    param(
        [Parameter(Mandatory)]
        [object]$Answers,

        [Parameter(Mandatory)]
        [object[]]$Definitions,

        [Parameter(Mandatory)]
        [object]$Rules
    )

    $schemaVersion = [string](Get-A365Property -InputObject $Answers -Name 'schemaVersion' -Default '')
    if ($schemaVersion -notin @('1.0', '1.1')) {
        throw 'Answers file schemaVersion must be 1.0 or 1.1.'
    }
    if ($null -eq $Answers.PSObject.Properties['answers']) {
        throw 'Answers file must contain an answers array.'
    }

    [object[]]$answerItems = @(Get-A365Property -InputObject $Answers -Name 'answers' -Default @())
    $duplicateAnswer = $answerItems |
        Group-Object id |
        Where-Object Count -gt 1 |
        Select-Object -First 1
    if ($duplicateAnswer) {
        throw "Answers file contains a duplicate id: $($duplicateAnswer.Name)"
    }

    $definitionById = @{}
    foreach ($definition in $Definitions) {
        $definitionById[[string]$definition.Id] = $definition
    }
    $automatedRuleIds = @($Rules.checks.id | Where-Object { -not $definitionById.ContainsKey([string]$_) })

    foreach ($answer in $answerItems) {
        $answerId = [string](Get-A365Property -InputObject $answer -Name 'id' -Default '')
        if (-not $definitionById.ContainsKey($answerId)) {
            if ($answerId -in $automatedRuleIds) {
                throw "Answers file cannot attest automated-only rule: $answerId"
            }
            throw "Answers file contains an unknown attestation id: $answerId"
        }

        $definition = $definitionById[$answerId]
        $answerValue = [string](Get-A365Property -InputObject $answer -Name 'answer' -Default '')
        if ($answerValue -notin @('Yes', 'No', 'NotApplicable')) {
            throw "Answers file contains an invalid answer for $answerId."
        }
        if ($answerValue -eq 'Yes') {
            if ([string]::IsNullOrWhiteSpace([string](Get-A365Property -InputObject $answer -Name 'owner' -Default ''))) {
                throw "Yes evidence for $answerId requires an accountable owner or role."
            }
            if ([string]::IsNullOrWhiteSpace([string](Get-A365Property -InputObject $answer -Name 'evidenceReference' -Default ''))) {
                throw "Yes evidence for $answerId requires an evidence reference."
            }
        }
        if ($answerValue -eq 'NotApplicable') {
            if (-not [bool]$definition.AllowNotApplicable) {
                throw "NotApplicable is not permitted for $answerId."
            }
            if ([string]::IsNullOrWhiteSpace([string](Get-A365Property -InputObject $answer -Name 'justification' -Default ''))) {
                throw "NotApplicable evidence for $answerId requires a justification."
            }
        }

        $answeredAtUtc = [string](Get-A365Property -InputObject $answer -Name 'answeredAtUtc' -Default '')
        if ($answeredAtUtc) {
            $parsedDate = [DateTimeOffset]::MinValue
            if (-not [DateTimeOffset]::TryParse($answeredAtUtc, [ref]$parsedDate)) {
                throw "answeredAtUtc for $answerId must be a valid timestamp."
            }
        }
    }
}

function Get-A365Evaluation {
    param(
        [Parameter(Mandatory)]
        [object]$Evidence,

        [Parameter(Mandatory)]
        [object]$Rules,

        [Parameter(Mandatory)]
        [object]$Guidance,

        [Parameter(Mandatory)]
        [object]$SkuCatalog,

        [Parameter(Mandatory)]
        [string[]]$Profiles,

        [Parameter(Mandatory)]
        [string[]]$Collectors,

        [AllowNull()]
        [object]$Answers
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $manualAttestations = [System.Collections.Generic.List[object]]::new()
    $evidenceTimeUtc = [string](Get-A365Property -InputObject $Evidence -Name 'generatedAtUtc' -Default (Get-Date).ToUniversalTime().ToString('o'))
    $issues = @(Get-A365Property -InputObject $Evidence -Name 'collectionIssues' -Default @())
    $auth = Get-A365Property -InputObject $Evidence -Name 'authentication' -Default ([pscustomobject]@{})
    $grantedScopes = @(
        Get-A365Property -InputObject $auth -Name 'grantedScopes' -Default @() |
            ForEach-Object { [string]$_ }
    )
    $authMode = [string](Get-A365Property -InputObject $auth -Name 'mode' -Default 'Unavailable')
    $tenant = Get-A365Property -InputObject $Evidence -Name 'tenant' -Default ([pscustomobject]@{})
    $commercial = Get-A365Property -InputObject $tenant -Name 'commercialAvailability' -Default $null
    $local = Get-A365Property -InputObject $Evidence -Name 'local' -Default ([pscustomobject]@{})
    $ruleIssuePatterns = @{
        'A365-FOUNDATION-002' = '^Licensing and assigned service plans$'
        'A365-FOUNDATION-003' = '^Licensing and assigned service plans$'
        'A365-FOUNDATION-004' = '^Active directory roles$'
        'A365-FOUNDATION-005' = '^Eligible directory roles$'
        'A365-FOUNDATION-006' = '^Service health$'
        'A365-REGISTRY-001' = '^Agent package catalog$'
        'A365-ENTRA-001' = '^Agent Identity Blueprints$'
        'A365-ENTRA-002' = '^Blueprint owners$'
        'A365-ENTRA-003' = '^Blueprint sponsors$'
        'A365-ENTRA-004' = '^Agent Identity Blueprints$'
        'A365-ENTRA-005' = '^Agent Identity Blueprints$'
        'A365-ENTRA-006' = '^Security defaults$'
        'A365-ENTRA-007' = '^Conditional Access policy inventory$'
        'A365-DEFENDER-001' = '^Defender agentsInfo aggregate query$'
        'A365-DEFENDER-002' = '^Defender behaviorInfo aggregate query$'
        'A365-PURVIEW-001' = '^Purview Audit Search aggregate query$'
        'A365-SHAREPOINT-001' = '^Get-SPOSite '
    }
    $ruleCollectors = @{
        'A365-FOUNDATION-002' = 'Licensing'
        'A365-FOUNDATION-003' = 'Licensing'
        'A365-FOUNDATION-004' = 'Roles'
        'A365-FOUNDATION-005' = 'Roles'
        'A365-FOUNDATION-006' = 'ServiceHealth'
        'A365-REGISTRY-001' = 'Registry'
        'A365-ENTRA-001' = 'AgentIdentity'
        'A365-ENTRA-002' = 'AgentIdentity'
        'A365-ENTRA-003' = 'AgentIdentity'
        'A365-ENTRA-004' = 'AgentIdentity'
        'A365-ENTRA-005' = 'AgentIdentity'
        'A365-ENTRA-006' = 'ConditionalAccess'
        'A365-ENTRA-007' = 'ConditionalAccess'
        'A365-DEFENDER-001' = 'Defender'
        'A365-DEFENDER-002' = 'Defender'
        'A365-DEFENDER-003' = 'Defender'
        'A365-PURVIEW-001' = 'Purview'
        'A365-PURVIEW-002' = 'Purview'
        'A365-SHAREPOINT-001' = 'SharePoint'
    }

    $powerShellVersion = [string](Get-A365Property -InputObject $local -Name 'powerShellVersion' -Default '0.0')
    $psStatus = try {
        if ([Version]$powerShellVersion -ge [Version]'7.0') { 'Passed' } else { 'Blocker' }
    }
    catch {
        'Error'
    }
    $results.Add((New-A365Result -Rules $Rules -Id 'A365-LOCAL-001' -Status $psStatus -Applicability 'Applicable' -Observed "PowerShell $powerShellVersion" -EvidenceMethod 'Local runtime' -Details $null -EvidenceTimeUtc $evidenceTimeUtc))

    $graphVersionText = [string](Get-A365Property -InputObject $local -Name 'graphModuleVersion' -Default '')
    $graphStatus = if (-not $graphVersionText) {
        'ActionRequired'
    }
    else {
        try {
            if ([Version]$graphVersionText -ge [Version]'2.20.0') { 'Passed' } else { 'ActionRequired' }
        }
        catch {
            'Error'
        }
    }
    $results.Add((New-A365Result -Rules $Rules -Id 'A365-LOCAL-002' -Status $graphStatus -Applicability 'Applicable' -Observed $(if ($graphVersionText) { "Version $graphVersionText" } else { 'Module not found' }) -EvidenceMethod 'Get-Module -ListAvailable' -Details $null -EvidenceTimeUtc $evidenceTimeUtc))

    $reachability = Get-A365Property -InputObject $local -Name 'graphEndpointReachable' -Default $null
    $reachabilityStatus = if ($reachability -eq $true) { 'Passed' } elseif ($reachability -eq $false) { 'Advisory' } else { 'Error' }
    $results.Add((New-A365Result -Rules $Rules -Id 'A365-LOCAL-003' -Status $reachabilityStatus -Applicability 'Applicable' -Observed "Reachable: $reachability" -EvidenceMethod 'HTTPS GET request' -Details $null -EvidenceTimeUtc $evidenceTimeUtc))

    $cloud = [string](Get-A365Property -InputObject $tenant -Name 'cloud' -Default 'Unknown')
    $availabilityStatus = if ($commercial -eq $true) { 'Passed' } elseif ($commercial -eq $false) { 'Blocker' } else { 'NotAuthorized' }
    $results.Add((New-A365Result -Rules $Rules -Id 'A365-FOUNDATION-001' -Status $availabilityStatus -Applicability 'Applicable' -Observed "Cloud: $cloud; commercial Agent 365 availability: $commercial" -EvidenceMethod 'Microsoft Graph organization context' -Details $null -EvidenceTimeUtc $evidenceTimeUtc))

    foreach ($rule in @($Rules.checks | Where-Object { $_.id -notin @('A365-LOCAL-001', 'A365-LOCAL-002', 'A365-LOCAL-003', 'A365-FOUNDATION-001') })) {
        if ($rule.id -eq 'A365-SHAREPOINT-001' -and $Profiles -notcontains 'SharePointAgents') {
            $results.Add((New-A365Result -Rules $Rules -Id $rule.id -Status 'NotApplicable' -Applicability 'Profile not selected' -Observed 'SharePointAgents was not selected.' -EvidenceMethod 'Selected profile declaration' -Details $null -EvidenceTimeUtc $evidenceTimeUtc))
            continue
        }

        $collectorName = $ruleCollectors[$rule.id]
        if ($collectorName -and $Collectors -notcontains $collectorName) {
            $results.Add((New-A365Result -Rules $Rules -Id $rule.id -Status 'NotApplicable' -Applicability 'Collector not selected' -Observed "$collectorName collection was not selected for this run." -EvidenceMethod 'Selected collector declaration' -Details $null -EvidenceTimeUtc $evidenceTimeUtc))
            continue
        }

        if ($commercial -eq $false) {
            $results.Add((New-A365Result -Rules $Rules -Id $rule.id -Status 'NotApplicable' -Applicability 'Unsupported cloud' -Observed "Not evaluated after the commercial availability gate for $cloud." -EvidenceMethod 'Availability gate' -Details $null -EvidenceTimeUtc $evidenceTimeUtc))
            continue
        }

        if (Test-A365RequiredPermissionMissing -RequiredPermission $rule.requiredPermission -GrantedScopes $grantedScopes -AuthenticationMode $authMode) {
            $results.Add((New-A365Result -Rules $Rules -Id $rule.id -Status 'NotAuthorized' -Applicability 'Applicable' -Observed "Required delegated permission is missing. Granted: $($grantedScopes -join ', ')" -EvidenceMethod 'Microsoft Graph authentication context' -Details $null -EvidenceTimeUtc $evidenceTimeUtc))
            continue
        }

        $issuePattern = $ruleIssuePatterns[$rule.id]
        $ruleIssue = if ($issuePattern) {
            Get-A365IssueForOperation -Issues $issues -OperationPattern $issuePattern
        }
        else {
            $null
        }
        if ($ruleIssue) {
            $issueCategory = [string](Get-A365Property -InputObject $ruleIssue -Name 'Category' -Default 'Api')
            $issueStatus = switch ($issueCategory) {
                { $_ -in @('Authentication', 'TenantConsent', 'PermissionOrRole', 'Authorization') } { 'NotAuthorized'; break }
                { $_ -in @('License', 'WorkloadAvailability') } { 'ActionRequired'; break }
                default { 'Error' }
            }
            $results.Add((New-A365Result -Rules $Rules -Id $rule.id -Status $issueStatus -Applicability 'Applicable' -Observed "Collection issue [$issueCategory]: $(Get-A365Property -InputObject $ruleIssue -Name 'Message' -Default 'No message returned.')" -EvidenceMethod 'Collection issue classification' -Details $ruleIssue -IsSensitive:($rule.id -eq 'A365-SHAREPOINT-001') -EvidenceTimeUtc $evidenceTimeUtc))
            continue
        }

        switch ($rule.id) {
            'A365-FOUNDATION-002' {
                $licensing = Get-A365Property -InputObject $Evidence -Name 'licensing' -Default $null
                if ($null -eq $licensing) {
                    $status = 'Error'
                    $observed = 'Licensing evidence was not collected.'
                    $details = $null
                }
                else {
                    $assigned = [int](Get-A365Property -InputObject $licensing -Name 'qualifyingAssignedUsers' -Default 0)
                    $unknown = @(Get-A365Property -InputObject $licensing -Name 'unknownSkuMappings' -Default @())
                    $status = if ($assigned -gt 0) { 'Passed' } elseif ($unknown.Count -gt 0) { 'ActionRequired' } else { 'Blocker' }
                    $observed = "$assigned user(s) have the qualifying AGENT_365 service plan enabled."
                    $details = [pscustomobject]@{
                        UnknownSkuMappings = $unknown
                        QualifyingProducts = @($SkuCatalog.qualifyingProducts.productName)
                    }
                }
                $results.Add((New-A365Result -Rules $Rules -Id $rule.id -Status $status -Applicability 'Applicable' -Observed $observed -EvidenceMethod 'Microsoft Graph subscribedSkus and aggregate assignedPlans scan' -Details $details -EvidenceTimeUtc $evidenceTimeUtc))
            }
            'A365-FOUNDATION-003' {
                $licensing = Get-A365Property -InputObject $Evidence -Name 'licensing' -Default $null
                if ($null -eq $licensing) {
                    $status = 'Error'
                    $observed = 'SKU evidence was not collected.'
                }
                else {
                    $skuParts = @(Get-A365Property -InputObject $licensing -Name 'subscribedSkus' -Default @() | ForEach-Object { [string](Get-A365Property -InputObject $_ -Name 'skuPartNumber' -Default '') })
                    $e5 = @($skuParts | Where-Object { $_ -in @($SkuCatalog.e5SkuPartNumbers) })
                    $status = if ($e5.Count -gt 0) { 'Passed' } else { 'Advisory' }
                    $observed = if ($e5.Count -gt 0) { "E5 SKU detected: $($e5 -join ', ')" } else { 'No known Microsoft 365 E5 SKU was detected. This is advisory.' }
                }
                $results.Add((New-A365Result -Rules $Rules -Id $rule.id -Status $status -Applicability 'Applicable' -Observed $observed -EvidenceMethod 'Microsoft Graph subscribedSkus' -Details $null -EvidenceTimeUtc $evidenceTimeUtc))
            }
            'A365-FOUNDATION-004' {
                $roles = Get-A365Property -InputObject $Evidence -Name 'roles' -Default $null
                [object[]]$active = @(Get-A365Property -InputObject $roles -Name 'active' -Default @())
                $targetRoles = @('AI Administrator', 'AI Reader', 'Global Reader', 'Global Administrator')
                [object[]]$found = @(
                    $active |
                        Where-Object {
                            (Get-A365Property -InputObject $_ -Name 'role' -Default '') -in $targetRoles
                        }
                )
                $status = if ($null -eq $roles -or $null -eq (Get-A365Property -InputObject $roles -Name 'active' -Default $null)) { 'Error' } elseif ($found.Count -gt 0) { 'Passed' } else { 'ActionRequired' }
                $observed = if ($found.Count -gt 0) { ($found | ForEach-Object { "$($_.role): $($_.assignmentCount)" }) -join '; ' } else { 'No visible active Agent 365 management read role assignment.' }
                $results.Add((New-A365Result -Rules $Rules -Id $rule.id -Status $status -Applicability 'Applicable' -Observed $observed -EvidenceMethod 'Microsoft Graph role assignments aggregate' -Details $active -EvidenceTimeUtc $evidenceTimeUtc))
            }
            'A365-FOUNDATION-005' {
                $roles = Get-A365Property -InputObject $Evidence -Name 'roles' -Default $null
                $eligibleProperty = if ($roles) { $roles.PSObject.Properties['eligible'] } else { $null }
                [object[]]$eligible = @()
                if ($eligibleProperty) {
                    $eligible = @($eligibleProperty.Value)
                }
                $issue = Get-A365IssueForOperation -Issues $issues -OperationPattern 'Eligible directory roles'
                $status = if ($issue) { if ($issue.Category -in @('Authentication', 'TenantConsent', 'Authorization', 'PermissionOrRole')) { 'NotAuthorized' } else { 'Error' } } elseif ($null -eq $eligibleProperty) { 'Error' } elseif ($eligible.Count -gt 0) { 'Passed' } else { 'Advisory' }
                $observed = if ($issue) { $issue.Message } elseif ($eligible.Count -gt 0) { "$($eligible.Count) eligible role definition(s) are visible." } else { 'No eligible role assignments were returned.' }
                $results.Add((New-A365Result -Rules $Rules -Id $rule.id -Status $status -Applicability 'When PIM is used' -Observed $observed -EvidenceMethod 'Microsoft Graph role eligibility aggregate' -Details $eligible -EvidenceTimeUtc $evidenceTimeUtc))
            }
            'A365-FOUNDATION-006' {
                $health = Get-A365Property -InputObject $Evidence -Name 'serviceHealth' -Default $null
                $available = Get-A365Property -InputObject $health -Name 'available' -Default $false
                $issueCount = [int](Get-A365Property -InputObject $health -Name 'activeIssueCount' -Default 0)
                $status = if (-not $available) { 'Error' } elseif ($issueCount -gt 0) { 'Advisory' } else { 'Passed' }
                $observed = if ($available) { "$issueCount active service-health issue(s) across: $(@(Get-A365Property -InputObject $health -Name 'affectedServices' -Default @()) -join ', ')" } else { 'Service health was not available.' }
                $results.Add((New-A365Result -Rules $Rules -Id $rule.id -Status $status -Applicability 'Applicable' -Observed $observed -EvidenceMethod 'Microsoft Graph service communications aggregate' -Details $health -EvidenceTimeUtc $evidenceTimeUtc))
            }
            'A365-REGISTRY-001' {
                $registry = Get-A365Property -InputObject $Evidence -Name 'registry' -Default $null
                $available = Get-A365Property -InputObject $registry -Name 'available' -Default $false
                $schemaDrift = Get-A365Property -InputObject $registry -Name 'schemaDrift' -Default $false
                $status = if ($schemaDrift) { 'Error' } elseif ($available) { 'Passed' } else { 'Error' }
                $packageCount = [int](Get-A365Property -InputObject $registry -Name 'packageCount' -Default 0)
                $observed = if ($schemaDrift) { 'The fixture or API response did not match the expected package schema.' } elseif ($available) { "$packageCount package record(s) summarized. This is not treated as complete agent inventory." } else { 'Package catalog evidence was not available.' }
                $results.Add((New-A365Result -Rules $Rules -Id $rule.id -Status $status -Applicability 'Applicable' -Observed $observed -EvidenceMethod 'Microsoft Graph Package Management API aggregate' -Details (Get-A365Property -InputObject $registry -Name 'summary' -Default @()) -EvidenceTimeUtc $evidenceTimeUtc))
            }
            'A365-ENTRA-001' {
                $identity = Get-A365Property -InputObject $Evidence -Name 'agentIdentity' -Default $null
                $available = Get-A365Property -InputObject $identity -Name 'available' -Default $false
                $count = [int](Get-A365Property -InputObject $identity -Name 'blueprintCount' -Default 0)
                $status = if (-not $available) { 'Error' } elseif ($count -gt 0) { 'Passed' } else { 'Advisory' }
                $results.Add((New-A365Result -Rules $Rules -Id $rule.id -Status $status -Applicability 'Applicable' -Observed "$count agent identity blueprint(s) returned." -EvidenceMethod 'Microsoft Graph Agent Identity Blueprint API aggregate' -Details $null -EvidenceTimeUtc $evidenceTimeUtc))
            }
            'A365-ENTRA-002' {
                $identity = Get-A365Property -InputObject $Evidence -Name 'agentIdentity' -Default $null
                $available = Get-A365Property -InputObject $identity -Name 'available' -Default $false
                $ownerReadable = Get-A365Property -InputObject $identity -Name 'ownerReadAvailable' -Default $available
                $missing = [int](Get-A365Property -InputObject $identity -Name 'missingOwnerCount' -Default 0)
                $status = if (-not $available) { 'Error' } elseif (-not $ownerReadable) { 'NotAuthorized' } elseif ($missing -eq 0) { 'Passed' } else { 'ActionRequired' }
                $observed = if ($ownerReadable) { "$missing blueprint(s) have no visible owner." } else { 'Owner evidence was not authorized or available.' }
                $results.Add((New-A365Result -Rules $Rules -Id $rule.id -Status $status -Applicability 'When blueprints exist' -Observed $observed -EvidenceMethod 'Microsoft Graph owners aggregate' -Details $null -EvidenceTimeUtc $evidenceTimeUtc))
            }
            'A365-ENTRA-003' {
                $identity = Get-A365Property -InputObject $Evidence -Name 'agentIdentity' -Default $null
                $available = Get-A365Property -InputObject $identity -Name 'available' -Default $false
                $sponsorReadable = Get-A365Property -InputObject $identity -Name 'sponsorReadAvailable' -Default $false
                $missing = [int](Get-A365Property -InputObject $identity -Name 'missingSponsorCount' -Default 0)
                $status = if (-not $available) { 'Error' } elseif (-not $sponsorReadable) { 'NotAuthorized' } elseif ($missing -eq 0) { 'Passed' } else { 'ActionRequired' }
                $results.Add((New-A365Result -Rules $Rules -Id $rule.id -Status $status -Applicability 'When blueprints exist' -Observed $(if ($sponsorReadable) { "$missing blueprint(s) have no visible sponsor." } else { 'Sponsor evidence was not authorized or available.' }) -EvidenceMethod 'Microsoft Graph blueprint sponsors aggregate' -Details $null -EvidenceTimeUtc $evidenceTimeUtc))
            }
            'A365-ENTRA-004' {
                $identity = Get-A365Property -InputObject $Evidence -Name 'agentIdentity' -Default $null
                $available = Get-A365Property -InputObject $identity -Name 'available' -Default $false
                $expired = [int](Get-A365Property -InputObject $identity -Name 'expiredCredentialCount' -Default 0)
                $expiring = [int](Get-A365Property -InputObject $identity -Name 'expiringCredentialCount' -Default 0)
                $status = if (-not $available) { 'Error' } elseif ($expired -gt 0 -or $expiring -gt 0) { 'ActionRequired' } else { 'Passed' }
                $results.Add((New-A365Result -Rules $Rules -Id $rule.id -Status $status -Applicability 'When credentials are returned' -Observed "$expired expired and $expiring expiring-within-30-days credential(s)." -EvidenceMethod 'Aggregate credential endDateTime evaluation' -Details $null -EvidenceTimeUtc $evidenceTimeUtc))
            }
            'A365-ENTRA-005' {
                $identity = Get-A365Property -InputObject $Evidence -Name 'agentIdentity' -Default $null
                $available = Get-A365Property -InputObject $identity -Name 'available' -Default $false
                $resources = [int](Get-A365Property -InputObject $identity -Name 'requestedResourceCount' -Default 0)
                $permissions = [int](Get-A365Property -InputObject $identity -Name 'requestedPermissionCount' -Default 0)
                $status = if ($available) { 'ManualValidation' } else { 'Error' }
                $results.Add((New-A365Result -Rules $Rules -Id $rule.id -Status $status -Applicability 'When blueprints exist' -Observed "$permissions requested permission entry or entries across $resources resource(s). Names and values were not persisted." -EvidenceMethod 'Aggregate requiredResourceAccess count' -Details $null -EvidenceTimeUtc $evidenceTimeUtc))
            }
            'A365-ENTRA-006' {
                $ca = Get-A365Property -InputObject $Evidence -Name 'conditionalAccess' -Default $null
                $known = Get-A365Property -InputObject $ca -Name 'securityDefaultsKnown' -Default $false
                $enabled = Get-A365Property -InputObject $ca -Name 'securityDefaultsEnabled' -Default $null
                $status = if ($known) { 'Passed' } else { 'Error' }
                $results.Add((New-A365Result -Rules $Rules -Id $rule.id -Status $status -Applicability 'Applicable' -Observed "Security defaults enabled: $enabled" -EvidenceMethod 'Microsoft Graph policy read' -Details $null -EvidenceTimeUtc $evidenceTimeUtc))
            }
            'A365-ENTRA-007' {
                $ca = Get-A365Property -InputObject $Evidence -Name 'conditionalAccess' -Default $null
                $defaultsEnabled = Get-A365Property -InputObject $ca -Name 'securityDefaultsEnabled' -Default $null
                $available = Get-A365Property -InputObject $ca -Name 'policyInventoryAvailable' -Default $false
                $enabled = [int](Get-A365Property -InputObject $ca -Name 'enabledPolicyCount' -Default 0)
                $reportOnly = [int](Get-A365Property -InputObject $ca -Name 'reportOnlyPolicyCount' -Default 0)
                if ($defaultsEnabled -eq $true) {
                    $status = 'NotApplicable'
                    $applicability = 'Security defaults enabled'
                    $observed = 'Security defaults are enabled. Agent Conditional Access policy inventory was not judged because Conditional Access does not apply while security defaults are enabled.'
                }
                elseif (-not $available) {
                    $status = 'Error'
                    $applicability = 'Applicable'
                    $observed = 'Conditional Access policy inventory was not available.'
                }
                elseif ($enabled -eq 0 -and $reportOnly -eq 0) {
                    $status = 'ActionRequired'
                    $applicability = 'Applicable'
                    $observed = 'No enabled or report-only policy was returned. Access-pattern coverage still requires manual validation.'
                }
                else {
                    $status = 'ManualValidation'
                    $applicability = 'Applicable'
                    $observed = "$enabled enabled and $reportOnly report-only policy or policies returned. Presence does not prove agent access-pattern coverage."
                }
                $results.Add((New-A365Result -Rules $Rules -Id $rule.id -Status $status -Applicability $applicability -Observed $observed -EvidenceMethod 'Security defaults gate plus Conditional Access policy aggregate' -Details $ca -EvidenceTimeUtc $evidenceTimeUtc))
            }
            'A365-DEFENDER-001' {
                $probe = Get-A365Property -InputObject (Get-A365Property -InputObject $Evidence -Name 'defender' -Default $null) -Name 'agentsInfo' -Default $null
                $available = Get-A365Property -InputObject $probe -Name 'available' -Default $false
                $count = [int](Get-A365Property -InputObject $probe -Name 'agentCount' -Default 0)
                $status = if (-not $available) { 'Error' } elseif ($count -gt 0) { 'Passed' } else { 'Advisory' }
                $results.Add((New-A365Result -Rules $Rules -Id $rule.id -Status $status -Applicability 'Applicable' -Observed "$count distinct agent(s) summarized from AgentsInfo." -EvidenceMethod 'Aggregate-only Microsoft Graph runHuntingQuery' -Details $probe -EvidenceTimeUtc $evidenceTimeUtc))
            }
            'A365-DEFENDER-002' {
                $probe = Get-A365Property -InputObject (Get-A365Property -InputObject $Evidence -Name 'defender' -Default $null) -Name 'behaviorInfo' -Default $null
                $available = Get-A365Property -InputObject $probe -Name 'available' -Default $false
                $count = [int](Get-A365Property -InputObject $probe -Name 'behaviorCount' -Default 0)
                $status = if (-not $available) { 'Error' } elseif ($count -gt 0) { 'Passed' } else { 'Advisory' }
                $results.Add((New-A365Result -Rules $Rules -Id $rule.id -Status $status -Applicability 'Applicable' -Observed "$count behavior record(s) summarized from BehaviorInfo." -EvidenceMethod 'Aggregate-only Microsoft Graph runHuntingQuery' -Details $probe -EvidenceTimeUtc $evidenceTimeUtc))
            }
            'A365-DEFENDER-003' {
                $results.Add((New-A365Result -Rules $Rules -Id $rule.id -Status 'ManualValidation' -Applicability 'Applicable' -Observed 'Portal-only enablement, connector, and real-time protection settings were not collected.' -EvidenceMethod 'Manual validation boundary' -Details $null -EvidenceTimeUtc $evidenceTimeUtc))
            }
            'A365-PURVIEW-001' {
                $audit = Get-A365Property -InputObject (Get-A365Property -InputObject $Evidence -Name 'purview' -Default $null) -Name 'audit' -Default $null
                $available = Get-A365Property -InputObject $audit -Name 'available' -Default $false
                $statusText = [string](Get-A365Property -InputObject $audit -Name 'queryStatus' -Default 'unknown')
                $count = [int](Get-A365Property -InputObject $audit -Name 'recordCount' -Default 0)
                $status = if (-not $available) { 'Error' } elseif ($count -gt 0) { 'Passed' } else { 'Advisory' }
                $observed = if ($available) { "Audit query $statusText with $count matching record(s). Zero means no evidence in the window, not disabled auditing." } else { "Audit query unavailable or incomplete; status: $statusText." }
                $results.Add((New-A365Result -Rules $Rules -Id $rule.id -Status $status -Applicability 'Applicable' -Observed $observed -EvidenceMethod 'Microsoft Graph v1.0 Audit Search API aggregate' -Details $audit -EvidenceTimeUtc $evidenceTimeUtc))
            }
            'A365-PURVIEW-002' {
                $metadata = Get-A365Property -InputObject (Get-A365Property -InputObject $Evidence -Name 'purview' -Default $null) -Name 'policyMetadata' -Default $null
                $available = Get-A365Property -InputObject $metadata -Name 'available' -Default $false
                $status = 'ManualValidation'
                $observed = if ($available) {
                    "Metadata only: DLP $(Get-A365Property $metadata 'dlpPolicyCount' 0), retention $(Get-A365Property $metadata 'retentionPolicyCount' 0), labels $(Get-A365Property $metadata 'labelCount' 0). Presence does not prove enforcement."
                }
                else {
                    'Supported first-party compliance commands or an authenticated workload session were not available. Validate manually.'
                }
                $results.Add((New-A365Result -Rules $Rules -Id $rule.id -Status $status -Applicability 'Optional module evidence' -Observed $observed -EvidenceMethod 'Approved first-party Get-* command counts when available' -Details $metadata -EvidenceTimeUtc $evidenceTimeUtc))
            }
            'A365-SHAREPOINT-001' {
                $sharePoint = Get-A365Property -InputObject $Evidence -Name 'sharePoint' -Default $null
                $moduleAvailable = Get-A365Property -InputObject $sharePoint -Name 'moduleAvailable' -Default $false
                $sites = @(Get-A365Property -InputObject $sharePoint -Name 'sites' -Default @())
                $unreadable = @($sites | Where-Object { -not (Get-A365Property -InputObject $_ -Name 'readable' -Default $false) })
                $status = if (-not $moduleAvailable -or $sites.Count -eq 0) { 'ManualValidation' } elseif ($unreadable.Count -gt 0) { 'ActionRequired' } else { 'ManualValidation' }
                $observed = if (-not $moduleAvailable) { 'The SharePoint Online module was not available.' } elseif ($sites.Count -eq 0) { 'No target-site evidence was supplied or collected.' } else { "$($sites.Count) target site(s) checked; $($unreadable.Count) unreadable. Access boundaries still require manual review." }
                $results.Add((New-A365Result -Rules $Rules -Id $rule.id -Status $status -Applicability 'Selected profile' -Observed $observed -EvidenceMethod 'Approved Get-SPOSite command when available' -Details $sites -IsSensitive $true -EvidenceTimeUtc $evidenceTimeUtc))
            }
        }
    }

    foreach ($profile in @($Profiles | Where-Object { $_ -ne 'ControlPlane' })) {
        $docsProperty = $Rules.profileGuidance.PSObject.Properties[$profile]
        $docsUrl = if ($docsProperty) { [string]$docsProperty.Value } else { 'https://learn.microsoft.com/microsoft-agent-365/' }
        $results.Add((New-A365ProfileResult -Profile $profile -DocsUrl $docsUrl -EvidenceTimeUtc $evidenceTimeUtc -RuleReviewDate $Rules.reviewDate))
    }

    [object[]]$answerList = @()
    if ($null -ne $Answers) {
        $answerList = @(Get-A365Property -InputObject $Answers -Name 'answers' -Default @())
    }
    foreach ($attestation in @($Rules.manualAttestations)) {
        $answer = @($answerList | Where-Object { $_.id -eq $attestation.id }) | Select-Object -First 1
        $answerValue = [string](Get-A365Property -InputObject $answer -Name 'answer' -Default '')
        $answered = [bool]$answerValue

        if ($commercial -eq $false) {
            $status = 'NotApplicable'
            $applicability = 'Unsupported cloud'
            $observed = 'Not evaluated after the commercial availability gate.'
        }
        else {
            $requiredAttestation = [bool]$attestation.required
            $applicability = if ($requiredAttestation) { 'Required manual attestation' } else { 'Optional manual attestation' }
            $status = 'ManualValidation'
            $observed = 'Customer-controlled validation and evidence are required.'
        }

        $manualAttestations.Add([pscustomobject][ordered]@{
            Id = $attestation.id
            Question = $attestation.question
            Required = [bool]$attestation.required
            Answered = $answered
            Answer = if ($answered) { $answerValue } else { $null }
            Owner = Get-A365Property -InputObject $answer -Name 'owner' -Default $null
            EvidenceReference = Get-A365Property -InputObject $answer -Name 'evidenceReference' -Default $null
            Status = $status
        })

        $results.Add([pscustomobject][ordered]@{
            Id = $attestation.id
            Title = $attestation.question
            Pillar = $attestation.pillar
            Area = $attestation.area
            Profiles = @($attestation.profiles)
            Applicability = $applicability
            Status = $status
            Expected = 'An explicit customer-owned answer with an accountable role and evidence reference.'
            Observed = $observed
            EvidenceMethod = 'Customer-supplied answers JSON'
            EvidenceTimeUtc = $evidenceTimeUtc
            RequiredPermission = 'None'
            RequiredRole = 'Customer-designated control owner'
            Remediation = $attestation.remediation
            DocsUrl = $attestation.docsUrl
            RuleReviewDate = $Rules.reviewDate
            Details = if ($answer) {
                [pscustomobject]@{
                    Owner = Get-A365Property -InputObject $answer -Name 'owner' -Default $null
                    EvidenceReference = Get-A365Property -InputObject $answer -Name 'evidenceReference' -Default $null
                    Notes = Get-A365Property -InputObject $answer -Name 'notes' -Default $null
                }
            } else { $null }
            IsSensitive = $true
        })
    }

    [object[]]$definitions = @(Get-A365AttestationDefinitions -Rules $Rules -Profiles $Profiles -Guidance $Guidance)
    $definitionById = @{}
    foreach ($definition in $definitions) {
        $definitionById[[string]$definition.Id] = $definition
    }
    $answerById = @{}
    foreach ($answerItem in $answerList) {
        $answerById[[string]$answerItem.id] = $answerItem
    }

    foreach ($result in $results.ToArray()) {
        $definition = $definitionById[[string]$result.Id]
        $manualAttestable = $null -ne $definition
        $result | Add-Member -NotePropertyName ManualAttestable -NotePropertyValue $manualAttestable -Force
        $result | Add-Member -NotePropertyName AttestationRequired -NotePropertyValue $(if ($manualAttestable) { [bool]$definition.Required } else { $false }) -Force

        if (-not $manualAttestable) {
            $result | Add-Member -NotePropertyName AttestationDefinition -NotePropertyValue $null -Force
            $result | Add-Member -NotePropertyName Attestation -NotePropertyValue $null -Force
            continue
        }

        $answer = $answerById[[string]$result.Id]
        $answerValue = [string](Get-A365Property -InputObject $answer -Name 'answer' -Default '')
        $baseStatus = [string]$result.Status
        $applied = $false
        if ($baseStatus -eq 'ManualValidation' -and $answerValue) {
            switch ($answerValue) {
                'Yes' {
                    $result.Status = 'Passed'
                    $applied = $true
                }
                'No' {
                    $result.Status = [string]$definition.NoStatus
                    $applied = $true
                }
                'NotApplicable' {
                    $result.Status = 'NotApplicable'
                    $applied = $true
                }
            }
        }

        $result | Add-Member -NotePropertyName AttestationDefinition -NotePropertyValue ([pscustomobject][ordered]@{
            Required = [bool]$definition.Required
            AllowNotApplicable = [bool]$definition.AllowNotApplicable
            NoStatus = [string]$definition.NoStatus
            EvidenceNeeded = [string]$definition.EvidenceNeeded
            RequiredRole = [string]$definition.RequiredRole
            Guidance = $definition.Guidance
            Source = [string]$definition.Source
        }) -Force
        $result | Add-Member -NotePropertyName Attestation -NotePropertyValue ([pscustomobject][ordered]@{
            Submitted = $null -ne $answer
            Answer = if ($answerValue) { $answerValue } else { $null }
            Owner = Get-A365Property -InputObject $answer -Name 'owner' -Default $null
            EvidenceReference = Get-A365Property -InputObject $answer -Name 'evidenceReference' -Default $null
            Notes = Get-A365Property -InputObject $answer -Name 'notes' -Default $null
            AnsweredAtUtc = Get-A365Property -InputObject $answer -Name 'answeredAtUtc' -Default $null
            Justification = Get-A365Property -InputObject $answer -Name 'justification' -Default $null
            Applied = $applied
            PreservedObserved = $result.Observed
        }) -Force
    }

    foreach ($manualState in $manualAttestations) {
        $manualResult = @($results | Where-Object Id -eq $manualState.Id) | Select-Object -First 1
        if ($manualResult) {
            $manualState.Status = $manualResult.Status
        }
    }

    return [pscustomobject]@{
        Results = $results.ToArray()
        ManualAttestations = $manualAttestations.ToArray()
    }
}

function Get-A365Coverage {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Results
    )

    $applicable = @($Results | Where-Object { $_.Status -ne 'NotApplicable' })
    $collected = @($applicable | Where-Object { $_.Status -notin @('NotAuthorized', 'Error') })

    $coverage = [ordered]@{
        Total = $applicable.Count
        Collected = $collected.Count
        Passed = @($Results | Where-Object Status -eq 'Passed').Count
        Blockers = @($Results | Where-Object Status -eq 'Blocker').Count
        ActionRequired = @($Results | Where-Object Status -eq 'ActionRequired').Count
        Advisory = @($Results | Where-Object Status -eq 'Advisory').Count
        ManualValidation = @($Results | Where-Object Status -eq 'ManualValidation').Count
        NotApplicable = @($Results | Where-Object Status -eq 'NotApplicable').Count
        NotAuthorized = @($Results | Where-Object Status -eq 'NotAuthorized').Count
        Error = @($Results | Where-Object Status -eq 'Error').Count
        Percentage = if ($applicable.Count -eq 0) { 0 } else { [Math]::Round(($collected.Count / $applicable.Count) * 100, 1) }
    }
    return [pscustomobject]$coverage
}

function Get-A365PassCriteria {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Results
    )

    $blockerCount = @($Results | Where-Object Status -eq 'Blocker').Count
    $actionRequiredCount = @($Results | Where-Object Status -eq 'ActionRequired').Count
    $notAuthorizedCount = @($Results | Where-Object Status -eq 'NotAuthorized').Count
    $errorCount = @($Results | Where-Object Status -eq 'Error').Count
    $requiredManualUnresolvedCount = @(
        $Results |
            Where-Object {
                $_.Status -eq 'ManualValidation' -and
                [bool](Get-A365Property -InputObject $_ -Name 'ManualAttestable' -Default $false) -and
                [bool](Get-A365Property -InputObject $_ -Name 'AttestationRequired' -Default $false)
            }
    ).Count
    $isSatisfied = (
        $blockerCount -eq 0 -and
        $actionRequiredCount -eq 0 -and
        $notAuthorizedCount -eq 0 -and
        $errorCount -eq 0 -and
        $requiredManualUnresolvedCount -eq 0
    )

    $summary = if ($isSatisfied) {
        'All required pass gates are satisfied. Advisories remain for customer review.'
    }
    else {
        "$blockerCount blocker(s), $actionRequiredCount required action(s), $notAuthorizedCount authorization gap(s), $errorCount collection error(s), and $requiredManualUnresolvedCount unresolved required manual gate(s) prevent passing."
    }

    return [pscustomobject][ordered]@{
        BlockerCount = $blockerCount
        ActionRequiredCount = $actionRequiredCount
        NotAuthorizedCount = $notAuthorizedCount
        ErrorCount = $errorCount
        RequiredManualUnresolvedCount = $requiredManualUnresolvedCount
        IsSatisfied = $isSatisfied
        Summary = $summary
    }
}

function Get-A365Verdict {
    param(
        [Parameter(Mandatory)]
        [object]$PassCriteria,

        [Parameter(Mandatory)]
        [ValidateSet('Pilot', 'Production')]
        [string]$Stage
    )

    $blockerCount = [int]$PassCriteria.BlockerCount
    $actionCount = [int]$PassCriteria.ActionRequiredCount
    $authorizationGapCount = [int]$PassCriteria.NotAuthorizedCount
    $errorCount = [int]$PassCriteria.ErrorCount
    $unansweredRequired = [int]$PassCriteria.RequiredManualUnresolvedCount

    if ($blockerCount -gt 0) {
        $label = 'Blocked'
        $summary = "$blockerCount blocking condition(s) must be resolved before the selected stage."
        $exitCode = 1
    }
    elseif ($actionCount -gt 0 -or $authorizationGapCount -gt 0 -or $errorCount -gt 0 -or $unansweredRequired -gt 0) {
        $label = 'Incomplete'
        $summary = "Evidence is incomplete: $actionCount required action(s), $authorizationGapCount authorization gap(s), $errorCount collection error(s), and $unansweredRequired unresolved required manual gate(s)."
        $exitCode = 2
    }
    elseif ($Stage -eq 'Pilot') {
        $label = 'Ready for pilot'
        $summary = 'All required pass gates are satisfied. Review nonblocking advisories before and during the controlled pilot.'
        $exitCode = 0
    }
    else {
        $label = 'Technical pre-flight complete'
        $summary = 'No technical blockers or incomplete evidence remain. This is not a security or compliance certification.'
        $exitCode = 0
    }

    return [pscustomobject]@{
        Label = $label
        Summary = $summary
        BlockerCount = $blockerCount
        ActionRequiredCount = $actionCount
        AuthorizationGapCount = $authorizationGapCount
        ExitCode = $exitCode
    }
}

function Get-A365PathToReady {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Results,

        [Parameter(Mandatory)]
        [object]$PassCriteria
    )

    $items = [System.Collections.Generic.List[object]]::new()
    $phaseCatalog = @(
        [pscustomobject]@{ Id = 'blockers'; Title = 'Resolve blockers'; Description = 'Correct conditions that prevent the selected stage.'; Priority = 1 }
        [pscustomobject]@{ Id = 'collection'; Title = 'Restore evidence collection'; Description = 'Fix permissions, roles, and technical collection errors.'; Priority = 2 }
        [pscustomobject]@{ Id = 'actions'; Title = 'Complete required actions'; Description = 'Apply every required remediation before passing.'; Priority = 3 }
        [pscustomobject]@{ Id = 'manual'; Title = 'Capture required evidence'; Description = 'Record accountable customer evidence for approved manual gates.'; Priority = 4 }
        [pscustomobject]@{ Id = 'advisories'; Title = 'Review advisories'; Description = 'Acknowledge nonblocking observations and decide whether they affect the pilot.'; Priority = 5 }
    )

    foreach ($result in $Results) {
        $status = [string]$result.Status
        $manualUnresolved = (
            $status -eq 'ManualValidation' -and
            [bool](Get-A365Property -InputObject $result -Name 'ManualAttestable' -Default $false) -and
            [bool](Get-A365Property -InputObject $result -Name 'AttestationRequired' -Default $false)
        )
        if ($status -notin @('Blocker', 'NotAuthorized', 'Error', 'ActionRequired', 'Advisory') -and -not $manualUnresolved) {
            continue
        }

        if ($status -eq 'Blocker') {
            $phase = 'blockers'; $priority = 1; $changeType = 'TenantChange'
        }
        elseif ($status -in @('NotAuthorized', 'Error')) {
            $phase = 'collection'; $priority = 2
            $changeType = if ($status -eq 'NotAuthorized') { 'ConsentOrRole' } else { 'TechnicalRetry' }
        }
        elseif ($status -eq 'ActionRequired') {
            $phase = 'actions'; $priority = 3; $changeType = 'TenantChange'
        }
        elseif ($manualUnresolved) {
            $phase = 'manual'; $priority = 4; $changeType = 'ManualEvidence'
        }
        else {
            $phase = 'advisories'; $priority = 5; $changeType = 'AdvisoryReview'
        }

        $attestationDefinition = Get-A365Property -InputObject $result -Name 'AttestationDefinition' -Default $null
        $isManualAttestable = [bool](Get-A365Property -InputObject $result -Name 'ManualAttestable' -Default $false)
        $evidenceNeeded = [string](Get-A365Property -InputObject $attestationDefinition -Name 'EvidenceNeeded' -Default '')
        if (-not $evidenceNeeded) {
            $evidenceNeeded = switch ($changeType) {
                'ConsentOrRole' { 'Recollect the check after the required permission, consent, and role are available.' }
                'TechnicalRetry' { 'Resolve the collection error and rerun the same collector.' }
                'TenantChange' { 'Apply the documented remediation and rerun to collect new evidence.' }
                'AdvisoryReview' { 'Record the customer decision if this advisory affects the pilot.' }
                default { 'Capture the required evidence and rerun.' }
            }
        }

        $items.Add([pscustomobject][ordered]@{
            Id = $result.Id
            Title = $result.Title
            Status = $status
            Priority = $priority
            Phase = $phase
            Pillar = $result.Pillar
            Area = $result.Area
            Profiles = @($result.Profiles)
            OwnerRole = $result.RequiredRole
            RequiredPermission = $result.RequiredPermission
            Remediation = $result.Remediation
            EvidenceNeeded = $evidenceNeeded
            DocsUrl = $result.DocsUrl
            ChangeType = $changeType
            RequiresTenantChange = $changeType -eq 'TenantChange'
            RequiresConsentOrRole = $changeType -eq 'ConsentOrRole'
            RequiresManualEvidence = $changeType -eq 'ManualEvidence' -or $isManualAttestable
            RequiresRerun = $changeType -ne 'AdvisoryReview'
            ManualAttestable = $isManualAttestable
        })
    }

    $orderedItems = @($items.ToArray() | Sort-Object Priority, Id)
    $phases = @(
        foreach ($phase in $phaseCatalog) {
            $phaseItems = @($orderedItems | Where-Object Phase -eq $phase.Id)
            [pscustomobject][ordered]@{
                Id = $phase.Id
                Title = $phase.Title
                Description = $phase.Description
                Count = $phaseItems.Count
            }
        }
    )

    return [pscustomobject][ordered]@{
        IsReady = [bool]$PassCriteria.IsSatisfied
        GateCounts = $PassCriteria
        Phases = $phases
        Items = $orderedItems
    }
}

function Get-A365ManuallyAttestableGates {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Results
    )

    return @(
        $Results |
            Where-Object {
                [bool](Get-A365Property -InputObject $_ -Name 'ManualAttestable' -Default $false) -and
                (
                    $_.Status -ne 'NotApplicable' -or
                    [bool](Get-A365Property -InputObject (Get-A365Property -InputObject $_ -Name 'Attestation' -Default $null) -Name 'Applied' -Default $false)
                )
            } |
            ForEach-Object {
                $definition = $_.AttestationDefinition
                [pscustomobject][ordered]@{
                    Id = $_.Id
                    Title = $_.Title
                    Status = $_.Status
                    Required = [bool]$definition.Required
                    AllowNotApplicable = [bool]$definition.AllowNotApplicable
                    NoStatus = [string]$definition.NoStatus
                    EvidenceNeeded = [string]$definition.EvidenceNeeded
                    DocsUrl = $_.DocsUrl
                    Profiles = @($_.Profiles)
                    RequiredRole = [string]$definition.RequiredRole
                    Observed = $_.Observed
                    IsSensitive = [bool](Get-A365Property -InputObject $_ -Name 'IsSensitive' -Default $false)
                    Guidance = $definition.Guidance
                }
            }
    )
}

function Get-A365Actions {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Results
    )

    $priority = @{
        Blocker = 1
        NotAuthorized = 2
        Error = 2
        ActionRequired = 3
        ManualValidation = 4
    }

    return @(
        $Results |
            Where-Object {
                $_.Status -in @('Blocker', 'NotAuthorized', 'Error', 'ActionRequired') -or
                (
                    $_.Status -eq 'ManualValidation' -and
                    [bool](Get-A365Property -InputObject $_ -Name 'ManualAttestable' -Default $false) -and
                    [bool](Get-A365Property -InputObject $_ -Name 'AttestationRequired' -Default $false)
                )
            } |
            Sort-Object @{ Expression = { $priority[$_.Status] } }, Id |
            ForEach-Object {
                [pscustomobject][ordered]@{
                    Priority = $priority[$_.Status]
                    ResultId = $_.Id
                    Title = $_.Title
                    Status = $_.Status
                    Remediation = $_.Remediation
                    DocsUrl = $_.DocsUrl
                }
            }
    )
}

function ConvertTo-A365PowerShellLiteral {
    param(
        [AllowNull()]
        [string]$Value
    )

    return "'$(([string]$Value).Replace("'", "''"))'"
}

function New-A365RerunMetadata {
    param(
        [Parameter(Mandatory)]
        [string]$Stage,

        [Parameter(Mandatory)]
        [string[]]$Profiles,

        [Parameter(Mandatory)]
        [string[]]$Collectors,

        [Parameter(Mandatory)]
        [int]$AuditWindowDays,

        [Parameter(Mandatory)]
        [int]$AuditQueryTimeoutSeconds,

        [AllowNull()]
        [string]$TenantId,

        [Parameter(Mandatory)]
        [string]$CurrentJsonPath,

        [Parameter(Mandatory)]
        [string]$EntryScriptPath,

        [Parameter(Mandatory)]
        [string]$AnswerPath,

        [Parameter(Mandatory)]
        [string]$OutputPath,

        [Parameter()]
        [bool]$IncludeSanitizedCopy,

        [Parameter()]
        [bool]$UseDeviceCode
    )

    $profileValue = $Profiles -join ','
    $collectorValue = $Collectors -join ','
    $fullArguments = [System.Collections.Generic.List[string]]::new()
    if ($TenantId) {
        $fullArguments.Add("-TenantId $(ConvertTo-A365PowerShellLiteral $TenantId)")
    }
    if ($UseDeviceCode) {
        $fullArguments.Add('-UseDeviceCode')
    }
    $fullArguments.Add("-Stage $Stage")
    $fullArguments.Add("-Profile $profileValue")
    $fullArguments.Add("-Collector $collectorValue")
    $fullArguments.Add("-AuditWindowDays $AuditWindowDays")
    $fullArguments.Add("-AuditQueryTimeoutSeconds $AuditQueryTimeoutSeconds")
    $fullArguments.Add("-AnswersPath $(ConvertTo-A365PowerShellLiteral $AnswerPath)")
    $fullArguments.Add("-PreviousResultPath $(ConvertTo-A365PowerShellLiteral $CurrentJsonPath)")
    if ($IncludeSanitizedCopy) {
        $fullArguments.Add('-IncludeSanitizedCopy')
    }
    $fullArguments.Add("-OutputPath $(ConvertTo-A365PowerShellLiteral $OutputPath)")

    $sanitizedArguments = [System.Collections.Generic.List[string]]::new()
    $sanitizedArguments.Add("-TenantId '<tenant-guid-or-domain>'")
    if ($UseDeviceCode) {
        $sanitizedArguments.Add('-UseDeviceCode')
    }
    $sanitizedArguments.Add("-Stage $Stage")
    $sanitizedArguments.Add("-Profile $profileValue")
    $sanitizedArguments.Add("-Collector $collectorValue")
    $sanitizedArguments.Add("-AuditWindowDays $AuditWindowDays")
    $sanitizedArguments.Add("-AuditQueryTimeoutSeconds $AuditQueryTimeoutSeconds")
    $sanitizedArguments.Add("-AnswersPath '<answers-file.json>'")
    $sanitizedArguments.Add("-PreviousResultPath '<previous-report.json>'")
    if ($IncludeSanitizedCopy) {
        $sanitizedArguments.Add('-IncludeSanitizedCopy')
    }
    $sanitizedArguments.Add("-OutputPath '<output-folder>'")

    $formatCommand = {
        param(
            [System.Collections.Generic.List[string]]$Arguments,
            [string]$ScriptPath
        )
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add("& $(ConvertTo-A365PowerShellLiteral $ScriptPath) ``")
        for ($index = 0; $index -lt $Arguments.Count; $index++) {
            $suffix = if ($index -lt ($Arguments.Count - 1)) { ' `' } else { '' }
            $lines.Add("  $($Arguments[$index])$suffix")
        }
        return $lines -join [Environment]::NewLine
    }

    return [pscustomobject][ordered]@{
        Command = & $formatCommand $fullArguments $EntryScriptPath
        SanitizedCommand = & $formatCommand $sanitizedArguments '<resource-folder>\Invoke-Agent365Preflight.ps1'
        TenantTarget = $TenantId
        AnswersPath = $AnswerPath
        PreviousResultPath = $CurrentJsonPath
        OutputPath = $OutputPath
        IncludeSanitizedCopy = $IncludeSanitizedCopy
        Stage = $Stage
        Profiles = @($Profiles)
        Collectors = @($Collectors)
        AuditWindowDays = $AuditWindowDays
        AuditQueryTimeoutSeconds = $AuditQueryTimeoutSeconds
        UseDeviceCode = $UseDeviceCode
    }
}

function Get-A365DownloadsPath {
    $profilePath = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    if ([string]::IsNullOrWhiteSpace($profilePath)) {
        return $null
    }

    return Join-Path $profilePath 'Downloads'
}

function New-A365ResumeMetadata {
    param(
        [Parameter(Mandatory)]
        [string]$ReportId,

        [Parameter(Mandatory)]
        [string]$ScriptPath,

        [Parameter(Mandatory)]
        [string]$AnswerFileName,

        [Parameter(Mandatory)]
        [string]$OutputPath
    )

    $downloadsPath = Get-A365DownloadsPath
    [object[]]$searchPaths = @(
        Join-Path $OutputPath $AnswerFileName
        if ($downloadsPath) {
            Join-Path $downloadsPath $AnswerFileName
        }
    )

    return [pscustomobject][ordered]@{
        Available = $true
        ReportId = $ReportId
        ScriptPath = $ScriptPath
        Command = "& $(ConvertTo-A365PowerShellLiteral $ScriptPath)"
        SanitizedCommand = "& '<output-folder>\Resume-Agent365Preflight.ps1'"
        AnswerFileName = $AnswerFileName
        AnswerSearchPaths = $searchPaths
    }
}

function Write-A365ResumeScript {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$LauncherPath,

        [Parameter(Mandatory)]
        [string]$PreviousResultPath,

        [Parameter()]
        [bool]$UseDeviceCode
    )

    $launcherLiteral = ConvertTo-A365PowerShellLiteral $LauncherPath
    $previousLiteral = ConvertTo-A365PowerShellLiteral $PreviousResultPath
    $deviceLine = if ($UseDeviceCode) { '    UseDeviceCode = $true' } else { $null }
    $lines = @(
        '#requires -Version 7.0'
        ''
        '<#'
        'Runs the Agent 365 pre-flight customer launcher in Resume mode.'
        'This generated helper contains no credentials, tokens, or certificate material.'
        '#>'
        '[CmdletBinding()]'
        'param('
        '    [Parameter()]'
        '    [string]$AnswersPath,'
        ''
        '    [Parameter()]'
        "    [ValidateSet('Ask', 'Always', 'Never')]"
        "    [string]`$OpenReport = 'Ask',"
        ''
        '    [Parameter()]'
        '    [switch]$UseDeviceCode,'
        ''
        '    [Parameter()]'
        '    [switch]$NonInteractive,'
        ''
        '    [Parameter()]'
        '    [switch]$PassThru,'
        ''
        '    [Parameter()]'
        '    [string]$ClientId,'
        ''
        '    [Parameter()]'
        '    [string]$CertificateThumbprint'
        ')'
        ''
        "`$launcherPath = $launcherLiteral"
        "`$previousResultPath = $previousLiteral"
        'if (-not (Test-Path -LiteralPath $launcherPath -PathType Leaf)) {'
        '    throw "The Agent 365 pre-flight launcher was not found: $launcherPath"'
        '}'
        'if (-not (Test-Path -LiteralPath $previousResultPath -PathType Leaf)) {'
        '    throw "The previous full report was not found: $previousResultPath"'
        '}'
        ''
        '$parameters = @{'
        "    Mode = 'Resume'"
        '    PreviousResultPath = $previousResultPath'
        '    OpenReport = $OpenReport'
        '}'
        $deviceLine
        'if ($AnswersPath) { $parameters.AnswersPath = $AnswersPath }'
        'if ($UseDeviceCode) { $parameters.UseDeviceCode = $true }'
        'if ($NonInteractive) { $parameters.NonInteractive = $true }'
        'if ($PassThru) { $parameters.PassThru = $true }'
        'if ($ClientId) { $parameters.ClientId = $ClientId }'
        'if ($CertificateThumbprint) { $parameters.CertificateThumbprint = $CertificateThumbprint }'
        ''
        '$result = & $launcherPath @parameters'
        'if ($PassThru) {'
        '    $result'
        '    return'
        '}'
        'exit $LASTEXITCODE'
    ) | Where-Object { $null -ne $_ }

    [System.IO.File]::WriteAllLines(
        $Path,
        $lines,
        [System.Text.UTF8Encoding]::new($false)
    )
    return (Resolve-Path -LiteralPath $Path).Path
}

function Compare-Agent365PreflightResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Current,

        [AllowNull()]
        [object]$Previous
    )

    if ($null -eq $Previous) {
        return [pscustomobject][ordered]@{
            HasBaseline = $false
            BaselineGeneratedAtUtc = $null
            Regressions = @()
            ResolvedBlockers = @()
            ResolvedRequiredActions = @()
            Changed = @()
        }
    }

    $severity = @{
        Passed = 0
        NotApplicable = 0
        Advisory = 1
        ManualValidation = 2
        ActionRequired = 3
        NotAuthorized = 4
        Error = 4
        Blocker = 5
    }
    $previousById = @{}
    foreach ($item in @(Get-A365Property -InputObject $Previous -Name 'Results' -Default @())) {
        $previousById[[string]$item.Id] = $item
    }

    $regressions = [System.Collections.Generic.List[object]]::new()
    $resolved = [System.Collections.Generic.List[object]]::new()
    $resolvedRequiredActions = [System.Collections.Generic.List[object]]::new()
    $changed = [System.Collections.Generic.List[object]]::new()

    foreach ($item in @(Get-A365Property -InputObject $Current -Name 'Results' -Default @())) {
        if (-not $previousById.ContainsKey([string]$item.Id)) {
            continue
        }

        $old = $previousById[[string]$item.Id]
        if ($old.Status -eq $item.Status) {
            continue
        }

        $entry = [pscustomobject][ordered]@{
            Id = $item.Id
            Title = $item.Title
            PreviousStatus = $old.Status
            CurrentStatus = $item.Status
        }
        $changed.Add($entry)

        if ($old.Status -eq 'Blocker' -and $item.Status -ne 'Blocker') {
            $resolved.Add($entry)
        }
        if ($old.Status -in @('ActionRequired', 'ManualValidation') -and
            $item.Status -in @('Passed', 'Advisory', 'NotApplicable')) {
            $resolvedRequiredActions.Add($entry)
        }
        elseif ($severity[[string]$item.Status] -gt $severity[[string]$old.Status]) {
            $regressions.Add($entry)
        }
    }

    return [pscustomobject][ordered]@{
        HasBaseline = $true
        BaselineGeneratedAtUtc = Get-A365Property -InputObject $Previous -Name 'GeneratedAtUtc' -Default $null
        Regressions = $regressions.ToArray()
        ResolvedBlockers = $resolved.ToArray()
        ResolvedRequiredActions = $resolvedRequiredActions.ToArray()
        Changed = $changed.ToArray()
    }
}

function ConvertTo-A365RedactedText {
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return $null
    }

    $text = [string]$Value
    $text = $text -replace '(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b', '[redacted-email]'
    $text = $text -replace '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b', '[redacted-id]'
    $text = $text -replace '(?i)https://[a-z0-9.-]+\.sharepoint\.com/[^\s"<>]*', '[redacted-sharepoint-url]'
    $text = $text -replace '(?i)\b[A-Z]:\\[^\r\n]*', '[redacted-path]'
    return $text
}

function New-Agent365SanitizedReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Report
    )

    $sanitized = $Report | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100
    $sanitized.Sanitized = $true
    $sanitized.Tenant.DisplayName = 'Redacted tenant'
    $sanitized.Tenant.TenantId = $null
    $sanitized.Tenant.PrimaryDomain = 'redacted.invalid'
    if ($sanitized.Tenant.PSObject.Properties['TargetAssertion']) {
        $sanitized.Tenant.TargetAssertion.Expected = if ($sanitized.Tenant.TargetAssertion.Expected) { 'Redacted' } else { $null }
        $sanitized.Tenant.TargetAssertion.ActualTenantId = $null
        $sanitized.Tenant.TargetAssertion.MatchedVerifiedDomain = $null
    }
    $sanitized.Authentication.Account = 'Redacted'

    foreach ($result in @($sanitized.Results)) {
        if ([bool](Get-A365Property -InputObject $result -Name 'IsSensitive' -Default $false)) {
            $result.Observed = 'Redacted in sanitized support copy.'
            $result.Details = $null
        }
        else {
            $result.Observed = ConvertTo-A365RedactedText $result.Observed
        }
        $resultAttestation = Get-A365Property -InputObject $result -Name 'Attestation' -Default $null
        if ($null -ne $resultAttestation) {
            $resultAttestation.Owner = if ($resultAttestation.Owner) { 'Redacted' } else { $null }
            $resultAttestation.EvidenceReference = if ($resultAttestation.EvidenceReference) { 'Redacted' } else { $null }
            $resultAttestation.Notes = if ($resultAttestation.Notes) { 'Redacted' } else { $null }
            $resultAttestation.Justification = if ($resultAttestation.Justification) { 'Redacted' } else { $null }
            $resultAttestation.PreservedObserved = if ([bool](Get-A365Property -InputObject $result -Name 'IsSensitive' -Default $false)) {
                'Redacted in sanitized support copy.'
            }
            else {
                ConvertTo-A365RedactedText $resultAttestation.PreservedObserved
            }
        }
    }

    foreach ($gate in @($sanitized.ManuallyAttestableGates)) {
        if ([bool](Get-A365Property -InputObject $gate -Name 'IsSensitive' -Default $false)) {
            $gate.Observed = 'Redacted in sanitized support copy.'
        }
        else {
            $gate.Observed = ConvertTo-A365RedactedText $gate.Observed
        }
    }

    foreach ($issue in @($sanitized.CollectionIssues)) {
        $issue.Message = ConvertTo-A365RedactedText $issue.Message
        if ($issue.PSObject.Properties['Operation']) {
            $issue.Operation = ConvertTo-A365RedactedText $issue.Operation
        }
    }

    foreach ($attestation in @($sanitized.ManualAttestations)) {
        $attestation.Owner = if ($attestation.Owner) { 'Redacted' } else { $null }
        $attestation.EvidenceReference = if ($attestation.EvidenceReference) { 'Redacted' } else { $null }
    }

    if ($sanitized.PSObject.Properties['Rerun'] -and $null -ne $sanitized.Rerun) {
        $sanitized.Rerun.Command = $sanitized.Rerun.SanitizedCommand
        $sanitized.Rerun.TenantTarget = '<tenant-guid-or-domain>'
        $sanitized.Rerun.AnswersPath = '<answers-file.json>'
        $sanitized.Rerun.PreviousResultPath = '<previous-report.json>'
        $sanitized.Rerun.OutputPath = '<output-folder>'
    }
    if ($sanitized.PSObject.Properties['Resume'] -and $null -ne $sanitized.Resume) {
        $sanitized.Resume.Available = $false
        $sanitized.Resume.ScriptPath = '<output-folder>\Resume-Agent365Preflight.ps1'
        $sanitized.Resume.Command = $sanitized.Resume.SanitizedCommand
        $sanitized.Resume.AnswerSearchPaths = @(
            "<output-folder>\$($sanitized.Resume.AnswerFileName)"
            "<Downloads>\$($sanitized.Resume.AnswerFileName)"
        )
    }

    if ($sanitized.Runtime.PSObject.Properties['OutputFiles']) {
        $sanitized.Runtime.OutputFiles = @()
    }

    return $sanitized
}

function Invoke-Agent365Preflight {
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
        [switch]$UseDeviceCode,

        [Parameter()]
        [string]$TenantId,

        [Parameter()]
        [string]$ClientId,

        [Parameter()]
        [string]$CertificateThumbprint
    )

    $started = Get-Date
    $profiles = @(
        @('ControlPlane') + @($Profile | Where-Object { $_ -ne 'ControlPlane' }) |
            Select-Object -Unique
    )
    $collectors = @(
        @('TenantFoundation') + @($Collector | Where-Object { $_ -ne 'TenantFoundation' }) |
            Select-Object -Unique
    )
    $rules = Read-A365Json -Path $script:RulesPath -Description 'Rule set'
    $guidance = Read-A365Json -Path $script:GuidancePath -Description 'Manual evidence guidance'
    $skuCatalog = Read-A365Json -Path $script:SkuCatalogPath -Description 'SKU catalog'
    $allowlist = Read-A365Json -Path $script:AllowlistPath -Description 'Operation allowlist'
    $answers = if ($AnswersPath) { Read-A365Json -Path $AnswersPath -Description 'Answers file' } else { $null }
    $previous = if ($PreviousResultPath) { Read-A365Json -Path $PreviousResultPath -Description 'Previous result' } else { $null }

    Test-A365GuidanceContract -Rules $rules -Guidance $guidance
    [object[]]$attestationDefinitions = @(
        Get-A365AttestationDefinitions -Rules $rules -Profiles $profiles -Guidance $guidance -IncludeAllProfiles
    )
    if ($answers) {
        Test-A365AnswersInput `
            -Answers $answers `
            -Definitions $attestationDefinitions `
            -Rules $rules
    }

    if ($previous -and (Get-A365Property -InputObject $previous -Name 'SchemaVersion' -Default '') -notin @('1.0', '1.1', '1.2', '1.3')) {
        throw 'Previous result SchemaVersion must be 1.0, 1.1, 1.2, or 1.3.'
    }
    if ($previous -and $null -eq $previous.PSObject.Properties['Results']) {
        throw 'Previous result must contain a Results array.'
    }

    if (-not (Test-Path -LiteralPath $OutputPath -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $OutputPath -Force -ErrorAction Stop
    }
    $resolvedOutputPath = (Resolve-Path -LiteralPath $OutputPath).Path

    [object[]]$scopes = @(
        Get-Agent365RequiredScopes -Profile $profiles -Collector $collectors
    )
    Write-Host 'Microsoft Graph permissions requested by this run:'
    foreach ($scope in $scopes) {
        Write-Host "  $scope"
    }
    if ($FixturePath) {
        Write-Host 'Fixture mode: no authentication or tenant request will occur.'
    }

    $issues = [System.Collections.Generic.List[object]]::new()
    $evidence = if ($FixturePath) {
        Read-A365Json -Path $FixturePath -Description 'Fixture file'
    }
    else {
        Get-A365LiveEvidence -Profiles $profiles -Collectors $collectors -Scopes $scopes -SkuCatalog $skuCatalog -Allowlist $allowlist -Issues $issues -InstallDependencies:$InstallDependencies -SharePointSiteUrl $SharePointSiteUrl -AuditWindowDays $AuditWindowDays -AuditQueryTimeoutSeconds $AuditQueryTimeoutSeconds -TenantId $TenantId -ClientId $ClientId -CertificateThumbprint $CertificateThumbprint -UseDeviceCode:$UseDeviceCode
    }

    $fixtureIssues = @(Get-A365Property -InputObject $evidence -Name 'collectionIssues' -Default @())
    $evaluation = Get-A365Evaluation -Evidence $evidence -Rules $rules -Guidance $guidance -SkuCatalog $skuCatalog -Profiles $profiles -Collectors $collectors -Answers $answers
    $results = @($evaluation.Results)
    $manualAttestations = @($evaluation.ManualAttestations)
    $passCriteria = Get-A365PassCriteria -Results $results
    $coverage = Get-A365Coverage -Results $results
    $verdictWithExit = Get-A365Verdict -PassCriteria $passCriteria -Stage $Stage
    $pathToReady = Get-A365PathToReady -Results $results -PassCriteria $passCriteria
    $manuallyAttestableGates = @(Get-A365ManuallyAttestableGates -Results $results)
    $authenticationEvidence = Get-A365Property -InputObject $evidence -Name 'authentication' -Default ([pscustomobject]@{})
    $grantedScopes = @(Get-A365Property -InputObject $authenticationEvidence -Name 'grantedScopes' -Default @())
    $missingScopes = @($scopes | Where-Object { $_ -notin $grantedScopes })
    $authMode = [string](Get-A365Property -InputObject $authenticationEvidence -Name 'mode' -Default 'Unavailable')
    if ($authMode -eq 'CertificateAppOnly') {
        $missingScopes = @()
    }
    [object[]]$authenticationNotes = @()
    if ($authMode -eq 'CertificateAppOnly') {
        $authenticationNotes = @(
            'Application permissions are configured on the app registration and are not represented as delegated scopes.'
        )
    }

    $tenantEvidence = Get-A365Property -InputObject $evidence -Name 'tenant' -Default ([pscustomobject]@{})
    $targetAssertionEvidence = Get-A365Property -InputObject $tenantEvidence -Name 'targetAssertion' -Default ([pscustomobject]@{
        requested = $false
        expected = $null
        method = 'NotRequested'
        matched = $null
        actualTenantId = $null
        matchedVerifiedDomain = $null
    })
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $reportId = "Agent365Preflight-$stamp"
    $jsonPath = Join-Path $resolvedOutputPath "$reportId.json"
    $htmlPath = Join-Path $resolvedOutputPath "$reportId.html"
    $sanitizedJsonPath = if ($IncludeSanitizedCopy) { Join-Path $resolvedOutputPath "$reportId-sanitized.json" } else { $null }
    $sanitizedHtmlPath = if ($IncludeSanitizedCopy) { Join-Path $resolvedOutputPath "$reportId-sanitized.html" } else { $null }
    $resumeScriptPath = Join-Path $resolvedOutputPath 'Resume-Agent365Preflight.ps1'
    $answerFileName = "$reportId-answers.json"
    $downloadsPath = Get-A365DownloadsPath
    $answerPath = if ($downloadsPath) {
        Join-Path $downloadsPath $answerFileName
    }
    else {
        Join-Path $resolvedOutputPath $answerFileName
    }
    $entryScriptPath = Join-Path $script:ModuleRoot 'Invoke-Agent365Preflight.ps1'
    $launcherPath = Join-Path $script:ModuleRoot 'Start-Agent365Preflight.ps1'
    $resumeMetadata = New-A365ResumeMetadata `
        -ReportId $reportId `
        -ScriptPath $resumeScriptPath `
        -AnswerFileName $answerFileName `
        -OutputPath $resolvedOutputPath
    $report = [pscustomobject][ordered]@{
        SchemaVersion = '1.3'
        ReportId = $reportId
        ToolVersion = $script:ToolVersion
        GeneratedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        RuleSetVersion = $rules.version
        RuleReviewDate = $rules.reviewDate
        GuidanceVersion = $guidance.version
        GuidanceReviewDate = $guidance.reviewDate
        Stage = $Stage
        Profiles = $profiles
        Collectors = $collectors
        Sanitized = $false
        BetaEnabled = [bool]$IncludeBeta
        FixtureMode = [bool]$FixturePath
        Verdict = [pscustomobject]@{
            Label = $verdictWithExit.Label
            Summary = $verdictWithExit.Summary
            BlockerCount = $verdictWithExit.BlockerCount
            ActionRequiredCount = $verdictWithExit.ActionRequiredCount
            AuthorizationGapCount = $verdictWithExit.AuthorizationGapCount
            ErrorCount = $passCriteria.ErrorCount
            RequiredManualUnresolvedCount = $passCriteria.RequiredManualUnresolvedCount
        }
        PassCriteria = $passCriteria
        PathToReady = $pathToReady
        Tenant = [pscustomobject][ordered]@{
            DisplayName = Get-A365Property -InputObject $tenantEvidence -Name 'displayName' -Default $null
            TenantId = Get-A365Property -InputObject $tenantEvidence -Name 'tenantId' -Default $null
            PrimaryDomain = Get-A365Property -InputObject $tenantEvidence -Name 'primaryDomain' -Default $null
            Cloud = Get-A365Property -InputObject $tenantEvidence -Name 'cloud' -Default 'Unknown'
            CommercialAvailability = Get-A365Property -InputObject $tenantEvidence -Name 'commercialAvailability' -Default $null
            TargetAssertion = [pscustomobject][ordered]@{
                Requested = [bool](Get-A365Property -InputObject $targetAssertionEvidence -Name 'requested' -Default $false)
                Expected = Get-A365Property -InputObject $targetAssertionEvidence -Name 'expected' -Default $null
                Method = Get-A365Property -InputObject $targetAssertionEvidence -Name 'method' -Default 'NotRequested'
                Matched = Get-A365Property -InputObject $targetAssertionEvidence -Name 'matched' -Default $null
                ActualTenantId = Get-A365Property -InputObject $targetAssertionEvidence -Name 'actualTenantId' -Default $null
                MatchedVerifiedDomain = Get-A365Property -InputObject $targetAssertionEvidence -Name 'matchedVerifiedDomain' -Default $null
            }
        }
        Coverage = $coverage
        Authentication = [pscustomobject][ordered]@{
            Mode = $authMode
            Account = Get-A365Property -InputObject $authenticationEvidence -Name 'account' -Default $null
            RequestedScopes = $scopes
            GrantedScopes = $grantedScopes
            MissingScopes = $missingScopes
            UseDeviceCode = [bool](Get-A365Property -InputObject $authenticationEvidence -Name 'useDeviceCode' -Default $false)
            ReusedExistingContext = [bool](Get-A365Property -InputObject $authenticationEvidence -Name 'reusedExistingContext' -Default $false)
            PermissionsUsed = @(
                @($results | Where-Object Status -ne 'NotApplicable').RequiredPermission -split ',' |
                    ForEach-Object { $_.Trim() } |
                    Where-Object { $_ -match '\.' } |
                    Sort-Object -Unique
            )
            Notes = $authenticationNotes
        }
        Results = $results
        Actions = @(Get-A365Actions -Results $results)
        ManualAttestations = $manualAttestations
        ManuallyAttestableGates = $manuallyAttestableGates
        Resume = $resumeMetadata
        Rerun = $null
        Drift = [pscustomobject]@{
            HasBaseline = $false
            BaselineGeneratedAtUtc = $null
            Regressions = @()
            ResolvedBlockers = @()
            ResolvedRequiredActions = @()
            Changed = @()
        }
        Sources = @(
            $results |
                Sort-Object DocsUrl -Unique |
                ForEach-Object {
                    [pscustomobject]@{
                        Title = $_.Title
                        Url = $_.DocsUrl
                        ReviewDate = $_.RuleReviewDate
                    }
                }
        )
        CollectionIssues = $fixtureIssues
        Runtime = [pscustomobject][ordered]@{
            PowerShellVersion = $PSVersionTable.PSVersion.ToString()
            Platform = "$($PSVersionTable.Platform) $([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture)"
            DurationSeconds = 0
            AuditWindowDays = $AuditWindowDays
            AuditQueryTimeoutSeconds = $AuditQueryTimeoutSeconds
            OutputFiles = @()
        }
    }

    $report.Drift = Compare-Agent365PreflightResult -Current $report -Previous $previous

    $outputFiles = @($htmlPath, $jsonPath, $resumeScriptPath)
    if ($IncludeSanitizedCopy) {
        $outputFiles += @($sanitizedHtmlPath, $sanitizedJsonPath)
    }
    $report.Rerun = New-A365RerunMetadata `
        -Stage $Stage `
        -Profiles $profiles `
        -Collectors $collectors `
        -AuditWindowDays $AuditWindowDays `
        -AuditQueryTimeoutSeconds $AuditQueryTimeoutSeconds `
        -TenantId $TenantId `
        -CurrentJsonPath $jsonPath `
        -EntryScriptPath $entryScriptPath `
        -AnswerPath $answerPath `
        -OutputPath $resolvedOutputPath `
        -IncludeSanitizedCopy ([bool]$IncludeSanitizedCopy) `
        -UseDeviceCode ([bool]$UseDeviceCode)
    $report.Runtime.OutputFiles = $outputFiles
    $report.Runtime.DurationSeconds = [Math]::Round(((Get-Date) - $started).TotalSeconds, 2)

    $resumeScriptPath = Write-A365ResumeScript `
        -Path $resumeScriptPath `
        -LauncherPath $launcherPath `
        -PreviousResultPath $jsonPath `
        -UseDeviceCode ([bool]$UseDeviceCode)
    $jsonPath = Write-A365JsonFile -InputObject $report -Path $jsonPath
    $htmlPath = New-Agent365PreflightHtml -Report $report -Path $htmlPath

    if ($IncludeSanitizedCopy) {
        $sanitized = New-Agent365SanitizedReport -Report $report
        $sanitizedJsonPath = Write-A365JsonFile -InputObject $sanitized -Path $sanitizedJsonPath
        $sanitizedHtmlPath = New-Agent365PreflightHtml -Report $sanitized -Path $sanitizedHtmlPath -Sanitized
    }

    return [pscustomobject]@{
        ExitCode = [int]$verdictWithExit.ExitCode
        Report = $report
        Paths = [pscustomobject]@{
            Html = $htmlPath
            Json = $jsonPath
            SanitizedHtml = $sanitizedHtmlPath
            SanitizedJson = $sanitizedJsonPath
            Resume = $resumeScriptPath
        }
    }
}

Export-ModuleMember -Function @(
    'Compare-Agent365PreflightResult'
    'Get-Agent365RequiredScopes'
    'Invoke-Agent365PagedRequest'
    'Invoke-Agent365Preflight'
    'New-Agent365SanitizedReport'
    'Test-Agent365OperationAllowed'
)
