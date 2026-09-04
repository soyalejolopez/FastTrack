BeforeAll {
$resourceRoot = Split-Path -Parent $PSScriptRoot
$launcherPath = Join-Path $resourceRoot 'Start-Agent365Preflight.ps1'
$modulePath = Join-Path $resourceRoot 'Agent365Preflight.psd1'
$fixturePath = Join-Path $resourceRoot 'fixtures\commercial-ready.json'
$answersPath = Join-Path $resourceRoot 'samples\answers.sample.json'
$packageBuilderPath = Join-Path $resourceRoot 'Build-Agent365PreflightPackage.ps1'
$startHerePath = Join-Path $resourceRoot 'START-HERE.txt'

Import-Module $modulePath -Force
. $launcherPath

function New-JourneyTestEnvironment {
    param([bool]$GraphReady = $true)

    [pscustomobject]@{
        PowerShellReady = $true
        PowerShellVersion = '7.6.0'
        GraphModuleReady = $GraphReady
        GraphModuleVersion = if ($GraphReady) { '2.38.1' } else { $null }
        GraphModule = if ($GraphReady) { [pscustomobject]@{ Version = [version]'2.38.1' } } else { $null }
        GraphReachable = $true
        OutputWritable = $true
        OutputPath = $TestDrive
        OutputError = $null
    }
}

function New-JourneyTestOutcome {
    param([int]$ExitCode = 2)

    [pscustomobject]@{
        ExitCode = $ExitCode
        Report = [pscustomobject]@{
            Verdict = [pscustomobject]@{ Label = 'Incomplete'; Summary = 'Guided test result.' }
            Drift = [pscustomobject]@{
                ResolvedRequiredActions = @()
                ResolvedBlockers = @()
            }
            PathToReady = [pscustomobject]@{ Items = @() }
        }
        Paths = [pscustomobject]@{
            Html = 'C:\Reports\Agent365Preflight-full.html'
            Json = 'C:\Reports\Agent365Preflight-full.json'
            SanitizedHtml = 'C:\Reports\Agent365Preflight-sanitized.html'
            SanitizedJson = 'C:\Reports\Agent365Preflight-sanitized.json'
            Resume = 'C:\Reports\Resume-Agent365Preflight.ps1'
        }
    }
}
}

