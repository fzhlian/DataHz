[CmdletBinding()]
param(
    [string]$ServiceName = "DataHz.Api",
    [string]$ReleaseRoot = "",
    [string]$TargetReleaseId = "",
    [string]$Urls = "http://0.0.0.0:5080",
    [string]$EnvironmentName = "Production",
    [string]$HealthEndpoint = "/health",
    [int]$HealthTimeoutSeconds = 60,
    [int]$HealthCheckIntervalSeconds = 2,
    [switch]$RunSmokeTest,
    [string]$SmokeApiKey = "",
    [string]$SmokeBearerToken = "",
    [switch]$SmokeRequireAuthenticatedApi,
    [int]$SmokeCheckRetryCount = 3,
    [int]$SmokeCheckRetryDelayMilliseconds = 500,
    [int]$SmokeHealthPollDelayMilliseconds = 500,
    [int]$SmokeWarnCheckDurationMilliseconds = 0,
    [int]$SmokeFailCheckDurationMilliseconds = 0,
    [int]$SmokeFailureContentSnippetLength = 240,
    [string]$SmokeOutputJsonPath = "",
    [switch]$SkipHealthCheck
)

$ErrorActionPreference = "Stop"

function Assert-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        throw "Administrator privileges required. Run PowerShell as Administrator."
    }
}

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

function Save-History([string]$HistoryFile, [array]$HistoryItems) {
    $json = ConvertTo-Json -InputObject @($HistoryItems) -Depth 10
    Set-Content -Path $HistoryFile -Value $json -Encoding UTF8
}

function Get-ActiveReleaseId([string]$ActiveFile) {
    if (-not (Test-Path $ActiveFile)) {
        return ""
    }

    $value = Get-Content $ActiveFile -Raw
    return if ([string]::IsNullOrWhiteSpace($value)) { "" } else { $value.Trim() }
}

function Set-ActiveReleaseId([string]$ActiveFile, [string]$ReleaseId) {
    Set-Content -Path $ActiveFile -Value $ReleaseId -Encoding UTF8
}

function Resolve-HealthUrl([string]$UrlsText, [string]$HealthPath) {
    $first = ($UrlsText -split ";")[0].Trim()
    if (-not [string]::IsNullOrWhiteSpace($first)) {
        $uri = $null
        if ([Uri]::TryCreate($first, [UriKind]::Absolute, [ref]$uri)) {
            $hostName = $uri.Host
            if ($hostName -eq "0.0.0.0" -or $hostName -eq "*" -or $hostName -eq "+") {
                $hostName = "127.0.0.1"
            }

            $path = if ($HealthPath.StartsWith("/")) { $HealthPath } else { "/" + $HealthPath }
            return "{0}://{1}:{2}{3}" -f $uri.Scheme, $hostName, $uri.Port, $path
        }
    }

    return "http://127.0.0.1:5080/health"
}

function Wait-ForHealth([string]$Url, [int]$TimeoutSeconds, [int]$IntervalSeconds) {
    $timeoutAt = (Get-Date).AddSeconds([Math]::Max(5, $TimeoutSeconds))
    $sleepSeconds = [Math]::Max(1, $IntervalSeconds)

    while ((Get-Date) -lt $timeoutAt) {
        try {
            $response = Invoke-WebRequest -Uri $Url -TimeoutSec 5 -UseBasicParsing
            if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300) {
                $content = $response.Content
                if ([string]::IsNullOrWhiteSpace($content)) {
                    return $true
                }

                try {
                    $json = $content | ConvertFrom-Json
                    if ($null -ne $json -and ($json.status -eq "ok" -or $json.Status -eq "ok")) {
                        return $true
                    }
                }
                catch {
                    return $true
                }
            }
        }
        catch {
        }

        Start-Sleep -Seconds $sleepSeconds
    }

    return $false
}

Assert-Admin

$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ReleaseRoot)) {
    $ReleaseRoot = Join-Path $root "artifacts\releases"
}

$ReleaseRoot = [System.IO.Path]::GetFullPath($ReleaseRoot)
if (-not (Test-Path $ReleaseRoot)) {
    throw "Release root not found: $ReleaseRoot"
}

