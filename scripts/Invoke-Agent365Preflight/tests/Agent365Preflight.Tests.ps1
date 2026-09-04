BeforeAll {
$resourceRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $resourceRoot 'Agent365Preflight.psd1'
$readyFixturePath = Join-Path $resourceRoot 'fixtures\commercial-ready.json'
$answersPath = Join-Path $resourceRoot 'samples\answers.sample.json'
$reportSchemaPath = Join-Path $resourceRoot 'schema\agent365-preflight-report.schema.json'
$answersSchemaPath = Join-Path $resourceRoot 'schema\agent365-preflight-answers.schema.json'
$allowlistPath = Join-Path $resourceRoot 'config\operation-allowlist.v1.json'
$guidancePath = Join-Path $resourceRoot 'config\guidance.v1.json'

Import-Module $modulePath -Force
Import-Module Microsoft.Graph.Authentication -MinimumVersion 2.20.0 -Force

function New-SyntheticFixture {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [scriptblock]$Mutator
    )

    $fixture = Get-Content -LiteralPath $readyFixturePath -Raw | ConvertFrom-Json -Depth 100
    & $Mutator $fixture
    $path = Join-Path $TestDrive "$Name.json"
    [System.IO.File]::WriteAllText(
        $path,
        ($fixture | ConvertTo-Json -Depth 100),
        [System.Text.UTF8Encoding]::new($false)
    )
    return $path
}

function New-SyntheticAnswers {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [scriptblock]$Mutator
    )

    $answers = Get-Content -LiteralPath $answersPath -Raw | ConvertFrom-Json -Depth 100
    & $Mutator $answers
    $path = Join-Path $TestDrive "$Name.json"
    [System.IO.File]::WriteAllText(
        $path,
        ($answers | ConvertTo-Json -Depth 100),
        [System.Text.UTF8Encoding]::new($false)
    )
    return $path
}

function Invoke-FixturePreflight {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter()]
        [string]$FixturePath = $readyFixturePath,

        [Parameter()]
        [string]$PreviousResultPath,

        [Parameter()]
        [string[]]$Profile = @('ControlPlane'),

        [Parameter()]
        [string[]]$Collector = @(
            'TenantFoundation', 'Licensing', 'Roles', 'ServiceHealth', 'Registry',
            'AgentIdentity', 'ConditionalAccess', 'Defender', 'Purview', 'SharePoint'
        ),

        [Parameter()]
        [string]$AnswersFile = $answersPath
    )

    $outputPath = Join-Path $TestDrive $Name
    $parameters = @{
        FixturePath = $FixturePath
        AnswersPath = $AnswersFile
        OutputPath = $outputPath
        Profile = $Profile
        Collector = $Collector
        IncludeSanitizedCopy = $true
    }
    if ($PreviousResultPath) {
        $parameters.PreviousResultPath = $PreviousResultPath
    }
    return Invoke-Agent365Preflight @parameters
}
}

Describe 'Agent 365 fixture evaluation' {
    It 'produces a ready-for-pilot report for the happy path' {
        $outcome = Invoke-FixturePreflight -Name 'happy'

        $outcome.ExitCode | Should -Be 0
        $outcome.Report.Verdict.Label | Should -Be 'Ready for pilot'
        $outcome.Paths.Html | Should -Exist
        $outcome.Paths.Json | Should -Exist
        $outcome.Report.Results.Count | Should -BeGreaterThan 20
    }

    It 'blocks when no user has the qualifying service plan enabled' {
        $fixturePath = New-SyntheticFixture -Name 'unlicensed' -Mutator {
            param($fixture)
            $fixture.licensing.qualifyingAssignedUsers = 0
            $fixture.licensing.unknownSkuMappings = @()
            $fixture.licensing.subscribedSkus = @(
                $fixture.licensing.subscribedSkus |
                    Where-Object { $_.skuPartNumber -ne 'AGENT_365' }
            )
        }

        $outcome = Invoke-FixturePreflight -Name 'unlicensed-output' -FixturePath $fixturePath
        $licenseResult = $outcome.Report.Results | Where-Object Id -eq 'A365-FOUNDATION-002'

        $outcome.ExitCode | Should -Be 1
        $outcome.Report.Verdict.Label | Should -Be 'Blocked'
        $licenseResult.Status | Should -Be 'Blocker'
    }

    It 'reports missing permissions as not authorized and incomplete' {
        $fixturePath = New-SyntheticFixture -Name 'missing-permission' -Mutator {
            param($fixture)
            $fixture.authentication.grantedScopes = @(
                $fixture.authentication.grantedScopes |
                    Where-Object { $_ -ne 'CopilotPackages.Read.All' }
            )
            $fixture.registry.available = $false
            $fixture.collectionIssues = @(
                [pscustomobject]@{
                    Adapter = 'Graph'
                    Operation = 'Agent package catalog'
                    Category = 'PermissionOrRole'
                    StatusCode = 403
                    Message = 'Insufficient privileges to complete the operation.'
                    RequiredPermission = 'CopilotPackages.Read.All'
                    DocsUrl = 'https://learn.microsoft.com/microsoft-365/copilot/extensibility/api/admin-settings/package/copilotpackages-list'
                }
            )
        }

        $outcome = Invoke-FixturePreflight -Name 'missing-permission-output' -FixturePath $fixturePath
        $registryResult = $outcome.Report.Results | Where-Object Id -eq 'A365-REGISTRY-001'

        $outcome.ExitCode | Should -Be 2
        $outcome.Report.Verdict.Label | Should -Be 'Incomplete'
        $registryResult.Status | Should -Be 'NotAuthorized'
        $registryResult.Status | Should -Not -Be 'Passed'
    }

    It 'classifies a role-level 403 as not authorized even when the scope is granted' {
        $fixturePath = New-SyntheticFixture -Name 'role-denied' -Mutator {
            param($fixture)
            $fixture.registry.available = $false
            $fixture.collectionIssues = @(
                [pscustomobject]@{
                    Adapter = 'Graph'
                    Operation = 'Agent package catalog'
                    Category = 'PermissionOrRole'
                    StatusCode = 403
                    Message = 'The signed-in user does not have a supported Agent 365 read role.'
                    RequiredPermission = 'CopilotPackages.Read.All'
                    DocsUrl = 'https://learn.microsoft.com/microsoft-365/copilot/extensibility/api/admin-settings/package/copilotpackages-list'
                }
            )
        }

        $outcome = Invoke-FixturePreflight -Name 'role-denied-output' -FixturePath $fixturePath
        $registryResult = $outcome.Report.Results | Where-Object Id -eq 'A365-REGISTRY-001'

        $registryResult.Status | Should -Be 'NotAuthorized'
        $registryResult.Observed | Should -Match 'PermissionOrRole'
    }

    It 'preserves independent Agent ID evidence when owner reads are unauthorized' {
        $fixturePath = New-SyntheticFixture -Name 'owner-denied' -Mutator {
            param($fixture)
            $fixture.agentIdentity.ownerReadAvailable = $false
            $fixture.collectionIssues = @(
                [pscustomobject]@{
                    Adapter = 'Graph'
                    Operation = 'Blueprint owners'
                    Category = 'PermissionOrRole'
                    StatusCode = 403
                    Message = 'Owner relationship is not authorized.'
                    RequiredPermission = 'AgentIdentityBlueprint.Read.All'
                    DocsUrl = 'https://learn.microsoft.com/graph/api/agentidentityblueprint-list-owners?view=graph-rest-1.0'
                }
            )
        }

        $outcome = Invoke-FixturePreflight -Name 'owner-denied-output' -FixturePath $fixturePath

        ($outcome.Report.Results | Where-Object Id -eq 'A365-ENTRA-002').Status | Should -Be 'NotAuthorized'
        ($outcome.Report.Results | Where-Object Id -eq 'A365-ENTRA-004').Status | Should -Be 'Passed'
        ($outcome.Report.Results | Where-Object Id -eq 'A365-ENTRA-005').Status | Should -Be 'Passed'
        ($outcome.Report.Results | Where-Object Id -eq 'A365-ENTRA-005').Attestation.Applied | Should -BeTrue
    }

    It 'uses one availability blocker for a non-commercial cloud' {
        $fixturePath = New-SyntheticFixture -Name 'non-commercial' -Mutator {
            param($fixture)
            $fixture.tenant.cloud = 'USGov'
            $fixture.tenant.commercialAvailability = $false
        }

        $outcome = Invoke-FixturePreflight -Name 'non-commercial-output' -FixturePath $fixturePath
        $remoteFailures = @(
            $outcome.Report.Results |
                Where-Object {
                    $_.Id -notlike 'A365-LOCAL-*' -and
                    $_.Id -ne 'A365-FOUNDATION-001' -and
                    $_.Status -in @('Blocker', 'Error', 'NotAuthorized', 'ActionRequired')
                }
        )

        $outcome.Report.Verdict.BlockerCount | Should -Be 1
        $remoteFailures.Count | Should -Be 0
        ($outcome.Report.Results | Where-Object Id -eq 'A365-FOUNDATION-001').Status | Should -Be 'Blocker'
    }

    It 'treats an unknown qualifying SKU mapping as action required rather than passed' {
        $fixturePath = New-SyntheticFixture -Name 'unknown-sku' -Mutator {
            param($fixture)
            $fixture.licensing.qualifyingAssignedUsers = 0
            $fixture.licensing.unknownSkuMappings = @('AGENT_365_FUTURE')
        }

        $outcome = Invoke-FixturePreflight -Name 'unknown-sku-output' -FixturePath $fixturePath
        $licenseResult = $outcome.Report.Results | Where-Object Id -eq 'A365-FOUNDATION-002'

        $licenseResult.Status | Should -Be 'ActionRequired'
        $licenseResult.Status | Should -Not -Be 'Passed'
    }

    It 'reports schema drift as an error and still writes reports' {
        $fixturePath = New-SyntheticFixture -Name 'schema-drift' -Mutator {
            param($fixture)
            $fixture.registry | Add-Member -NotePropertyName schemaDrift -NotePropertyValue $true
        }

        $outcome = Invoke-FixturePreflight -Name 'schema-drift-output' -FixturePath $fixturePath
        $registryResult = $outcome.Report.Results | Where-Object Id -eq 'A365-REGISTRY-001'

        $outcome.ExitCode | Should -Be 2
        $registryResult.Status | Should -Be 'Error'
        $outcome.Paths.Html | Should -Exist
        $outcome.Paths.Json | Should -Exist
    }

    It 'survives a partial collection failure' {
        $fixturePath = New-SyntheticFixture -Name 'partial-failure' -Mutator {
            param($fixture)
            $fixture.defender.agentsInfo.available = $false
            $fixture.collectionIssues = @(
                [pscustomobject]@{
                    Adapter = 'Graph'
                    Operation = 'Defender agentsInfo aggregate query'
                    Category = 'WorkloadAvailability'
                    StatusCode = 404
                    Message = 'AgentsInfo is unavailable.'
                    RequiredPermission = 'ThreatHunting.Read.All'
                    DocsUrl = 'https://learn.microsoft.com/defender-xdr/advanced-hunting-agentsinfo-table'
                }
            )
        }

        $outcome = Invoke-FixturePreflight -Name 'partial-failure-output' -FixturePath $fixturePath
        $result = $outcome.Report.Results | Where-Object Id -eq 'A365-DEFENDER-001'

        $result.Status | Should -Be 'ActionRequired'
        $result.Status | Should -Not -Be 'Passed'
        $outcome.Report.CollectionIssues.Count | Should -Be 1
        $outcome.Paths.Html | Should -Exist
    }

    It 'keeps E5 absence advisory rather than blocking' {
        $fixturePath = New-SyntheticFixture -Name 'no-e5' -Mutator {
            param($fixture)
            $fixture.licensing.subscribedSkus = @(
                $fixture.licensing.subscribedSkus |
                    Where-Object { $_.skuPartNumber -ne 'MICROSOFT_365_E5' }
            )
        }

        $outcome = Invoke-FixturePreflight -Name 'no-e5-output' -FixturePath $fixturePath
        $e5Result = $outcome.Report.Results | Where-Object Id -eq 'A365-FOUNDATION-003'

        $e5Result.Status | Should -Be 'Advisory'
        $outcome.Report.Verdict.Label | Should -Be 'Ready for pilot'
    }

    It 'evaluates and renders exactly one active target role under strict mode' {
        $fixturePath = New-SyntheticFixture -Name 'single-active-role' -Mutator {
            param($fixture)
            $fixture.roles.active = [pscustomobject]@{
                role = 'AI Administrator'
                assignmentCount = 1
            }
        }

        $outcome = Invoke-FixturePreflight -Name 'single-active-role-output' -FixturePath $fixturePath
        $roleResult = $outcome.Report.Results | Where-Object Id -eq 'A365-FOUNDATION-004'
        $html = Get-Content -LiteralPath $outcome.Paths.Html -Raw

        $roleResult.Status | Should -Be 'Passed'
        @($roleResult.Details).Count | Should -Be 1
        $roleResult.Observed | Should -Match 'AI Administrator: 1'
        $html | Should -Match 'AI Administrator'
    }

    It 'evaluates and renders exactly one eligible role under strict mode' {
        $fixturePath = New-SyntheticFixture -Name 'single-eligible-role' -Mutator {
            param($fixture)
            $fixture.roles.eligible = [pscustomobject]@{
                role = 'Global Reader'
                assignmentCount = 1
            }
        }

        $outcome = Invoke-FixturePreflight -Name 'single-eligible-role-output' -FixturePath $fixturePath
        $roleResult = $outcome.Report.Results | Where-Object Id -eq 'A365-FOUNDATION-005'
        $html = Get-Content -LiteralPath $outcome.Paths.Html -Raw

        $roleResult.Status | Should -Be 'Passed'
        @($roleResult.Details).Count | Should -Be 1
        $roleResult.Observed | Should -Be '1 eligible role definition(s) are visible.'
        $html | Should -Match 'Global Reader'
    }

    It 'blocks readiness when a required manual attestation is answered No' {
        $answers = Get-Content -LiteralPath $answersPath -Raw | ConvertFrom-Json -Depth 100
        ($answers.answers | Where-Object id -eq 'A365-MANUAL-003').answer = 'No'
        $noAnswersPath = Join-Path $TestDrive 'required-no-answers.json'
        [System.IO.File]::WriteAllText(
            $noAnswersPath,
            ($answers | ConvertTo-Json -Depth 100),
            [System.Text.UTF8Encoding]::new($false)
        )

        $outcome = Invoke-FixturePreflight -Name 'required-no-output' -AnswersFile $noAnswersPath
        $manualResult = $outcome.Report.Results | Where-Object Id -eq 'A365-MANUAL-003'

        $manualResult.Status | Should -Be 'Blocker'
        $outcome.Report.Verdict.Label | Should -Be 'Blocked'
        $outcome.ExitCode | Should -Be 1
    }

    It 'checks security defaults before judging Conditional Access inventory' {
        $fixturePath = New-SyntheticFixture -Name 'security-defaults' -Mutator {
            param($fixture)
            $fixture.conditionalAccess.securityDefaultsEnabled = $true
            $fixture.conditionalAccess.policyInventoryAvailable = $false
        }

        $outcome = Invoke-FixturePreflight -Name 'security-defaults-output' -FixturePath $fixturePath
        $conditionalAccess = $outcome.Report.Results | Where-Object Id -eq 'A365-ENTRA-007'

        $conditionalAccess.Status | Should -Be 'NotApplicable'
        $conditionalAccess.Observed | Should -Match 'Security defaults are enabled'
    }
}

