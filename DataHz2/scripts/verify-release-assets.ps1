[CmdletBinding()]
param(
    [string]$AssetsDir = "",
    [string]$Tag = "",
    [string[]]$Runtimes = @("win-x64", "win-arm64"),
    [string]$OutputIndexFile = "",
    [string]$OutputSha256ListFile = ""
)

$ErrorActionPreference = "Stop"

function Read-PackageShaExpected([string]$ShaFile) {
    $firstLine = Get-Content $ShaFile | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($firstLine)) {
        throw "Invalid sha256 file (empty): $ShaFile"
    }

    $expected = ($firstLine -split "\s+")[0].Trim()
    if ([string]::IsNullOrWhiteSpace($expected) -or $expected.Length -lt 32) {
        throw "Invalid sha256 content: $ShaFile"
    }

    return $expected.ToLowerInvariant()
}

function Ensure-ParentDir([string]$Path) {
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
}

if ([string]::IsNullOrWhiteSpace($AssetsDir)) {
    throw "AssetsDir is required."
}

if ([string]::IsNullOrWhiteSpace($Tag)) {
    throw "Tag is required."
}

$resolvedAssetsDir = [System.IO.Path]::GetFullPath($AssetsDir)
if (-not (Test-Path $resolvedAssetsDir)) {
    throw "AssetsDir not found: $resolvedAssetsDir"
}

$verifyScript = Join-Path $PSScriptRoot "verify-release.ps1"
if (-not (Test-Path $verifyScript)) {
    throw "verify-release.ps1 not found: $verifyScript"
}

$normalizedTag = $Tag.Trim()
if ([string]::IsNullOrWhiteSpace($OutputIndexFile)) {
    $OutputIndexFile = Join-Path $resolvedAssetsDir ("datahz2-release-" + $normalizedTag + ".index.json")
}
if ([string]::IsNullOrWhiteSpace($OutputSha256ListFile)) {
    $OutputSha256ListFile = Join-Path $resolvedAssetsDir ("datahz2-release-" + $normalizedTag + ".sha256")
}

$OutputIndexFile = [System.IO.Path]::GetFullPath($OutputIndexFile)
$OutputSha256ListFile = [System.IO.Path]::GetFullPath($OutputSha256ListFile)
Ensure-ParentDir -Path $OutputIndexFile
Ensure-ParentDir -Path $OutputSha256ListFile

$results = New-Object System.Collections.Generic.List[object]
$assetFiles = New-Object System.Collections.Generic.List[string]

foreach ($runtime in $Runtimes) {
    $rt = $runtime.Trim()
    if ([string]::IsNullOrWhiteSpace($rt)) {
        continue
    }

    $base = "datahz2-api-$rt-$Tag"
    $zip = Join-Path $resolvedAssetsDir ($base + ".zip")
    $sha = Join-Path $resolvedAssetsDir ($base + ".sha256")
    $manifest = Join-Path $resolvedAssetsDir ($base + ".manifest.json")

    if (-not (Test-Path $zip)) {
        throw "Missing release asset zip: $zip"
    }
    if (-not (Test-Path $sha)) {
        throw "Missing release asset sha256: $sha"
    }
    if (-not (Test-Path $manifest)) {
        throw "Missing release asset manifest: $manifest"
    }

    & $verifyScript `
        -PackageZip $zip `
        -PackageSha256File $sha `
        -PackageManifestFile $manifest

    $expectedSha = Read-PackageShaExpected -ShaFile $sha
    $zipInfo = Get-Item -Path $zip
    $manifestInfo = Get-Item -Path $manifest
    $shaInfo = Get-Item -Path $sha

    $results.Add([pscustomobject]@{
        Runtime = $rt
        Zip = [System.IO.Path]::GetFileName($zip)
        Sha256 = [System.IO.Path]::GetFileName($sha)
        Manifest = [System.IO.Path]::GetFileName($manifest)
        PackageSha256 = $expectedSha
        ZipSizeBytes = $zipInfo.Length
        ManifestSizeBytes = $manifestInfo.Length
        Sha256FileSizeBytes = $shaInfo.Length
    })

    $assetFiles.Add($zip)
    $assetFiles.Add($sha)
    $assetFiles.Add($manifest)
}

$assetMetadata = @()
foreach ($path in $assetFiles) {
    $fileInfo = Get-Item -Path $path
    $assetMetadata += [ordered]@{
        file = [System.IO.Path]::GetFileName($path)
        sizeBytes = $fileInfo.Length
        sha256 = (Get-FileHash -Path $path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

$index = [ordered]@{
    formatVersion = 1
    tag = $normalizedTag
    generatedUtc = (Get-Date).ToUniversalTime().ToString("o")
    runtimeCount = $results.Count
    runtimes = $results.ToArray()
    assets = $assetMetadata
    provenance = [ordered]@{
        repository = $env:GITHUB_REPOSITORY
        ref = $env:GITHUB_REF
        refName = $env:GITHUB_REF_NAME
        sha = $env:GITHUB_SHA
        runId = $env:GITHUB_RUN_ID
        runNumber = $env:GITHUB_RUN_NUMBER
        runAttempt = $env:GITHUB_RUN_ATTEMPT
        actor = $env:GITHUB_ACTOR
        serverUrl = $env:GITHUB_SERVER_URL
        workflow = $env:GITHUB_WORKFLOW
    }
    generatedBy = [ordered]@{
        script = [System.IO.Path]::GetFileName($PSCommandPath)
        powershellVersion = $PSVersionTable.PSVersion.ToString()
        machine = $env:COMPUTERNAME
    }
}

$index | ConvertTo-Json -Depth 8 | Set-Content -Path $OutputIndexFile -Encoding UTF8

$shaEntries = New-Object System.Collections.Generic.List[string]
foreach ($path in $assetFiles) {
    $hash = (Get-FileHash -Path $path -Algorithm SHA256).Hash.ToLowerInvariant()
    $name = [System.IO.Path]::GetFileName($path)
    $shaEntries.Add("$hash  $name")
}

$indexHash = (Get-FileHash -Path $OutputIndexFile -Algorithm SHA256).Hash.ToLowerInvariant()
$indexName = [System.IO.Path]::GetFileName($OutputIndexFile)
$shaEntries.Add("$indexHash  $indexName")
Set-Content -Path $OutputSha256ListFile -Value $shaEntries -Encoding UTF8

Write-Host ""
Write-Host "Release assets verification passed."
foreach ($item in $results) {
    Write-Host "  [$($item.Runtime)] $($item.Zip)"
}
Write-Host "  Index: $OutputIndexFile"
Write-Host "  Sha256List: $OutputSha256ListFile"