$historyFile = Join-Path $ReleaseRoot "deploy-history.json"
$activeFile = Join-Path $ReleaseRoot "active-release.txt"
$installScript = Join-Path $PSScriptRoot "install-windows-service.ps1"
$smokeScript = Join-Path $PSScriptRoot "smoke-test-api.ps1"

$history = Load-History -HistoryFile $historyFile
$activeReleaseId = Get-ActiveReleaseId -ActiveFile $activeFile

if ([string]::IsNullOrWhiteSpace($TargetReleaseId)) {
    $candidate = $history |
        Where-Object {
            $_.status -eq "succeeded" -or $_.status -eq "published-only"
        } |
        Sort-Object startedAtUtc -Descending |
        Where-Object {
            $_.releaseId -ne $activeReleaseId
        } |
        Select-Object -First 1

    if ($candidate) {
        $TargetReleaseId = [string]$candidate.releaseId
    }
}

if ([string]::IsNullOrWhiteSpace($TargetReleaseId)) {
    throw "No rollback target found."
}

$targetDir = Join-Path $ReleaseRoot $TargetReleaseId
$targetExe = Join-Path $targetDir "DataHz.Api.exe"
if (-not (Test-Path $targetExe)) {
    throw "Rollback target executable not found: $targetExe"
}

$installParams = @{
    ServiceName = $ServiceName
    PublishDir = $targetDir
    Urls = $Urls
    EnvironmentName = $EnvironmentName
    StartAfterInstall = $true
}
& $installScript @installParams

$healthUrl = Resolve-HealthUrl -UrlsText $Urls -HealthPath $HealthEndpoint
if (-not $SkipHealthCheck) {
    $healthy = Wait-ForHealth -Url $healthUrl -TimeoutSeconds $HealthTimeoutSeconds -IntervalSeconds $HealthCheckIntervalSeconds
    if (-not $healthy) {
        throw "Rollback health check timed out: $healthUrl"
    }
}

if ($RunSmokeTest) {
    $healthUri = [Uri]$healthUrl
    $smokeBaseUrl = "{0}://{1}:{2}" -f $healthUri.Scheme, $healthUri.Host, $healthUri.Port
    $smokeParams = @{
        BaseUrl = $smokeBaseUrl
        ServiceName = $ServiceName
        TimeoutSeconds = [Math]::Max(5, $HealthCheckIntervalSeconds * 5)
        CheckRetryCount = $SmokeCheckRetryCount
        CheckRetryDelayMilliseconds = $SmokeCheckRetryDelayMilliseconds
        HealthPollDelayMilliseconds = $SmokeHealthPollDelayMilliseconds
        WarnCheckDurationMilliseconds = $SmokeWarnCheckDurationMilliseconds
        FailCheckDurationMilliseconds = $SmokeFailCheckDurationMilliseconds
        FailureContentSnippetLength = $SmokeFailureContentSnippetLength
    }
    if (-not [string]::IsNullOrWhiteSpace($SmokeApiKey)) {
        $smokeParams.ApiKey = $SmokeApiKey
    }
    if (-not [string]::IsNullOrWhiteSpace($SmokeBearerToken)) {
        $smokeParams.BearerToken = $SmokeBearerToken
    }
    if ($SmokeRequireAuthenticatedApi) {
        $smokeParams.RequireAuthenticatedApi = $true
    }
    if (-not [string]::IsNullOrWhiteSpace($SmokeOutputJsonPath)) {
        $smokeParams.OutputJsonPath = $SmokeOutputJsonPath
    }

    & $smokeScript @smokeParams
}

Set-ActiveReleaseId -ActiveFile $activeFile -ReleaseId $TargetReleaseId

$entry = [ordered]@{
    releaseId = $TargetReleaseId
    releaseDir = $targetDir
    serviceName = $ServiceName
    startedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    completedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    previousActiveReleaseId = $activeReleaseId
    status = "manual-rollback"
    healthUrl = $healthUrl
}

$history = @($history) + [pscustomobject]$entry
Save-History -HistoryFile $historyFile -HistoryItems $history

Write-Host "Rollback completed."
Write-Host "  TargetReleaseId: $TargetReleaseId"
Write-Host "  TargetDir: $targetDir"
Write-Host "  HealthUrl: $healthUrl"
