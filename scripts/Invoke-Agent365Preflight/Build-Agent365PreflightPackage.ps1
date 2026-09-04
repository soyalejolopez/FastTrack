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
    [switch]$Force
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
    'config\guidance.v1.json'
    'config\operation-allowlist.v1.json'
    'config\rules.v1.json'
    'config\sku-catalog.v1.json'
    'schema\agent365-preflight-answers.schema.json'
    'schema\agent365-preflight-report.schema.json'
    'samples\answers.sample.json'
    'fixtures\commercial-ready.json'
)

foreach ($relativePath in $relativeFiles) {
    $sourcePath = Join-Path $resourceRoot $relativePath
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "Required package file was not found: $relativePath"
    }
}

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
            $source = [System.IO.File]::OpenRead((Join-Path $resourceRoot $relativePath))
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
    }
    finally {
        $archive.Dispose()
    }
}
finally {
    $stream.Dispose()
}

$hash = Get-FileHash -LiteralPath $archivePath -Algorithm SHA256
[pscustomobject]@{
    Version = $version
    Path = (Resolve-Path -LiteralPath $archivePath).Path
    FileName = $archiveName
    RootFolder = $rootFolder
    FileCount = $relativeFiles.Count
    Files = @($relativeFiles)
    SHA256 = $hash.Hash
}
