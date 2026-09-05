function Get-A365ContentHash {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))).Replace('-', '').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

function Get-A365RuleCollector {
    param([Parameter(Mandatory)][string]$Id)
    switch -Regex ($Id) {
        '^A365-FOUNDATION-00[23]$' { return 'Licensing' }
        '^A365-FOUNDATION-00[45]$' { return 'Roles' }
        '^A365-FOUNDATION-006$' { return 'ServiceHealth' }
        '^A365-REGISTRY-' { return 'Registry' }
        '^A365-ENTRA-00[1-5]$' { return 'AgentIdentity' }
        '^A365-ENTRA-00[67]$' { return 'ConditionalAccess' }
        '^A365-DEFENDER-' { return 'Defender' }
        '^A365-PURVIEW-' { return 'Purview' }
        '^A365-SHAREPOINT-' { return 'SharePoint' }
        '^A365-(LOCAL|FOUNDATION)-' { return 'TenantFoundation' }
        default { return 'Customer' }
    }
}

function New-A365AssessmentScope {
    param(
        [Parameter(Mandatory)][object]$Rules,
        [Parameter(Mandatory)][string]$Stage,
        [Parameter(Mandatory)][string[]]$Profiles,
        [string[]]$SharePointSiteUrl = @(),
        [ValidateSet('ActiveRoles', 'PIM')][string]$RolePolicy = 'ActiveRoles',
        [string[]]$ExcludeRequirement = @(),
        [string]$ScopeJustification
    )
    $targets = @(
        foreach ($target in $SharePointSiteUrl) {
            $uri = $null
            if (-not [Uri]::TryCreate($target, [UriKind]::Absolute, [ref]$uri) -or
                $uri.Scheme -ne 'https' -or $uri.Port -ne 443 -or $uri.UserInfo -or
                $uri.Query -or $uri.Fragment -or $uri.DnsSafeHost -notmatch '\.sharepoint\.com$') {
                throw 'Target sites must be HTTPS Commercial SharePoint URLs without credentials, query strings, or fragments.'
            }
            $uri.AbsoluteUri.TrimEnd('/').ToLowerInvariant()
        }
    ) | Sort-Object -Unique
    $profilesInScope = @(@('ControlPlane') + $Profiles | Sort-Object -Unique)
    if (@($targets).Count -gt 0) {
        $profilesInScope = @($profilesInScope + 'SharePointAgents' | Sort-Object -Unique)
    }
    $allIds = @('A365-RULES-001') + @($Rules.checks.id) + @($Rules.manualAttestations.id) +
        @($profilesInScope | Where-Object { $_ -ne 'ControlPlane' } | ForEach-Object { Get-A365ProfileResultId $_ })
    foreach ($id in $ExcludeRequirement) {
        if ($id -notin $allIds -or $id -match '^A365-(LOCAL|FOUNDATION|RULES)-') {
            throw "Assessment exclusion is unknown or a non-excludable foundation gate: $id"
        }
    }
    if ($ExcludeRequirement.Count -gt 0 -and [string]::IsNullOrWhiteSpace($ScopeJustification)) {
        throw 'An explicit assessment exclusion requires a reviewable ScopeJustification. Omitted collectors never exclude requirements.'
    }
    $requirements = @(
        foreach ($id in $allIds) {
            $applies = $true
            $reason = 'Selected assessment baseline'
            if ($id -eq 'A365-FOUNDATION-005' -and $RolePolicy -ne 'PIM') {
                $applies = $false; $reason = 'Active-role policy selected; PIM is not required'
            }
            if ($id -eq 'A365-SHAREPOINT-001' -and $profilesInScope -notcontains 'SharePointAgents') {
                $applies = $false; $reason = 'No SharePoint profile or target site in the assessment'
            }
            if ($id -in $ExcludeRequirement) {
                $applies = $false; $reason = "Explicit assessment exclusion: $ScopeJustification"
            }
            [pscustomobject][ordered]@{
                Id = $id
                Applicable = $applies
                Reason = $reason
                Collector = Get-A365RuleCollector $id
            }
        }
    )
    $scope = [ordered]@{
        Version = '2.0'
        Stage = $Stage
        Profiles = @($profilesInScope)
        TargetSites = @($targets)
        RolePolicy = $RolePolicy
        ExcludedRequirements = @($ExcludeRequirement | Sort-Object -Unique)
        Justification = $ScopeJustification
        Requirements = @($requirements | Sort-Object Id)
    }
    $normative = [ordered]@{
        Version = $scope.Version; Stage = $Stage; Profiles = $scope.Profiles
        TargetSites = $scope.TargetSites; RolePolicy = $RolePolicy
        ExcludedRequirements = $scope.ExcludedRequirements
        ApplicableRequirements = @($requirements | Where-Object Applicable | Sort-Object Id | Select-Object -ExpandProperty Id)
    }
    $fingerprint = Get-A365ContentHash ($normative | ConvertTo-Json -Depth 20 -Compress)
    $scope.Fingerprint = $fingerprint
    return [pscustomobject]$scope
}

