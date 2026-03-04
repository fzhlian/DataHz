[CmdletBinding()]
param(
    [string]$ServiceName = "DataHz.Api",
    [string]$PackageZip = "",
    [string]$PackageSha256File = "",
    [string]$PackageManifestFile = "",
    [string]$PackageIndexFile = "",
    [string]$PackageIndexSha256File = "",
    [string]$PackageUrl = "",
    [string]$PackageSha256Url = "",
    [string]$PackageManifestUrl = "",
    [string]$PackageIndexUrl = "",
    [string]$PackageIndexSha256Url = "",
    [string]$PackageBearerToken = "",
    [string]$ReleaseRoot = "",
    [string]$Urls = "http://0.0.0.0:5080",
    [string]$EnvironmentName = "Production",
    [string]$HealthEndpoint = "/health",
    [int]$HealthTimeoutSeconds = 90,
    [int]$HealthCheckIntervalSeconds = 2,
    [int]$KeepReleases = 5,
    [string]$SmokeApiKey = "",
    [string]$SmokeBearerToken = "",
    [switch]$SmokeRequireAuthenticatedApi,
    [int]$SmokeCheckRetryCount = 5,
    [int]$SmokeCheckRetryDelayMilliseconds = 800,
    [int]$SmokeHealthPollDelayMilliseconds = 500,
    [int]$SmokeWarnCheckDurationMilliseconds = 3000,
    [int]$SmokeFailCheckDurationMilliseconds = 0,
    [int]$SmokeFailureContentSnippetLength = 240,
    [string]$SmokeOutputJsonPath = "",
    [switch]$AllowUnsafeBypass,
    [switch]$SkipServiceInstall,
    [switch]$SkipHealthCheck,
    [string]$LogsRoot = "",
    [string]$RunLabel = "",
    [switch]$SkipRollback,
    [string]$RollbackTargetReleaseId = "",
    [switch]$SkipRollbackSmokeTest,
    [switch]$TreatRollbackSuccessAsSuccess
)

$ErrorActionPreference = "Stop"

function Get-SafeRunLabel([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return "deploy-prod"
    }

    $safe = $Value.Trim()
    $safe = [System.Text.RegularExpressions.Regex]::Replace($safe, "[^a-zA-Z0-9\-_]+", "-")
    $safe = $safe.Trim("-")

    if ([string]::IsNullOrWhiteSpace($safe)) {
        return "deploy-prod"
    }

    return $safe
}

function Resolve-BaseUrl([string]$UrlsText) {
    $first = ($UrlsText -split ";")[0].Trim()
    if (-not [string]::IsNullOrWhiteSpace($first)) {
        $uri = $null
        if ([Uri]::TryCreate($first, [UriKind]::Absolute, [ref]$uri)) {
            $hostName = $uri.Host
            if ($hostName -eq "0.0.0.0" -or $hostName -eq "*" -or $hostName -eq "+") {
                $hostName = "127.0.0.1"
            }

            return "{0}://{1}:{2}" -f $uri.Scheme, $hostName, $uri.Port
        }
    }

    return "http://127.0.0.1:5080"
}

function Save-StatusSnapshot(
    [string]$StatusScriptPath,
    [string]$OutputPath,
    [string]$ServiceNameValue,
    [string]$BaseUrlValue,
    [string]$ReleaseRootValue
) {
    $statusParams = @{
        ServiceName = $ServiceNameValue
        BaseUrl = $BaseUrlValue
        AsJson = $true
    }
    if (-not [string]::IsNullOrWhiteSpace($ReleaseRootValue)) {
        $statusParams.ReleaseRoot = $ReleaseRootValue
    }

    try {
        $statusJson = & $StatusScriptPath @statusParams
        Set-Content -Path $OutputPath -Value $statusJson -Encoding UTF8
    }
    catch {
        $fallback = [ordered]@{
            utc = (Get-Date).ToUniversalTime().ToString("O")
            error = $_.Exception.Message
        }
        $fallback | ConvertTo-Json -Depth 5 | Set-Content -Path $OutputPath -Encoding UTF8
    }
}

