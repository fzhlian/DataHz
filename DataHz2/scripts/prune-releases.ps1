[CmdletBinding()]
param(
    [string]$ReleaseRoot = "",
    [int]$KeepReleases = 5,
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

function Get-ActiveReleaseId([string]$ActiveFile) {
    if (-not (Test-Path $ActiveFile)) {
        return ""
    }

    $value = Get-Content $ActiveFile -Raw
    if ([string]::IsNullOrWhiteSpace($value)) {
        return ""
    }

    return $value.Trim()
}

$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ReleaseRoot)) {
    $ReleaseRoot = Join-Path $root "artifacts\releases"
}

$ReleaseRoot = [System.IO.Path]::GetFullPath($ReleaseRoot)
if (-not (Test-Path $ReleaseRoot)) {
    Write-Host "Release root not found: $ReleaseRoot"
    exit 0
}

$KeepReleases = [Math]::Max(1, $KeepReleases)
$activeFile = Join-Path $ReleaseRoot "active-release.txt"
$activeReleaseId = Get-ActiveReleaseId -ActiveFile $activeFile

$releaseDirs = Get-ChildItem -Path $ReleaseRoot -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match "^\d{8}-\d{6}$" } |
    Sort-Object Name -Descending

if ($releaseDirs.Count -le $KeepReleases) {
    Write-Host "No prune needed. Release count=$($releaseDirs.Count), keep=$KeepReleases."
    exit 0
}

$removeList = $releaseDirs | Select-Object -Skip $KeepReleases
$removed = 0
$skipped = 0
$downloadRemoved = 0
$downloadRoot = Join-Path $ReleaseRoot "_downloads"

foreach ($dir in $removeList) {
    if ($dir.Name -eq $activeReleaseId) {
        $skipped++
        Write-Host "Skip active release: $($dir.Name)"
        continue
    }

    if ($WhatIf) {
        Write-Host "[WhatIf] Remove: $($dir.FullName)"
        $downloadDir = Join-Path $downloadRoot $dir.Name
        if (Test-Path $downloadDir) {
            Write-Host "[WhatIf] Remove download cache: $downloadDir"
        }
        continue
    }

    Remove-Item -Path $dir.FullName -Recurse -Force -ErrorAction SilentlyContinue
    $removed++
    Write-Host "Removed: $($dir.FullName)"

    $downloadDir = Join-Path $downloadRoot $dir.Name
    if (Test-Path $downloadDir) {
        Remove-Item -Path $downloadDir -Recurse -Force -ErrorAction SilentlyContinue
        $downloadRemoved++
        Write-Host "Removed download cache: $downloadDir"
    }
}

if ($WhatIf) {
    Write-Host "Prune simulation completed. Candidate count=$($removeList.Count), skippedActive=$skipped."
}
else {
    Write-Host "Prune completed. Removed=$removed, skippedActive=$skipped, downloadCacheRemoved=$downloadRemoved."
}