Describe 'Customer launcher environment and modes' {
    BeforeEach {
        Mock Get-A365LauncherEnvironment { New-JourneyTestEnvironment }
        Mock Import-Module {}
        Mock Get-Agent365RequiredScopes { @('Organization.Read.All', 'Policy.Read.All') }
        Mock Invoke-A365LauncherAuthentication {
            [pscustomobject]@{
                Reused = $false
                Method = 'Interactive'
                Context = [pscustomobject]@{}
            }
        }
        Mock Invoke-A365JourneyEngine { New-JourneyTestOutcome }
        Mock Open-A365FullReport {}
        Mock Install-A365LauncherGraphModule {}
    }

    It 'runs the guided sample path from mocked Read-Host input without authenticating' {
        $responses = [System.Collections.Generic.Queue[string]]::new()
        @('1', '', '') | ForEach-Object { $responses.Enqueue($_) }
        Mock Read-Host { $responses.Dequeue() }

        $result = Invoke-A365CustomerJourney -Mode Guided -OpenReport Never -OutputPath $TestDrive

        $result.Plan.Mode | Should -Be 'Sample'
        $result.Plan.FixturePath | Should -Be $fixturePath
        Should -Invoke Invoke-A365LauncherAuthentication -Times 0 -Exactly
        Should -Invoke Invoke-A365JourneyEngine -Times 1 -Exactly
    }

    It 'uses the recommended Control Plane collector set and one delegated sign-in' {
        $script:capturedParameters = $null
        $script:capturedAuthMethod = $null
        Mock Get-A365LauncherHostAssessment {
            [pscustomobject]@{
                IsWindows = $true
                IsWindowsTerminal = $true
                IsLikelyEmbedded = $false
                IsInteractive = $true
                RecommendInteractive = $true
                Reason = 'Native Windows Terminal.'
            }
        }
        Mock Invoke-A365LauncherAuthentication {
            param($Scopes, $TenantId, $Method)
            $script:capturedAuthMethod = $Method
            [pscustomobject]@{
                Reused = $false
                Method = $Method
                Context = [pscustomobject]@{}
            }
        }
        Mock Invoke-A365JourneyEngine {
            param($Parameters)
            $script:capturedParameters = $Parameters
            New-JourneyTestOutcome
        }

        $result = Invoke-A365CustomerJourney `
            -Mode Recommended `
            -TenantId 'contoso.onmicrosoft.com' `
            -NonInteractive `
            -OpenReport Never `
            -OutputPath $TestDrive

        $result.Plan.Collectors | Should -Be $script:A365RecommendedCollectors
        $result.Plan.Profiles | Should -Be @('ControlPlane')
        $script:capturedParameters.TenantId | Should -Be 'contoso.onmicrosoft.com'
        $script:capturedAuthMethod | Should -Be 'Interactive'
        Should -Invoke Invoke-A365LauncherAuthentication -Times 1 -Exactly
    }

    It 'stops a live run when dependency installation is declined' {
        Mock Get-A365LauncherEnvironment { New-JourneyTestEnvironment -GraphReady $false }

        {
            Invoke-A365CustomerJourney `
                -Mode Recommended `
                -TenantId 'contoso.onmicrosoft.com' `
                -NonInteractive `
                -OpenReport Never `
                -OutputPath $TestDrive
        } | Should -Throw '*requires Microsoft.Graph.Authentication*'
        Should -Invoke Install-A365LauncherGraphModule -Times 0 -Exactly
    }

    It 'installs the Graph module only after explicit opt-in' {
        $script:environmentCalls = 0
        Mock Get-A365LauncherEnvironment {
            $script:environmentCalls++
            New-JourneyTestEnvironment -GraphReady ($script:environmentCalls -gt 1)
        }
        Mock Install-A365LauncherGraphModule {}

        $null = Invoke-A365CustomerJourney `
            -Mode Recommended `
            -TenantId 'contoso.onmicrosoft.com' `
            -InstallDependencies `
            -NonInteractive `
            -OpenReport Never `
            -OutputPath $TestDrive

        Should -Invoke Install-A365LauncherGraphModule -Times 1 -Exactly
    }

    It 'honors interactive dependency-install decline' {
        Mock Get-A365LauncherEnvironment { New-JourneyTestEnvironment -GraphReady $false }
        Mock Read-A365JourneyYesNo { $false }
        Mock Read-A365JourneyChoice { 1 }

        {
            Invoke-A365CustomerJourney `
                -Mode Recommended `
                -TenantId 'contoso.onmicrosoft.com' `
                -OpenReport Never `
                -OutputPath $TestDrive
        } | Should -Throw '*requires Microsoft.Graph.Authentication*'
        Should -Invoke Install-A365LauncherGraphModule -Times 0 -Exactly
    }

    It 'installs after interactive confirmation and continues' {
        $script:environmentCalls = 0
        Mock Get-A365LauncherEnvironment {
            $script:environmentCalls++
            New-JourneyTestEnvironment -GraphReady ($script:environmentCalls -gt 1)
        }
        Mock Read-A365JourneyYesNo { $true }
        Mock Read-A365JourneyChoice { 1 }
        Mock Read-Host { '' }

        $null = Invoke-A365CustomerJourney `
            -Mode Recommended `
            -TenantId 'contoso.onmicrosoft.com' `
            -OpenReport Never `
            -OutputPath $TestDrive

        Should -Invoke Install-A365LauncherGraphModule -Times 1 -Exactly
        Should -Invoke Invoke-A365JourneyEngine -Times 1 -Exactly
    }

    It 'opens only the full local report when requested' {
        $null = Invoke-A365CustomerJourney `
            -Mode Sample `
            -NonInteractive `
            -OpenReport Always `
            -OutputPath $TestDrive

        Should -Invoke Open-A365FullReport -Times 1 -Exactly -ParameterFilter {
            $Path -eq 'C:\Reports\Agent365Preflight-full.html'
        }
        Should -Invoke Open-A365FullReport -Times 0 -Exactly -ParameterFilter {
            $Path -match 'sanitized'
        }
    }

    It 'stops when the output folder is not writable' {
        Mock Get-A365LauncherEnvironment {
            $status = New-JourneyTestEnvironment
            $status.OutputWritable = $false
            $status.OutputError = 'Access denied.'
            $status
        }

        {
            Invoke-A365CustomerJourney `
                -Mode Sample `
                -NonInteractive `
                -OpenReport Never `
                -OutputPath $TestDrive
        } | Should -Throw '*not writable*'
        Should -Invoke Invoke-A365JourneyEngine -Times 0 -Exactly
    }

    It 'stops a live run when Microsoft Graph is unreachable' {
        Mock Get-A365LauncherEnvironment {
            $status = New-JourneyTestEnvironment
            $status.GraphReachable = $false
            $status
        }

        {
            Invoke-A365CustomerJourney `
                -Mode Recommended `
                -TenantId 'contoso.onmicrosoft.com' `
                -NonInteractive `
                -OpenReport Never `
                -OutputPath $TestDrive
        } | Should -Throw '*Microsoft Graph is not reachable*'
        Should -Invoke Invoke-A365JourneyEngine -Times 0 -Exactly
    }
}

Describe 'Customer launcher authentication recovery' {
    BeforeEach {
        Mock Import-Module {}
        $script:contextCalls = 0
        Mock Get-MgContext {
            $script:contextCalls++
            if ($script:contextCalls -eq 1) {
                return $null
            }
            [pscustomobject]@{
                TenantId = '11111111-1111-1111-1111-111111111111'
                AuthType = 'Delegated'
                Account = 'admin@contoso.invalid'
                Scopes = @('Organization.Read.All')
            }
        }
    }

    It 'falls back from a WAM window-handle error to device code' {
        $script:connectCalls = 0
        Mock Connect-MgGraph {
            $script:connectCalls++
            if ($script:connectCalls -eq 1) {
                throw 'A parent window handle is required by WAM.'
            }
        }
        Mock Read-A365JourneyChoice { 1 }
        Mock Read-A365JourneyYesNo { $true }

        $result = Invoke-A365LauncherAuthentication `
            -Scopes @('Organization.Read.All') `
            -TenantId 'contoso.onmicrosoft.com' `
            -Method Interactive

        $result.Method | Should -Be 'DeviceCode'
        $script:connectCalls | Should -Be 2
        Should -Invoke Connect-MgGraph -Times 1 -Exactly -ParameterFilter { $UseDeviceCode }
    }

    It 'keeps the wizard alive and retries an expired device code' {
        $script:connectCalls = 0
        Mock Connect-MgGraph {
            $script:connectCalls++
            if ($script:connectCalls -eq 1) {
                throw 'Device code authentication timed out.'
            }
        }
        Mock Read-A365JourneyYesNo { $true }

        $result = Invoke-A365LauncherAuthentication `
            -Scopes @('Organization.Read.All') `
            -TenantId 'contoso.onmicrosoft.com' `
            -Method DeviceCode

        $result.Method | Should -Be 'DeviceCode'
        $script:connectCalls | Should -Be 2
    }

    It 'detects an embedded Windows host and recommends the portable fallback' {
        $originalVscodePid = $env:VSCODE_PID
        try {
            $env:VSCODE_PID = '1234'
            $assessment = Get-A365LauncherHostAssessment

            $assessment.IsLikelyEmbedded | Should -BeTrue
            $assessment.RecommendInteractive | Should -BeFalse
            $assessment.Reason | Should -Match 'parent window'
        }
        finally {
            $env:VSCODE_PID = $originalVscodePid
        }
    }

    It 'reuses a compatible delegated process context without another sign-in' {
        $script:contextCalls = 1
        Mock Connect-MgGraph {}

        $result = Invoke-A365LauncherAuthentication `
            -Scopes @('Organization.Read.All') `
            -TenantId 'contoso.onmicrosoft.com' `
            -Method Interactive `
            -NonInteractive

        $result.Method | Should -Be 'ExistingContext'
        Should -Invoke Connect-MgGraph -Times 0 -Exactly
    }
}

Describe 'Report-linked resume discovery and validation' {
    BeforeEach {
        $script:resumeOutput = Join-Path $TestDrive "resume-source-$([guid]::NewGuid().ToString('N'))"
        $script:first = Invoke-Agent365Preflight `
            -FixturePath $fixturePath `
            -OutputPath $script:resumeOutput `
            -IncludeSanitizedCopy
    }

    It 'discovers the exact report-linked answers file in the output folder' {
        $expectedAnswers = Join-Path $script:resumeOutput $script:first.Report.Resume.AnswerFileName
        Copy-Item -LiteralPath (Join-Path $resourceRoot 'samples\answers.sample.json') -Destination $expectedAnswers

        $plan = Get-A365ResumePlan `
            -PreviousResultPath $script:first.Paths.Json `
            -NonInteractive

        $plan.AnswersPath | Should -Be (Resolve-Path $expectedAnswers).Path
        $plan.PreviousResultPath | Should -Be $script:first.Paths.Json
        $plan.Profiles | Should -Be $script:first.Report.Profiles
        $plan.Collectors | Should -Be $script:first.Report.Collectors
        $plan.AuditWindowDays | Should -Be $script:first.Report.Runtime.AuditWindowDays
        $plan.AuditQueryTimeoutSeconds | Should -Be $script:first.Report.Runtime.AuditQueryTimeoutSeconds
    }

    It 'requires an explicit choice when multiple matching files exist noninteractively' {
        $candidates = @(
            [pscustomobject]@{ Path = 'C:\one\answers.json'; LastWriteTime = Get-Date; Source = 'OutputFolder' },
            [pscustomobject]@{ Path = 'C:\two\answers.json'; LastWriteTime = Get-Date; Source = 'Downloads' }
        )

        { Select-A365AnswerCandidate -Candidates $candidates -NonInteractive } |
            Should -Throw '*Multiple matching answers files*'
    }

    It 'returns the customer-selected file when multiple candidates are shown' {
        $candidates = @(
            [pscustomobject]@{ Path = 'C:\one\answers.json'; LastWriteTime = Get-Date; Source = 'OutputFolder' },
            [pscustomobject]@{ Path = 'C:\two\answers.json'; LastWriteTime = Get-Date; Source = 'Downloads' }
        )
        Mock Read-A365JourneyChoice { 2 }

        (Select-A365AnswerCandidate -Candidates $candidates) | Should -Be 'C:\two\answers.json'
    }

    It 'fails clearly when the report-linked answers file is absent' {
        {
            Get-A365ResumePlan `
                -PreviousResultPath $script:first.Paths.Json `
                -NonInteractive
        } | Should -Throw '*No matching answers file was found*'
    }

    It 'rejects a malformed answers file' {
        $bad = Join-Path $TestDrive 'bad-answers.json'
        [System.IO.File]::WriteAllText($bad, '{"schemaVersion":"1.1","answers":[{"id":"UNKNOWN","answer":"Yes"}]}')

        { Test-A365AnswerFile -Path $bad } | Should -Throw
    }

    It 'rejects sanitized reports as resume sources' {
        { Read-A365FullReport -Path $script:first.Paths.SanitizedJson } |
            Should -Throw '*full local report JSON*'
    }

    It 'rejects injected profile values instead of turning report data into parameters' {
        $report = Get-Content -LiteralPath $script:first.Paths.Json -Raw | ConvertFrom-Json -Depth 100
        $report.Profiles = @('ControlPlane; Remove-Item C:\')
        $tampered = Join-Path $TestDrive 'tampered-report.json'
        [System.IO.File]::WriteAllText(
            $tampered,
            ($report | ConvertTo-Json -Depth 100),
            [System.Text.UTF8Encoding]::new($false)
        )

        { Read-A365FullReport -Path $tampered } |
            Should -Throw '*unsupported profile*'
    }
}

Describe 'Clean package self-service journey' {
    It 'runs sample, downloads report-linked answers, and resumes without development paths' {
        $packageRoot = Join-Path $TestDrive 'clean-package\Invoke-Agent365Preflight'
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $packageRoot) -Force
        Copy-Item -LiteralPath $resourceRoot -Destination $packageRoot -Recurse
        $packageLauncher = Join-Path $packageRoot 'Start-Agent365Preflight.ps1'
        $outputPath = Join-Path $TestDrive 'clean-output'

        $first = & $packageLauncher `
            -Mode Sample `
            -NonInteractive `
            -PassThru `
            -OpenReport Never `
            -OutputPath $outputPath
        $expectedAnswers = Join-Path $outputPath $first.Outcome.Report.Resume.AnswerFileName
        Copy-Item -LiteralPath (Join-Path $packageRoot 'samples\answers.sample.json') -Destination $expectedAnswers
        $second = & $first.Outcome.Paths.Resume `
            -AnswersPath $expectedAnswers `
            -NonInteractive `
            -PassThru `
            -OpenReport Never

        $first.ExitCode | Should -Be 2
        $second.ExitCode | Should -Be 0
        $second.Outcome.Report.Verdict.Label | Should -Be 'Ready for pilot'
        $second.Outcome.Report.Drift.ResolvedRequiredActions.Count | Should -BeGreaterOrEqual 0
        $resumeText = Get-Content -LiteralPath $second.Outcome.Paths.Resume -Raw
        $second.Outcome.Report.Rerun.Command | Should -Match ([regex]::Escape($packageRoot))
        $second.Outcome.Report.Rerun.Command | Should -Not -Match ([regex]::Escape($resourceRoot))
        $resumeText | Should -Match ([regex]::Escape($packageLauncher.Replace("'", "''")))
        $resumeText | Should -Not -Match '\bInvoke-Expression\b|\biex\b|ClientSecret|Bearer|[A-Fa-f0-9]{40}'
    }

    Describe 'Standalone customer package' {
        BeforeAll {
            $packageOutputA = Join-Path $TestDrive 'package-a'
            $packageOutputB = Join-Path $TestDrive 'package-b'
            $packageA = & $packageBuilderPath -OutputDirectory $packageOutputA -Force
            $packageB = & $packageBuilderPath -OutputDirectory $packageOutputB -Force
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $archive = [System.IO.Compression.ZipFile]::OpenRead($packageA.Path)
            try {
                $packageEntries = @($archive.Entries | ForEach-Object { $_.FullName })
            }
            finally {
                $archive.Dispose()
            }
            $extractedPath = Join-Path $TestDrive 'standalone-extracted'
            [System.IO.Compression.ZipFile]::ExtractToDirectory($packageA.Path, $extractedPath)
            $extractedRoot = Join-Path $extractedPath $packageA.RootFolder
        }

        It 'contains the exact customer runtime allowlist under one intuitive root' {
            $expectedFiles = @(
                'START-HERE.txt',
                'Agent365Preflight.psd1',
                'Agent365Preflight.psm1',
                'CHANGELOG.md',
                'Invoke-Agent365Preflight.ps1',
                'Private/ReportRenderer.ps1',
                'README.md',
                'Start-Agent365Preflight.ps1',
                'VERSION',
                'config/guidance.v1.json',
                'config/operation-allowlist.v1.json',
                'config/rules.v1.json',
                'config/sku-catalog.v1.json',
                'fixtures/commercial-ready.json',
                'samples/answers.sample.json',
                'schema/agent365-preflight-answers.schema.json',
                'schema/agent365-preflight-report.schema.json'
            )
            $expectedEntries = @($expectedFiles | ForEach-Object { "$($packageA.RootFolder)/$_" })

            $packageA.FileCount | Should -Be 17
            @($packageEntries | Sort-Object) | Should -Be @($expectedEntries | Sort-Object)
            $packageEntries[0] | Should -Be "$($packageA.RootFolder)/START-HERE.txt"
            (Get-ChildItem -LiteralPath $extractedPath -Force).Count | Should -Be 1
            Test-Path -LiteralPath (Join-Path $extractedRoot 'Start-Agent365Preflight.ps1') | Should -BeTrue
        }

        It 'excludes tests, build tooling, generated output, Git data, and customer evidence' {
            $entryText = $packageEntries -join "`n"

            $entryText | Should -Not -Match '(?i)(^|/)tests?/|Build-Agent365PreflightPackage|\.playwright|\.git|test-results|Agent365PreflightOutput|customer.*answers'
            @($packageEntries | Where-Object { $_ -match '(?i)-sanitized\.(html|json)$|Agent365Preflight-\d{8}-\d{6}\.(html|json)$' }).Count | Should -Be 0
        }

        It 'contains no development path, personal fork URL, secret, or remote execution bootstrap' {
            $packageText = @(
                Get-ChildItem -LiteralPath $extractedRoot -Recurse -File |
                    ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }
            ) -join "`n"
            $builderText = Get-Content -LiteralPath $packageBuilderPath -Raw

            $packageText | Should -Not -Match ([regex]::Escape($resourceRoot))
            $packageText | Should -Not -Match '(?i)github\.com/soyalejolopez|alejanl|claw-skills|BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY|Bearer\s+[A-Za-z0-9._~-]{20,}'
            $builderText | Should -Not -Match '(?i)\bInvoke-Expression\b|\biex\b|Invoke-WebRequest|Start-BitsTransfer|DownloadString'
        }

        It 'builds the same ordered bytes from unchanged source files' {
            $packageA.SHA256 | Should -Be $packageB.SHA256
            $packageA.FileName | Should -Be 'Agent365Preflight-1.4.1.zip'
            $packageA.RootFolder | Should -Be 'Agent365Preflight-1.4.1'
        }

        It 'puts the immediate customer instructions beside the launcher' {
            $startHere = Get-Content -LiteralPath (Join-Path $extractedRoot 'START-HERE.txt') -Raw

            $startHere | Should -Match 'Windows Terminal with PowerShell 7'
            $startHere | Should -Match '\\Start-Agent365Preflight\.ps1'
            $startHere | Should -Match 'Incomplete verdict is expected'
            $startHere | Should -Match 'FULL local report'
            $startHere | Should -Match 'SANITIZED report'
            $startHere | Should -Match 'Resume-Agent365Preflight\.ps1'
            $startHere | Should -Match '(?s)Do not share.*credentials'
            $startHere | Should -Not -Match 'soyalejolopez|alejanl|claw-skills'
        }

        It 'runs Sample mode directly from the extracted standalone root' {
            $launcher = Join-Path $extractedRoot 'Start-Agent365Preflight.ps1'
            $outputPath = Join-Path $TestDrive 'standalone-output'
            $result = & $launcher `
                -Mode Sample `
                -NonInteractive `
                -PassThru `
                -OpenReport Never `
                -OutputPath $outputPath

            $result.ExitCode | Should -Be 2
            $result.Outcome.Report.Verdict.Label | Should -Be 'Incomplete'
            $result.Outcome.Paths.Html | Should -Exist
            $result.Outcome.Paths.Resume | Should -Exist
            $result.Outcome.Report.Rerun.Command | Should -Match ([regex]::Escape($extractedRoot))
            $result.Outcome.Report.Rerun.Command | Should -Not -Match ([regex]::Escape($resourceRoot))
        }
    }

    Describe 'Customer journey documentation' {
        It 'puts the guided canonical start path before technical detail' {
            $readme = Get-Content -LiteralPath (Join-Path $resourceRoot 'README.md') -Raw
            $startIndex = $readme.IndexOf('## START HERE')
            $technicalIndex = $readme.IndexOf('## What it does and does not prove')

            $startIndex | Should -BeGreaterOrEqual 0
            $technicalIndex | Should -BeGreaterThan $startIndex
            $readme | Should -Match '\\Start-Agent365Preflight\.ps1'
            $readme | Should -Match 'github\.com/microsoft/FastTrack/archive/refs/heads/master\.zip'
            $readme | Should -Not -Match 'github\.com/soyalejolopez/FastTrack'
        }

        It 'documents native WAM, device retry, full-report remediation, and report-linked resume' {
            $readme = Get-Content -LiteralPath (Join-Path $resourceRoot 'README.md') -Raw

            $readme | Should -Match '2\.34 and later uses Windows Authentication Manager \(WAM\)'
            $readme | Should -Match 'about 120 seconds'
            $readme | Should -Match 'Try again now'
            $readme | Should -Match 'Do not use `Set-MgGraphOption -DisableLoginByWAM`'
            $readme | Should -Match 'full local working report'
            $readme | Should -Match 'Resume-Agent365Preflight\.ps1'
            $readme | Should -Match 'exact report-linked answers file'
        }

        It 'keeps runtime answer validation compatible with the PowerShell 7.0 minimum' {
            $launcher = Get-Content -LiteralPath $launcherPath -Raw

            $launcher | Should -Match 'Test-Json -Schema \$schema'
            $launcher | Should -Not -Match 'Test-Json -SchemaFile'
        }
    }

    Describe 'Customer launcher exit semantics' {
        BeforeEach {
            Mock Get-A365LauncherEnvironment { New-JourneyTestEnvironment }
            Mock Import-Module {}
            Mock Get-Agent365RequiredScopes { @() }
            Mock Invoke-A365LauncherAuthentication {}
            Mock Open-A365FullReport {}
        }

        It 'preserves engine exit code <ExitCode>' -ForEach @(
            @{ ExitCode = 0 },
            @{ ExitCode = 1 },
            @{ ExitCode = 2 }
        ) {
            Mock Invoke-A365JourneyEngine { New-JourneyTestOutcome -ExitCode $ExitCode }

            $result = Invoke-A365CustomerJourney `
                -Mode Sample `
                -NonInteractive `
                -OpenReport Never `
                -OutputPath $TestDrive

            $result.ExitCode | Should -Be $ExitCode
        }
    }
}
