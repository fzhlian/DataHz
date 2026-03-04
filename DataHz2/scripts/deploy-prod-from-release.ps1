[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Tag,
    [ValidateSet("win-x64", "win-arm64")]
    [string]$Runtime = "win-x64",
    [string]$Repository = "fzhlian/DataHz",
    [string]$ReleaseDownloadBaseUrl = "",
    [string]$ServiceName = "DataHz.Api",
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
    [switch]$TreatRollbackSuccessAsSuccess,
    [switch]$ValidateAssetUrls,
    [int]$ValidateAssetTimeoutSeconds = 20,
    [int]$ValidateAssetRetryCount = 2,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

function Test-AssetUrl(
    [string]$Url,
    [int]$TimeoutSeconds,
    [int]$RetryCount,
    [hashtable]$Headers
) {
    $attemptLimit = [Math]::Max(1, $RetryCount)
    $timeout = [Math]::Max(1, $TimeoutSeconds)
    $lastDetail = ""
    $lastStatusCode = 0
    $lastMethod = "HEAD"

    for ($attempt = 1; $attempt -le $attemptLimit; $attempt++) {
        foreach ($probeMethod in @("HEAD", "GET")) {
            $methodName = if ($probeMethod -eq "HEAD") { "Head" } else { "Get" }
            try {
                $resp = Invoke-WebRequest `
                    -Uri $Url `
                    -Method $methodName `
                    -Headers $Headers `
                    -TimeoutSec $timeout `
                    -UseBasicParsing

                $lastStatusCode = [int]$resp.StatusCode
                $lastMethod = $probeMethod
                if ($lastStatusCode -ge 200 -and $lastStatusCode -lt 400) {
                    return [pscustomobject]@{
                        Url = $Url
                        Passed = $true
                        StatusCode = $lastStatusCode
                        Attempts = $attempt
                        Method = $probeMethod
                        Detail = "ok"
                    }
                }

                $lastDetail = "HTTP $lastStatusCode"
            }
            catch {
                $statusCode = 0
                if ($_.Exception -and $_.Exception.Response) {
                    try {
                        $statusCode = [int]$_.Exception.Response.StatusCode
                    }
                    catch {
                        $statusCode = 0
                    }
                }

                $lastStatusCode = $statusCode
                $lastMethod = $probeMethod
                $lastDetail = $_.Exception.Message
            }
        }

        if ($attempt -lt $attemptLimit) {
            Start-Sleep -Milliseconds 300
        }
    }

    return [pscustomobject]@{
        Url = $Url
        Passed = $false
        StatusCode = $lastStatusCode
        Attempts = $attemptLimit
        Method = $lastMethod
        Detail = $lastDetail
    }
}

if ([string]::IsNullOrWhiteSpace($Tag)) {
    throw "Tag is required."
}

$normalizedTag = $Tag.Trim()
if (-not $normalizedTag.StartsWith("datahz2-v")) {
    throw "Tag must start with 'datahz2-v'. Received: $normalizedTag"
}

$wrapperScript = Join-Path $PSScriptRoot "deploy-prod-with-auto-rollback.ps1"
if (-not (Test-Path $wrapperScript)) {
    throw "deploy-prod-with-auto-rollback.ps1 not found: $wrapperScript"
}

$normalizedRepository = $Repository.Trim().Trim("/")
$baseUrl = ""
if (-not [string]::IsNullOrWhiteSpace($ReleaseDownloadBaseUrl)) {
    $customBase = $ReleaseDownloadBaseUrl.Trim().TrimEnd("/")
    $uri = $null
    if (-not [Uri]::TryCreate($customBase, [UriKind]::Absolute, [ref]$uri)) {
        throw "ReleaseDownloadBaseUrl must be an absolute URL. Received: $ReleaseDownloadBaseUrl"
    }
    $baseUrl = $customBase
}
else {
    if (-not ($normalizedRepository -like "*/*")) {
        throw "Repository must be in 'owner/name' format. Received: $Repository"
    }
    $baseUrl = "https://github.com/$normalizedRepository/releases/download/$normalizedTag"
}

$assetPrefix = "datahz2-api-$Runtime-$normalizedTag"

$packageUrl = "$baseUrl/$assetPrefix.zip"
$packageSha256Url = "$baseUrl/$assetPrefix.sha256"
$packageManifestUrl = "$baseUrl/$assetPrefix.manifest.json"
$packageIndexUrl = "$baseUrl/datahz2-release-$normalizedTag.index.json"
$packageIndexSha256Url = "$baseUrl/datahz2-release-$normalizedTag.sha256"

$effectiveBearerToken = $PackageBearerToken
if ([string]::IsNullOrWhiteSpace($effectiveBearerToken)) {
    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) {
        $effectiveBearerToken = $env:GITHUB_TOKEN
    }
}

$effectiveRunLabel = $RunLabel
if ([string]::IsNullOrWhiteSpace($effectiveRunLabel)) {
    $effectiveRunLabel = "release-$Runtime-$normalizedTag"
}

$assetValidationResults = @()
if ($ValidateAssetUrls) {
    $headers = @{}
    if (-not [string]::IsNullOrWhiteSpace($effectiveBearerToken)) {
        $headers["Authorization"] = "Bearer $effectiveBearerToken"
    }

    $assetUrls = @(
        $packageUrl,
        $packageSha256Url,
        $packageManifestUrl,
        $packageIndexUrl,
        $packageIndexSha256Url
    )

    $assetValidationResults = @($assetUrls | ForEach-Object {
        Test-AssetUrl `
            -Url $_ `
            -TimeoutSeconds $ValidateAssetTimeoutSeconds `
            -RetryCount $ValidateAssetRetryCount `
            -Headers $headers
    })

    $failed = @($assetValidationResults | Where-Object { -not $_.Passed })
    if ($failed.Count -gt 0) {
        $details = $failed | ForEach-Object {
            "$($_.Url) status=$($_.StatusCode) detail=$($_.Detail)"
        }
        throw "Asset URL validation failed for $($failed.Count) file(s). $($details -join '; ')"
    }
}

$deployParams = @{
    ServiceName = $ServiceName
    PackageUrl = $packageUrl
    PackageSha256Url = $packageSha256Url
    PackageManifestUrl = $packageManifestUrl
    PackageIndexUrl = $packageIndexUrl
    PackageIndexSha256Url = $packageIndexSha256Url
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
    RunLabel = $effectiveRunLabel
}

if (-not [string]::IsNullOrWhiteSpace($effectiveBearerToken)) {
    $deployParams.PackageBearerToken = $effectiveBearerToken
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
if (-not [string]::IsNullOrWhiteSpace($SmokeOutputJsonPath)) {
    $deployParams.SmokeOutputJsonPath = $SmokeOutputJsonPath
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
if (-not [string]::IsNullOrWhiteSpace($LogsRoot)) {
    $deployParams.LogsRoot = $LogsRoot
}
if ($SkipRollback) {
    $deployParams.SkipRollback = $true
}
if (-not [string]::IsNullOrWhiteSpace($RollbackTargetReleaseId)) {
    $deployParams.RollbackTargetReleaseId = $RollbackTargetReleaseId
}
if ($SkipRollbackSmokeTest) {
    $deployParams.SkipRollbackSmokeTest = $true
}
if ($TreatRollbackSuccessAsSuccess) {
    $deployParams.TreatRollbackSuccessAsSuccess = $true
}
if ($assetValidationResults.Count -gt 0) {
    $deployParams.AssetValidationResults = @($assetValidationResults)
}

Write-Host "Deploy from release profile:"
Write-Host "  Tag: $normalizedTag"
Write-Host "  Runtime: $Runtime"
if (-not [string]::IsNullOrWhiteSpace($ReleaseDownloadBaseUrl)) {
    Write-Host "  ReleaseDownloadBaseUrl: $baseUrl"
}
else {
    Write-Host "  Repository: $normalizedRepository"
}
Write-Host "  ServiceName: $ServiceName"
Write-Host "  PackageUrl: $packageUrl"
Write-Host "  PackageSha256Url: $packageSha256Url"
Write-Host "  PackageManifestUrl: $packageManifestUrl"
Write-Host "  PackageIndexUrl: $packageIndexUrl"
Write-Host "  PackageIndexSha256Url: $packageIndexSha256Url"
Write-Host "  PackageBearerToken: $(if ([string]::IsNullOrWhiteSpace($effectiveBearerToken)) { '<none>' } else { '<provided>' })"
Write-Host "  ValidateAssetUrls: $([bool]$ValidateAssetUrls)"
Write-Host "  ValidateAssetTimeoutSeconds: $ValidateAssetTimeoutSeconds"
Write-Host "  ValidateAssetRetryCount: $ValidateAssetRetryCount"
Write-Host "  RunLabel: $effectiveRunLabel"
Write-Host "  DryRun: $([bool]$DryRun)"

if ($DryRun) {
    $preview = [ordered]@{
        wrapperScript = $wrapperScript
        assetValidation = $assetValidationResults
        params = $deployParams
    }
    $preview | ConvertTo-Json -Depth 8
    exit 0
}

& $wrapperScript @deployParams