function Invoke-StepWithLog(
    [string]$StepName,
    [string]$LogPath,
    [scriptblock]$Operation
) {
    "=== $StepName started at $((Get-Date).ToUniversalTime().ToString("O")) ===" | Out-File -FilePath $LogPath -Encoding UTF8
    try {
        & $Operation *>&1 | Tee-Object -FilePath $LogPath -Append
        "=== $StepName completed at $((Get-Date).ToUniversalTime().ToString("O")) ===" | Out-File -FilePath $LogPath -Append -Encoding UTF8
        return [pscustomobject]@{
            succeeded = $true
            errorMessage = ""
        }
    }
    catch {
        $message = $_ | Out-String
        if (-not [string]::IsNullOrWhiteSpace($message)) {
            $message.TrimEnd() | Out-File -FilePath $LogPath -Append -Encoding UTF8
        }

        "=== $StepName failed at $((Get-Date).ToUniversalTime().ToString("O")) ===" | Out-File -FilePath $LogPath -Append -Encoding UTF8
        return [pscustomobject]@{
            succeeded = $false
            errorMessage = $_.Exception.Message
        }
    }
}

$deployScript = Join-Path $PSScriptRoot "deploy-prod.ps1"
$rollbackScript = Join-Path $PSScriptRoot "rollback-api.ps1"
$statusScript = Join-Path $PSScriptRoot "deployment-status.ps1"

foreach ($scriptPath in @($deployScript, $rollbackScript, $statusScript)) {
    if (-not (Test-Path $scriptPath)) {
        throw "Required script not found: $scriptPath"
    }
}

$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($LogsRoot)) {
    $LogsRoot = Join-Path $root "artifacts\deploy-runs"
}

$LogsRoot = [System.IO.Path]::GetFullPath($LogsRoot)
New-Item -ItemType Directory -Path $LogsRoot -Force | Out-Null

$stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMdd-HHmmss")
$runPrefix = Get-SafeRunLabel -Value $RunLabel
$runId = "$runPrefix-$stamp"
$runDir = Join-Path $LogsRoot $runId
New-Item -ItemType Directory -Path $runDir -Force | Out-Null

$deployLog = Join-Path $runDir "deploy.log"
$rollbackLog = Join-Path $runDir "rollback.log"
$statusBeforePath = Join-Path $runDir "status-before.json"
$statusAfterDeployPath = Join-Path $runDir "status-after-deploy.json"
$statusAfterRollbackPath = Join-Path $runDir "status-after-rollback.json"
$summaryPath = Join-Path $runDir "run-summary.json"

$defaultDeploySmokeReportPath = Join-Path $runDir "deploy-smoke.json"
$defaultRollbackSmokeReportPath = Join-Path $runDir "rollback-smoke.json"

$deploySmokeReportPath = if ([string]::IsNullOrWhiteSpace($SmokeOutputJsonPath)) {
    $defaultDeploySmokeReportPath
}
else {
    [System.IO.Path]::GetFullPath($SmokeOutputJsonPath)
}