function Assert-A365RawField {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory)][string]$Name,
        [ValidateSet('Array', 'String', 'Boolean', 'Count', 'Date', 'Guid', 'Object')][string]$Type,
        [switch]$Nullable
    )
    $property = if ($null -ne $Object) { $Object.PSObject.Properties[$Name] } else { $null }
    if ($null -eq $property) { throw "MalformedEvidence: required $Name property is absent." }
    $value = $property.Value
    if ($null -eq $value -and $Nullable) { return }
    $valid = switch ($Type) {
        'Array' { $value -is [Array] }
        'String' { $value -is [string] -and -not [string]::IsNullOrWhiteSpace($value) }
        'Boolean' { $value -is [bool] }
        'Count' { ($value -is [int] -or $value -is [long] -or $value -is [double] -or $value -is [decimal]) -and $value -ge 0 -and $value -le [int]::MaxValue -and $value -eq [Math]::Truncate($value) }
        'Date' { $parsed = [DateTimeOffset]::MinValue; $value -is [DateTime] -or $value -is [DateTimeOffset] -or ($value -is [string] -and [DateTimeOffset]::TryParse($value, [ref]$parsed)) }
        'Guid' { $parsed = [Guid]::Empty; $value -is [string] -and [Guid]::TryParse($value, [ref]$parsed) }
        'Object' { $value -is [pscustomobject] }
    }
    if (-not $valid) { throw "MalformedEvidence: $Name must be $Type." }
}

function Assert-A365NextLink {
    param([object]$Response, [string]$Uri, [object]$Allowlist)
    $property = $Response.PSObject.Properties['@odata.nextLink']
    if ($null -eq $property) { return }
    $next = $property.Value
    $parsed = $null
    if ($next -isnot [string] -or -not [Uri]::TryCreate($next, [UriKind]::Absolute, [ref]$parsed) -or
        -not (Test-Agent365OperationAllowed -Adapter Graph -Method GET -Target $next -Allowlist $Allowlist) -or
        $parsed.AbsolutePath -cne ([Uri]$Uri).AbsolutePath) {
        throw 'MalformedEvidence: pagination link is not an allowlisted HTTPS Graph URL for this operation.'
    }
}