Describe 'Passing and manual evidence contract' {
    It 'keeps the complete sample answers file schema-valid' {
        (Get-Content -LiteralPath $answersPath -Raw) |
            Test-Json -SchemaFile $answersSchemaPath |
            Should -BeTrue
    }

    It 'keeps customer-facing ActionRequired and exit-code language aligned with pass gates' {
        $readme = Get-Content -LiteralPath (Join-Path $resourceRoot 'README.md') -Raw
        $customerText = @(
            $readme
            (Get-Content -LiteralPath (Join-Path $resourceRoot 'Invoke-Agent365Preflight.ps1') -Raw)
            (Get-Content -LiteralPath (Join-Path $resourceRoot 'Private\ReportRenderer.ps1') -Raw)
            (Get-Content -LiteralPath (Join-Path $resourceRoot 'config\rules.v1.json') -Raw)
        ) -join [Environment]::NewLine

        $readme | Should -Match '\| `ActionRequired` \| The finding must be resolved before passing\. Until then, the overall verdict is `Incomplete`\.'
        $readme | Should -Match '\| `0` \| All pass gates are clear: zero Blocker, ActionRequired, NotAuthorized, Error, and unresolved required manual gates\.'
        $readme | Should -Match '\| `2` \| One or more ActionRequired, NotAuthorized, Error, unresolved required manual gates, or other collection gaps prevent passing\.'
        $customerText | Should -Not -Match 'does not automatically block|before or during (the )?pilot|no blockers (is|are) enough|No blockers and collection is complete enough'
    }

    It 'rejects whitespace-only required evidence in schema validation' {
        $answers = Get-Content -LiteralPath $answersPath -Raw | ConvertFrom-Json -Depth 100
        ($answers.answers | Where-Object id -eq 'A365-ENTRA-005').owner = '   '

        ($answers | ConvertTo-Json -Depth 100) |
            Test-Json -SchemaFile $answersSchemaPath -ErrorAction SilentlyContinue |
            Should -BeFalse
    }

    It 'keeps Pilot and Production incomplete when ActionRequired is the only pass gate' {
        $fixturePath = New-SyntheticFixture -Name 'action-only' -Mutator {
            param($fixture)
            $fixture.licensing.qualifyingAssignedUsers = 0
            $fixture.licensing.unknownSkuMappings = @('AGENT_365_FUTURE')
        }

        $pilot = Invoke-FixturePreflight -Name 'action-only-pilot' -FixturePath $fixturePath
        $production = Invoke-Agent365Preflight `
            -FixturePath $fixturePath `
            -AnswersPath $answersPath `
            -Stage Production `
            -OutputPath (Join-Path $TestDrive 'action-only-production')

        foreach ($outcome in @($pilot, $production)) {
            $outcome.Report.PassCriteria.BlockerCount | Should -Be 0
            $outcome.Report.PassCriteria.ActionRequiredCount | Should -Be 1
            $outcome.Report.PassCriteria.NotAuthorizedCount | Should -Be 0
            $outcome.Report.PassCriteria.ErrorCount | Should -Be 0
            $outcome.Report.PassCriteria.IsSatisfied | Should -BeFalse
            $outcome.Report.Verdict.Label | Should -Be 'Incomplete'
            $outcome.Report.Verdict.Summary | Should -Match '1 required action'
            $outcome.ExitCode | Should -Be 2
        }
    }

    It 'reaches Ready for pilot after remediation, valid evidence, and rerun' {
        $blockedFixture = New-SyntheticFixture -Name 'before-remediation' -Mutator {
            param($fixture)
            $fixture.licensing.qualifyingAssignedUsers = 0
            $fixture.licensing.unknownSkuMappings = @('AGENT_365_FUTURE')
        }
        $before = Invoke-FixturePreflight -Name 'before-remediation-output' -FixturePath $blockedFixture
        $after = Invoke-FixturePreflight `
            -Name 'after-remediation-output' `
            -PreviousResultPath $before.Paths.Json

        $before.Report.Verdict.Label | Should -Be 'Incomplete'
        $after.Report.Verdict.Label | Should -Be 'Ready for pilot'
        $after.Report.PassCriteria.IsSatisfied | Should -BeTrue
        @($after.Report.Drift.ResolvedRequiredActions | Where-Object Id -eq 'A365-FOUNDATION-002').Count | Should -Be 1
        $afterHtml = Get-Content -LiteralPath $after.Paths.Html -Raw
        $afterHtml | Should -Match 'Resolved required actions'
        $driftSection = [regex]::Match($afterHtml, '<section id="drift"[\s\S]*?</section>').Value
        ([regex]::Matches($driftSection, 'A365-FOUNDATION-002')).Count | Should -Be 1
    }

    It 'reaches Technical pre-flight complete only when Production pass gates are clear' {
        $outcome = Invoke-Agent365Preflight `
            -FixturePath $readyFixturePath `
            -AnswersPath $answersPath `
            -Stage Production `
            -OutputPath (Join-Path $TestDrive 'production-complete')

        $outcome.Report.PassCriteria.IsSatisfied | Should -BeTrue
        $outcome.Report.Verdict.Label | Should -Be 'Technical pre-flight complete'
        $outcome.ExitCode | Should -Be 0
    }

    It 'applies approved evidence while preserving the collected observation' {
        $outcome = Invoke-FixturePreflight -Name 'approved-evidence'
        $result = $outcome.Report.Results | Where-Object Id -eq 'A365-ENTRA-005'

        $result.Status | Should -Be 'Passed'
        $result.ManualAttestable | Should -BeTrue
        $result.AttestationRequired | Should -BeTrue
        $result.Attestation.Applied | Should -BeTrue
        $result.Attestation.Owner | Should -Be 'Agent ID reviewer'
        $result.Attestation.EvidenceReference | Should -Be 'Blueprint permission review record'
        $result.Observed | Should -Match 'requested permission'
        $result.Attestation.PreservedObserved | Should -Be $result.Observed
    }

    It 'redacts submitted manual evidence in sanitized support copies' {
        $outcome = Invoke-FixturePreflight -Name 'sanitized-evidence'
        $sanitized = Get-Content -LiteralPath $outcome.Paths.SanitizedJson -Raw | ConvertFrom-Json -Depth 100
        $result = $sanitized.Results | Where-Object Id -eq 'A365-ENTRA-005'

        $result.Attestation.Owner | Should -Be 'Redacted'
        $result.Attestation.EvidenceReference | Should -Be 'Redacted'
        $result.Attestation.Notes | Should -Be 'Redacted'
    }

    It 'redacts preserved observations for sensitive manually attestable results' {
        $outcome = Invoke-FixturePreflight -Name 'sanitized-sensitive-evidence' -Profile @('SharePointAgents')
        $full = Get-Content -LiteralPath $outcome.Paths.Json -Raw | ConvertFrom-Json -Depth 100
        $sanitized = Get-Content -LiteralPath $outcome.Paths.SanitizedJson -Raw | ConvertFrom-Json -Depth 100
        $fullResult = $full.Results | Where-Object Id -eq 'A365-SHAREPOINT-001'
        $sanitizedResult = $sanitized.Results | Where-Object Id -eq 'A365-SHAREPOINT-001'

        $fullResult.Attestation.PreservedObserved | Should -Not -Be 'Redacted in sanitized support copy.'
        $sanitizedResult.Observed | Should -Be 'Redacted in sanitized support copy.'
        $sanitizedResult.Attestation.PreservedObserved | Should -Be 'Redacted in sanitized support copy.'
    }

    It 'does not let Yes evidence override an automated ActionRequired result' {
        $fixturePath = New-SyntheticFixture -Name 'automated-action' -Mutator {
            param($fixture)
            $fixture.conditionalAccess.enabledPolicyCount = 0
            $fixture.conditionalAccess.reportOnlyPolicyCount = 0
        }

        $outcome = Invoke-FixturePreflight -Name 'automated-action-output' -FixturePath $fixturePath
        $result = $outcome.Report.Results | Where-Object Id -eq 'A365-ENTRA-007'

        $result.Status | Should -Be 'ActionRequired'
        $result.Attestation.Submitted | Should -BeTrue
        $result.Attestation.Applied | Should -BeFalse
        $outcome.Report.Verdict.Label | Should -Be 'Incomplete'
    }

    It 'keeps unanswered approved manual gates incomplete' {
        $answersFile = New-SyntheticAnswers -Name 'missing-approved-gate' -Mutator {
            param($answers)
            $answers.answers = @($answers.answers | Where-Object id -ne 'A365-ENTRA-005')
        }

        $outcome = Invoke-FixturePreflight -Name 'missing-approved-gate-output' -AnswersFile $answersFile
        $result = $outcome.Report.Results | Where-Object Id -eq 'A365-ENTRA-005'

        $result.Status | Should -Be 'ManualValidation'
        $outcome.Report.PassCriteria.RequiredManualUnresolvedCount | Should -Be 1
        $outcome.Report.Verdict.Label | Should -Be 'Incomplete'
    }

    It 'maps No evidence by the approved rule severity' {
        $answersFile = New-SyntheticAnswers -Name 'no-evidence' -Mutator {
            param($answers)
            ($answers.answers | Where-Object id -eq 'A365-ENTRA-005').answer = 'No'
            ($answers.answers | Where-Object id -eq 'A365-MANUAL-003').answer = 'No'
        }

        $outcome = Invoke-FixturePreflight -Name 'no-evidence-output' -AnswersFile $answersFile

        ($outcome.Report.Results | Where-Object Id -eq 'A365-ENTRA-005').Status | Should -Be 'ActionRequired'
        ($outcome.Report.Results | Where-Object Id -eq 'A365-MANUAL-003').Status | Should -Be 'Blocker'
        $outcome.Report.Verdict.Label | Should -Be 'Blocked'
    }

    It 'rejects unknown, duplicate, and automated-only attestation IDs' {
        $unknown = New-SyntheticAnswers -Name 'unknown-answer' -Mutator {
            param($answers)
            $answers.answers += [pscustomobject]@{ id = 'A365-UNKNOWN-999'; answer = 'No' }
        }
        $duplicate = New-SyntheticAnswers -Name 'duplicate-answer' -Mutator {
            param($answers)
            $answers.answers += $answers.answers[0]
        }
        $automated = New-SyntheticAnswers -Name 'automated-answer' -Mutator {
            param($answers)
            $answers.answers += [pscustomobject]@{ id = 'A365-LOCAL-001'; answer = 'No' }
        }

        { Invoke-Agent365Preflight -FixturePath $readyFixturePath -AnswersPath $unknown -OutputPath (Join-Path $TestDrive 'unknown-answer-output') } | Should -Throw '*unknown attestation id*'
        { Invoke-Agent365Preflight -FixturePath $readyFixturePath -AnswersPath $duplicate -OutputPath (Join-Path $TestDrive 'duplicate-answer-output') } | Should -Throw '*duplicate id*'
        { Invoke-Agent365Preflight -FixturePath $readyFixturePath -AnswersPath $automated -OutputPath (Join-Path $TestDrive 'automated-answer-output') } | Should -Throw '*automated-only rule*'
    }

    It 'rejects incomplete Yes evidence and unpermitted NotApplicable evidence' {
        $missingOwner = New-SyntheticAnswers -Name 'missing-owner' -Mutator {
            param($answers)
            ($answers.answers | Where-Object id -eq 'A365-ENTRA-005').owner = ''
        }
        $missingReference = New-SyntheticAnswers -Name 'missing-reference' -Mutator {
            param($answers)
            ($answers.answers | Where-Object id -eq 'A365-ENTRA-005').evidenceReference = ''
        }
        $unpermittedNa = New-SyntheticAnswers -Name 'unpermitted-na' -Mutator {
            param($answers)
            ($answers.answers | Where-Object id -eq 'A365-ENTRA-005').answer = 'NotApplicable'
            ($answers.answers | Where-Object id -eq 'A365-ENTRA-005') |
                Add-Member -NotePropertyName justification -NotePropertyValue 'Not used' -Force
        }

        { Invoke-Agent365Preflight -FixturePath $readyFixturePath -AnswersPath $missingOwner -OutputPath (Join-Path $TestDrive 'missing-owner-output') } | Should -Throw '*requires an accountable owner*'
        { Invoke-Agent365Preflight -FixturePath $readyFixturePath -AnswersPath $missingReference -OutputPath (Join-Path $TestDrive 'missing-reference-output') } | Should -Throw '*requires an evidence reference*'
        { Invoke-Agent365Preflight -FixturePath $readyFixturePath -AnswersPath $unpermittedNa -OutputPath (Join-Path $TestDrive 'unpermitted-na-output') } | Should -Throw '*NotApplicable is not permitted*'
    }

    It 'requires a justification for permitted NotApplicable evidence' {
        $missingJustification = New-SyntheticAnswers -Name 'missing-na-justification' -Mutator {
            param($answers)
            ($answers.answers | Where-Object id -eq 'A365-SHAREPOINT-001').answer = 'NotApplicable'
        }
        $validNa = New-SyntheticAnswers -Name 'valid-na' -Mutator {
            param($answers)
            $answer = $answers.answers | Where-Object id -eq 'A365-SHAREPOINT-001'
            $answer.answer = 'NotApplicable'
            $answer | Add-Member -NotePropertyName justification -NotePropertyValue 'The selected pilot does not use SharePoint knowledge or target sites.' -Force
        }

        { Invoke-Agent365Preflight -FixturePath $readyFixturePath -AnswersPath $missingJustification -Profile SharePointAgents -OutputPath (Join-Path $TestDrive 'missing-na-justification-output') } | Should -Throw '*requires a justification*'
        $outcome = Invoke-Agent365Preflight `
            -FixturePath $readyFixturePath `
            -AnswersPath $validNa `
            -Profile SharePointAgents `
            -OutputPath (Join-Path $TestDrive 'valid-na-output')

        ($outcome.Report.Results | Where-Object Id -eq 'A365-SHAREPOINT-001').Status | Should -Be 'NotApplicable'
    }

    It 'accepts version 1.0 answers while leaving new required gates unresolved' {
        $legacyAnswers = New-SyntheticAnswers -Name 'legacy-answers' -Mutator {
            param($answers)
            $answers.schemaVersion = '1.0'
            $answers.answers = @($answers.answers | Where-Object id -like 'A365-MANUAL-*')
        }

        $outcome = Invoke-FixturePreflight -Name 'legacy-answers-output' -AnswersFile $legacyAnswers

        $outcome.Report.Verdict.Label | Should -Be 'Incomplete'
        $outcome.Report.PassCriteria.RequiredManualUnresolvedCount | Should -BeGreaterThan 0
    }

    It 'applies evidence to selected stable profile gates' {
        $outcome = Invoke-FixturePreflight -Name 'profile-evidence' -Profile @('CopilotStudio')
        $result = $outcome.Report.Results | Where-Object Id -eq 'A365-PROFILE-COPILOTSTUDIO'

        $result.Status | Should -Be 'Passed'
        $result.Attestation.Applied | Should -BeTrue
        @($outcome.Report.ManuallyAttestableGates | Where-Object Id -eq $result.Id).Count | Should -Be 1
    }

    It 'builds ordered Path to Ready and safe full and sanitized rerun commands' {
        $fixturePath = New-SyntheticFixture -Name 'path-to-ready' -Mutator {
            param($fixture)
            $fixture.licensing.qualifyingAssignedUsers = 0
            $fixture.licensing.unknownSkuMappings = @('AGENT_365_FUTURE')
        }
        $outcome = Invoke-Agent365Preflight `
            -FixturePath $fixturePath `
            -AnswersPath $answersPath `
            -Profile CopilotStudio `
            -Collector TenantFoundation,Licensing,AgentIdentity `
            -Stage Pilot `
            -AuditWindowDays 14 `
            -AuditQueryTimeoutSeconds 300 `
            -UseDeviceCode `
            -IncludeSanitizedCopy `
            -OutputPath (Join-Path $TestDrive 'path-to-ready-output')
        $item = $outcome.Report.PathToReady.Items | Where-Object Id -eq 'A365-FOUNDATION-002'
        $sanitized = Get-Content -LiteralPath $outcome.Paths.SanitizedJson -Raw | ConvertFrom-Json -Depth 100

        $outcome.Report.PathToReady.IsReady | Should -BeFalse
        $item.Status | Should -Be 'ActionRequired'
        $item.Priority | Should -Be 3
        $item.RequiresTenantChange | Should -BeTrue
        $item.RequiresRerun | Should -BeTrue
        $outcome.Report.Rerun.Command | Should -Match '-Profile ControlPlane,CopilotStudio'
        $outcome.Report.Rerun.Command | Should -Match '-Collector TenantFoundation,Licensing,AgentIdentity'
        $outcome.Report.Rerun.Command | Should -Match '-AuditWindowDays 14'
        $outcome.Report.Rerun.Command | Should -Match '-AuditQueryTimeoutSeconds 300'
        $outcome.Report.Rerun.Command | Should -Match '-AnswersPath'
        $outcome.Report.Rerun.Command | Should -Match '-PreviousResultPath'
        $outcome.Report.Rerun.Command | Should -Match '-UseDeviceCode'
        $outcome.Report.Rerun.Command | Should -Not -Match 'ClientId|CertificateThumbprint|ClientSecret'
        $sanitized.Rerun.Command | Should -Match '<tenant-guid-or-domain>'
        $sanitized.Rerun.Command | Should -Match '<previous-report\.json>'
        $sanitized.Rerun.Command | Should -Match '<output-folder>'
        $sanitized.Rerun.Command | Should -Not -Match [regex]::Escape($TestDrive)
    }

    It 'orders Path to Ready from blockers through advisories' {
        $fixturePath = New-SyntheticFixture -Name 'path-priority' -Mutator {
            param($fixture)
            $fixture.licensing.qualifyingAssignedUsers = 0
            $fixture.licensing.unknownSkuMappings = @()
            $fixture.licensing.subscribedSkus = @(
                $fixture.licensing.subscribedSkus |
                    Where-Object skuPartNumber -ne 'MICROSOFT_365_E5'
            )
            $fixture.authentication.grantedScopes = @(
                $fixture.authentication.grantedScopes |
                    Where-Object { $_ -ne 'CopilotPackages.Read.All' }
            )
            $fixture.registry.available = $false
            $fixture.defender.agentsInfo.available = $false
            $fixture.conditionalAccess.enabledPolicyCount = 0
            $fixture.conditionalAccess.reportOnlyPolicyCount = 0
            $fixture.collectionIssues = @(
                [pscustomobject]@{
                    Adapter = 'Graph'
                    Operation = 'Agent package catalog'
                    Category = 'PermissionOrRole'
                    StatusCode = 403
                    Message = 'Registry read is not authorized.'
                    RequiredPermission = 'CopilotPackages.Read.All'
                    DocsUrl = 'https://learn.microsoft.com/microsoft-365/copilot/extensibility/api/admin-settings/package/copilotpackages-list'
                },
                [pscustomobject]@{
                    Adapter = 'Graph'
                    Operation = 'Defender agentsInfo aggregate query'
                    Category = 'Api'
                    StatusCode = 500
                    Message = 'Synthetic Defender collection error.'
                    RequiredPermission = 'ThreatHunting.Read.All'
                    DocsUrl = 'https://learn.microsoft.com/defender-xdr/advanced-hunting-agentsinfo-table'
                }
            )
        }
        $answersFile = New-SyntheticAnswers -Name 'path-priority-answers' -Mutator {
            param($answers)
            $answers.answers = @($answers.answers | Where-Object id -ne 'A365-ENTRA-005')
        }

        $outcome = Invoke-FixturePreflight `
            -Name 'path-priority-output' `
            -FixturePath $fixturePath `
            -AnswersFile $answersFile
        $items = @($outcome.Report.PathToReady.Items)
        $priorities = @($items.Priority)

        $priorities -join ',' | Should -Be (@($priorities | Sort-Object) -join ',')
        ($items | Where-Object Id -eq 'A365-FOUNDATION-002').Priority | Should -Be 1
        ($items | Where-Object Id -eq 'A365-REGISTRY-001').Priority | Should -Be 2
        ($items | Where-Object Id -eq 'A365-DEFENDER-001').Priority | Should -Be 2
        ($items | Where-Object Id -eq 'A365-ENTRA-007').Priority | Should -Be 3
        ($items | Where-Object Id -eq 'A365-ENTRA-005').Priority | Should -Be 4
        ($items | Where-Object Id -eq 'A365-FOUNDATION-003').Priority | Should -Be 5
    }
}

Describe 'Manual evidence guidance contract' {
    BeforeAll {
        $allGuidedProfiles = @(
            'ControlPlane', 'CopilotStudio', 'AgentBuilder', 'SharePointAgents', 'Foundry',
            'CustomProCode', 'ExternalRegistrySync', 'LocalAgents', 'WorkIQ', 'AITeammate'
        )
    }

    It 'provides complete structured guidance for every manually attestable ID' {
        $outcome = Invoke-FixturePreflight -Name 'complete-guidance' -Profile $allGuidedProfiles
        [object[]]$gates = @($outcome.Report.ManuallyAttestableGates)

        $gates.Count | Should -Be 21
        @($gates.Id | Sort-Object -Unique).Count | Should -Be 21
        foreach ($gate in $gates) {
            $gate.Guidance.Intent | Should -Not -BeNullOrEmpty
            $gate.Guidance.WhyItMatters | Should -Not -BeNullOrEmpty
            $gate.Guidance.WhoShouldAnswer | Should -Not -BeNullOrEmpty
            @($gate.Guidance.YesCriteria).Count | Should -BeGreaterThan 0
            @($gate.Guidance.EvidenceToRetain).Count | Should -BeGreaterThan 0
            @($gate.Guidance.VerificationSteps).Count | Should -BeGreaterThan 0
            $gate.Guidance.NoRemediation | Should -Not -BeNullOrEmpty
            $gate.Guidance.NotApplicableGuidance | Should -Not -BeNullOrEmpty
            @($gate.Guidance.PublicSources).Count | Should -BeGreaterThan 0
            $gate.Guidance.ReviewDate | Should -Match '^\d{4}-\d{2}-\d{2}$'
            $gate.Guidance.SearchText | Should -Not -BeNullOrEmpty
        }
    }

    It 'fails the guidance contract when a required field is missing' {
        $guidance = Get-Content -LiteralPath $guidancePath -Raw | ConvertFrom-Json -Depth 100
        $guidance.items.'A365-MANUAL-001'.PSObject.Properties.Remove('intent')
        $badGuidancePath = Join-Path $TestDrive 'missing-guidance-field.json'
        [System.IO.File]::WriteAllText(
            $badGuidancePath,
            ($guidance | ConvertTo-Json -Depth 100),
            [System.Text.UTF8Encoding]::new($false)
        )
        $outputPath = Join-Path $TestDrive 'missing-guidance-output'

        InModuleScope Agent365Preflight -Parameters @{
            BadGuidancePath = $badGuidancePath
            FixturePath = $readyFixturePath
            OutputPath = $outputPath
        } {
            $originalGuidancePath = $script:GuidancePath
            try {
                $script:GuidancePath = $BadGuidancePath
                { Invoke-Agent365Preflight -FixturePath $FixturePath -OutputPath $OutputPath } |
                    Should -Throw "*A365-MANUAL-001*intent*"
            }
            finally {
                $script:GuidancePath = $originalGuidancePath
            }
        }
    }

    It 'rejects non-public guidance sources' {
        $rules = Get-Content -LiteralPath (Join-Path $resourceRoot 'config\rules.v1.json') -Raw | ConvertFrom-Json -Depth 100
        $guidance = Get-Content -LiteralPath $guidancePath -Raw | ConvertFrom-Json -Depth 100
        $guidance.items.'A365-MANUAL-001'.publicSources[0].url = 'https://contoso.invalid/owners'

        InModuleScope Agent365Preflight -Parameters @{ Rules = $rules; Guidance = $guidance } {
            { Test-A365GuidanceContract -Rules $Rules -Guidance $Guidance } |
                Should -Throw '*invalid or non-public Microsoft Learn source*'
        }
    }

    It 'keeps NotApplicable guidance aligned with rule permission' {
        $outcome = Invoke-FixturePreflight -Name 'guidance-na' -Profile $allGuidedProfiles
        [object[]]$gates = @($outcome.Report.ManuallyAttestableGates)
        $sharePoint = $gates | Where-Object Id -eq 'A365-SHAREPOINT-001'
        [object[]]$notAllowed = @($gates | Where-Object Id -ne 'A365-SHAREPOINT-001')

        $sharePoint.AllowNotApplicable | Should -BeTrue
        $sharePoint.Guidance.NotApplicableAllowed | Should -BeTrue
        foreach ($gate in $notAllowed) {
            $gate.AllowNotApplicable | Should -BeFalse
            $gate.Guidance.NotApplicableAllowed | Should -BeFalse
        }
    }

    It 'sanitizes the current observation without removing generic guidance' {
        $outcome = Invoke-FixturePreflight -Name 'guidance-sanitized' -Profile @('SharePointAgents')
        $sanitized = Get-Content -LiteralPath $outcome.Paths.SanitizedJson -Raw | ConvertFrom-Json -Depth 100
        $gate = $sanitized.ManuallyAttestableGates | Where-Object Id -eq 'A365-SHAREPOINT-001'

        $gate.Observed | Should -Be 'Redacted in sanitized support copy.'
        $gate.Guidance.Intent | Should -Match 'approved pilot sites'
        $gate.Guidance.PublicSources[0].Url | Should -Match '^https://learn\.microsoft\.com/'
    }
}

Describe 'Paging and throttling' {
    It 'follows Microsoft Graph next links' {
        $pages = @{
            first = [pscustomobject]@{
                value = @([pscustomobject]@{ id = 1 }, [pscustomobject]@{ id = 2 })
                '@odata.nextLink' = 'second'
            }

            second = [pscustomobject]@{
                value = @([pscustomobject]@{ id = 3 })
            }
        }

        $items = Invoke-Agent365PagedRequest -InitialUri 'first' -RequestScript {
            param($uri)
            return $pages[$uri]
        }

        $items.Count | Should -Be 3
        $items[2].id | Should -Be 3
    }

    It 'honors a 429 retry response before succeeding' {
        $script:requestCount = 0
        $script:sleepCount = 0

        $items = Invoke-Agent365PagedRequest -InitialUri 'first' -RequestScript {
            param($uri)
            $script:requestCount++
            if ($script:requestCount -eq 1) {
                return [pscustomobject]@{
                    StatusCode = 429
                    RetryAfter = 0
                    Body = $null
                }
            }
            return [pscustomobject]@{
                StatusCode = 200
                Body = [pscustomobject]@{
                    value = @([pscustomobject]@{ id = 'after-retry' })
                }
            }
        } -SleepScript {
            param($seconds)
            $script:sleepCount++
        }

        $script:requestCount | Should -Be 2
        $script:sleepCount | Should -Be 1
        $items[0].id | Should -Be 'after-retry'
    }
}

Describe 'Purview Audit Search polling' {
    It 'continues beyond 60 seconds and succeeds before the default 300-second deadline' {
        InModuleScope Agent365Preflight {
            $script:auditClock = [DateTimeOffset]'2026-09-02T00:00:00Z'
            $script:auditPolls = 0
            $result = Wait-A365AuditQuery `
                -InitialResponse ([pscustomobject]@{ status = 'running' }) `
                -QueryId '11111111-2222-3333-4444-555555555555' `
                -Allowlist ([pscustomobject]@{}) `
                -TimeoutSeconds 300 `
                -PollIntervalSeconds 5 `
                -RequestScript {
                    param($uri, $allowlist)
                    $script:auditPolls++
                    [pscustomobject]@{
                        status = if ($script:auditPolls -ge 13) { 'succeeded' } else { 'running' }
                    }
                } `
                -SleepScript {
                    param($seconds)
                    $script:auditClock = $script:auditClock.AddSeconds($seconds)
                } `
                -UtcNowScript { $script:auditClock }

            $result.Status | Should -Be 'succeeded'
            $result.TimedOut | Should -BeFalse
            $result.PollCount | Should -Be 13
            $result.ElapsedSeconds | Should -Be 65
        }
    }

    It 'stops at the deadline when a query remains running' {
        InModuleScope Agent365Preflight {
            $script:auditClock = [DateTimeOffset]'2026-09-02T00:00:00Z'
            $result = Wait-A365AuditQuery `
                -InitialResponse ([pscustomobject]@{ status = 'running' }) `
                -QueryId '11111111-2222-3333-4444-555555555555' `
                -Allowlist ([pscustomobject]@{}) `
                -TimeoutSeconds 30 `
                -PollIntervalSeconds 5 `
                -RequestScript {
                    param($uri, $allowlist)
                    [pscustomobject]@{ status = 'running' }
                } `
                -SleepScript {
                    param($seconds)
                    $script:auditClock = $script:auditClock.AddSeconds($seconds)
                } `
                -UtcNowScript { $script:auditClock }

            $result.Status | Should -Be 'running'
            $result.TimedOut | Should -BeTrue
            $result.PollCount | Should -Be 5
            $result.ElapsedSeconds | Should -Be 30
        }
    }

    It 'honors Retry-After surfaced by an audit status response' {
        InModuleScope Agent365Preflight {
            $script:auditClock = [DateTimeOffset]'2026-09-02T00:00:00Z'
            $script:auditDelays = [System.Collections.Generic.List[int]]::new()
            $result = Wait-A365AuditQuery `
                -InitialResponse ([pscustomobject]@{
                    status = 'running'
                    retryAfterSeconds = 20
                }) `
                -QueryId '11111111-2222-3333-4444-555555555555' `
                -Allowlist ([pscustomobject]@{}) `
                -TimeoutSeconds 300 `
                -PollIntervalSeconds 5 `
                -RequestScript {
                    param($uri, $allowlist)
                    [pscustomobject]@{ status = 'succeeded' }
                } `
                -SleepScript {
                    param($seconds)
                    $script:auditDelays.Add($seconds)
                    $script:auditClock = $script:auditClock.AddSeconds($seconds)
                } `
                -UtcNowScript { $script:auditClock }

            $result.Status | Should -Be 'succeeded'
            $script:auditDelays.Count | Should -Be 1
            $script:auditDelays[0] | Should -Be 20
            $result.ElapsedSeconds | Should -Be 20
        }
    }

    It 'stops immediately on failed and cancelled terminal states' {
        InModuleScope Agent365Preflight {
            foreach ($terminalStatus in @('failed', 'cancelled')) {
                $result = Wait-A365AuditQuery `
                    -InitialResponse ([pscustomobject]@{ status = $terminalStatus }) `
                    -QueryId '11111111-2222-3333-4444-555555555555' `
                    -Allowlist ([pscustomobject]@{}) `
                    -TimeoutSeconds 300

                $result.Status | Should -Be $terminalStatus
                $result.TimedOut | Should -BeFalse
                $result.PollCount | Should -Be 0
            }
        }
    }

    It 'classifies deadline expiry as Timeout and keeps the verdict incomplete' {
        $fixturePath = New-SyntheticFixture -Name 'purview-timeout' -Mutator {
            param($fixture)
            $fixture.purview.audit.available = $false
            $fixture.purview.audit.queryStatus = 'running'
            $fixture.purview.audit | Add-Member -NotePropertyName pollingElapsedSeconds -NotePropertyValue 300 -Force
            $fixture.purview.audit | Add-Member -NotePropertyName pollCount -NotePropertyValue 60 -Force
            $fixture.purview.audit | Add-Member -NotePropertyName timedOut -NotePropertyValue $true -Force
            $fixture.collectionIssues = @(
                [pscustomobject]@{
                    Adapter = 'Graph'
                    Operation = 'Purview Audit Search aggregate query'
                    Category = 'Timeout'
                    StatusCode = $null
                    Message = "Purview Audit Search timed out after 300 seconds while status remained 'running'. The retained query job may continue server-side."
                    RequiredPermission = 'AuditLogsQuery.Read.All'
                    DocsUrl = 'https://learn.microsoft.com/graph/api/security-auditcoreroot-post-auditlogqueries?view=graph-rest-1.0'
                    QueryStatus = 'running'
                    PollingElapsedSeconds = 300
                    TimedOut = $true
                }
            )
        }

        $outcome = Invoke-FixturePreflight -Name 'purview-timeout-output' -FixturePath $fixturePath
        $result = $outcome.Report.Results | Where-Object Id -eq 'A365-PURVIEW-001'

        $result.Status | Should -Be 'Error'
        $result.Observed | Should -Match '\[Timeout\]'
        $result.Details.QueryStatus | Should -Be 'running'
        $result.Details.PollingElapsedSeconds | Should -Be 300
        $outcome.Report.Verdict.Label | Should -Be 'Incomplete'
        $outcome.ExitCode | Should -Be 2
    }

    It 'validates the public timeout parameter range and records it in runtime metadata' {
        {
            Invoke-Agent365Preflight `
                -FixturePath $readyFixturePath `
                -AuditQueryTimeoutSeconds 29 `
                -OutputPath (Join-Path $TestDrive 'timeout-too-low')
        } | Should -Throw

        {
            Invoke-Agent365Preflight `
                -FixturePath $readyFixturePath `
                -AuditQueryTimeoutSeconds 901 `
                -OutputPath (Join-Path $TestDrive 'timeout-too-high')
        } | Should -Throw

        $outcome = Invoke-Agent365Preflight `
            -FixturePath $readyFixturePath `
            -AnswersPath $answersPath `
            -AuditQueryTimeoutSeconds 30 `
            -OutputPath (Join-Path $TestDrive 'timeout-minimum')

        $outcome.Report.Runtime.AuditQueryTimeoutSeconds | Should -Be 30
    }
}

Describe 'Collector-scoped consent and stable profile identity' {
    It 'derives scopes only from selected collectors plus tenant foundation' {
        $scopes = @(Get-Agent365RequiredScopes -Collector Registry)

        $scopes.Count | Should -Be 2
        ($scopes -contains 'Organization.Read.All') | Should -Be $true
        ($scopes -contains 'CopilotPackages.Read.All') | Should -Be $true
        ($scopes -contains 'ThreatHunting.Read.All') | Should -Be $false
        ($scopes -contains 'Application.Read.All') | Should -Be $false
    }

    It 'marks unselected collector checks not applicable instead of passed' {
        $outcome = Invoke-FixturePreflight -Name 'registry-only' -Collector @('Registry')

        ($outcome.Report.Collectors -contains 'TenantFoundation') | Should -Be $true
        ($outcome.Report.Results | Where-Object Id -eq 'A365-REGISTRY-001').Status | Should -Be 'Passed'
        ($outcome.Report.Results | Where-Object Id -eq 'A365-DEFENDER-001').Status | Should -Be 'NotApplicable'
        ($outcome.Report.Authentication.RequestedScopes -contains 'ThreatHunting.Read.All') | Should -Be $false
    }

    It 'keeps profile result IDs stable when profile order changes' {
        $first = Invoke-FixturePreflight -Name 'profile-order-one' -Profile @('CopilotStudio', 'Foundry')
        $second = Invoke-FixturePreflight -Name 'profile-order-two' -Profile @('Foundry', 'CopilotStudio')
        $firstProfiles = @($first.Report.Results | Where-Object Id -like 'A365-PROFILE-*')
        $secondProfiles = @($second.Report.Results | Where-Object Id -like 'A365-PROFILE-*')

        @($firstProfiles.Id | Sort-Object) -join ',' | Should -Be (@($secondProfiles.Id | Sort-Object) -join ',')
        ($firstProfiles | Where-Object Title -like 'CopilotStudio*').Id | Should -Be 'A365-PROFILE-COPILOTSTUDIO'
        ($secondProfiles | Where-Object Title -like 'Foundry*').Id | Should -Be 'A365-PROFILE-FOUNDRY'
    }

    It 'does not cross-wire profile drift when profile order changes' {
        $first = Invoke-FixturePreflight -Name 'profile-drift-one' -Profile @('CopilotStudio', 'Foundry')
        $second = Invoke-FixturePreflight -Name 'profile-drift-two' -Profile @('Foundry', 'CopilotStudio')
        ($first.Report.Results | Where-Object Title -like 'CopilotStudio*').Status = 'Blocker'
        ($second.Report.Results | Where-Object Title -like 'CopilotStudio*').Status = 'Blocker'

        $drift = Compare-Agent365PreflightResult -Current $second.Report -Previous $first.Report

        @($drift.Changed | Where-Object Id -like 'A365-PROFILE-*').Count | Should -Be 0
    }
}

Describe 'Tenant targeting safety' {
    It 'passes a GUID TenantId to delegated Connect-MgGraph and verifies the context tenant' {
        $expectedTenant = '11111111-2222-3333-4444-555555555555'

        InModuleScope Agent365Preflight -Parameters @{ ExpectedTenant = $expectedTenant } {
            Mock Connect-MgGraph {}
            $script:contextCalls = 0
            Mock Get-A365ActiveContext {
                $script:contextCalls++
                if ($script:contextCalls -eq 1) {
                    return $null
                }
                [pscustomobject]@{
                    TenantId = $ExpectedTenant.ToUpperInvariant()
                    Scopes = @('Organization.Read.All')
                    AuthType = 'Delegated'
                    Environment = 'Global'
                    Account = 'fixture@example.invalid'
                }
            }

            $connection = Connect-A365GraphContext `
                -Scopes @('Organization.Read.All') `
                -TenantId $ExpectedTenant `
                -ClientId $null `
                -CertificateThumbprint $null

            $connection.AppOnly | Should -BeFalse
            $connection.TargetAssertion.Method | Should -Be 'TenantId'
            $connection.TargetAssertion.Matched | Should -BeTrue
            $connection.TargetAssertion.ActualTenantId | Should -Be $ExpectedTenant.ToUpperInvariant()
            Should -Invoke Connect-MgGraph -Times 1 -Exactly -ParameterFilter {
                $TenantId -eq $ExpectedTenant -and
                $Scopes -contains 'Organization.Read.All' -and
                -not $ClientId -and
                -not $CertificateThumbprint
            }
        }
    }

    It 'passes a verified domain to delegated auth and verifies the first organization response' {
        $expectedDomain = 'fixture.onmicrosoft.com'
        $actualTenant = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'

        InModuleScope Agent365Preflight -Parameters @{
            ExpectedDomain = $expectedDomain
            ActualTenant = $actualTenant
        } {
            Mock Connect-MgGraph {}
            $script:contextCalls = 0
            Mock Get-A365ActiveContext {
                $script:contextCalls++
                if ($script:contextCalls -eq 1) {
                    return $null
                }
                [pscustomobject]@{
                    TenantId = $ActualTenant
                    Scopes = @('Organization.Read.All')
                    AuthType = 'Delegated'
                    Environment = 'Global'
                    Account = 'fixture@example.invalid'
                }
            }
            Mock Invoke-A365GraphRequest {
                [pscustomobject]@{
                    value = @(
                        [pscustomobject]@{
                            id = $ActualTenant
                            displayName = 'Fixture organization'
                            verifiedDomains = @(
                                [pscustomobject]@{
                                    name = $ExpectedDomain.ToUpperInvariant()
                                    isDefault = $true
                                }
                            )
                        }
                    )
                }
            }

            $connection = Connect-A365GraphContext `
                -Scopes @('Organization.Read.All') `
                -TenantId $ExpectedDomain `
                -ClientId $null `
                -CertificateThumbprint $null
            $organization = Get-A365OrganizationContext `
                -Allowlist ([pscustomobject]@{}) `
                -TargetAssertion $connection.TargetAssertion

            $connection.AppOnly | Should -BeFalse
            $organization.TargetAssertion.Method | Should -Be 'VerifiedDomain'
            $organization.TargetAssertion.Matched | Should -BeTrue
            $organization.TargetAssertion.MatchedVerifiedDomain | Should -Be $ExpectedDomain.ToUpperInvariant()
            Should -Invoke Connect-MgGraph -Times 1 -Exactly -ParameterFilter {
                $TenantId -eq $ExpectedDomain -and
                $Scopes -contains 'Organization.Read.All' -and
                -not $ClientId -and
                -not $CertificateThumbprint
            }
            Should -Invoke Invoke-A365GraphRequest -Times 1 -Exactly -ParameterFilter {
                $Method -eq 'GET' -and $Uri -match '/v1\.0/organization'
            }
        }
    }

    It 'marks GUID and verified-domain mismatches as safe startup aborts' {
        InModuleScope Agent365Preflight {
            Mock Connect-MgGraph {}
            Mock Get-A365ActiveContext {
                [pscustomobject]@{
                    TenantId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
                    Scopes = @('Organization.Read.All')
                    Environment = 'Global'
                    Account = 'fixture@example.invalid'
                }
            }

            $guidError = $null
            try {
                $null = Connect-A365GraphContext `
                    -Scopes @('Organization.Read.All') `
                    -TenantId '11111111-2222-3333-4444-555555555555' `
                    -ClientId $null `
                    -CertificateThumbprint $null
            }
            catch {
                $guidError = $_
            }

            $domainAssertion = [pscustomobject]@{
                requested = $true
                expected = 'expected.onmicrosoft.com'
                method = 'VerifiedDomain'
                matched = $null
                actualTenantId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
                matchedVerifiedDomain = $null
            }
            $domainError = $null
            try {
                $null = Confirm-A365DomainTenantTarget `
                    -TargetAssertion $domainAssertion `
                    -Organization ([pscustomobject]@{
                        verifiedDomains = @([pscustomobject]@{ name = 'other.onmicrosoft.com' })
                    })
            }
            catch {
                $domainError = $_
            }

            $guidError.Exception.Message | Should -Match 'Tenant target mismatch'
            $guidError.Exception.Data['Agent365SafeStartupAbort'] | Should -BeTrue
            $domainError.Exception.Message | Should -Match 'Tenant target mismatch'
            $domainError.Exception.Data['Agent365SafeStartupAbort'] | Should -BeTrue
        }
    }

    It 'rejects every partial certificate app-only tuple before authentication' {
        InModuleScope Agent365Preflight {
            Mock Connect-MgGraph {}

            {
                Connect-A365GraphContext `
                    -Scopes @('Organization.Read.All') `
                    -TenantId 'contoso.onmicrosoft.com' `
                    -ClientId 'client-id' `
                    -CertificateThumbprint $null
            } | Should -Throw '*Missing: CertificateThumbprint*'

            {
                Connect-A365GraphContext `
                    -Scopes @('Organization.Read.All') `
                    -TenantId 'contoso.onmicrosoft.com' `
                    -ClientId $null `
                    -CertificateThumbprint 'thumbprint'
            } | Should -Throw '*Missing: ClientId*'

            {
                Connect-A365GraphContext `
                    -Scopes @('Organization.Read.All') `
                    -TenantId $null `
                    -ClientId 'client-id' `
                    -CertificateThumbprint 'thumbprint'
            } | Should -Throw '*Missing: TenantId*'

            Should -Invoke Connect-MgGraph -Times 0 -Exactly
        }
    }

    It 'writes no normal report after a safe startup abort' {
        $outputPath = Join-Path $TestDrive 'tenant-mismatch-abort'

        InModuleScope Agent365Preflight -Parameters @{ OutputPath = $outputPath } {
            Mock Get-A365LiveEvidence {
                throw (New-A365SafeStartupException -Message 'Tenant target mismatch. No report was written.')
            }

            {
                Invoke-Agent365Preflight `
                    -TenantId 'expected.onmicrosoft.com' `
                    -Collector TenantFoundation `
                    -OutputPath $OutputPath
            } | Should -Throw '*Tenant target mismatch*'
        }

        @(Get-ChildItem -LiteralPath $outputPath -File -ErrorAction SilentlyContinue).Count | Should -Be 0
    }

    It 'records successful target evidence and redacts it from support copies' {
        $fixturePath = New-SyntheticFixture -Name 'target-assertion-evidence' -Mutator {
            param($fixture)
            $fixture.tenant | Add-Member -NotePropertyName targetAssertion -NotePropertyValue ([pscustomobject]@{
                requested = $true
                expected = 'fixture.onmicrosoft.com'
                method = 'VerifiedDomain'
                matched = $true
                actualTenantId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
                matchedVerifiedDomain = 'fixture.onmicrosoft.com'
            })
        }

        $outcome = Invoke-FixturePreflight -Name 'target-assertion-output' -FixturePath $fixturePath
        $fullHtml = Get-Content -LiteralPath $outcome.Paths.Html -Raw
        $sanitizedHtml = Get-Content -LiteralPath $outcome.Paths.SanitizedHtml -Raw
        $sanitizedJson = Get-Content -LiteralPath $outcome.Paths.SanitizedJson -Raw | ConvertFrom-Json -Depth 100

        $outcome.Report.Tenant.TargetAssertion.Method | Should -Be 'VerifiedDomain'
        $outcome.Report.Tenant.TargetAssertion.Matched | Should -BeTrue
        $fullHtml | Should -Match 'fixture\.onmicrosoft\.com'
        $fullHtml | Should -Match 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
        $sanitizedHtml | Should -Not -Match 'fixture\.onmicrosoft\.com'
        $sanitizedHtml | Should -Not -Match 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
        $sanitizedJson.Tenant.TargetAssertion.Expected | Should -Be 'Redacted'
        $sanitizedJson.Tenant.TargetAssertion.ActualTenantId | Should -BeNullOrEmpty
        $sanitizedJson.Tenant.TargetAssertion.MatchedVerifiedDomain | Should -BeNullOrEmpty
    }

    It 'preserves the original delegated authentication failure and mode under strict mode' {
        InModuleScope Agent365Preflight {
            Mock Get-Module {
                [pscustomobject]@{ Name = 'Microsoft.Graph.Authentication'; Version = [Version]'2.38.1' }
            }
            Mock Import-Module {}
            Mock Test-A365GraphEndpointReachability { $true }
            Mock Connect-A365GraphContext {
                throw [System.InvalidOperationException]::new('Original delegated authentication failure.')
            }
            $issues = [System.Collections.Generic.List[object]]::new()

            $evidence = Get-A365LiveEvidence `
                -Profiles @('ControlPlane') `
                -Collectors @('TenantFoundation') `
                -Scopes @('Organization.Read.All') `
                -SkuCatalog ([pscustomobject]@{}) `
                -Allowlist ([pscustomobject]@{}) `
                -Issues $issues `
                -TenantId 'fixture.onmicrosoft.com'

            $evidence.authentication.mode | Should -Be 'InteractiveDelegated'
            $evidence.tenant.targetAssertion.method | Should -Be 'Unverified'
            $issues.Count | Should -Be 1
            $issues[0].Category | Should -Be 'Authentication'
            $issues[0].Message | Should -Be 'Original delegated authentication failure.'
            $issues[0].Message | Should -Not -Match '\$appOnly'
        }
    }

    It 'preserves the original app-only authentication failure and intended mode under strict mode' {
        InModuleScope Agent365Preflight {
            Mock Get-Module {
                [pscustomobject]@{ Name = 'Microsoft.Graph.Authentication'; Version = [Version]'2.38.1' }
            }
            Mock Import-Module {}
            Mock Test-A365GraphEndpointReachability { $true }
            Mock Connect-A365GraphContext {
                throw [System.InvalidOperationException]::new('Original certificate authentication failure.')
            }
            $issues = [System.Collections.Generic.List[object]]::new()

            $evidence = Get-A365LiveEvidence `
                -Profiles @('ControlPlane') `
                -Collectors @('TenantFoundation') `
                -Scopes @('Organization.Read.All') `
                -SkuCatalog ([pscustomobject]@{}) `
                -Allowlist ([pscustomobject]@{}) `
                -Issues $issues `
                -TenantId '11111111-2222-3333-4444-555555555555' `
                -ClientId 'client-id' `
                -CertificateThumbprint 'thumbprint'

            $evidence.authentication.mode | Should -Be 'CertificateAppOnly'
            $evidence.tenant.targetAssertion.method | Should -Be 'Unverified'
            $issues.Count | Should -Be 1
            $issues[0].Category | Should -Be 'Authentication'
            $issues[0].Message | Should -Be 'Original certificate authentication failure.'
            $issues[0].Message | Should -Not -Match '\$appOnly'
        }
    }

    It 'still rethrows safe-startup tenant mismatch failures from the live collector' {
        InModuleScope Agent365Preflight {
            Mock Get-Module {
                [pscustomobject]@{ Name = 'Microsoft.Graph.Authentication'; Version = [Version]'2.38.1' }
            }
            Mock Import-Module {}
            Mock Test-A365GraphEndpointReachability { $true }
            Mock Connect-A365GraphContext {
                throw (New-A365SafeStartupException -Message 'Tenant target mismatch. No report was written.')
            }
            $issues = [System.Collections.Generic.List[object]]::new()

            {
                Get-A365LiveEvidence `
                    -Profiles @('ControlPlane') `
                    -Collectors @('TenantFoundation') `
                    -Scopes @('Organization.Read.All') `
                    -SkuCatalog ([pscustomobject]@{}) `
                    -Allowlist ([pscustomobject]@{}) `
                    -Issues $issues `
                    -TenantId 'fixture.onmicrosoft.com'
            } | Should -Throw '*Tenant target mismatch*'

            $issues.Count | Should -Be 0
        }
    }

    It 'treats empty granted scopes as missing and still writes an incomplete report' {
        InModuleScope Agent365Preflight {
            Test-A365RequiredPermissionMissing `
                -RequiredPermission 'Organization.Read.All' `
                -GrantedScopes @() `
                -AuthenticationMode 'InteractiveDelegated' |
                Should -BeTrue
        }

        $fixturePath = New-SyntheticFixture -Name 'empty-granted-scopes' -Mutator {
            param($fixture)
            $fixture.authentication.grantedScopes = @()
            $fixture.collectionIssues = @(
                [pscustomobject]@{
                    Adapter = 'Graph'
                    Operation = 'Microsoft Graph authentication'
                    Category = 'Authentication'
                    StatusCode = $null
                    Message = 'Delegated authentication did not return granted scopes.'
                    RequiredPermission = 'Organization.Read.All'
                    DocsUrl = 'https://learn.microsoft.com/powershell/microsoftgraph/authentication-commands'
                }
            )
        }

        $outcome = Invoke-FixturePreflight -Name 'empty-granted-scopes-output' -FixturePath $fixturePath

        $outcome.Report.Authentication.GrantedScopes.Count | Should -Be 0
        $outcome.Report.Authentication.MissingScopes.Count | Should -BeGreaterThan 0
        ($outcome.Report.Results | Where-Object Id -eq 'A365-FOUNDATION-002').Status | Should -Be 'NotAuthorized'
        $outcome.Report.Verdict.Label | Should -Be 'Incomplete'
        $outcome.Paths.Html | Should -Exist
        $outcome.Paths.Json | Should -Exist
    }

    It 'reuses an existing delegated context with the requested tenant and all scopes' {
        InModuleScope Agent365Preflight {
            Mock Connect-MgGraph {}
            Mock Get-A365ActiveContext {
                [pscustomobject]@{
                    TenantId = '11111111-2222-3333-4444-555555555555'
                    Scopes = @('organization.read.all', 'Policy.Read.All')
                    AuthType = 'Delegated'
                    Environment = 'Global'
                    Account = 'fixture@example.invalid'
                }
            }

            $connection = Connect-A365GraphContext `
                -Scopes @('Organization.Read.All', 'Policy.Read.All') `
                -TenantId '11111111-2222-3333-4444-555555555555' `
                -ClientId $null `
                -CertificateThumbprint $null

            $connection.ReusedExistingContext | Should -BeTrue
            $connection.AppOnly | Should -BeFalse
            $connection.TargetAssertion.Matched | Should -BeTrue
            Should -Invoke Connect-MgGraph -Times 0 -Exactly
        }
    }

    It 'reconnects when the existing delegated context is missing a requested scope' {
        InModuleScope Agent365Preflight {
            Mock Connect-MgGraph {}
            $script:contextCalls = 0
            Mock Get-A365ActiveContext {
                $script:contextCalls++
                if ($script:contextCalls -eq 1) {
                    return [pscustomobject]@{
                        TenantId = '11111111-2222-3333-4444-555555555555'
                        Scopes = @('Organization.Read.All')
                        AuthType = 'Delegated'
                        Account = 'fixture@example.invalid'
                    }
                }
                return [pscustomobject]@{
                    TenantId = '11111111-2222-3333-4444-555555555555'
                    Scopes = @('Organization.Read.All', 'Policy.Read.All')
                    AuthType = 'Delegated'
                    Account = 'fixture@example.invalid'
                }
            }

            $connection = Connect-A365GraphContext `
                -Scopes @('Organization.Read.All', 'Policy.Read.All') `
                -TenantId '11111111-2222-3333-4444-555555555555' `
                -ClientId $null `
                -CertificateThumbprint $null

            $connection.ReusedExistingContext | Should -BeFalse
            Should -Invoke Connect-MgGraph -Times 1 -Exactly -ParameterFilter {
                $Scopes -contains 'Policy.Read.All'
            }
        }
    }

    It 'does not reuse an existing delegated context for the wrong requested tenant GUID' {
        InModuleScope Agent365Preflight {
            Mock Connect-MgGraph {}
            $script:contextCalls = 0
            Mock Get-A365ActiveContext {
                $script:contextCalls++
                if ($script:contextCalls -eq 1) {
                    return [pscustomobject]@{
                        TenantId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
                        Scopes = @('Organization.Read.All')
                        AuthType = 'Delegated'
                        Account = 'fixture@example.invalid'
                    }
                }
                return [pscustomobject]@{
                    TenantId = '11111111-2222-3333-4444-555555555555'
                    Scopes = @('Organization.Read.All')
                    AuthType = 'Delegated'
                    Account = 'fixture@example.invalid'
                }
            }

            $connection = Connect-A365GraphContext `
                -Scopes @('Organization.Read.All') `
                -TenantId '11111111-2222-3333-4444-555555555555' `
                -ClientId $null `
                -CertificateThumbprint $null

            $connection.ReusedExistingContext | Should -BeFalse
            $connection.TargetAssertion.Matched | Should -BeTrue
            Should -Invoke Connect-MgGraph -Times 1 -Exactly
        }
    }

    It 'does not reuse a delegated context that has no actual tenant ID' {
        InModuleScope Agent365Preflight {
            Mock Connect-MgGraph {}
            $script:contextCalls = 0
            Mock Get-A365ActiveContext {
                $script:contextCalls++
                if ($script:contextCalls -eq 1) {
                    return [pscustomobject]@{
                        TenantId = ''
                        Scopes = @('Organization.Read.All')
                        AuthType = 'Delegated'
                        Account = 'fixture@example.invalid'
                    }
                }
                return [pscustomobject]@{
                    TenantId = '11111111-2222-3333-4444-555555555555'
                    Scopes = @('Organization.Read.All')
                    AuthType = 'Delegated'
                    Account = 'fixture@example.invalid'
                }
            }

            $connection = Connect-A365GraphContext `
                -Scopes @('Organization.Read.All') `
                -TenantId '11111111-2222-3333-4444-555555555555' `
                -ClientId $null `
                -CertificateThumbprint $null

            $connection.ReusedExistingContext | Should -BeFalse
            Should -Invoke Connect-MgGraph -Times 1 -Exactly
        }
    }

    It 'reuses a delegated domain context only after the organization assertion succeeds' {
        InModuleScope Agent365Preflight {
            Mock Connect-MgGraph {}
            Mock Get-A365ActiveContext {
                [pscustomobject]@{
                    TenantId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
                    Scopes = @('Organization.Read.All')
                    AuthType = 'Delegated'
                    Account = 'fixture@example.invalid'
                }
            }
            Mock Invoke-A365GraphRequest {
                [pscustomobject]@{
                    value = @(
                        [pscustomobject]@{
                            id = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
                            verifiedDomains = @(
                                [pscustomobject]@{ name = 'fixture.onmicrosoft.com'; isDefault = $true }
                            )
                        }
                    )
                }
            }

            $connection = Connect-A365GraphContext `
                -Scopes @('Organization.Read.All') `
                -TenantId 'fixture.onmicrosoft.com' `
                -ClientId $null `
                -CertificateThumbprint $null
            $organization = Get-A365OrganizationContext `
                -Allowlist ([pscustomobject]@{}) `
                -TargetAssertion $connection.TargetAssertion

            $connection.ReusedExistingContext | Should -BeTrue
            $organization.TargetAssertion.Matched | Should -BeTrue
            Should -Invoke Connect-MgGraph -Times 0 -Exactly
            Should -Invoke Invoke-A365GraphRequest -Times 1 -Exactly -ParameterFilter {
                $Uri -match '/v1\.0/organization'
            }
        }
    }

    It 'never reuses an app-only context for a delegated run' {
        InModuleScope Agent365Preflight {
            Mock Connect-MgGraph {}
            $script:contextCalls = 0
            Mock Get-A365ActiveContext {
                $script:contextCalls++
                if ($script:contextCalls -eq 1) {
                    return [pscustomobject]@{
                        TenantId = '11111111-2222-3333-4444-555555555555'
                        Scopes = @('Organization.Read.All')
                        AuthType = 'AppOnly'
                        Account = $null
                    }
                }
                return [pscustomobject]@{
                    TenantId = '11111111-2222-3333-4444-555555555555'
                    Scopes = @('Organization.Read.All')
                    AuthType = 'Delegated'
                    Account = 'fixture@example.invalid'
                }
            }

            $connection = Connect-A365GraphContext `
                -Scopes @('Organization.Read.All') `
                -TenantId '11111111-2222-3333-4444-555555555555' `
                -ClientId $null `
                -CertificateThumbprint $null

            $connection.ReusedExistingContext | Should -BeFalse
            $connection.AppOnly | Should -BeFalse
            Should -Invoke Connect-MgGraph -Times 1 -Exactly
        }
    }

    It 'never reuses a delegated context for an app-only run' {
        InModuleScope Agent365Preflight {
            Mock Connect-MgGraph {}
            $script:contextCalls = 0
            Mock Get-A365ActiveContext {
                $script:contextCalls++
                if ($script:contextCalls -eq 1) {
                    return [pscustomobject]@{
                        TenantId = '11111111-2222-3333-4444-555555555555'
                        Scopes = @('Organization.Read.All')
                        AuthType = 'Delegated'
                        Account = 'fixture@example.invalid'
                    }
                }
                return [pscustomobject]@{
                    TenantId = '11111111-2222-3333-4444-555555555555'
                    Scopes = @()
                    AuthType = 'AppOnly'
                    Account = $null
                }
            }

            $connection = Connect-A365GraphContext `
                -Scopes @('Organization.Read.All') `
                -TenantId '11111111-2222-3333-4444-555555555555' `
                -ClientId 'client-id' `
                -CertificateThumbprint 'thumbprint'

            $connection.ReusedExistingContext | Should -BeFalse
            $connection.AppOnly | Should -BeTrue
            Should -Invoke Connect-MgGraph -Times 1 -Exactly -ParameterFilter {
                $ClientId -eq 'client-id' -and $CertificateThumbprint -eq 'thumbprint'
            }
        }
    }

    It 'passes UseDeviceCode only to a new delegated connection' {
        InModuleScope Agent365Preflight {
            Mock Connect-MgGraph {}
            $script:contextCalls = 0
            Mock Get-A365ActiveContext {
                $script:contextCalls++
                if ($script:contextCalls -eq 1) {
                    return $null
                }
                return [pscustomobject]@{
                    TenantId = '11111111-2222-3333-4444-555555555555'
                    Scopes = @('Organization.Read.All')
                    AuthType = 'Delegated'
                    Account = 'fixture@example.invalid'
                }
            }

            $connection = Connect-A365GraphContext `
                -Scopes @('Organization.Read.All') `
                -TenantId '11111111-2222-3333-4444-555555555555' `
                -ClientId $null `
                -CertificateThumbprint $null `
                -UseDeviceCode

            $connection.UseDeviceCode | Should -BeTrue
            Should -Invoke Connect-MgGraph -Times 1 -Exactly -ParameterFilter {
                $UseDeviceCode -eq $true -and -not $ClientId -and -not $CertificateThumbprint
            }
        }

    }

    It 'rejects UseDeviceCode with certificate app-only authentication before connect' {
        InModuleScope Agent365Preflight {
            Mock Connect-MgGraph {}

            {
                Connect-A365GraphContext `
                    -Scopes @('Organization.Read.All') `
                    -TenantId '11111111-2222-3333-4444-555555555555' `
                    -ClientId 'client-id' `
                    -CertificateThumbprint 'thumbprint' `
                    -UseDeviceCode
            } | Should -Throw '*cannot be combined with certificate app-only*'

            Should -Invoke Connect-MgGraph -Times 0 -Exactly
        }
    }
}