$statusBaseUrl = Resolve-BaseUrl -UrlsText $Urls
Save-StatusSnapshot `
    -StatusScriptPath $statusScript `
    -OutputPath $statusBeforePath `
    -ServiceNameValue $ServiceName `
    -BaseUrlValue $statusBaseUrl `
    -ReleaseRootValue $ReleaseRoot

$startedAtUtc = (Get-Date).ToUniversalTime().ToString("O")

$deployParams = @{
    ServiceName = $ServiceName
    Urls = $Urls
    EnvironmentName = $EnvironmentName
    HealthEndpoint = $HealthEndpoint
    HealthTimeoutSeconds = $HealthTimeoutSeconds
    HealthCheckIntervalSeconds = $HealthCheckIntervalSeconds
    KeepReleases = $KeepReleases
    SmokeCheckRetryCount = $SmokeCheckRetryCount
    SmokeCheckRetryDelayMilliseconds = $SmokeCheckRetryDelayMilliseconds
    SmokeHealthPollDelayMilliseconds = $SmokeHealthPollDelayMilliseconds
    SmokeWarnCheckDurationMilliseconds = $SmokeWarnCheckDurationMilliseconds
    SmokeFailCheckDurationMilliseconds = $SmokeFailCheckDurationMilliseconds
    SmokeFailureContentSnippetLength = $SmokeFailureContentSnippetLength
    SmokeOutputJsonPath = $deploySmokeReportPath
}

if (-not [string]::IsNullOrWhiteSpace($PackageZip)) {
    $deployParams.PackageZip = $PackageZip
}
if (-not [string]::IsNullOrWhiteSpace($PackageSha256File)) {
    $deployParams.PackageSha256File = $PackageSha256File
}
if (-not [string]::IsNullOrWhiteSpace($PackageManifestFile)) {
    $deployParams.PackageManifestFile = $PackageManifestFile
}
if (-not [string]::IsNullOrWhiteSpace($PackageIndexFile)) {
    $deployParams.PackageIndexFile = $PackageIndexFile
}
if (-not [string]::IsNullOrWhiteSpace($PackageIndexSha256File)) {
    $deployParams.PackageIndexSha256File = $PackageIndexSha256File
}
if (-not [string]::IsNullOrWhiteSpace($PackageUrl)) {
    $deployParams.PackageUrl = $PackageUrl
}
if (-not [string]::IsNullOrWhiteSpace($PackageSha256Url)) {
    $deployParams.PackageSha256Url = $PackageSha256Url
}
if (-not [string]::IsNullOrWhiteSpace($PackageManifestUrl)) {
    $deployParams.PackageManifestUrl = $PackageManifestUrl
}
if (-not [string]::IsNullOrWhiteSpace($PackageIndexUrl)) {
    $deployParams.PackageIndexUrl = $PackageIndexUrl
}
if (-not [string]::IsNullOrWhiteSpace($PackageIndexSha256Url)) {
    $deployParams.PackageIndexSha256Url = $PackageIndexSha256Url
}
if (-not [string]::IsNullOrWhiteSpace($PackageBearerToken)) {
    $deployParams.PackageBearerToken = $PackageBearerToken
}
if (-not [string]::IsNullOrWhiteSpace($ReleaseRoot)) {
    $deployParams.ReleaseRoot = $ReleaseRoot
}
if (-not [string]::IsNullOrWhiteSpace($SmokeApiKey)) {
    $deployParams.SmokeApiKey = $SmokeApiKey
}
if (-not [string]::IsNullOrWhiteSpace($SmokeBearerToken)) {
    $deployParams.SmokeBearerToken = $SmokeBearerToken
}
if ($SmokeRequireAuthenticatedApi) {
    $deployParams.SmokeRequireAuthenticatedApi = $true
}
if ($AllowUnsafeBypass) {
    $deployParams.AllowUnsafeBypass = $true
}
if ($SkipServiceInstall) {
    $deployParams.SkipServiceInstall = $true
}
if ($SkipHealthCheck) {
    $deployParams.SkipHealthCheck = $true
}

Write-Host "Starting deploy run with auto rollback wrapper."
Write-Host "  RunId: $runId"
Write-Host "  RunDir: $runDir"
Write-Host "  StatusBaseUrl: $statusBaseUrl"

$deployStep = Invoke-StepWithLog -StepName "deploy-prod" -LogPath $deployLog -Operation {
    & $deployScript @deployParams
}

Save-StatusSnapshot `
    -StatusScriptPath $statusScript `
    -OutputPath $statusAfterDeployPath `
    -ServiceNameValue $ServiceName `
    -BaseUrlValue $statusBaseUrl `
    -ReleaseRootValue $ReleaseRoot

$rollbackAttempted = $false
$rollbackSucceeded = $false
$rollbackErrorMessage = ""
$rollbackSmokeReportPath = ""

