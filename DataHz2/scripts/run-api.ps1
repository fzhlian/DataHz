$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$checkScript = Join-Path $PSScriptRoot 'check-dotnet.ps1'

& $checkScript -Quiet
if ($LASTEXITCODE -ne 0) {
    Write-Host "dotnet not found. Please install .NET SDK 10.0+ first." -ForegroundColor Yellow
    exit 1
}

$dotnetCmd = (Get-Command dotnet -ErrorAction SilentlyContinue)
if ($dotnetCmd) {
    $dotnet = $dotnetCmd.Source
} else {
    $dotnet = "$env:ProgramFiles\dotnet\dotnet.exe"
}

Push-Location $root
try {
    & $dotnet restore .\DataHz2.sln
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    & $dotnet build .\DataHz2.sln -c Release
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    & $dotnet run --project .\src\DataHz.Api\DataHz.Api.csproj
}
finally {
    Pop-Location
}
