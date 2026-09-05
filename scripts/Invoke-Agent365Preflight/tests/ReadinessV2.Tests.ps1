BeforeAll {
    $v2Root = Split-Path -Parent $PSScriptRoot
    Get-Module Agent365Preflight | Remove-Module -Force -ErrorAction Stop
    Import-Module (Join-Path $v2Root 'Agent365Preflight.psd1') -Force
    Import-Module Microsoft.Graph.Authentication -MinimumVersion 2.20.0
    . (Join-Path $PSScriptRoot 'TestData.ps1')
}

Describe 'Assessment contract v2' {
    It 'preserves assessment denominators across all stages profiles and omitted collectors' {
        InModuleScope Agent365Preflight {
            $rules = Read-A365Json $script:RulesPath Rules
            $guidance = Read-A365Json $script:GuidancePath Guidance
            $catalog = Read-A365Json $script:SkuCatalogPath Catalog
            $fixture = Read-A365Json (Join-Path $script:ModuleRoot 'fixtures\commercial-ready.json') Fixture
            $collectors = @('TenantFoundation', 'Licensing', 'Roles', 'ServiceHealth', 'Registry', 'AgentIdentity', 'ConditionalAccess', 'Defender', 'Purview', 'SharePoint')
            foreach ($stage in @('Pilot', 'Production')) {
                foreach ($profile in @('ControlPlane') + @($rules.profileGuidance.PSObject.Properties.Name)) {
                    $scope = New-A365AssessmentScope -Rules $rules -Stage $stage -Profiles @('ControlPlane', $profile)
                    $parameters = @{ Evidence = $fixture; Rules = $rules; Guidance = $guidance; SkuCatalog = $catalog; Profiles = $scope.Profiles; AssessmentScope = $scope }
                    $full = Get-A365Evaluation @parameters -Collectors $collectors
                    $coverage = Get-A365Coverage $full.Results
                    foreach ($omitted in @('Licensing', 'Roles', 'Registry', 'AgentIdentity', 'ConditionalAccess', 'Defender', 'Purview')) {
                        $less = Get-A365Evaluation @parameters -Collectors @($collectors | Where-Object { $_ -ne $omitted })
                        $actual = Get-A365Coverage $less.Results
                        $actual.Total | Should -Be $coverage.Total
                        $actual.Percentage | Should -BeLessOrEqual $coverage.Percentage
                        $actual.Passed | Should -BeLessOrEqual $coverage.Passed
                        (Get-A365PassCriteria $less.Results).IsSatisfied | Should -BeFalse
                        @($less.Results | Where-Object Status -eq NotAssessed).Count | Should -BeGreaterThan 0
                    }
                }
            }
        }
    }
    It 'keeps a negative Defender manual gate applicable when its collector is omitted' {
        InModuleScope Agent365Preflight {
            $answer = [pscustomobject]@{ answers = @([pscustomobject]@{ id = 'A365-DEFENDER-003'; answer = 'No' }) }
            $result = Get-A365Evaluation -Evidence (Read-A365Json (Join-Path $script:ModuleRoot 'fixtures\commercial-ready.json') Fixture) -Rules (Read-A365Json $script:RulesPath Rules) -Guidance (Read-A365Json $script:GuidancePath Guidance) -SkuCatalog (Read-A365Json $script:SkuCatalogPath Catalog) -Profiles ControlPlane -Collectors TenantFoundation -Answers $answer
            ($result.Results | Where-Object Id -eq A365-DEFENDER-003).Status | Should -Be ActionRequired
        }
    }
    It 'makes SharePoint targets applicable even without an explicitly selected profile' {
        InModuleScope Agent365Preflight {
            $rules = Read-A365Json $script:RulesPath Rules
            $scope = New-A365AssessmentScope -Rules $rules -Stage Pilot -Profiles ControlPlane -SharePointSiteUrl 'https://example.sharepoint.com/sites/pilot'
            $scope.Profiles | Should -Contain SharePointAgents
            $defs = Get-A365AttestationDefinitions -Rules $rules -Profiles $scope.Profiles -Guidance (Read-A365Json $script:GuidancePath Guidance) -AssessmentScope $scope
            ($defs | Where-Object Id -eq A365-SHAREPOINT-001).AllowNotApplicable | Should -BeFalse
        }
    }
    It 'requires explicit justified exclusions and keeps foundation gates mandatory' {
        InModuleScope Agent365Preflight {
            $rules = Read-A365Json $script:RulesPath Rules
            { New-A365AssessmentScope -Rules $rules -Stage Pilot -Profiles ControlPlane -ExcludeRequirement A365-DEFENDER-001 } | Should -Throw '*ScopeJustification*'
            { New-A365AssessmentScope -Rules $rules -Stage Pilot -Profiles ControlPlane -ExcludeRequirement A365-FOUNDATION-002 -ScopeJustification Review } | Should -Throw '*non-excludable*'
        }
    }
    It 'models active-only and PIM assessment policies separately' {
        InModuleScope Agent365Preflight {
            $rules = Read-A365Json $script:RulesPath Rules
            $active = New-A365AssessmentScope -Rules $rules -Stage Pilot -Profiles ControlPlane
            $pim = New-A365AssessmentScope -Rules $rules -Stage Pilot -Profiles ControlPlane -RolePolicy PIM
            ($active.Requirements | Where-Object Id -eq A365-FOUNDATION-005).Applicable | Should -BeFalse
            ($pim.Requirements | Where-Object Id -eq A365-FOUNDATION-005).Applicable | Should -BeTrue
            $active.Fingerprint | Should -Not -Be $pim.Fingerprint
            @(Get-Agent365RequiredScopes -Collector Roles) | Should -Not -Contain RoleEligibilitySchedule.Read.Directory
        }
    }
    It 'accepts successful acquisition with a documented alternate package permission' {
        InModuleScope Agent365Preflight {
            $fixture = Read-A365Json (Join-Path $script:ModuleRoot 'fixtures\commercial-ready.json') Fixture
            $fixture.authentication.mode = 'InteractiveDelegated'
            $fixture.authentication.grantedScopes = @('Organization.Read.All', 'CopilotPackages.ReadWrite.All')
            $evaluation = Get-A365Evaluation -Evidence $fixture -Rules (Read-A365Json $script:RulesPath Rules) -Guidance (Read-A365Json $script:GuidancePath Guidance) -SkuCatalog (Read-A365Json $script:SkuCatalogPath Catalog) -Profiles ControlPlane -Collectors TenantFoundation,Registry
            ($evaluation.Results | Where-Object Id -eq A365-REGISTRY-001).Status | Should -Be Passed
            $fixture.authentication.grantedScopes | Should -Contain CopilotPackages.ReadWrite.All
        }
    }
}

