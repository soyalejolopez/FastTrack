#requires -Version 7.0

<#
.SYNOPSIS
Builds the standalone Microsoft Agent 365 pre-flight customer ZIP.

.DESCRIPTION
Creates Agent365Preflight-<version>.zip with one intuitive root folder and a strict allowlist of
runtime and customer documentation files. The archive excludes tests, generated reports, browser
artifacts, Git files, and customer evidence. Entry order and timestamps are fixed for reproducible
output on the same runtime.

.PARAMETER OutputDirectory
Directory where the ZIP is written.

.PARAMETER Force
Replaces an existing ZIP with the same versioned name.

.EXAMPLE
.\Build-Agent365PreflightPackage.ps1 -OutputDirectory C:\Temp -Force
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$OutputDirectory = $PWD,

    [Parameter()]
    [switch]$Force,

    [DateTimeOffset]$BuiltAtUtc = [DateTimeOffset]::UtcNow,

    [switch]$Release
)

$ErrorActionPreference = 'Stop'
$resourceRoot = $PSScriptRoot
$versionPath = Join-Path $resourceRoot 'VERSION'
if (-not (Test-Path -LiteralPath $versionPath -PathType Leaf)) {
    throw "VERSION was not found: $versionPath"
}
$version = (Get-Content -LiteralPath $versionPath -Raw).Trim()
if ($version -notmatch '^\d+\.\d+\.\d+$') {
    throw "VERSION must use MAJOR.MINOR.PATCH: $version"
}