if (-not $deployStep.succeeded -and -not $SkipRollback) {
    $rollbackAttempted = $true

    $rollbackSmokeReportPath = $defaultRollbackSmokeReportPath
    $rollbackParams = @{
        ServiceName = $ServiceName
        Urls = $Urls
        EnvironmentName = $EnvironmentName
        HealthEndpoint = $HealthEndpoint
        HealthTimeoutSeconds = $HealthTimeoutSeconds
        HealthCheckIntervalSeconds = $HealthCheckIntervalSeconds
        SmokeCheckRetryCount = $SmokeCheckRetryCount
        SmokeCheckRetryDelayMilliseconds = $SmokeCheckRetryDelayMilliseconds
        SmokeHealthPollDelayMilliseconds = $SmokeHealthPollDelayMilliseconds
        SmokeWarnCheckDurationMilliseconds = $SmokeWarnCheckDurationMilliseconds
        SmokeFailCheckDurationMilliseconds = $SmokeFailCheckDurationMilliseconds
        SmokeFailureContentSnippetLength = $SmokeFailureContentSnippetLength
    }

    if (-not [string]::IsNullOrWhiteSpace($ReleaseRoot)) {
        $rollbackParams.ReleaseRoot = $ReleaseRoot
    }
    if (-not [string]::IsNullOrWhiteSpace($RollbackTargetReleaseId)) {
        $rollbackParams.TargetReleaseId = $RollbackTargetReleaseId
    }
    if (-not [string]::IsNullOrWhiteSpace($SmokeApiKey)) {
        $rollbackParams.SmokeApiKey = $SmokeApiKey
    }
    if (-not [string]::IsNullOrWhiteSpace($SmokeBearerToken)) {
        $rollbackParams.SmokeBearerToken = $SmokeBearerToken
    }
    if ($SmokeRequireAuthenticatedApi) {
        $rollbackParams.SmokeRequireAuthenticatedApi = $true
    }
    if (-not $SkipRollbackSmokeTest) {
        $rollbackParams.RunSmokeTest = $true
        $rollbackParams.SmokeOutputJsonPath = $rollbackSmokeReportPath
    }

    $rollbackStep = Invoke-StepWithLog -StepName "rollback-api" -LogPath $rollbackLog -Operation {
        & $rollbackScript @rollbackParams
    }
    $rollbackSucceeded = $rollbackStep.succeeded
    $rollbackErrorMessage = $rollbackStep.errorMessage
}

Save-StatusSnapshot `
    -StatusScriptPath $statusScript `
    -OutputPath $statusAfterRollbackPath `
    -ServiceNameValue $ServiceName `
    -BaseUrlValue $statusBaseUrl `
    -ReleaseRootValue $ReleaseRoot

$summary = [ordered]@{
    runId = $runId
    startedAtUtc = $startedAtUtc
    completedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    serviceName = $ServiceName
    urls = $Urls
    releaseRoot = if ([string]::IsNullOrWhiteSpace($ReleaseRoot)) { "" } else { [System.IO.Path]::GetFullPath($ReleaseRoot) }
    deploy = [ordered]@{
        succeeded = [bool]$deployStep.succeeded
        errorMessage = $deployStep.errorMessage
        logPath = $deployLog
        smokeReportPath = $deploySmokeReportPath
    }
    rollback = [ordered]@{
        attempted = $rollbackAttempted
        skipped = [bool]$SkipRollback
        targetReleaseId = $RollbackTargetReleaseId
        succeeded = $rollbackSucceeded
        errorMessage = $rollbackErrorMessage
        logPath = if ($rollbackAttempted) { $rollbackLog } else { "" }
        smokeReportPath = $rollbackSmokeReportPath
    }
    snapshots = [ordered]@{
        before = $statusBeforePath
        afterDeploy = $statusAfterDeployPath
        afterRollback = $statusAfterRollbackPath
    }
}

$summary | ConvertTo-Json -Depth 10 | Set-Content -Path $summaryPath -Encoding UTF8

$archivePath = Join-Path $LogsRoot "$runId.zip"
if (Test-Path $archivePath) {
    Remove-Item -Path $archivePath -Force
}

try {
    Compress-Archive -Path $runDir -DestinationPath $archivePath -Force
}
catch {
    Write-Warning "Failed to archive run directory: $($_.Exception.Message)"
}

Write-Host "Deploy auto rollback run completed."
Write-Host "  DeploySucceeded: $($deployStep.succeeded)"
Write-Host "  RollbackAttempted: $rollbackAttempted"
Write-Host "  RollbackSucceeded: $rollbackSucceeded"
Write-Host "  Summary: $summaryPath"
Write-Host "  Archive: $archivePath"

if ($deployStep.succeeded) {
    exit 0
}

if ($rollbackAttempted -and $rollbackSucceeded -and $TreatRollbackSuccessAsSuccess) {
    exit 0
}

if ($rollbackAttempted -and -not $rollbackSucceeded) {
    exit 2
}

exit 1
