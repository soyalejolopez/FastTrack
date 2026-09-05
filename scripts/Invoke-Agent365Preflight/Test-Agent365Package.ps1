#requires -Version 7.0
[CmdletBinding()]
param([switch]$RequireSigned)

$ErrorActionPreference = 'Stop'
$manifestPath = Join-Path $PSScriptRoot 'release-manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw 'This is an unpackaged source folder. Obtain the published package and its independently published SHA256 checksum.'
}
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -Depth 30
if ($manifest.manifestVersion -ne '2.0' -or $manifest.files -isnot [Array] -or $manifest.files.Count -eq 0) {
    throw 'Unsupported or empty release manifest.'
}
$listed = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($entry in $manifest.files) {
    if ($entry.path -match '(^[\\/]|^[a-zA-Z]:|(^|[\\/])\.\.([\\/]|$))') { throw 'Unsafe manifest file path.' }
    $path = Join-Path $PSScriptRoot $entry.path
    $relativePath = $entry.path.Replace('/', '\')
    if (-not $listed.Add($relativePath)) { throw "Duplicate manifest entry: $relativePath" }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing package file: $($entry.path)" }
    if ((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Package file must not be a link: $($entry.path)" }
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $entry.sha256) { throw "Package hash mismatch: $($entry.path)" }
}
foreach ($required in @('Start-Agent365Preflight.ps1', 'Invoke-Agent365Preflight.ps1', 'Agent365Preflight.psm1', 'Agent365Preflight.psd1', 'Test-Agent365Package.ps1', 'LICENSE', 'LICENSE-CODE')) {
    if (-not $listed.Contains($required)) { throw "Required runtime file is absent from the manifest: $required" }
}
$root = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
foreach ($item in Get-ChildItem -LiteralPath $PSScriptRoot -Recurse -Force) {
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Package directories and files must not contain links.' }
    if ($item.PSIsContainer) { continue }
    $relative = $item.FullName.Substring($root.Length).Replace('/', '\')
    if ($relative -ne 'release-manifest.json' -and -not $listed.Contains($relative)) {
        throw "Unlisted file in package. Keep reports outside the extracted package: $relative"
    }
}
if ($IsWindows) {
    $unsigned = 0
    foreach ($entry in @($manifest.files | Where-Object path -Match '\.(ps1|psm1|psd1)$')) {
        $signature = Get-AuthenticodeSignature -LiteralPath (Join-Path $PSScriptRoot $entry.path)
        if ($signature.Status -eq 'NotSigned') { $unsigned++; continue }
        if ($signature.Status -ne 'Valid') { throw "Invalid Authenticode signature: $($entry.path). Status: $($signature.Status)" }
    }
    if ($unsigned -gt 0) {
        if ($RequireSigned) { throw "$unsigned package scripts are unsigned; organizational signing policy is not met." }
        Write-Warning "$unsigned scripts are unsigned. A checksum detects changes but does not authenticate the publisher. Verify the release source and your organization's approval."
    }
}
elseif ($RequireSigned) {
    throw 'Authenticode verification requires Windows. Verify on an approved Windows host before use.'
}
else {
    Write-Warning 'Authenticode was not checked on this platform. This release is unsigned.'
}
[pscustomobject]@{ Version = $manifest.version; SourceCommit = $manifest.sourceCommit; FilesVerified = @($manifest.files).Count; SignedRequired = [bool]$RequireSigned }
