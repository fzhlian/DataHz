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
    [int]$SmokeCheckRetryCount = 3,
    [int]$SmokeCheckRetryDelayMilliseconds = 500,
    [int]$SmokeHealthPollDelayMilliseconds = 500,
    [int]$SmokeWarnCheckDurationMilliseconds = 0,
    [int]$SmokeFailCheckDurationMilliseconds = 0,
    [int]$SmokeFailureContentSnippetLength = 240,
    [string]$SmokeOutputJsonPath = "",
    [switch]$AllowUnsafeBypass,
    [switch]$SkipServiceInstall,
    [switch]$SkipHealthCheck
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($PackageZip) -and [string]::IsNullOrWhiteSpace($PackageUrl)) {
    throw "Production deploy requires PackageZip or PackageUrl."
}

if (-not [string]::IsNullOrWhiteSpace($PackageZip) -and -not [string]::IsNullOrWhiteSpace($PackageUrl)) {
    throw "PackageZip and PackageUrl are mutually exclusive. Use only one."
}

if (-not [string]::IsNullOrWhiteSpace($PackageUrl) -and [string]::IsNullOrWhiteSpace($PackageManifestUrl)) {
    throw "Production deploy from PackageUrl requires PackageManifestUrl."
}

if (-not [string]::IsNullOrWhiteSpace($PackageIndexFile) -and -not [string]::IsNullOrWhiteSpace($PackageIndexUrl)) {
    throw "PackageIndexFile and PackageIndexUrl are mutually exclusive. Use only one."
}

if (-not [string]::IsNullOrWhiteSpace($PackageIndexUrl) -and [string]::IsNullOrWhiteSpace($PackageUrl)) {
    throw "PackageIndexUrl requires PackageUrl."
}

if (-not [string]::IsNullOrWhiteSpace($PackageIndexSha256File) -and -not [string]::IsNullOrWhiteSpace($PackageIndexSha256Url)) {
    throw "PackageIndexSha256File and PackageIndexSha256Url are mutually exclusive. Use only one."
}

if (-not [string]::IsNullOrWhiteSpace($PackageIndexSha256Url) -and [string]::IsNullOrWhiteSpace($PackageIndexUrl)) {
    throw "PackageIndexSha256Url requires PackageIndexUrl."
}

if (($SkipServiceInstall -or $SkipHealthCheck) -and -not $AllowUnsafeBypass) {
    throw "SkipServiceInstall/SkipHealthCheck are blocked in deploy-prod.ps1. Add -AllowUnsafeBypass only for test environments."
}

$deployScript = Join-Path $PSScriptRoot "deploy-api.ps1"
if (-not (Test-Path $deployScript)) {
    throw "deploy-api.ps1 not found: $deployScript"
}

$deployParams = @{
    ServiceName = $ServiceName
    RequireManifest = $true
    RunSmokeTest = $true
    Urls = $Urls
    EnvironmentName = $EnvironmentName
    HealthEndpoint = $HealthEndpoint
    HealthTimeoutSeconds = $HealthTimeoutSeconds
    HealthCheckIntervalSeconds = $HealthCheckIntervalSeconds
    KeepReleases = $KeepReleases
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
$deployParams.SmokeCheckRetryCount = $SmokeCheckRetryCount
$deployParams.SmokeCheckRetryDelayMilliseconds = $SmokeCheckRetryDelayMilliseconds
$deployParams.SmokeHealthPollDelayMilliseconds = $SmokeHealthPollDelayMilliseconds
$deployParams.SmokeWarnCheckDurationMilliseconds = $SmokeWarnCheckDurationMilliseconds
$deployParams.SmokeFailCheckDurationMilliseconds = $SmokeFailCheckDurationMilliseconds
$deployParams.SmokeFailureContentSnippetLength = $SmokeFailureContentSnippetLength
if (-not [string]::IsNullOrWhiteSpace($SmokeOutputJsonPath)) {
    $deployParams.SmokeOutputJsonPath = $SmokeOutputJsonPath
}
if ($SkipServiceInstall) {
    $deployParams.SkipServiceInstall = $true
}
if ($SkipHealthCheck) {
    $deployParams.SkipHealthCheck = $true
}

Write-Host "Production deployment profile enabled."
Write-Host "  RequireManifest: true"
Write-Host "  RunSmokeTest: true"
Write-Host "  Source: $(if (-not [string]::IsNullOrWhiteSpace($PackageUrl)) { "package-url" } else { "package-zip" })"
Write-Host "  SmokeCheckRetryCount: $SmokeCheckRetryCount"
Write-Host "  SmokeCheckRetryDelayMilliseconds: $SmokeCheckRetryDelayMilliseconds"
Write-Host "  SmokeHealthPollDelayMilliseconds: $SmokeHealthPollDelayMilliseconds"
Write-Host "  SmokeWarnCheckDurationMilliseconds: $SmokeWarnCheckDurationMilliseconds"
Write-Host "  SmokeFailCheckDurationMilliseconds: $SmokeFailCheckDurationMilliseconds"
Write-Host "  SmokeFailureContentSnippetLength: $SmokeFailureContentSnippetLength"
Write-Host "  SmokeOutputJsonPath: $(if (-not [string]::IsNullOrWhiteSpace($SmokeOutputJsonPath)) { $SmokeOutputJsonPath } else { '<none>' })"
if ($AllowUnsafeBypass) {
    Write-Host "  UnsafeBypass: true (test-only)"
}

& $deployScript @deployParams
