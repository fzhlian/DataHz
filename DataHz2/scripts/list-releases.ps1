[CmdletBinding()]
param(
    [string]$ReleaseRoot = "",
    [switch]$AsJson
)

$ErrorActionPreference = "Stop"

function Load-History([string]$HistoryFile) {
    if (-not (Test-Path $HistoryFile)) {
        return @()
    }

    try {
        $json = Get-Content $HistoryFile -Raw
        if ([string]::IsNullOrWhiteSpace($json)) {
            return @()
        }

        $value = ConvertFrom-Json -InputObject $json
        if ($null -eq $value) {
            return @()
        }

        return @($value)
    }
    catch {
        return @()
    }
}

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

$historyFile = Join-Path $ReleaseRoot "deploy-history.json"
$activeFile = Join-Path $ReleaseRoot "active-release.txt"
$activeReleaseId = Get-ActiveReleaseId -ActiveFile $activeFile
$history = Load-History -HistoryFile $historyFile

$dirs = Get-ChildItem -Path $ReleaseRoot -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match "^\d{8}-\d{6}$" } |
    Sort-Object Name -Descending

$items = foreach ($dir in $dirs) {
    $releaseId = $dir.Name
    $exePath = Join-Path $dir.FullName "DataHz.Api.exe"
    $latest = $history |
        Where-Object { $_.releaseId -eq $releaseId } |
        Sort-Object startedAtUtc -Descending |
        Select-Object -First 1

    [pscustomobject]@{
        ReleaseId = $releaseId
        Active = ($releaseId -eq $activeReleaseId)
        Status = if ($latest) { [string]$latest.status } else { "" }
        Source = if ($latest) { [string]$latest.source } else { "" }
        RequireManifest = if ($latest -and $null -ne $latest.requireManifest) { [bool]$latest.requireManifest } else { $false }
        Manifest = if ($latest -and -not [string]::IsNullOrWhiteSpace([string]$latest.packageManifestFile)) { $true } else { $false }
        Index = if ($latest -and -not [string]::IsNullOrWhiteSpace([string]$latest.packageIndexFile)) { $true } else { $false }
        IndexSha = if ($latest -and -not [string]::IsNullOrWhiteSpace([string]$latest.packageIndexSha256File)) { $true } else { $false }
        StartedAtUtc = if ($latest) { [string]$latest.startedAtUtc } else { "" }
        CompletedAtUtc = if ($latest) { [string]$latest.completedAtUtc } else { "" }
        Directory = $dir.FullName
        HasExecutable = (Test-Path $exePath)
    }
}

if ($AsJson) {
    $items | ConvertTo-Json -Depth 6
}
else {
    if ($items.Count -eq 0) {
        Write-Host "No release directories found under: $ReleaseRoot"
        exit 0
    }

    $items | Format-Table -AutoSize ReleaseId, Active, Status, Source, RequireManifest, Manifest, Index, IndexSha, HasExecutable, StartedAtUtc, CompletedAtUtc
}