function Assert-A365RawResponse {
    param([object]$Response, [string]$Uri, [string]$Method, [object]$Body, [object]$Allowlist)
    if ($Response -isnot [pscustomobject]) { throw 'MalformedEvidence: Graph response must be an object.' }
    if ($Response.PSObject.Properties['error']) { throw 'MalformedEvidence: success response contains an error envelope.' }
    $path = ([Uri]$Uri).AbsolutePath
    if ($path -eq '/v1.0/security/runHuntingQuery') {
        Assert-A365RawField $Response 'results' Array
        if ($Response.results.Count -ne 1) { throw 'MalformedEvidence: summarize query must return exactly one aggregate row, including zero counts.' }
        $row = $Response.results[0]
        $query = [string]$Body.Query
        $counts = if ($query -match '^AgentsInfo \|') { @('AgentCount', 'PlatformCount') } else { @('BehaviorCount') }
        foreach ($column in $counts) { Assert-A365RawField $row $column Count }
        Assert-A365RawField $row 'LatestEvidenceUtc' Date -Nullable
        return $(if ($row.PSObject.Properties[$counts[0]].Value -eq 0) { 'ValidZero' } else { 'Valid' })
    }
    if ($path -match '^/v1\.0/security/auditLog/queries(?:/[0-9a-fA-F-]+)?$') {
        Assert-A365RawField $Response 'id' Guid
        Assert-A365RawField $Response 'status' String
        if ($Response.status -notin @('notStarted', 'running', 'succeeded', 'failed', 'cancelled')) {
            throw 'MalformedEvidence: unrecognized Audit Search status. Review the API contract before continuing.'
        }
        return 'Valid'
    }
    if ($path -eq '/v1.0/policies/identitySecurityDefaultsEnforcementPolicy') {
        Assert-A365RawField $Response 'isEnabled' Boolean
        return 'Valid'
    }
    Assert-A365RawField $Response 'value' Array
    Assert-A365NextLink -Response $Response -Uri $Uri -Allowlist $Allowlist
    if ($path -eq '/v1.0/organization' -and $Response.value.Count -ne 1) {
        throw 'MalformedEvidence: organization must return exactly one tenant.'
    }
    foreach ($item in $Response.value) {
        if ($item -isnot [pscustomobject]) { throw 'MalformedEvidence: collection row must be an object.' }
        switch -Regex ($path) {
            '^/v1\.0/organization$' {
                Assert-A365RawField $item 'id' Guid
                Assert-A365RawField $item 'displayName' String
                Assert-A365RawField $item 'verifiedDomains' Array
                foreach ($domain in $item.verifiedDomains) {
                    Assert-A365RawField $domain 'name' String
                    Assert-A365RawField $domain 'isDefault' Boolean
                }
            }
            '^/v1\.0/users$' {
                Assert-A365RawField $item 'assignedPlans' Array
                foreach ($plan in $item.assignedPlans) {
                    Assert-A365RawField $plan 'servicePlanId' Guid
                    Assert-A365RawField $plan 'capabilityStatus' String
                }
            }
            '^/v1\.0/subscribedSkus$' {
                foreach ($field in @('skuId', 'skuPartNumber', 'capabilityStatus')) { Assert-A365RawField $item $field String }
                Assert-A365RawField $item 'consumedUnits' Count
                Assert-A365RawField $item 'servicePlans' Array
                foreach ($plan in $item.servicePlans) {
                    Assert-A365RawField $plan 'servicePlanId' Guid
                    Assert-A365RawField $plan 'servicePlanName' String
                    Assert-A365RawField $plan 'provisioningStatus' String
                }
            }
            '^/v1\.0/copilot/admin/catalog/packages$' {
                foreach ($field in @('platform', 'type', 'deployedTo')) { Assert-A365RawField $item $field String }
                Assert-A365RawField $item 'isBlocked' Boolean
            }
            '^/v1\.0/roleManagement/' {
                Assert-A365RawField $item 'roleDefinition' Object
                Assert-A365RawField $item.roleDefinition 'displayName' String
            }
            '^/v1\.0/admin/serviceAnnouncement/' {
                Assert-A365RawField $item 'service' String
                Assert-A365RawField $item 'issues' Array
                foreach ($issue in $item.issues) { Assert-A365RawField $issue 'isResolved' Boolean }
            }
            '^/v1\.0/identity/conditionalAccess/' {
                Assert-A365RawField $item 'id' Guid
                Assert-A365RawField $item 'state' String
                if ($item.state -notin @('enabled', 'disabled', 'enabledForReportingButNotEnforced')) { throw 'MalformedEvidence: unknown Conditional Access state.' }
            }
            '^/v1\.0/applications/microsoft\.graph\.agentIdentityBlueprint$' {
                Assert-A365RawField $item 'id' Guid
                foreach ($field in @('keyCredentials', 'passwordCredentials', 'requiredResourceAccess')) { Assert-A365RawField $item $field Array }
                foreach ($credential in @($item.keyCredentials) + @($item.passwordCredentials)) {
                    Assert-A365RawField $credential 'endDateTime' Date
                }
                foreach ($resource in $item.requiredResourceAccess) {
                    Assert-A365RawField $resource 'resourceAppId' Guid
                    Assert-A365RawField $resource 'resourceAccess' Array
                    foreach ($access in $resource.resourceAccess) {
                        Assert-A365RawField $access 'id' Guid
                        Assert-A365RawField $access 'type' String
                        if ($access.type -notin @('Role', 'Scope')) { throw 'MalformedEvidence: unrecognized resource access type.' }
                    }
                }
            }
            '/(owners|sponsors|records)$' { Assert-A365RawField $item 'id' String }
        }
    }
    return $(if ($Response.value.Count -eq 0) { 'ValidEmpty' } else { 'Valid' })
}

