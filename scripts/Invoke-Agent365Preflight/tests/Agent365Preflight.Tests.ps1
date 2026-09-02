BeforeAll {
$resourceRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $resourceRoot 'Agent365Preflight.psd1'
$readyFixturePath = Join-Path $resourceRoot 'fixtures\commercial-ready.json'
$answersPath = Join-Path $resourceRoot 'samples\answers.sample.json'
$reportSchemaPath = Join-Path $resourceRoot 'schema\agent365-preflight-report.schema.json'
$allowlistPath = Join-Path $resourceRoot 'config\operation-allowlist.v1.json'

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
        ($outcome.Report.Results | Where-Object Id -eq 'A365-ENTRA-005').Status | Should -Be 'ManualValidation'
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
            Mock Get-A365ActiveContext {
                [pscustomobject]@{
                    TenantId = $ExpectedTenant.ToUpperInvariant()
                    Scopes = @('Organization.Read.All')
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
            Mock Get-A365ActiveContext {
                [pscustomobject]@{
                    TenantId = $ActualTenant
                    Scopes = @('Organization.Read.All')
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
        $json | Test-Json -SchemaFile $reportSchemaPath | Should -Be $true
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

    It 'keeps interactive hooks feature-identical in sanitized reports' {
        $outcome = Invoke-FixturePreflight -Name 'sanitized-interactive'
        $full = Get-Content -LiteralPath $outcome.Paths.Html -Raw
        $sanitized = Get-Content -LiteralPath $outcome.Paths.SanitizedHtml -Raw
        $hooks = @('resultSearch', 'filterStatus', 'advancedFiltersToggle', 'detailBlade', 'data-result-card')

        foreach ($hook in $hooks) {
            $full.Contains($hook) | Should -Be $true
            $sanitized.Contains($hook) | Should -Be $true
        }
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
