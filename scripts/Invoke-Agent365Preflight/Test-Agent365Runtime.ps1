# Compatible with Windows PowerShell 5.1. No downloads, installs, or tenant requests.
[CmdletBinding()]
param()

$command = Get-Command pwsh -ErrorAction SilentlyContinue
if ($null -eq $command) {
    Write-Host 'PowerShell 7 is not on PATH. Windows PowerShell 5.1 cannot run the checker.'
    Write-Host 'Install PowerShell 7 using your organization-approved tooling and the official instructions:'
    Write-Host 'https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows'
    Write-Host 'This readiness check does not download or execute an installer.'
    exit 2
}
$version = & $command.Source -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
if ($LASTEXITCODE -ne 0 -or [version]$version -lt [version]'7.0') { throw 'The discovered pwsh runtime could not start or is older than 7.0.' }
Write-Host "PowerShell $version found: $($command.Source)"
Write-Host 'Open Windows Terminal with PowerShell 7 in the extracted folder.'
Write-Host 'Verify package provenance using START-HERE.txt before running .\Start-Agent365Preflight.ps1.'