function Get-A365ConfigurationManifest {
    $items = @(
        foreach ($name in @('rules.v1.json', 'guidance.v1.json', 'sku-catalog.v1.json', 'operation-allowlist.v1.json', 'assessment-policy.v2.json')) {
            $path = Join-Path $script:ModuleRoot "config\$name"
            $config = Read-A365Json $path $name
            [pscustomobject][ordered]@{
                File = $name
                Version = $config.version
                ReviewDate = $config.reviewDate
                SHA256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
            }

        }
    )
    $engine = [ordered]@{
        Version = $script:ToolVersion
        EvaluatorSHA256 = (Get-FileHash -LiteralPath (Join-Path $script:ModuleRoot 'Agent365Preflight.psm1') -Algorithm SHA256).Hash.ToLowerInvariant()
        ContractsSHA256 = (Get-FileHash -LiteralPath (Join-Path $script:ModuleRoot 'Private\EvidenceContracts.ps1') -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    return [pscustomobject]@{
        Version = '2.0'
        Files = $items
        Engine = [pscustomobject]$engine
        SemanticsHash = Get-A365ContentHash ([ordered]@{ Engine = $engine; Configuration = $items } | ConvertTo-Json -Depth 10 -Compress)
    }
}

function Get-A365SourceProvenance {
    $manifestPath = Join-Path $script:ModuleRoot 'release-manifest.json'
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        $manifest = Read-A365Json $manifestPath 'Release manifest'
        return [pscustomobject]@{
            SourceCommit = $manifest.sourceCommit
            SourceRepository = $manifest.sourceRepository
            BuiltAtUtc = $manifest.builtAtUtc
            SourceState = $manifest.sourceState
            ManifestSHA256 = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
            PublisherAuthentication = 'Unsigned; independently verify the release ZIP checksum and source.'
        }
    }
    [pscustomobject]@{
        SourceCommit = $null; SourceRepository = $null; BuiltAtUtc = $null
        SourceState = 'Unpackaged development source'
        ManifestSHA256 = $null
        PublisherAuthentication = 'No release manifest. Source is not a verified release package.'
    }
}

function New-A365EvidenceContext {
    param([object]$Scope, [object]$Evidence, [object]$Configuration, [object]$Policy)
    $tenant = Get-A365Property $Evidence tenant
    [pscustomobject]@{
        AssessmentFingerprint = $Scope.Fingerprint
        TenantBinding = Get-A365ContentHash ("$($tenant.tenantId)|$($tenant.cloud)".ToLowerInvariant())
        SemanticsHash = $Configuration.SemanticsHash
        Policy = $Policy
    }
}

function Get-A365GateBinding {
    param([object]$Result, [object]$Context)
    $observation = if ($Result.Id -in @('A365-ENTRA-005', 'A365-ENTRA-007', 'A365-SHAREPOINT-001', 'A365-PURVIEW-002')) {
        [ordered]@{ Observed = $Result.Observed; Details = $Result.Details }
    } else { 'Customer assertion independent of automated telemetry' }
    $observationHash = Get-A365ContentHash ($observation | ConvertTo-Json -Depth 30 -Compress)
    return Get-A365ContentHash "$($Context.AssessmentFingerprint)|$($Context.TenantBinding)|$($Context.SemanticsHash)|$($Result.Id)|$observationHash"
}

function Get-A365AnswerFreshness {
    param([object]$Answer, [object]$Result, [object]$Context, [string]$Binding)
    if (-not $Answer) { return 'Unanswered' }
    if (-not $Context) { return 'Needs revalidation' }
    $date = [DateTimeOffset]::MinValue
    $dateText = [string](Get-A365Property $Answer answeredAtUtc '')
    if (-not [DateTimeOffset]::TryParse($dateText, [ref]$date)) { return 'Needs revalidation' }
    $maxAge = [int]$Context.Policy.manualEvidence.defaultMaxAgeDays
    $override = $Context.Policy.manualEvidence.gateMaxAgeDays.PSObject.Properties[[string]$Result.Id]
    if ($override) { $maxAge = [int]$override.Value }
    if ($date -lt [DateTimeOffset]::UtcNow.AddDays(-$maxAge)) { return 'Expired' }
    if ([string](Get-A365Property $Answer binding '') -cne $Binding) { return 'Needs revalidation' }
    if ([string](Get-A365Property $Answer reviewDecision '') -notin @('Retain', 'Revalidate', 'Edit')) { return 'Needs revalidation' }
    return 'Current'
}

function Get-A365RuleFreshnessResult {
    param([object]$Policy, [string]$Stage)
    $expired = [DateTimeOffset]::UtcNow -ge [DateTimeOffset]::Parse("$($Policy.validThrough)T23:59:59Z")
    [pscustomobject][ordered]@{
        Id = 'A365-RULES-001'; Title = 'Assessment rule validity'
        Pillar = 'Govern'; Area = 'Rule freshness'; Profiles = @('ControlPlane')
        Applicability = 'Applicable'; Status = if ($expired) { $Policy.expiredCriticalRulePolicy.$Stage } else { 'Passed' }
        Expected = 'A reviewed rule package within its published validity window.'
        Observed = "Rule package valid through $($Policy.validThrough); owner: $($Policy.owner)."
        EvidenceMethod = 'Local versioned policy'; EvidenceTimeUtc = [DateTimeOffset]::UtcNow.ToString('o')
        RequiredPermission = 'None'; RequiredRole = 'Release owner'
        Remediation = 'Review public sources and obtain a reviewed release. Do not extend the date to force passing.'
        DocsUrl = 'https://learn.microsoft.com/microsoft-agent-365/overview'; RuleReviewDate = $Policy.reviewDate
        Details = $null; IsSensitive = $false; ManualAttestable = $false; AttestationRequired = $false
        AttestationDefinition = $null; Attestation = $null
        CollectionState = 'Collected'
    }
}

function Get-A365ComparisonCompatibility {
    param([object]$Current, [object]$Previous)
    if (-not $Previous) { return 'No baseline' }
    foreach ($report in @($Current, $Previous)) {
        if ((Get-A365Property $report SchemaVersion '') -ne '2.0' -or
            -not (Get-A365Property $report AssessmentScope) -or
            -not (Get-A365Property $report ConfigurationManifest) -or
            -not (Get-A365Property $report RunSpecification) -or
            (Get-A365Property $report Sanitized $false)) {
            return 'ComparisonUnavailable: a full v2 context-bound baseline is required.'
        }
    }
    if (-not $Current.Tenant.TenantId -or -not $Previous.Tenant.TenantId -or
        $Current.Tenant.TenantId -ne $Previous.Tenant.TenantId -or $Current.Tenant.Cloud -ne $Previous.Tenant.Cloud) {
        return 'ComparisonUnavailable: tenant or cloud differs or is unknown.'
    }
    if ($Current.FixtureMode -ne $Previous.FixtureMode -or
        $Current.AssessmentScope.Fingerprint -cne $Previous.AssessmentScope.Fingerprint -or
        $Current.ConfigurationManifest.SemanticsHash -cne $Previous.ConfigurationManifest.SemanticsHash -or
        (@($Current.Collectors | Sort-Object) -join ',') -cne (@($Previous.Collectors | Sort-Object) -join ',')) {
        return 'ComparisonUnavailable: collection intent, assessment, targets, evidence mode, or rule semantics differ.'
    }
    foreach ($field in @('AuditWindowDays', 'AuditQueryTimeoutSeconds', 'AuthenticationMode', 'ClientId', 'DelegatedClientId')) {
        if ([string](Get-A365Property $Current.RunSpecification $field '') -cne [string](Get-A365Property $Previous.RunSpecification $field '')) {
            return 'ComparisonUnavailable: audit window, timeout, or authentication collection intent differs.'
        }
    }
    return 'Comparable'
}

function Get-A365AnswerBundleHash {
    param([object]$Bundle)
    $canonical = [ordered]@{}
    foreach ($key in @('sourceReportId', 'assessmentFingerprint', 'generatedAtUtc', 'modifiedAtUtc', 'bundleId', 'baseRevision')) {
        $canonical[$key] = [string](Get-A365Property $Bundle $key '')
    }
    $canonical.draft = [bool](Get-A365Property $Bundle draft $false)
    $canonical.answers = @(
        foreach ($answer in @($Bundle.answers | Sort-Object id)) {
            $entry = [ordered]@{}
            foreach ($key in @('id', 'answer', 'owner', 'evidenceReference', 'notes', 'answeredAtUtc', 'modifiedAtUtc', 'justification', 'binding', 'reviewDecision', 'baseHash')) {
                $entry[$key] = [string](Get-A365Property $answer $key '')
            }
            [pscustomobject]$entry
        }
    )
    return Get-A365ContentHash ($canonical | ConvertTo-Json -Depth 20 -Compress)
}

function Test-A365AnswerBundle {
    param([object]$Bundle, [object]$Previous)
    if ((Get-A365Property $Bundle schemaVersion '') -ne '2.0') { throw 'A v2 context-bound bundle is required for resume. Import legacy answers as a draft and revalidate in the full report.' }
    if (-not $Previous -or $Bundle.sourceReportId -cne $Previous.ReportId -or
        $Bundle.assessmentFingerprint -cne $Previous.AssessmentScope.Fingerprint) {
        throw 'Answer bundle does not belong to this report and assessment.'
    }
    if ((Get-A365AnswerBundleHash $Bundle) -cne $Bundle.contentHash) { throw 'Answer bundle content hash does not match. Export the corrected bundle again.' }
    $generated = [DateTimeOffset]::MinValue
    $modified = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse($Bundle.generatedAtUtc, [ref]$generated) -or
        -not [DateTimeOffset]::TryParse($Bundle.modifiedAtUtc, [ref]$modified) -or
        $modified -lt $generated -or $modified -gt [DateTimeOffset]::UtcNow) {
        throw 'Answer bundle timestamps are invalid, future-dated, or out of order.'
    }
    if (Get-A365Property $Bundle draft $false) { throw 'Draft bundles must be reviewed and exported as answers before evaluation.' }
    foreach ($answer in $Bundle.answers) {
        $gate = @($Previous.ManuallyAttestableGates | Where-Object Id -eq $answer.id)
        if ($gate.Count -ne 1 -or $answer.binding -cne $gate[0].Binding) {
            throw "Answer binding does not match the source report gate: $($answer.id)"
        }
        if ($answer.reviewDecision -eq 'Retain') {
            $prior = $gate[0].PreviousAnswer
            if (-not $prior -or -not $prior.Submitted -or $prior.Freshness -ne 'Current') {
                throw "Retain requires current previously accepted evidence: $($answer.id)"
            }
            foreach ($field in @('Answer', 'Owner', 'EvidenceReference', 'Notes', 'Justification', 'AnsweredAtUtc', 'Binding')) {
                if ([string](Get-A365Property $answer $field '') -cne [string](Get-A365Property $prior $field '')) {
                    throw "Retain cannot change prior approval fields: $($answer.id). Choose Edit or Revalidate."
                }
            }
        }
    }
}
