BeforeAll {
    $guideRoot = Split-Path -Parent $PSScriptRoot
    $guideName = 'PERMISSIONS-AND-CONSENT.md'
    $guideText = Get-Content -LiteralPath (Join-Path $guideRoot $guideName) -Raw
    Get-Module Agent365Preflight | Remove-Module -Force -ErrorAction Stop
    Import-Module (Join-Path $guideRoot 'Agent365Preflight.psd1') -Force
}

Describe 'Customer permissions guide' {
    It 'answers the customer question: <Question>' -ForEach @(
        @{ Question = 'Is this too much permission?' }
        @{ Question = 'Why no app registration?' }
        @{ Question = 'Does it work only once?' }
        @{ Question = 'What persists after closing PowerShell?' }
        @{ Question = 'Can we reduce the scopes?' }
        @{ Question = 'Can we use our own app registration?' }
        @{ Question = 'How do we remove access afterward?' }
        @{ Question = 'Does the tool store tokens or raw tenant content?' }
    ) {
        $guideText | Should -Match ('(?m)^### ' + [regex]::Escape($Question) + '\r?$')
    }

    It 'documents every requested scope with purpose and maximum delegated boundaries' {
        $policy = Get-Content -LiteralPath (Join-Path $guideRoot 'config\assessment-policy.v2.json') -Raw | ConvertFrom-Json
        foreach ($scope in $policy.maximumRequestedScopes) {
            $guideText | Should -Match ([regex]::Escape("``$scope``"))
            $anchor = $scope.Replace('.', '').ToLowerInvariant()
            $guideText | Should -Match ([regex]::Escape("https://learn.microsoft.com/graph/permissions-reference#$anchor"))
        }
        $guideText | Should -Match 'Maximum delegated permission boundary'
        $guideText | Should -Match 'complete permission set is broad'
        $guideText | Should -Match 'formally review'
    }

    It 'keeps citations public and excludes secrets and tenant-specific examples' {
        $urls = @([regex]::Matches($guideText, 'https?://[^\s<>")]+') | ForEach-Object Value)
        $urls.Count | Should -BeGreaterThan 10
        foreach ($url in $urls) {
            $uri = [Uri]$url
            $uri.Scheme | Should -Be https
            $uri.DnsSafeHost | Should -Be 'learn.microsoft.com'
            $uri.UserInfo | Should -BeNullOrEmpty
        }
        $guideText | Should -Not -Match '(?i)dev\.azure\.com|seismic\.com|engage\.cloud|onmicrosoft\.com|https://[a-z0-9-]+\.sharepoint\.com|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
        $guideText | Should -Not -Match 'BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY|Bearer\s+[A-Za-z0-9._~-]{20,}|C:\\Users\\|copilot-worktrees'
        $guideText | Should -Match 'Public sources reviewed: 2026-09-14'
    }

    It 'has a concise copy-ready SME response with no false reassurance' {
        $response = [regex]::Match($guideText, '(?s)## Suggested SME response\s+```text\r?\n(.*?)\r?\n```').Groups[1].Value
        $response | Should -Not -BeNullOrEmpty
        @($response -split '\s+').Count | Should -BeLessOrEqual 200
        $response | Should -Match 'broad|security and identity review'
        $response | Should -Match 'consent can persist'
        $response | Should -Match 'POSTs'
        $response | Should -Match 'not a sandbox'
        $response | Should -Match 'not consent revocation'
    }

    It 'distinguishes session lifetime isolation and safe revocation' {
        foreach ($term in @('ContextScope Process', 'Disconnect-MgGraph', 'WAM', 'localStorage', '-DelegatedClientId', '-ClientId', '-CertificateThumbprint', 'Assignment required?', 'single-tenant', 'Admin consent', 'User consent', 'NotAssessed')) {
            $guideText | Should -Match ([regex]::Escape($term))
        }
        $guideText | Should -Match 'not a security sandbox'
        $guideText | Should -Match 'not bypasses'
        $guideText | Should -Match 'Do not blindly revoke'
        $guideText | Should -Match 'not existing tenant grants or the capabilities of a reused token'
        $guideText | Should -Match 'oauth2permissiongrant-delete'
    }

    It 'links the guide from both README entry points and local offboarding instructions' {
        $readme = Get-Content -LiteralPath (Join-Path $guideRoot 'README.md') -Raw
        $startHere = [regex]::Match($readme, '(?s)## START HERE(.*?)## What it does and does not prove').Groups[1].Value
        $prerequisites = [regex]::Match($readme, '(?s)## Prerequisites(.*?)## Setup and first run').Groups[1].Value
        foreach ($text in @($startHere, $prerequisites, (Get-Content -LiteralPath (Join-Path $guideRoot 'OFFBOARDING.md') -Raw))) {
            $text | Should -Match '\]\(PERMISSIONS-AND-CONSENT\.md\)'
        }
        $localStart = Get-Content -LiteralPath (Join-Path $guideRoot 'START-HERE.txt') -Raw
        $localStart.IndexOf($guideName) | Should -BeLessThan $localStart.IndexOf('.\Start-Agent365Preflight.ps1')
        $launcher = Get-Content -LiteralPath (Join-Path $guideRoot 'Start-Agent365Preflight.ps1') -Raw
        $launcher.IndexOf($guideName) | Should -BeLessThan $launcher.IndexOf('$authResult = Invoke-A365LauncherAuthentication')
    }

    It 'shows the FAQ pointer in the existing trust receipt without changing requested permissions' {
        InModuleScope Agent365Preflight {
            $scopes = @(Get-Agent365RequiredScopes -Collector TenantFoundation,Licensing)
            $receipt = New-A365TrustReceipt -Scopes $scopes -FixtureMode $true `
                -Policy (Read-A365Json (Join-Path $script:ModuleRoot 'config\assessment-policy.v2.json') Policy) `
                -Allowlist (Read-A365Json $script:AllowlistPath Allowlist)
            $receipt.Consent | Should -Match 'Before consent, read PERMISSIONS-AND-CONSENT\.md'
            $receipt.Permissions.Scope | Should -Be $scopes
            $console = @(& { Write-A365TrustReceipt -Receipt $receipt } 6>&1) -join "`n"
            $console | Should -Match 'PERMISSIONS-AND-CONSENT\.md'
        }
    }

    It 'includes the packaged guide reference in full and sharing reports' {
        $result = Invoke-Agent365Preflight -FixturePath (Join-Path $guideRoot 'fixtures\commercial-ready.json') `
            -OutputPath (Join-Path $TestDrive 'guide-report') -IncludeSanitizedCopy
        $result.Report.ToolVersion | Should -Be '2.0.1'
        $result.Report.SchemaVersion | Should -Be '2.0'
        foreach ($path in @($result.Paths.Html, $result.Paths.SanitizedHtml, $result.Paths.Json, $result.Paths.SanitizedJson)) {
            (Get-Content -LiteralPath $path -Raw) | Should -Match 'PERMISSIONS-AND-CONSENT\.md'
        }
    }
}
