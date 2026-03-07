[CmdletBinding()]
param(
    [switch]$NoBuild,
    [switch]$NoBrowser,
    [string]$BaseUrl = "http://127.0.0.1:5080",
    [string]$LaunchPath = "/",
    [ValidateRange(1, 300)]
    [int]$BrowserLaunchTimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$checkScript = Join-Path $PSScriptRoot 'check-dotnet.ps1'

function Normalize-BaseUrl([string]$Url) {
    if ([string]::IsNullOrWhiteSpace($Url)) {
        return "http://127.0.0.1:5080"
    }

    return $Url.Trim().TrimEnd('/')
}

function Normalize-LaunchPath([string]$PathValue) {
    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return "/"
    }

    $trimmed = $PathValue.Trim()
    if ($trimmed.StartsWith('/')) {
        return $trimmed
    }

    return "/$trimmed"
}

function Start-BrowserLaunchJob(
    [string]$TargetUrl,
    [string]$HealthUrl,
    [int]$TimeoutSeconds
) {
    return Start-Job -ScriptBlock {
        param(
            [string]$InnerTargetUrl,
            [string]$InnerHealthUrl,
            [int]$InnerTimeoutSeconds
        )

        $deadline = (Get-Date).AddSeconds([Math]::Max(1, $InnerTimeoutSeconds))
        while ((Get-Date) -lt $deadline) {
            try {
                $response = Invoke-WebRequest -Uri $InnerHealthUrl -UseBasicParsing -TimeoutSec 3
                if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 500) {
                    break
                }
            }
            catch {
            }

            Start-Sleep -Milliseconds 500
        }

        try {
            Start-Process -FilePath $InnerTargetUrl -ErrorAction Stop | Out-Null
            return
        }
        catch {
        }

        try {
            $psi = [System.Diagnostics.ProcessStartInfo]::new($InnerTargetUrl)
            $psi.UseShellExecute = $true
            [System.Diagnostics.Process]::Start($psi) | Out-Null
        }
        catch {
        }
    } -ArgumentList $TargetUrl, $HealthUrl, $TimeoutSeconds
}

& $checkScript -Quiet
if ($LASTEXITCODE -ne 0) {
    Write-Host "dotnet not found. Please install .NET SDK 10.0+ first." -ForegroundColor Yellow
    exit 1
}

$dotnetCmd = Get-Command dotnet -ErrorAction SilentlyContinue
if ($dotnetCmd) {
    $dotnet = $dotnetCmd.Source
} else {
    $dotnet = "$env:ProgramFiles\dotnet\dotnet.exe"
}

$browserJob = $null
$normalizedBaseUrl = Normalize-BaseUrl -Url $BaseUrl
$normalizedLaunchPath = Normalize-LaunchPath -PathValue $LaunchPath
$targetUrl = "$normalizedBaseUrl$normalizedLaunchPath"
$healthUrl = "$normalizedBaseUrl/health"

if (-not $NoBrowser) {
    Write-Host "Browser auto-launch enabled: $targetUrl"
    $browserJob = Start-BrowserLaunchJob `
        -TargetUrl $targetUrl `
        -HealthUrl $healthUrl `
        -TimeoutSeconds $BrowserLaunchTimeoutSeconds
} else {
    Write-Host "Browser auto-launch disabled. Open manually: $targetUrl"
}

Push-Location $root
try {
    & $dotnet restore .\DataHz2.sln
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    if (-not $NoBuild) {
        & $dotnet build .\DataHz2.sln -c Release
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }

    & $dotnet run --project .\src\DataHz.Api\DataHz.Api.csproj --configuration Release --no-build
}
finally {
    Pop-Location
    if ($browserJob) {
        Remove-Job -Id $browserJob.Id -Force -ErrorAction SilentlyContinue
    }
}