Describe 'Operation safety allowlists' {
    It 'allows only approved Graph read and query operations' {
        Test-Agent365OperationAllowed -Adapter Graph -Method GET -Target 'https://graph.microsoft.com/v1.0/copilot/admin/catalog/packages?$top=10' | Should -Be $true
        Test-Agent365OperationAllowed -Adapter Graph -Method POST -Target 'https://graph.microsoft.com/v1.0/security/runHuntingQuery' | Should -Be $true
        Test-Agent365OperationAllowed -Adapter Graph -Method POST -Target 'https://graph.microsoft.com/v1.0/applications' | Should -Be $false
        Test-Agent365OperationAllowed -Adapter Graph -Method DELETE -Target 'https://graph.microsoft.com/v1.0/applications/00000000-0000-0000-0000-000000000000' | Should -Be $false
        Test-Agent365OperationAllowed -Adapter Graph -Method GET -Target 'https://graph.microsoft.com/v1.0/applications/00000000-0000-0000-0000-000000000000/microsoft.graph.agentIdentityBlueprint/owners' | Should -Be $true
        Test-Agent365OperationAllowed -Adapter Graph -Method GET -Target 'https://graph.microsoft.com/v1.0/applications/00000000-0000-0000-0000-000000000000/owners' | Should -Be $false
    }

    It 'does not allow configuration module commands' {
        Test-Agent365OperationAllowed -Adapter ExchangeOnlineManagement -Method COMMAND -Target 'Search-UnifiedAuditLog' | Should -Be $true
        Test-Agent365OperationAllowed -Adapter ExchangeOnlineManagement -Method COMMAND -Target 'Set-DlpCompliancePolicy' | Should -Be $false
        Test-Agent365OperationAllowed -Adapter 'Microsoft.Online.SharePoint.PowerShell' -Method COMMAND -Target 'Remove-SPOSite' | Should -Be $false

        $allowlistText = Get-Content -LiteralPath $allowlistPath -Raw
        $allowlistText | Should -Not -Match '"(Set|New|Remove|Add|Update)-'
    }

    It 'allowlists the unauthenticated metadata reachability probe' {
        Test-Agent365OperationAllowed -Adapter Graph -Method GET -Target 'https://graph.microsoft.com/v1.0/$metadata' | Should -Be $true

        $moduleText = Get-Content -LiteralPath (Join-Path $resourceRoot 'Agent365Preflight.psm1') -Raw
        $moduleText | Should -Not -Match 'SkipHttpErrorCheck'
    }

    It 'uses the least-privileged blueprint owner endpoint and correct package API roles' {
        $moduleText = Get-Content -LiteralPath (Join-Path $resourceRoot 'Agent365Preflight.psm1') -Raw
        $rules = Get-Content -LiteralPath (Join-Path $resourceRoot 'config\rules.v1.json') -Raw | ConvertFrom-Json -Depth 100
        $ownerRule = $rules.checks | Where-Object id -eq 'A365-ENTRA-002'
        $registryRule = $rules.checks | Where-Object id -eq 'A365-REGISTRY-001'

        $moduleText | Should -Match 'microsoft\.graph\.agentIdentityBlueprint/owners'
        $moduleText | Should -Not -Match 'applications/\$blueprintId/owners'
        $ownerRule.requiredPermission | Should -Be 'AgentIdentityBlueprint.Read.All'
        $registryRule.requiredRole | Should -Be 'AI Administrator or Global Administrator'
    }
}

