@{
    RootModule = 'Agent365Preflight.psm1'
    ModuleVersion = '1.4.0'
    GUID = '87c4af68-5403-4cf6-8aca-0d649c9e5ca5'
    Author = 'Microsoft FastTrack'
    CompanyName = 'Microsoft'
    Copyright = '(c) Microsoft Corporation. All rights reserved.'
    Description = 'Read-only Microsoft Agent 365 technical pre-flight evidence collector and report generator.'
    PowerShellVersion = '7.0'
    FunctionsToExport = @(
        'Compare-Agent365PreflightResult'
        'Get-Agent365RequiredScopes'
        'Invoke-Agent365PagedRequest'
        'Invoke-Agent365Preflight'
        'New-Agent365SanitizedReport'
        'Test-Agent365OperationAllowed'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{
        PSData = @{
            Tags = @('Agent365', 'Microsoft365', 'Readiness', 'Preflight')
            ProjectUri = 'https://github.com/microsoft/FastTrack'
            LicenseUri = 'https://github.com/microsoft/FastTrack/blob/master/LICENSE-CODE'
            ReleaseNotes = 'Adds a guided customer launcher and report-linked one-command resume workflow.'
        }
    }
}
