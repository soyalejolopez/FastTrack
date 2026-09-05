#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$OutputPath, [string]$ResourceRoot = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
$root = $ResourceRoot
$module = Import-Module (Join-Path $root 'Agent365Preflight.psd1') -Force -PassThru
. (Join-Path $PSScriptRoot 'TestData.ps1')
$null = New-Item -ItemType Directory -Path $OutputPath -Force
$templatePath = Join-Path $root 'samples\answers.sample.json'
$baseFixture = Join-Path $root 'fixtures\commercial-ready.json'
$samples = [Collections.Generic.List[object]]::new()
foreach ($scenario in @('blocked', 'malformed-evidence', 'missing-collector', 'incomplete', 'stale-evidence', 'passing-no-advisory', 'passing-with-advisory')) {
    $folder = Join-Path $OutputPath $scenario
    $null = New-Item -ItemType Directory -Path $folder -Force
    $fixture = Get-Content -LiteralPath $baseFixture -Raw | ConvertFrom-Json -Depth 100
    switch ($scenario) {
        blocked { $fixture.licensing.qualifyingAssignedUsers = 0 }
        malformed-evidence {
            $fixture.registry.available = $false
            $fixture.collectionIssues = @([pscustomobject]@{
                Adapter = 'Graph'; Operation = 'Agent package catalog'; Category = 'MalformedEvidence'
                StatusCode = 200; Message = 'MalformedEvidence: required value array is absent.'
                RequiredPermission = 'CopilotPackages.Read.All'
                DocsUrl = 'https://learn.microsoft.com/microsoft-365/copilot/extensibility/api/admin-settings/package/copilotpackages-list'
            })
        }
        passing-with-advisory { $fixture.defender.agentsInfo.agentCount = 0 }
    }
    $fixturePath = Join-Path $folder 'synthetic-fixture.json'
    [IO.File]::WriteAllText($fixturePath, ($fixture | ConvertTo-Json -Depth 100))
    $parameters = @{ FixturePath = $fixturePath; OutputPath = $folder; IncludeSanitizedCopy = $true }
    if ($scenario -eq 'missing-collector') { $parameters.Collector = @('TenantFoundation') }
    $first = Invoke-Agent365Preflight @parameters
    $result = $first
    if ($scenario -ne 'incomplete') {
        $answerPath = New-A365TestBundle -Report $first.Report -TemplatePath $templatePath -Path (Join-Path $folder $first.Report.Resume.AnswerFileName)
        if ($scenario -eq 'stale-evidence') {
            $bundle = & $module { param($Path) Read-A365Json $Path Answers } $answerPath
            foreach ($answer in $bundle.answers) {
                $answer.answeredAtUtc = [DateTimeOffset]::UtcNow.AddDays(-90).ToString('o')
                $answer.modifiedAtUtc = $answer.answeredAtUtc
            }
            $bundle.contentHash = & $module { param($Bundle) Get-A365AnswerBundleHash $Bundle } $bundle
            [IO.File]::WriteAllText($answerPath, ($bundle | ConvertTo-Json -Depth 50))
        }
        $result = Invoke-Agent365Preflight @parameters -AnswersPath $answerPath -PreviousResultPath $first.Paths.Json
    }
    $samples.Add([pscustomobject]@{ Scenario = $scenario; Verdict = $result.Report.Verdict.Label; Paths = $result.Paths })
    if ($scenario -eq 'passing-no-advisory') { $volumeSource = $result.Report }
}
$volume = $volumeSource | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100
$volume.Results = @(
    foreach ($n in 1..8) {
        foreach ($original in $volumeSource.Results) {
            $item = $original | ConvertTo-Json -Depth 50 | ConvertFrom-Json -Depth 50
            $item.Id = "$($item.Id)-SYNTHETIC$n"
            $item.Title = "$($item.Title) synthetic performance row $n"
            $item
        }
    }
)
$volumePath = Join-Path $OutputPath 'high-volume.html'
& $module { param($Report, $Path) $null = New-Agent365PreflightHtml -Report $Report -Path $Path } $volume $volumePath
$samples.Add([pscustomobject]@{ Scenario = 'high-volume'; Findings = $volume.Results.Count; Html = $volumePath })
$indexPath = Join-Path $OutputPath 'sample-index.json'
[IO.File]::WriteAllText($indexPath, ($samples.ToArray() | ConvertTo-Json -Depth 20))
$samples.ToArray()
