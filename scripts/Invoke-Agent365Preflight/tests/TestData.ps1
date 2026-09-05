function New-A365TestBundle {
    param([object]$Report, [string]$TemplatePath, [string]$Path)
    $template = Get-Content -LiteralPath $TemplatePath -Raw | ConvertFrom-Json -Depth 100
    $now = [DateTimeOffset]::UtcNow.AddSeconds(-1).ToString('o')
    $answers = @(
        foreach ($answer in $template.answers) {
            $gate = @($Report.ManuallyAttestableGates | Where-Object Id -eq $answer.id)
            if ($gate.Count -ne 1) { continue }
            $answer | Add-Member -NotePropertyName binding -NotePropertyValue $gate[0].Binding -Force
            $answer | Add-Member -NotePropertyName reviewDecision -NotePropertyValue Revalidate -Force
            $answer | Add-Member -NotePropertyName answeredAtUtc -NotePropertyValue $now -Force
            $answer | Add-Member -NotePropertyName modifiedAtUtc -NotePropertyValue $now -Force
            $answer
        }
    )
    $bundle = [pscustomobject][ordered]@{
        schemaVersion = '2.0'; sourceReportId = $Report.ReportId
        assessmentFingerprint = $Report.AssessmentScope.Fingerprint
        generatedAtUtc = $now; modifiedAtUtc = $now; bundleId = [Guid]::NewGuid().ToString()
        baseRevision = ''; draft = $false; answers = $answers; contentHash = ''
    }
    $bundle.contentHash = & (Get-Module Agent365Preflight | Select-Object -First 1) { param($Bundle) Get-A365AnswerBundleHash $Bundle } $bundle
    [IO.File]::WriteAllText($Path, ($bundle | ConvertTo-Json -Depth 50), [Text.UTF8Encoding]::new($false))
    return $Path
}
