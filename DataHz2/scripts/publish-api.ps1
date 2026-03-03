[CmdletBinding()]
param(
    [string]$Configuration = "Release",
    [string]$Runtime = "win-x64",
    [string]$OutputDir = "",
    [switch]$FrameworkDependent,
    [switch]$MultiFile,
    [switch]$ReadyToRun,
    [switch]$Trimmed,
    [switch]$NoRestore
)

$ErrorActionPreference = "Stop"

function Resolve-DotNet {
    $fromPath = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($fromPath) {
        return $fromPath.Source
    }

    $fallback = "$env:ProgramFiles\dotnet\dotnet.exe"
    if (Test-Path $fallback) {
        return $fallback
    }

    throw "dotnet not found. Install .NET SDK 10.0+."
}

$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $root "artifacts\publish\$Runtime"
}

$OutputDir = [System.IO.Path]::GetFullPath($OutputDir)
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$dotnet = Resolve-DotNet
$project = Join-Path $root "src\DataHz.Api\DataHz.Api.csproj"
$selfContained = -not $FrameworkDependent
$singleFile = -not $MultiFile

$publishArgs = @(
    "publish",
    $project,
    "-c", $Configuration,
    "-r", $Runtime,
    "-o", $OutputDir,
    "-p:SelfContained=$($selfContained.ToString().ToLowerInvariant())",
    "-p:PublishSingleFile=$($singleFile.ToString().ToLowerInvariant())",
    "-p:PublishReadyToRun=$($ReadyToRun.IsPresent.ToString().ToLowerInvariant())",
    "-p:PublishTrimmed=$($Trimmed.IsPresent.ToString().ToLowerInvariant())",
    "-p:DebugType=None",
    "-p:DebugSymbols=false",
    "-p:IncludeNativeLibrariesForSelfExtract=true"
)

if ($NoRestore) {
    $publishArgs += "--no-restore"
}

Write-Host "Publishing DataHz.Api ..."
Write-Host "dotnet: $dotnet"
Write-Host "output: $OutputDir"
Write-Host "self-contained: $selfContained"
Write-Host "single-file: $singleFile"

Push-Location $root
try {
    & $dotnet @publishArgs
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}
finally {
    Pop-Location
}

Write-Host ""
Write-Host "Publish completed." -ForegroundColor Green
Write-Host "Executable: $(Join-Path $OutputDir 'DataHz.Api.exe')"
