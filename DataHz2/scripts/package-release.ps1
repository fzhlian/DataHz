[CmdletBinding()]
param(
    [string]$InputDir = "",
    [string]$OutputDir = "",
    [string]$Name = "datahz2-api-win-x64",
    [switch]$Overwrite
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($InputDir)) {
    throw "InputDir is required."
}

$root = Split-Path -Parent $PSScriptRoot
$resolvedInput = [System.IO.Path]::GetFullPath($InputDir)
if (-not (Test-Path $resolvedInput)) {
    throw "InputDir not found: $resolvedInput"
}

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $root "artifacts\packages"
}

$resolvedOutput = [System.IO.Path]::GetFullPath($OutputDir)
New-Item -ItemType Directory -Force -Path $resolvedOutput | Out-Null

$normalizedName = $Name.Trim()
if ([string]::IsNullOrWhiteSpace($normalizedName)) {
    throw "Name is empty."
}

$zipPath = Join-Path $resolvedOutput ($normalizedName + ".zip")
$shaPath = Join-Path $resolvedOutput ($normalizedName + ".sha256")
$manifestPath = Join-Path $resolvedOutput ($normalizedName + ".manifest.json")

$existingOutputs = @($zipPath, $shaPath, $manifestPath) | Where-Object { Test-Path $_ }
if (($existingOutputs.Count -gt 0) -and -not $Overwrite) {
    $joined = ($existingOutputs | ForEach-Object { [System.IO.Path]::GetFileName($_) }) -join ", "
    throw "Output files already exist: $joined (use -Overwrite to replace)"
}

if (Test-Path $zipPath) {
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
}

if (Test-Path $shaPath) {
    Remove-Item $shaPath -Force -ErrorAction SilentlyContinue
}

if (Test-Path $manifestPath) {
    Remove-Item $manifestPath -Force -ErrorAction SilentlyContinue
}

Compress-Archive -Path (Join-Path $resolvedInput "*") -DestinationPath $zipPath -CompressionLevel Optimal
$hash = Get-FileHash -Path $zipPath -Algorithm SHA256
"$($hash.Hash)  $([System.IO.Path]::GetFileName($zipPath))" | Set-Content -Path $shaPath -Encoding UTF8

$inputFiles = @(Get-ChildItem -Path $resolvedInput -File -Recurse | Sort-Object FullName)
$manifestFiles = @()
foreach ($file in $inputFiles) {
    $fullPath = [System.IO.Path]::GetFullPath($file.FullName)
    $basePath = $resolvedInput
    if (-not $basePath.EndsWith("\")) {
        $basePath += "\"
    }
    if ($fullPath.StartsWith($basePath, [System.StringComparison]::OrdinalIgnoreCase)) {
        $relativePath = $fullPath.Substring($basePath.Length)
    } else {
        $relativePath = $file.Name
    }
    $relativePath = $relativePath.Replace("\", "/")
    $manifestFiles += [ordered]@{
        path = $relativePath
        sizeBytes = $file.Length
        lastWriteUtc = $file.LastWriteTimeUtc.ToString("o")
    }
}

$zipInfo = Get-Item -Path $zipPath
$manifest = [ordered]@{
    formatVersion = 1
    packageName = $normalizedName
    createdUtc = (Get-Date).ToUniversalTime().ToString("o")
    sourceDirectory = $resolvedInput
    outputDirectory = $resolvedOutput
    package = [ordered]@{
        file = [System.IO.Path]::GetFileName($zipPath)
        sizeBytes = $zipInfo.Length
        sha256 = $hash.Hash.ToLowerInvariant()
        sha256File = [System.IO.Path]::GetFileName($shaPath)
    }
    contents = [ordered]@{
        fileCount = $inputFiles.Count
        files = $manifestFiles
    }
    build = [ordered]@{
        gitSha = $env:GITHUB_SHA
        runId = $env:GITHUB_RUN_ID
        runNumber = $env:GITHUB_RUN_NUMBER
        workflow = $env:GITHUB_WORKFLOW
    }
}

$manifest | ConvertTo-Json -Depth 8 | Set-Content -Path $manifestPath -Encoding UTF8

Write-Host "Package created."
Write-Host "  Zip: $zipPath"
Write-Host "  Sha256: $shaPath"
Write-Host "  Manifest: $manifestPath"