Describe 'Raw response contracts v2' {
    It 'accepts a valid empty catalog but rejects absent null and wrong-type envelopes' {
        InModuleScope Agent365Preflight {
            $args = @{ Uri = 'https://graph.microsoft.com/v1.0/copilot/admin/catalog/packages'; Method = 'GET'; Allowlist = (Read-A365Json $script:AllowlistPath Allowlist) }
            (Assert-A365RawResponse @args -Response ([pscustomobject]@{ value = @() })) | Should -Be ValidEmpty
            foreach ($raw in @([pscustomobject]@{}, [pscustomobject]@{ value = $null }, [pscustomobject]@{ value = 'empty' }, [pscustomobject]@{ value = [pscustomobject]@{} })) {
                { Assert-A365RawResponse @args -Response $raw } | Should -Throw '*MalformedEvidence*'
            }
        }
    }
    It 'rejects missing assignedPlans rather than inventing unlicensed users' {
        InModuleScope Agent365Preflight {
            { Assert-A365RawResponse -Response ([pscustomobject]@{ value = @([pscustomobject]@{}) }) -Uri 'https://graph.microsoft.com/v1.0/users' -Method GET -Allowlist (Read-A365Json $script:AllowlistPath Allowlist) } | Should -Throw '*assignedPlans*'
        }
    }
    It 'accepts zero hunting aggregates but rejects missing empty and wrong columns' {
        InModuleScope Agent365Preflight {
            $args = @{ Uri = 'https://graph.microsoft.com/v1.0/security/runHuntingQuery'; Method = 'POST'; Body = @{ Query = 'AgentsInfo | summarize AgentCount=dcount(AgentId)' }; Allowlist = (Read-A365Json $script:AllowlistPath Allowlist) }
            (Assert-A365RawResponse @args -Response ([pscustomobject]@{ results = @([pscustomobject]@{ AgentCount = 0; PlatformCount = 0; LatestEvidenceUtc = $null }) })) | Should -Be ValidZero
            foreach ($raw in @([pscustomobject]@{}, [pscustomobject]@{ results = @() }, [pscustomobject]@{ results = @([pscustomobject]@{ AgentCount = '0' }) })) {
                { Assert-A365RawResponse @args -Response $raw } | Should -Throw '*MalformedEvidence*'
            }
        }
    }
    It 'rejects unsafe or cross-operation pagination links before following' {
        InModuleScope Agent365Preflight {
            foreach ($link in @('http://graph.microsoft.com/v1.0/users', 'https://graph.microsoft.com:444/v1.0/users', 'https://other.invalid/v1.0/users', 'https://graph.microsoft.com/v1.0/organization', '/v1.0/users', 'https://user@graph.microsoft.com/v1.0/users', 23)) {
                { Assert-A365RawResponse -Response ([pscustomobject]@{ value = @(); '@odata.nextLink' = $link }) -Uri 'https://graph.microsoft.com/v1.0/users' -Method GET -Allowlist (Read-A365Json $script:AllowlistPath Allowlist) } | Should -Throw '*pagination*'
            }
        }
    }
    It 'distinguishes 403 429 503 timeout and malformed evidence' {
        InModuleScope Agent365Preflight {
            (Resolve-A365IssueCategory -StatusCode 403 -Message Denied -RequiredPermission None) | Should -Be Authorization
            (Resolve-A365IssueCategory -StatusCode 429 -Message Limited -RequiredPermission None) | Should -Be Throttling
            (Resolve-A365IssueCategory -StatusCode 503 -Message Unavailable -RequiredPermission None) | Should -Be ServiceFailure
            (Resolve-A365IssueCategory -Message 'Request timed out' -RequiredPermission None) | Should -Be Timeout
            (Resolve-A365IssueCategory -Message 'MalformedEvidence: missing column' -RequiredPermission None) | Should -Be MalformedEvidence
        }
    }
    It 'makes organization failure verdict relevant despite a commercial context' {
        InModuleScope Agent365Preflight {
            $fixture = Read-A365Json (Join-Path $script:ModuleRoot 'fixtures\commercial-ready.json') Fixture
            $fixture.collectionIssues = @([pscustomobject]@{ Operation = 'Organization context'; Category = 'ServiceFailure'; Message = 'HTTP 503' })
            $result = Get-A365Evaluation -Evidence $fixture -Rules (Read-A365Json $script:RulesPath Rules) -Guidance (Read-A365Json $script:GuidancePath Guidance) -SkuCatalog (Read-A365Json $script:SkuCatalogPath Catalog) -Profiles ControlPlane -Collectors TenantFoundation
            ($result.Results | Where-Object Id -eq A365-FOUNDATION-001).Status | Should -Be Error
        }
    }
    It 'classifies a raw transport <Status> failure without accepting an empty response' -ForEach @(
        @{ Status = 403; Category = 'PermissionOrRole' },
        @{ Status = 429; Category = 'Throttling' },
        @{ Status = 503; Category = 'ServiceFailure' }
    ) {
        InModuleScope Agent365Preflight -Parameters @{ Status = $Status; Category = $Category } {
            Mock Invoke-MgGraphRequest {
                throw [Net.Http.HttpRequestException]::new('Synthetic HTTP failure', $null, [Net.HttpStatusCode]$Status)
            }
            $caught = $false
            try {
                $null = Invoke-A365GraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/users' -Allowlist (Read-A365Json $script:AllowlistPath Allowlist) -MaxRetryCount 0
            }
            catch {
                $caught = $true
                $issue = New-A365CollectionIssue -Adapter Graph -Operation 'Synthetic users request' -ErrorRecord $_ -RequiredPermission User.Read.All
                $issue.StatusCode | Should -Be $Status
                $issue.Category | Should -Be $Category
            }
            $caught | Should -BeTrue
            Should -Invoke Invoke-MgGraphRequest -Times 1 -Exactly
        }
    }
}

