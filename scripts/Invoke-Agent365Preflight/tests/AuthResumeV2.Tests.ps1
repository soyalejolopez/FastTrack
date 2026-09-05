BeforeAll {
    $authRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $authRoot 'Agent365Preflight.psd1') -Force
    Import-Module Microsoft.Graph.Authentication -MinimumVersion 2.20.0
    . (Join-Path $authRoot 'Start-Agent365Preflight.ps1')
}

Describe 'Explicit authentication and resume boundaries v2' {
    It 'uses a distinct custom delegated client without selecting certificate authentication' {
        InModuleScope Agent365Preflight {
            Mock Connect-MgGraph {}
            $script:authCalls = 0
            Mock Get-A365ActiveContext {
                $script:authCalls++
                if ($script:authCalls -eq 1) { return $null }
                [pscustomobject]@{
                    ClientId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
                    TenantId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
                    ContextScope = 'Process'; Environment = 'Global'; AuthType = 'Delegated'
                    Account = 'synthetic@example.invalid'; Scopes = @('Organization.Read.All')
                }
            }
            $connection = Connect-A365GraphContext -Scopes Organization.Read.All -TenantId 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb' -DelegatedClientId 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
            $connection.AppOnly | Should -BeFalse
            Should -Invoke Connect-MgGraph -Times 1 -Exactly -ParameterFilter { $ClientId -eq 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' -and -not $CertificateThumbprint }
        }
    }
    It 'rejects mixing delegated and certificate application parameters before authentication' {
        InModuleScope Agent365Preflight {
            Mock Connect-MgGraph {}
            { Connect-A365GraphContext -Scopes Organization.Read.All -TenantId fixture -ClientId application -CertificateThumbprint synthetic -DelegatedClientId delegated } | Should -Throw '*cannot be combined*'
            Should -Invoke Connect-MgGraph -Times 0 -Exactly
        }
    }
    It 'does not reuse a different client or persistent context for an isolated delegated run' {
        InModuleScope Agent365Preflight {
            $context = [pscustomobject]@{
                ClientId = 'one'; TenantId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
                ContextScope = 'Process'; Environment = 'Global'; AuthType = 'Delegated'
                Account = 'synthetic@example.invalid'; Scopes = @('Organization.Read.All')
            }
            (Test-A365ReusableDelegatedContext -Context $context -Scopes Organization.Read.All -DelegatedClientId two) | Should -BeFalse
            $context.ContextScope = 'CurrentUser'
            (Test-A365ReusableDelegatedContext -Context $context -Scopes Organization.Read.All -DelegatedClientId one) | Should -BeFalse
        }
    }
    It 'keeps certificate details out of reports and requires resupply on app-only resume' {
        $out = Invoke-Agent365Preflight -FixturePath (Join-Path $authRoot 'fixtures\commercial-ready.json') -Profile SharePointAgents -SharePointSiteUrl 'https://example.sharepoint.com/sites/pilot' -ClientId 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' -CertificateThumbprint 'SYNTHETIC-NOT-A-CERTIFICATE' -OutputPath (Join-Path $TestDrive 'certificate-fixture')
        (Get-Content -LiteralPath $out.Paths.Json -Raw) | Should -Not -Match 'SYNTHETIC-NOT-A-CERTIFICATE'
        $plan = Get-A365ResumePlan -PreviousResultPath $out.Paths.Json -AutomatedOnly -NonInteractive
        $plan.AuthenticationMode | Should -Be CertificateAppOnly
        $plan.TargetSites | Should -Be @('https://example.sharepoint.com/sites/pilot')
        Mock Invoke-A365LauncherAuthentication { throw 'Must not authenticate for this offline test' }
        { Invoke-A365CustomerJourney -Mode Resume -PreviousResultPath $out.Paths.Json -AutomatedOnly -NonInteractive -OpenReport Never } | Should -Throw '*securely re-supplied*'
        { Invoke-A365CustomerJourney -Mode Resume -PreviousResultPath $out.Paths.Json -AutomatedOnly -NonInteractive -OpenReport Never -UseDeviceCode } | Should -Throw '*cannot switch*'
        Should -Invoke Invoke-A365LauncherAuthentication -Times 0 -Exactly
    }
    It 'blocks unsupported cloud selection before local reachability or authentication' {
        Mock Get-A365LauncherEnvironment { throw 'No environment probe expected' }
        { Invoke-A365CustomerJourney -Mode Recommended -Cloud USGov -TenantId 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb' -NonInteractive } | Should -Throw '*Commercial cloud only*'
        Should -Invoke Get-A365LauncherEnvironment -Times 0 -Exactly
    }
    It 'retains an old report-specific helper when a newer run updates the latest helper' {
        $folder = Join-Path $TestDrive 'immutable-resume'
        $first = Invoke-Agent365Preflight -FixturePath (Join-Path $authRoot 'fixtures\commercial-ready.json') -OutputPath $folder -UseDeviceCode
        $before = (Get-FileHash -LiteralPath $first.Paths.Resume).Hash
        $second = Invoke-Agent365Preflight -FixturePath (Join-Path $authRoot 'fixtures\commercial-ready.json') -OutputPath $folder
        (Get-FileHash -LiteralPath $first.Paths.Resume).Hash | Should -Be $before
        $second.Paths.Resume | Should -Not -Be $first.Paths.Resume
        (Get-Content -LiteralPath $first.Paths.Resume -Raw) | Should -Match '\$parameters.UseDeviceCode = \$true'
    }
    It 'round-trips ASCII and typographic quote characters as inert PowerShell data' {
        InModuleScope Agent365Preflight {
            foreach ($code in @(0x27, 0x2018, 0x2019, 0x201A, 0x201B)) {
                $value = 'left' + [char]$code + '; Write-Output NOT-EXECUTED; ' + [char]$code + 'right'
                $literal = ConvertTo-A365PowerShellLiteral $value
                $tokens = $null
                $errors = $null
                $ast = [Management.Automation.Language.Parser]::ParseInput($literal, [ref]$tokens, [ref]$errors)
                @($errors).Count | Should -Be 0
                $ast.EndBlock.Statements.Count | Should -Be 1
                $constant = $ast.Find({ param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] }, $true)
                $constant.Value | Should -BeExactly $value
            }
        }
    }
}
