param(
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

function Find-DotNet {
    $fromPath = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($fromPath) {
        return $fromPath.Source
    }

    $candidates = @(
        "$env:ProgramFiles\dotnet\dotnet.exe",
        "$env:ProgramFiles(x86)\dotnet\dotnet.exe",
        "$env:LOCALAPPDATA\Microsoft\dotnet\dotnet.exe"
    )

    foreach ($path in $candidates) {
        if (Test-Path $path) {
            return $path
        }
    }

    return $null
}

$dotnet = Find-DotNet
if (-not $dotnet) {
    if (-not $Quiet) {
        Write-Host "dotnet not found. Install .NET SDK 10.0+ from https://dotnet.microsoft.com/download" -ForegroundColor Yellow
    }
    exit 1
}

$version = & $dotnet --version
if (-not $Quiet) {
    Write-Host "dotnet: $dotnet"
    Write-Host "version: $version"
}

exit 0