Describe 'Bound evidence and drift v2' {
    BeforeAll {
        $v2First = Invoke-Agent365Preflight -FixturePath (Join-Path $v2Root 'fixtures\commercial-ready.json') -OutputPath (Join-Path $TestDrive 'v2-first') -IncludeSanitizedCopy
        $v2Answer = New-A365TestBundle -Report $v2First.Report -TemplatePath (Join-Path $v2Root 'samples\answers.sample.json') -Path (Join-Path $TestDrive 'v2-answers.json')
    }
    It 'carries accepted evidence without renewing the original approval date' {
        $second = Invoke-Agent365Preflight -FixturePath (Join-Path $v2Root 'fixtures\commercial-ready.json') -PreviousResultPath $v2First.Paths.Json -AnswersPath $v2Answer -OutputPath (Join-Path $TestDrive 'v2-second')
        $third = Invoke-Agent365Preflight -FixturePath (Join-Path $v2Root 'fixtures\commercial-ready.json') -PreviousResultPath $second.Paths.Json -OutputPath (Join-Path $TestDrive 'v2-third')
        $third.ExitCode | Should -Be 0
        ($third.Report.Results | Where-Object Id -eq A365-MANUAL-001).Attestation.AnsweredAtUtc | Should -Be ($second.Report.Results | Where-Object Id -eq A365-MANUAL-001).Attestation.AnsweredAtUtc
    }
    It 'rejects foreign report binding and altered bundle hashes' {
        InModuleScope Agent365Preflight -Parameters @{ AnswerPath = $v2Answer; Report = $v2First.Report } {
            $bundle = Read-A365Json $AnswerPath Answers
            $bundle.sourceReportId = 'foreign'
            { Test-A365AnswerBundle $bundle $Report } | Should -Throw '*does not belong*'
            $bundle.sourceReportId = $Report.ReportId
            $bundle.answers[0].notes = 'Altered concurrently'
            { Test-A365AnswerBundle $bundle $Report } | Should -Throw '*hash*'
        }
    }
    It 'distinguishes current expired and revalidation-needed evidence' {
        InModuleScope Agent365Preflight {
            $context = [pscustomobject]@{ Policy = Read-A365Json (Join-Path $script:ModuleRoot 'config\assessment-policy.v2.json') Policy }
            $result = [pscustomobject]@{ Id = 'A365-MANUAL-001' }
            $answer = [pscustomobject]@{ answeredAtUtc = [DateTimeOffset]::UtcNow.AddDays(-60).ToString('o'); binding = 'same'; reviewDecision = 'Retain' }
            (Get-A365AnswerFreshness $answer $result $context same) | Should -Be Expired
            $answer.answeredAtUtc = [DateTimeOffset]::UtcNow.AddHours(-1).ToString('o')
            (Get-A365AnswerFreshness $answer $result $context different) | Should -Be 'Needs revalidation'
            (Get-A365AnswerFreshness $answer $result $context same) | Should -Be Current
        }
    }
    It 'rejects future dates and invalid modification ordering' {
        InModuleScope Agent365Preflight {
            $rules = Read-A365Json $script:RulesPath Rules
            $defs = @(Get-A365AttestationDefinitions -Rules $rules -Profiles ControlPlane -Guidance (Read-A365Json $script:GuidancePath Guidance))
            $answer = [pscustomobject]@{ id = 'A365-MANUAL-001'; answer = 'Yes'; owner = 'Synthetic'; evidenceReference = 'Synthetic'; answeredAtUtc = [DateTimeOffset]::UtcNow.AddHours(1).ToString('o'); modifiedAtUtc = [DateTimeOffset]::UtcNow.ToString('o') }
            $bundle = [pscustomobject]@{ schemaVersion = '2.0'; answers = @($answer) }
            { Test-A365AnswersInput $bundle $defs $rules } | Should -Throw '*future*'
            $answer.answeredAtUtc = [DateTimeOffset]::UtcNow.AddHours(-1).ToString('o')
            $answer.modifiedAtUtc = [DateTimeOffset]::UtcNow.AddHours(-2).ToString('o')
            { Test-A365AnswersInput $bundle $defs $rules } | Should -Throw '*ordering*'
        }
    }
    It 'checks every status transition without treating unknown as resolved' {
        $states = @('Passed', 'Advisory', 'ActionRequired', 'Blocker', 'ManualValidation', 'NotAssessed', 'NotAuthorized', 'Error', 'NotApplicable')
        foreach ($old in $states) {
            foreach ($new in $states) {
                $previous = $v2First.Report | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100
                $current = $v2First.Report | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100
                $previous.Results = @([pscustomobject]@{ Id = 'A365-TEST-001'; Title = 'Synthetic'; Status = $old })
                $current.Results = @([pscustomobject]@{ Id = 'A365-TEST-001'; Title = 'Synthetic'; Status = $new })
                $drift = Compare-Agent365PreflightResult $current $previous
                $drift.Comparable | Should -BeTrue
                if ($new -in @('NotAssessed', 'NotAuthorized', 'Error', 'NotApplicable')) {
                    $drift.Resolved.Count | Should -Be 0
                    if ($new -ne $old) { $drift.NotReassessed.Count | Should -Be 1 }
                }
                if ($old -eq 'Blocker' -and $new -in @('Passed', 'Advisory')) { $drift.ResolvedBlockers.Count | Should -Be 1 }
            }
        }
    }
    It 'refuses cross-tenant scope semantics collector mode and schema comparisons' {
        foreach ($mutation in @('Tenant', 'Scope', 'Semantics', 'Collector', 'Mode', 'Schema', 'AuditWindow', 'Authentication')) {
            $current = $v2First.Report | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100
            switch ($mutation) {
                Tenant { $current.Tenant.TenantId = 'another-synthetic-tenant' }
                Scope { $current.AssessmentScope.Fingerprint = 'different' }
                Semantics { $current.ConfigurationManifest.SemanticsHash = 'different' }
                Collector { $current.Collectors = @('TenantFoundation') }
                Mode { $current.FixtureMode = $false }
                Schema { $current.SchemaVersion = '1.3' }
                AuditWindow { $current.RunSpecification.AuditWindowDays = 14 }
                Authentication { $current.RunSpecification.AuthenticationMode = 'CertificateAppOnly' }
            }
            (Compare-Agent365PreflightResult $current $v2First.Report).Comparable | Should -BeFalse
        }
    }
    It 'enforces critical rule expiration in both stages' {
        InModuleScope Agent365Preflight {
            $policy = Read-A365Json (Join-Path $script:ModuleRoot 'config\assessment-policy.v2.json') Policy
            $policy.validThrough = '2020-01-01'
            (Get-A365RuleFreshnessResult $policy Pilot).Status | Should -Be ActionRequired
            (Get-A365RuleFreshnessResult $policy Production).Status | Should -Be Blocker
        }
    }
    It 'keeps the bootstrap compatible with Windows PowerShell 5.1 syntax' {
        (Get-Content (Join-Path $v2Root 'Test-Agent365Runtime.ps1') -Raw) | Should -Not -Match '#requires -Version 7|\?\?|\?\.|ForEach-Object -Parallel'
    }
    It 'keeps live canaries disabled without explicit test-tenant approval' {
        { & (Join-Path $v2Root 'tests\Invoke-Agent365ContractCanary.ps1') } | Should -Throw '*disabled*'
    }
    It 'removes exclusion rationale from every sharing-copy projection' {
        $reason = 'SYNTHETIC-CONFIDENTIAL-RATIONALE-DO-NOT-SHARE'
        $outcome = Invoke-Agent365Preflight -FixturePath (Join-Path $v2Root 'fixtures\commercial-ready.json') -OutputPath (Join-Path $TestDrive 'excluded-sharing') -ExcludeRequirement A365-DEFENDER-001 -ScopeJustification $reason -IncludeSanitizedCopy
        (Get-Content -LiteralPath $outcome.Paths.Json -Raw) | Should -Match $reason
        (Get-Content -LiteralPath $outcome.Paths.SanitizedJson -Raw) | Should -Not -Match $reason
        (Get-Content -LiteralPath $outcome.Paths.SanitizedHtml -Raw) | Should -Not -Match $reason
    }
    It 'revalidates same-count metadata changes without invalidating on collection time alone' {
        InModuleScope Agent365Preflight -Parameters @{ Report = $v2First.Report } {
            $row = $Report.Results | Where-Object Id -eq A365-ENTRA-005
            $context = [pscustomobject]@{ AssessmentFingerprint = 'scope'; TenantBinding = 'tenant'; SemanticsHash = 'semantics' }
            $firstBinding = Get-A365GateBinding $row $context
            $row.EvidenceTimeUtc = [DateTimeOffset]::UtcNow.AddSeconds(1).ToString('o')
            (Get-A365GateBinding $row $context) | Should -Be $firstBinding
            $row.Details.MetadataFingerprint = 'changed-permissions-with-identical-count'
            (Get-A365GateBinding $row $context) | Should -Not -Be $firstBinding
        }
    }
}