Describe 'Report comparison, redaction, and rendering' {
    It 'finds regressions and resolved blockers by result ID' {
        $previous = [pscustomobject]@{
            GeneratedAtUtc = '2026-08-01T00:00:00Z'
            Results = @(
                [pscustomobject]@{ Id = 'A365-ONE-001'; Title = 'One'; Status = 'Passed' },
                [pscustomobject]@{ Id = 'A365-TWO-002'; Title = 'Two'; Status = 'Blocker' }
            )
        }
        $current = [pscustomobject]@{
            Results = @(
                [pscustomobject]@{ Id = 'A365-ONE-001'; Title = 'One'; Status = 'ActionRequired' },
                [pscustomobject]@{ Id = 'A365-TWO-002'; Title = 'Two'; Status = 'Passed' }
            )
        }

        $drift = Compare-Agent365PreflightResult -Current $current -Previous $previous

        $drift.Regressions.Count | Should -Be 1
        $drift.ResolvedBlockers.Count | Should -Be 1
        $drift.Changed.Count | Should -Be 2
    }

    It 'redacts tenant identity, email, identifiers, paths, and sensitive details' {
        $outcome = Invoke-FixturePreflight -Name 'redaction-source'
        $outcome.Report.Tenant.TargetAssertion.Requested = $true
        $outcome.Report.Tenant.TargetAssertion.Expected = 'contoso.onmicrosoft.com'
        $outcome.Report.Tenant.TargetAssertion.Method = 'VerifiedDomain'
        $outcome.Report.Tenant.TargetAssertion.Matched = $true
        $outcome.Report.Tenant.TargetAssertion.ActualTenantId = '11111111-2222-3333-4444-555555555555'
        $outcome.Report.Tenant.TargetAssertion.MatchedVerifiedDomain = 'contoso.onmicrosoft.com'
        $outcome.Report.CollectionIssues = @(
            [pscustomobject]@{
                Adapter = 'Graph'
                Operation = 'Read for admin@contoso.com'
                Category = 'Api'
                StatusCode = 500
                Message = 'Failure for admin@contoso.com tenant 11111111-2222-3333-4444-555555555555 at C:\Secret\file.txt'
                RequiredPermission = 'User.Read.All'
                DocsUrl = 'https://learn.microsoft.com/graph/'
            }
        )

        $sanitized = New-Agent365SanitizedReport -Report $outcome.Report
        $text = $sanitized | ConvertTo-Json -Depth 100

        $sanitized.Tenant.DisplayName | Should -Be 'Redacted tenant'
        $sanitized.Tenant.TenantId | Should -BeNullOrEmpty
        $sanitized.Tenant.TargetAssertion.Expected | Should -Be 'Redacted'
        $sanitized.Tenant.TargetAssertion.ActualTenantId | Should -BeNullOrEmpty
        $sanitized.Tenant.TargetAssertion.MatchedVerifiedDomain | Should -BeNullOrEmpty
        $text | Should -Not -Match 'admin@contoso.com'
        $text | Should -Not -Match '11111111-2222-3333-4444-555555555555'
        $text | Should -Not -Match 'C:\\Secret'
        ($sanitized.Results | Where-Object IsSensitive -eq $true | Select-Object -First 1).Details | Should -BeNullOrEmpty
    }

    It 'generates self-contained HTML and a schema-valid JSON sidecar' {
        $outcome = Invoke-FixturePreflight -Name 'render' -Profile @('ControlPlane', 'SharePointAgents', 'Foundry')
        $html = Get-Content -LiteralPath $outcome.Paths.Html -Raw
        $json = Get-Content -LiteralPath $outcome.Paths.Json -Raw

        $html | Should -Match '<!DOCTYPE html>'
        $html | Should -Match 'not a security or compliance certification'
        $html | Should -Match 'Tenant target'
        $html | Should -Match 'Not explicitly pinned'
        $html | Should -Not -Match '<link[^>]+stylesheet'
        $html | Should -Not -Match '<script[^>]+src='
        $outcome.Report.SchemaVersion | Should -Be '1.3'
        $outcome.Report.GuidanceVersion | Should -Be '1.0.0'
        $outcome.Report.ReportId | Should -Match '^Agent365Preflight-\d{8}-\d{6}$'
        $outcome.Report.Resume.AnswerFileName | Should -Be "$($outcome.Report.ReportId)-answers.json"
        $outcome.Paths.Resume | Should -Exist
        $json | Test-Json -SchemaFile $reportSchemaPath | Should -Be $true
    }

    It 'generates a path-safe secret-free resume helper and sanitized placeholders' {
        $outputPath = Join-Path $TestDrive "customer's output; Write-Host injected"
        $outcome = Invoke-Agent365Preflight `
            -FixturePath $readyFixturePath `
            -OutputPath $outputPath `
            -IncludeSanitizedCopy
        $resumeText = Get-Content -LiteralPath $outcome.Paths.Resume -Raw
        $sanitized = Get-Content -LiteralPath $outcome.Paths.SanitizedJson -Raw | ConvertFrom-Json -Depth 100

        $resumeText | Should -Match 'Start-Agent365Preflight\.ps1'
        $resumeText | Should -Match "customer''s output; Write-Host injected"
        $resumeText | Should -Not -Match '\bInvoke-Expression\b|\biex\b|ClientSecret|Bearer|[A-Fa-f0-9]{40}'
        $outcome.Report.Resume.Command | Should -Match "^& '.*Resume-Agent365Preflight\.ps1'$"
        $outcome.Report.Resume.AnswerFileName | Should -Be "$($outcome.Report.ReportId)-answers.json"
        $outcome.Report.Rerun.AnswersPath | Should -Match ([regex]::Escape($outcome.Report.Resume.AnswerFileName))
        $sanitized.Resume.Available | Should -BeFalse
        $sanitized.Resume.Command | Should -Be "& '<output-folder>\Resume-Agent365Preflight.ps1'"
        $sanitized.Resume.ScriptPath | Should -Not -Match [regex]::Escape($TestDrive)
        ($sanitized.Resume.AnswerSearchPaths -join ' ') | Should -Not -Match [regex]::Escape($TestDrive)
    }

    It 'never derives the sanitized rerun entry path from an apostrophe-containing real path' {
        InModuleScope Agent365Preflight {
            $metadata = New-A365RerunMetadata `
                -Stage Pilot `
                -Profiles @('ControlPlane') `
                -Collectors @('TenantFoundation') `
                -AuditWindowDays 7 `
                -AuditQueryTimeoutSeconds 300 `
                -TenantId 'contoso.onmicrosoft.com' `
                -CurrentJsonPath "C:\O'Brien\report.json" `
                -EntryScriptPath "C:\O'Brien\Invoke-Agent365Preflight.ps1" `
                -AnswerPath "C:\O'Brien\report-answers.json" `
                -OutputPath "C:\O'Brien" `
                -IncludeSanitizedCopy $true `
                -UseDeviceCode $false

            $metadata.Command | Should -Match "C:\\O''Brien\\Invoke-Agent365Preflight\.ps1"
            $metadata.SanitizedCommand | Should -Match "<resource-folder>\\Invoke-Agent365Preflight\.ps1"
            $metadata.SanitizedCommand | Should -Not -Match "O''Brien|C:\\"
        }
    }

    It 'accepts report schema 1.0 through 1.3 baselines' {
        $current = Invoke-FixturePreflight -Name 'schema-1-3-baseline'
        $currentComparison = Invoke-FixturePreflight -Name 'schema-1-3-current' -PreviousResultPath $current.Paths.Json
        $legacy = Get-Content -LiteralPath $current.Paths.Json -Raw | ConvertFrom-Json -Depth 100
        $legacy.SchemaVersion = '1.0'
        $legacyPath = Join-Path $TestDrive 'schema-1-0-baseline.json'
        [System.IO.File]::WriteAllText(
            $legacyPath,
            ($legacy | ConvertTo-Json -Depth 100),
            [System.Text.UTF8Encoding]::new($false)
        )
        $legacyComparison = Invoke-FixturePreflight -Name 'schema-1-0-current' -PreviousResultPath $legacyPath
        $prior = Get-Content -LiteralPath $current.Paths.Json -Raw | ConvertFrom-Json -Depth 100
        $prior.SchemaVersion = '1.1'
        $priorPath = Join-Path $TestDrive 'schema-1-1-baseline.json'
        [System.IO.File]::WriteAllText(
            $priorPath,
            ($prior | ConvertTo-Json -Depth 100),
            [System.Text.UTF8Encoding]::new($false)
        )
        $priorComparison = Invoke-FixturePreflight -Name 'schema-1-1-current' -PreviousResultPath $priorPath
        $priorTwo = Get-Content -LiteralPath $current.Paths.Json -Raw | ConvertFrom-Json -Depth 100
        $priorTwo.SchemaVersion = '1.2'
        $priorTwoPath = Join-Path $TestDrive 'schema-1-2-baseline.json'
        [System.IO.File]::WriteAllText(
            $priorTwoPath,
            ($priorTwo | ConvertTo-Json -Depth 100),
            [System.Text.UTF8Encoding]::new($false)
        )
        $priorTwoComparison = Invoke-FixturePreflight -Name 'schema-1-2-current' -PreviousResultPath $priorTwoPath

        $currentComparison.Report.Drift.HasBaseline | Should -BeTrue
        $legacyComparison.Report.Drift.HasBaseline | Should -BeTrue
        $priorComparison.Report.Drift.HasBaseline | Should -BeTrue
        $priorTwoComparison.Report.Drift.HasBaseline | Should -BeTrue
    }

    It 'renders the complete accessible interactive findings contract' {
        $outcome = Invoke-FixturePreflight -Name 'interactive-contract' -Profile @('ControlPlane', 'SharePointAgents', 'Foundry')
        $html = Get-Content -LiteralPath $outcome.Paths.Html -Raw
        $requiredHooks = @(
            'id="resultSearch"',
            'id="clearSearch"',
            'id="filterStatus"',
            'data-status-filter="all"',
            'data-status-filter="Blocker"',
            'data-status-filter="ActionRequired"',
            'data-status-filter="ManualValidation"',
            'data-status-filter="autherror"',
            'data-status-filter="Advisory"',
            'data-status-filter="Passed"',
            'id="advancedFiltersToggle"',
            'id="pillarFilter"',
            'id="areaFilter"',
            'id="profileFilter"',
            'id="resetFilters"',
            'id="filterResultCount"',
            'aria-live="polite"',
            'data-result-group',
            'data-result-card',
            'data-result-search',
            'data-view-details',
            'id="detailBlade"',
            'id="detailBackdrop"',
            'id="detailClose"',
            'role="dialog"',
            'aria-modal="true"',
            'data-result-full'
        )

        foreach ($hook in $requiredHooks) {
            $html.Contains($hook) | Should -Be $true
        }

        ([regex]::Matches($html, '<article class="finding [^"]+" data-result-card')).Count | Should -Be $outcome.Report.Results.Count
        ([regex]::Matches($html, '<div class="finding-full" data-result-full>')).Count | Should -Be $outcome.Report.Results.Count
        $html | Should -Match '@media print'
        $html | Should -Match '\.finding-full \{ display: block !important; \}'
        $html | Should -Not -Match '\beval\s*\('
        $html | Should -Not -Match '\.innerHTML\s*='
        $html | Should -Match '\.textContent\s*='
        $html | Should -Match 'cloneNode\(true\)'
        $html | Should -Match 'function focusBladeClose\('
        $html | Should -Match 'requestAnimationFrame\(function \(\) \{ requestAnimationFrame\(run\); \}\)'
        $html | Should -Match 'setTimeout\(run, 60\)'
        $html | Should -Match 'var printExpanded = false;'
        $html | Should -Match 'if \(printExpanded\) \{ return; \}'
        $html | Should -Match 'if \(!printExpanded\) \{ return; \}'
        $html | Should -Match 'prefers-reduced-motion'
        $html | Should -Match 'function bindExpanded\('
        $html | Should -Match '<summary aria-controls="area-[^"]+-body">'
        $html | Should -Match '<div class="finding-group-body" id="area-[^"]+-body">'
        $html | Should -Match '\.filter-pill \{[\s\S]*?min-height: 40px;'
        $html | Should -Match '\.advanced > summary \{[\s\S]*?min-height: 40px;'
        $html | Should -Match '\.grid > \* \{ min-width: 0; \}'
    }

    It 'renders the remediation workspace, answers builder, and rerun tools safely' {
        $fixturePath = New-SyntheticFixture -Name 'remediation-workspace' -Mutator {
            param($fixture)
            $fixture.licensing.qualifyingAssignedUsers = 0
            $fixture.licensing.unknownSkuMappings = @('AGENT_365_FUTURE')
        }
        $outcome = Invoke-FixturePreflight -Name 'remediation-workspace-output' -FixturePath $fixturePath -Profile @('CopilotStudio')
        $html = Get-Content -LiteralPath $outcome.Paths.Html -Raw
        $hooks = @(
            'id="commandCenter"',
            'id="openPathToReady"',
            'id="workspaceNav"',
            'id="pathToReady"',
            'data-path-item',
            'data-local-complete',
            'id="localProgressNotice"',
            'id="resetLocalProgress"',
            'id="answersBuilder"',
            'data-answer-gate',
            'data-answer-value',
            'data-answer-owner',
            'data-answer-reference',
            'data-answer-notes',
            'id="downloadAnswers"',
            'id="answersFeedback"',
            'id="rerunCommand"',
            'id="copyRerunCommand"',
            'id="downloadRemediation"',
            'id="rerunFeedback"',
            'id="evidenceRerun"'
        )

        foreach ($hook in $hooks) {
            $html.Contains($hook) | Should -BeTrue
        }

        $html | Should -Match 'Local check marks never change the verdict'
        $html | Should -Match 'schemaVersion: "1\.1"'
        $html | Should -Match 'new Blob'
        $html | Should -Match 'createObjectURL'
        $html | Should -Not -Match '\beval\s*\('
        $html | Should -Not -Match '\.innerHTML\s*='
        $html | Should -Not -Match 'fetch\s*\('
        $html | Should -Not -Match 'localStorage\.setItem\([^,\r\n]*(owner|reference|notes|answer)'
        $html | Should -Match '\.theme-toggle \{[\s\S]*?min-height: 40px;'
        $html | Should -Match '\.search-clear \{[\s\S]*?width: 40px; height: 40px;'
        ([regex]::Matches($html, 'data-answer-gate="')).Count | Should -Be $outcome.Report.ManuallyAttestableGates.Count
        $html | Should -Match ('data-answer-filename="' + [regex]::Escape($outcome.Report.Resume.AnswerFileName) + '"')
        $html | Should -Match 'Full local working report'
        $html | Should -Match 'id="whatNext"'
        $html | Should -Match 'Start remediation'
        $html | Should -Match 'id="resumeCommand"'
        $html | Should -Match 'id="copyResumeCommand"'
        $html | Should -Match 'Advanced rerun command'
        $html | Should -Match 'Answers download started\. Next: run Resume-Agent365Preflight\.ps1 from the output folder\.'
    }

    It 'renders canonical guidance for search, dialog, no-JavaScript, print, and checklist workflows' {
        $profiles = @(
            'ControlPlane', 'CopilotStudio', 'AgentBuilder', 'SharePointAgents', 'Foundry',
            'CustomProCode', 'ExternalRegistrySync', 'LocalAgents', 'WorkIQ', 'AITeammate'
        )
        $outcome = Invoke-FixturePreflight -Name 'guided-answers-workspace' -Profile $profiles
        $html = Get-Content -LiteralPath $outcome.Paths.Html -Raw
        $gateCount = $outcome.Report.ManuallyAttestableGates.Count
        $hooks = @(
            'data-guidance-open',
            'data-guidance-appendix',
            'data-guidance-doc',
            'id="guidanceBackdrop"',
            'id="guidanceDialog"',
            'aria-labelledby="guidanceTitle"',
            'aria-describedby="guidanceBody"',
            'id="guidanceClose"',
            'id="guidanceBack"',
            'id="guidanceCopy"',
            'id="guidanceCopyFeedback"',
            'Back to answer',
            'Copy evidence checklist',
            'What the scan observed',
            'What you are confirming',
            'Why this matters',
            'Who should confirm it',
            'Answer Yes when',
            'Evidence to retain',
            'How to verify',
            'If the answer is No',
            'When Not applicable is valid',
            'Public sources'
        )

        foreach ($hook in $hooks) {
            $html.Contains($hook) | Should -BeTrue
        }

        ([regex]::Matches($html, 'data-guidance-open="')).Count | Should -Be $gateCount
        ([regex]::Matches($html, '<details class="guidance-doc" data-guidance-doc')).Count | Should -Be $gateCount
        $html | Should -Match 'on-behalf-of \(OBO\)'
        $html | Should -Match 'data-result-search="[^"]*incident response'
        $html | Should -Match 'var payload = \{ schemaVersion: "1\.1", answers: res\.items \};'
        $html | Should -Match 'lines\.push\("  - Acceptance criteria:"\)'
        $html | Should -Match 'lines\.push\("  - Evidence to retain:"\)'
        $html | Should -Match '@media print[\s\S]*?\.guidance-doc'
        $html | Should -Match 'function closeGuidance\(\)[\s\S]*?radio\.focus\(\)'
        $html | Should -Not -Match 'function closeGuidance\(\)[\s\S]{0,1200}?radio\.click\(\)'
        $html | Should -Not -Match 'localStorage\.setItem\([^,\r\n]*guidance'
    }

    It 'keeps interactive hooks feature-identical in sanitized reports' {
        $outcome = Invoke-FixturePreflight -Name 'sanitized-interactive'
        $full = Get-Content -LiteralPath $outcome.Paths.Html -Raw
        $sanitized = Get-Content -LiteralPath $outcome.Paths.SanitizedHtml -Raw
        $hooks = @(
            'resultSearch', 'filterStatus', 'advancedFiltersToggle', 'detailBlade',
            'data-result-card', 'guidanceDialog', 'data-guidance-open', 'data-guidance-doc'
        )

        foreach ($hook in $hooks) {
            $full.Contains($hook) | Should -Be $true
            $sanitized.Contains($hook) | Should -Be $true
        }
        $full | Should -Match 'Full local working report'
        $sanitized | Should -Match 'Sanitized sharing copy'
        $sanitized | Should -Match 'Do not use this copy to complete remediation\. Open the full local report generated alongside it\.'
        $sanitized | Should -Not -Match ([regex]::Escape($outcome.Report.Resume.ScriptPath))
    }

    It 'HTML-encodes untrusted collection errors inside searchable finding attributes' {
        $fixturePath = New-SyntheticFixture -Name 'interactive-encoding' -Mutator {
            param($fixture)
            $fixture.registry.available = $false
            $fixture.collectionIssues = @(
                [pscustomobject]@{
                    Adapter = 'Graph'
                    Operation = 'Agent package catalog'
                    Category = 'PermissionOrRole'
                    StatusCode = 403
                    Message = '<img src=x onerror=alert(1)> " onfocus="alert(2)'
                    RequiredPermission = 'CopilotPackages.Read.All'
                    DocsUrl = 'https://learn.microsoft.com/microsoft-365/copilot/extensibility/api/admin-settings/package/copilotpackages-list'
                }
            )
        }

        $outcome = Invoke-FixturePreflight -Name 'interactive-encoding-output' -FixturePath $fixturePath
        $html = Get-Content -LiteralPath $outcome.Paths.Html -Raw

        $html | Should -Not -Match '<img src=x'
        $html | Should -Match '&lt;img src=x onerror=alert\(1\)&gt;'
        $html | Should -Not -Match 'data-result-search="[^"]*" onfocus='
    }

    It 'keeps default single-item Profiles and Collectors schema-valid arrays' {
        $outputPath = Join-Path $TestDrive 'default-array-shape'
        $outcome = Invoke-Agent365Preflight `
            -FixturePath $readyFixturePath `
            -AnswersPath $answersPath `
            -Collector TenantFoundation `
            -OutputPath $outputPath
        $json = Get-Content -LiteralPath $outcome.Paths.Json -Raw
        $parsed = $json | ConvertFrom-Json -Depth 100

        $parsed.Profiles.GetType().IsArray | Should -Be $true
        $parsed.Collectors.GetType().IsArray | Should -Be $true
        $json | Test-Json -SchemaFile $reportSchemaPath | Should -Be $true
    }

    It 'HTML-encodes fixture-derived content' {
        $fixturePath = New-SyntheticFixture -Name 'html-encoding' -Mutator {
            param($fixture)
            $fixture.tenant.displayName = '<script>alert("fixture")</script>'
        }

        $outcome = Invoke-FixturePreflight -Name 'html-encoding-output' -FixturePath $fixturePath
        $html = Get-Content -LiteralPath $outcome.Paths.Html -Raw

        $html | Should -Not -Match '<script>alert\\("fixture"\\)</script>'
        $html | Should -Match '&lt;script&gt;'
    }

    It 'includes all required evidence fields on every result' {
        $outcome = Invoke-FixturePreflight -Name 'result-shape'
        $required = @(
            'Id', 'Pillar', 'Applicability', 'Status', 'Expected', 'Observed',
            'EvidenceMethod', 'EvidenceTimeUtc', 'RequiredPermission', 'RequiredRole',
            'Remediation', 'DocsUrl', 'RuleReviewDate'
        )

        foreach ($result in $outcome.Report.Results) {
            foreach ($property in $required) {
                ($result.PSObject.Properties.Name -contains $property) | Should -Be $true
            }
        }
        ($outcome.Report.Profiles -contains 'ControlPlane') | Should -Be $true
    }

    It 'uses AgentsInfo and never the retired AIAgentsInfo table' {
        $moduleText = Get-Content -LiteralPath (Join-Path $resourceRoot 'Agent365Preflight.psm1') -Raw

        $moduleText | Should -Match "AgentsInfo \| summarize"
        $moduleText | Should -Not -Match '\bAIAgentsInfo\b'
    }

    It 'compares a previous generated report during a fixture run' {
        $baseline = Invoke-FixturePreflight -Name 'baseline'
        $changedFixture = New-SyntheticFixture -Name 'changed-baseline' -Mutator {
            param($fixture)
            $fixture.agentIdentity.missingOwnerCount = 2
        }
        $current = Invoke-FixturePreflight -Name 'current' -FixturePath $changedFixture -PreviousResultPath $baseline.Paths.Json

        $current.Report.Drift.HasBaseline | Should -Be $true
        $current.Report.Drift.Regressions.Count | Should -BeGreaterThan 0
    }
}

Describe 'Invalid fixture input' {
    It 'rejects malformed JSON as invalid execution input' {
        $badPath = Join-Path $TestDrive 'bad.json'
        [System.IO.File]::WriteAllText($badPath, '{not-json', [System.Text.UTF8Encoding]::new($false))

        $threw = $false
        try {
            $null = Invoke-Agent365Preflight -FixturePath $badPath -OutputPath (Join-Path $TestDrive 'bad-output')
        }
        catch {
            $threw = $true
        }

        $threw | Should -Be $true
    }
}