$relativeFiles = @(
    'START-HERE.txt'
    'README.md'
    'Start-Agent365Preflight.ps1'
    'Invoke-Agent365Preflight.ps1'
    'Agent365Preflight.psd1'
    'Agent365Preflight.psm1'
    'VERSION'
    'CHANGELOG.md'
    'Private\ReportRenderer.ps1'
    'Private\EvidenceContracts.ps1'
    'Private\TrustReceipt.ps1'
    'Private\ReportExperience.css'
    'Private\EvidenceWorkspace.js'
    'Test-Agent365Runtime.ps1'
    'Test-Agent365Package.ps1'
    'OFFBOARDING.md'
    'RELEASE-CHECKLIST.md'
    'config\assessment-policy.v2.json'
    'config\strings.en.json'
    'config\guidance.v1.json'
    'config\operation-allowlist.v1.json'
    'config\rules.v1.json'
    'config\sku-catalog.v1.json'
    'schema\agent365-preflight-answers.schema.json'
    'schema\agent365-preflight-report.schema.json'
    'samples\answers.sample.json'
    'fixtures\commercial-ready.json'
    'LICENSE'
    'LICENSE-CODE'
)

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $resourceRoot '..\..')).Path
$sourcePaths = @{}
foreach ($relativePath in $relativeFiles) {
    $sourcePath = if ($relativePath -in @('LICENSE', 'LICENSE-CODE')) {
        Join-Path $repositoryRoot $relativePath
    } else { Join-Path $resourceRoot $relativePath }
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "Required package file was not found: $relativePath"
    }
    $sourcePaths[$relativePath] = $sourcePath
}
$sourceCommit = (& git -C $resourceRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $sourceCommit -notmatch '^[a-f0-9]{40}$') { throw 'Build from a Git source checkout with a verifiable source commit.' }
$sourceRemote = (& git -C $resourceRoot remote get-url origin).Trim()
$sourceUri = $null
if ($LASTEXITCODE -ne 0 -or -not [Uri]::TryCreate($sourceRemote, [UriKind]::Absolute, [ref]$sourceUri) -or
    $sourceUri.Scheme -ne 'https' -or $sourceUri.UserInfo -or $sourceUri.Query -or $sourceUri.Fragment) {
    throw 'Release provenance requires a credential-free HTTPS origin URL.'
}
$dirty = @(& git -C $repositoryRoot status --porcelain -- scripts/Invoke-Agent365Preflight LICENSE LICENSE-CODE).Count -gt 0
if ($Release -and $dirty) { throw 'Release packaging requires a clean committed resource and license files.' }
$manifest = [ordered]@{
    manifestVersion = '2.0'
    version = $version
    sourceCommit = $sourceCommit
    sourceState = if ($dirty) { 'Development: uncommitted changes included; not a release' } else { 'Committed' }
    builtAtUtc = $BuiltAtUtc.ToUniversalTime().ToString('o')
    sourceRepository = $sourceRemote -replace '\.git$', ''
    upstreamRepository = 'https://github.com/microsoft/FastTrack'
    minimumPowerShell = '7.0'
    supportedRuntime = 'PowerShell 7 on supported Windows, macOS and Linux; Graph-only cross-platform. SharePoint module checks require a supported Windows module session. See README support matrix.'
    dependencies = @([ordered]@{ name = 'Microsoft.Graph.Authentication'; minimumVersion = '2.20.0'; source = 'PowerShell Gallery'; install = 'Explicit operator opt-in only' })
    provenance = 'Unsigned community source. Internal file hashes detect changes, not publisher identity. Compare the ZIP SHA256 with the separately published release checksum from a trusted source.'
    externalChecksum = 'The ZIP hash cannot be embedded in itself. SHA256 is returned by the builder and written to a .zip.sha256 sidecar; release owner publishes it through the approved release channel.'
    files = @(
        foreach ($name in $relativeFiles | Sort-Object) {
            [ordered]@{ path = $name.Replace('\', '/'); sha256 = (Get-FileHash -LiteralPath $sourcePaths[$name] -Algorithm SHA256).Hash.ToLowerInvariant() }
        }
    )
}
$manifestBytes = [Text.Encoding]::UTF8.GetBytes(($manifest | ConvertTo-Json -Depth 20))

if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) {
    $null = New-Item -ItemType Directory -Path $OutputDirectory -Force
}
$resolvedOutput = (Resolve-Path -LiteralPath $OutputDirectory).Path
$archiveName = "Agent365Preflight-$version.zip"
$archivePath = Join-Path $resolvedOutput $archiveName
if (Test-Path -LiteralPath $archivePath) {
    if (-not $Force) {
        throw "Package already exists. Use -Force to replace it: $archivePath"
    }
    Remove-Item -LiteralPath $archivePath -Force
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$rootFolder = "Agent365Preflight-$version"
$fixedTimestamp = [DateTimeOffset]::new(2026, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
$stream = [System.IO.File]::Open(
    $archivePath,
    [System.IO.FileMode]::CreateNew,
    [System.IO.FileAccess]::ReadWrite,
    [System.IO.FileShare]::None
)
try {
    $archive = [System.IO.Compression.ZipArchive]::new(
        $stream,
        [System.IO.Compression.ZipArchiveMode]::Create,
        $true,
        [System.Text.Encoding]::UTF8
    )
    try {
        $orderedFiles = @(
            $relativeFiles |
                Sort-Object @{ Expression = { if ($_ -eq 'START-HERE.txt') { 0 } else { 1 } } }, @{ Expression = { $_ } }
        )
        foreach ($relativePath in $orderedFiles) {
            $entryPath = "$rootFolder/$($relativePath.Replace('\', '/'))"
            $entry = $archive.CreateEntry(
                $entryPath,
                [System.IO.Compression.CompressionLevel]::Optimal
            )
            $entry.LastWriteTime = $fixedTimestamp
            $source = [System.IO.File]::OpenRead($sourcePaths[$relativePath])
            try {
                $destination = $entry.Open()
                try {
                    $source.CopyTo($destination)
                }
                finally {
                    $destination.Dispose()
                }
            }
            finally {
                $source.Dispose()
            }
        }
        $entry = $archive.CreateEntry("$rootFolder/release-manifest.json", [IO.Compression.CompressionLevel]::Optimal)
        $entry.LastWriteTime = $fixedTimestamp
        $destination = $entry.Open()
        try { $destination.Write($manifestBytes, 0, $manifestBytes.Length) }
        finally { $destination.Dispose() }
    }
    finally {
        $archive.Dispose()
    }
}
finally {
    $stream.Dispose()
}

$hash = Get-FileHash -LiteralPath $archivePath -Algorithm SHA256
[IO.File]::WriteAllText("$archivePath.sha256", "$($hash.Hash.ToLowerInvariant())  $archiveName`n", [Text.UTF8Encoding]::new($false))
[pscustomobject]@{
    Version = $version
    Path = (Resolve-Path -LiteralPath $archivePath).Path
    FileName = $archiveName
    RootFolder = $rootFolder
    FileCount = $relativeFiles.Count + 1
    Files = @($relativeFiles) + 'release-manifest.json'
    SourceCommit = $sourceCommit
    BuiltAtUtc = $manifest.builtAtUtc
    SHA256 = $hash.Hash
}
