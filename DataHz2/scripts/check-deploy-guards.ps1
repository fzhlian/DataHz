[CmdletBinding()]
param(
    [string]$PackageZip = "",
    [switch]$IncludeOnlineSmokeCase,
    [string]$OnlineSmokePublishDir = "",
    [int]$OnlineSmokeStartupSeconds = 4,
    [switch]$KeepArtifacts
)

$ErrorActionPreference = "Stop"
$script:AutoPackagePublishDir = ""

function Resolve-ManifestPath([string]$ZipPath) {
    $parent = Split-Path -Parent $ZipPath
    $base = [System.IO.Path]::GetFileNameWithoutExtension($ZipPath)
    $candidate = Join-Path $parent ($base + ".manifest.json")
    if (-not (Test-Path $candidate)) {
        throw "Manifest not found for package zip: $candidate"
    }

    return $candidate
}

function Resolve-ShaPath([string]$ZipPath) {
    $candidate = [System.IO.Path]::ChangeExtension($ZipPath, ".sha256")
    if (-not (Test-Path $candidate)) {
        return ""
    }

    return $candidate
}

function Get-FreeTcpPort {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try {
        return ($listener.LocalEndpoint).Port
    }
    finally {
        $listener.Stop()
    }
}

function Convert-ToFileUri([string]$Path) {
    $resolved = [System.IO.Path]::GetFullPath($Path)
    return ([System.Uri]::new($resolved)).AbsoluteUri
}

function Start-StaticFileServer([string]$RootPath, [int]$Port) {
    $resolvedRoot = [System.IO.Path]::GetFullPath($RootPath)
    $prefix = "http://127.0.0.1:$Port/"

    $job = Start-Job -ArgumentList $resolvedRoot, $prefix -ScriptBlock {
        param($serverRoot, $serverPrefix)

        $rootResolved = [System.IO.Path]::GetFullPath($serverRoot)
        if (-not $rootResolved.EndsWith("\")) {
            $rootResolved += "\"
        }

        $listener = [System.Net.HttpListener]::new()
        $listener.Prefixes.Add($serverPrefix)
        $listener.Start()
        try {
            while ($true) {
                $ctx = $listener.GetContext()
                $resp = $ctx.Response
                try {
                    $relative = [System.Uri]::UnescapeDataString($ctx.Request.Url.AbsolutePath.TrimStart('/'))
                    $relative = $relative.Replace("/", "\")
                    $fullPath = [System.IO.Path]::GetFullPath((Join-Path $rootResolved $relative))

                    $insideRoot = $fullPath.StartsWith($rootResolved, [System.StringComparison]::OrdinalIgnoreCase)
                    if ((-not $insideRoot) -or (-not (Test-Path $fullPath -PathType Leaf))) {
                        $resp.StatusCode = 404
                    }
                    else {
                        $bytes = [System.IO.File]::ReadAllBytes($fullPath)
                        $resp.StatusCode = 200
                        $resp.ContentLength64 = $bytes.LongLength
                        $resp.OutputStream.Write($bytes, 0, $bytes.Length)
                    }
                }
                catch {
                    $resp.StatusCode = 500
                }
                finally {
                    $resp.OutputStream.Close()
                }
            }
        }
        finally {
            if ($listener.IsListening) {
                $listener.Stop()
            }
            $listener.Close()
        }
    }

    Start-Sleep -Milliseconds 300
    return [pscustomobject]@{
        Job = $job
        BaseUrl = $prefix
    }
}

function Test-IsValidPublishDir([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    if (-not (Test-Path $Path)) {
        return $false
    }

    $exe = Join-Path $Path "DataHz.Api.exe"
    $dll = Join-Path $Path "DataHz.Api.dll"
    return (Test-Path $exe) -or (Test-Path $dll)
}

function Resolve-PublishDirForAutoPackage([string]$Root, [string]$PackageName) {
    $publishRoot = Join-Path $Root "artifacts\publish"
    if (-not (Test-Path $publishRoot)) {
        return ""
    }

    $candidates = New-Object System.Collections.Generic.List[string]
    $named = Join-Path $publishRoot $PackageName
    if (Test-Path $named) {
        $candidates.Add([System.IO.Path]::GetFullPath($named))
    }

    $verifyFd = Join-Path $publishRoot "verify-fd"
    if (Test-Path $verifyFd) {
        $candidates.Add([System.IO.Path]::GetFullPath($verifyFd))
    }

    $candidates.Add([System.IO.Path]::GetFullPath($publishRoot))

    $childDirs = @(Get-ChildItem -Path $publishRoot -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending)
    foreach ($dir in $childDirs) {
        $candidates.Add([System.IO.Path]::GetFullPath($dir.FullName))
    }

    foreach ($candidate in $candidates | Select-Object -Unique) {
        if (Test-IsValidPublishDir -Path $candidate) {
            return $candidate
        }
    }

    return ""
}

function Ensure-PackageZipAvailable([string]$ZipPath, [string]$Root, [string]$ScriptsRoot) {
    if (Test-Path $ZipPath) {
        $script:AutoPackagePublishDir = ""
        return @()
    }

    $packageName = [System.IO.Path]::GetFileNameWithoutExtension($ZipPath)
    $outputDir = Split-Path -Parent $ZipPath
    New-Item -ItemType Directory -Force -Path $outputDir | Out-Null

    $publishDir = Resolve-PublishDirForAutoPackage -Root $Root -PackageName $packageName
    if ([string]::IsNullOrWhiteSpace($publishDir)) {
        throw "Package zip not found: $ZipPath. Auto-package fallback could not find a publish directory with DataHz.Api.exe/DataHz.Api.dll under artifacts\\publish."
    }

    $packageScript = Join-Path $ScriptsRoot "package-release.ps1"
    if (-not (Test-Path $packageScript)) {
        throw "Package zip not found: $ZipPath. package-release.ps1 not found: $packageScript"
    }

    Write-Host "Package zip not found, auto-generating from publish directory: $publishDir"
    & $packageScript -InputDir $publishDir -OutputDir $outputDir -Name $packageName -Overwrite
    $script:AutoPackagePublishDir = $publishDir

    $generated = New-Object System.Collections.Generic.List[string]
    $generated.Add($ZipPath) | Out-Null

    $shaPath = [System.IO.Path]::ChangeExtension($ZipPath, ".sha256")
    if (Test-Path $shaPath) {
        $generated.Add($shaPath) | Out-Null
    }

    $manifestPath = Join-Path $outputDir ($packageName + ".manifest.json")
    if (Test-Path $manifestPath) {
        $generated.Add($manifestPath) | Out-Null
    }

    return @($generated.ToArray())
}

function Run-Case(
    [string]$Name,
    [scriptblock]$Action,
    [bool]$ExpectFailure,
    [string]$ExpectedMessagePart
) {
    try {
        & $Action
        if ($ExpectFailure) {
            return [pscustomobject]@{
                Case = $Name
                Passed = $false
                Detail = "Expected failure but command succeeded."
            }
        }

        return [pscustomobject]@{
            Case = $Name
            Passed = $true
            Detail = "Succeeded."
        }
    }
    catch {
        $message = $_.Exception.Message
        if (-not $ExpectFailure) {
            return [pscustomobject]@{
                Case = $Name
                Passed = $false
                Detail = "Unexpected failure: $message"
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($ExpectedMessagePart) -and ($message -notlike "*$ExpectedMessagePart*")) {
            return [pscustomobject]@{
                Case = $Name
                Passed = $false
                Detail = "Failed with unexpected message: $message"
            }
        }

        return [pscustomobject]@{
            Case = $Name
            Passed = $true
            Detail = "Failed as expected: $message"
        }
    }
}

function Get-PowerShellExecutablePath {
    $pwshInPsHome = Join-Path $PSHOME "pwsh.exe"
    if (Test-Path $pwshInPsHome) {
        return $pwshInPsHome
    }

    $powershellInPsHome = Join-Path $PSHOME "powershell.exe"
    if (Test-Path $powershellInPsHome) {
        return $powershellInPsHome
    }

    $pwshCmd = Get-Command -Name "pwsh" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pwshCmd) {
        return $pwshCmd.Source
    }

    $powershellCmd = Get-Command -Name "powershell" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($powershellCmd) {
        return $powershellCmd.Source
    }

    throw "Unable to locate a PowerShell executable for subprocess invocation."
}

function Invoke-ScriptSubprocess(
    [string]$ScriptPath,
    [string[]]$ArgumentList,
    [string]$StdOutPath,
    [string]$StdErrPath
) {
    $fullScriptPath = [System.IO.Path]::GetFullPath($ScriptPath)
    if (-not (Test-Path $fullScriptPath)) {
        throw "Script not found for subprocess invocation: $fullScriptPath"
    }

    $stdoutDir = Split-Path -Parent $StdOutPath
    if (-not [string]::IsNullOrWhiteSpace($stdoutDir)) {
        New-Item -ItemType Directory -Force -Path $stdoutDir | Out-Null
    }

    $stderrDir = Split-Path -Parent $StdErrPath
    if (-not [string]::IsNullOrWhiteSpace($stderrDir)) {
        New-Item -ItemType Directory -Force -Path $stderrDir | Out-Null
    }

    $arguments = @("-NoProfile", "-NonInteractive", "-File", $fullScriptPath)
    if ($ArgumentList) {
        $arguments += $ArgumentList
    }

    $proc = Start-Process `
        -FilePath $script:PowerShellExecutable `
        -ArgumentList $arguments `
        -Wait `
        -PassThru `
        -WindowStyle Hidden `
        -RedirectStandardOutput $StdOutPath `
        -RedirectStandardError $StdErrPath

    return [pscustomobject]@{
        ExitCode = [int]$proc.ExitCode
        StdOutPath = $StdOutPath
        StdErrPath = $StdErrPath
    }
}

function Get-LatestRunSummary([string]$LogsRootPath) {
    if ([string]::IsNullOrWhiteSpace($LogsRootPath)) {
        return $null
    }

    if (-not (Test-Path $LogsRootPath)) {
        return $null
    }

    $latestRunDir = Get-ChildItem -Path $LogsRootPath -Directory -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1

    if (-not $latestRunDir) {
        return $null
    }

    $summaryPath = Join-Path $latestRunDir.FullName "run-summary.json"
    if (-not (Test-Path $summaryPath)) {
        return $null
    }

    return Get-Content -Path $summaryPath -Raw | ConvertFrom-Json
}

function New-RunId {
    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMdd-HHmmss-fff")
    $suffix = [Guid]::NewGuid().ToString("N").Substring(0, 8)
    return "$timestamp-$suffix"
}

$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($PackageZip)) {
    $PackageZip = Join-Path $root "artifacts\packages\datahz2-api-win-x64.zip"
}

$resolvedZip = [System.IO.Path]::GetFullPath($PackageZip)
$autoGeneratedPackageFiles = @(Ensure-PackageZipAvailable -ZipPath $resolvedZip -Root $root -ScriptsRoot $PSScriptRoot)
if (-not (Test-Path $resolvedZip)) {
    throw "Package zip not found: $resolvedZip"
}

$resolvedManifest = Resolve-ManifestPath -ZipPath $resolvedZip
$resolvedSha = Resolve-ShaPath -ZipPath $resolvedZip

$deployApiScript = Join-Path $PSScriptRoot "deploy-api.ps1"
$deployProdScript = Join-Path $PSScriptRoot "deploy-prod.ps1"
$deployProdAutoRollbackScript = Join-Path $PSScriptRoot "deploy-prod-with-auto-rollback.ps1"
if (-not $script:PowerShellExecutable) {
    $script:PowerShellExecutable = Get-PowerShellExecutablePath
}
if (-not (Test-Path $deployApiScript)) {
    throw "deploy-api.ps1 not found: $deployApiScript"
}
if (-not (Test-Path $deployProdScript)) {
    throw "deploy-prod.ps1 not found: $deployProdScript"
}
if (-not (Test-Path $deployProdAutoRollbackScript)) {
    throw "deploy-prod-with-auto-rollback.ps1 not found: $deployProdAutoRollbackScript"
}

$runId = New-RunId
$tempRoot = Join-Path $root ("artifacts\selftest\deploy-guards-" + $runId)
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

$caseZipDir = Join-Path $tempRoot "case-require-manifest-missing"
New-Item -ItemType Directory -Force -Path $caseZipDir | Out-Null
$zipOnlyPath = Join-Path $caseZipDir ([System.IO.Path]::GetFileName($resolvedZip))
Copy-Item -Path $resolvedZip -Destination $zipOnlyPath -Force

$caseInvalidIndexDir = Join-Path $tempRoot "case-package-index-invalid-json"
New-Item -ItemType Directory -Force -Path $caseInvalidIndexDir | Out-Null
$invalidIndexPath = Join-Path $caseInvalidIndexDir "release.invalid.index.json"
Set-Content -Path $invalidIndexPath -Value "{ invalid json" -Encoding UTF8

$caseValidIndexDir = Join-Path $tempRoot "case-package-index-valid"
New-Item -ItemType Directory -Force -Path $caseValidIndexDir | Out-Null
$validIndexPath = Join-Path $caseValidIndexDir "release.valid.index.json"

$zipName = [System.IO.Path]::GetFileName($resolvedZip)
$zipInfo = Get-Item -Path $resolvedZip
$zipSha = (Get-FileHash -Path $resolvedZip -Algorithm SHA256).Hash.ToLowerInvariant()

$runtimeEntry = [ordered]@{
    Runtime = "selftest"
    Zip = $zipName
    PackageSha256 = $zipSha
}

$assetMetadata = @([ordered]@{
    file = $zipName
    sizeBytes = $zipInfo.Length
    sha256 = $zipSha
})

$manifestName = [System.IO.Path]::GetFileName($resolvedManifest)
$manifestInfo = Get-Item -Path $resolvedManifest
$manifestSha = (Get-FileHash -Path $resolvedManifest -Algorithm SHA256).Hash.ToLowerInvariant()
$runtimeEntry.Manifest = $manifestName
$assetMetadata += [ordered]@{
    file = $manifestName
    sizeBytes = $manifestInfo.Length
    sha256 = $manifestSha
}

if (-not [string]::IsNullOrWhiteSpace($resolvedSha)) {
    $shaName = [System.IO.Path]::GetFileName($resolvedSha)
    $shaInfo = Get-Item -Path $resolvedSha
    $shaHash = (Get-FileHash -Path $resolvedSha -Algorithm SHA256).Hash.ToLowerInvariant()
    $runtimeEntry.Sha256 = $shaName
    $assetMetadata += [ordered]@{
        file = $shaName
        sizeBytes = $shaInfo.Length
        sha256 = $shaHash
    }
}

$validIndex = [ordered]@{
    formatVersion = 1
    tag = "selftest-$runId"
    generatedUtc = (Get-Date).ToUniversalTime().ToString("o")
    runtimeCount = 1
    runtimes = @([pscustomobject]$runtimeEntry)
    assets = $assetMetadata
}
$validIndex | ConvertTo-Json -Depth 8 | Set-Content -Path $validIndexPath -Encoding UTF8

$validIndexName = [System.IO.Path]::GetFileName($validIndexPath)
$validIndexHash = (Get-FileHash -Path $validIndexPath -Algorithm SHA256).Hash.ToLowerInvariant()
$validIndexShaPath = Join-Path $caseValidIndexDir "release.valid.sha256"
Set-Content -Path $validIndexShaPath -Encoding UTF8 -Value @(
    "$zipSha  $zipName"
    "$validIndexHash  $validIndexName"
)

$invalidIndexShaPath = Join-Path $tempRoot "invalid-index.sha256"
$invalidIndexHash = if ($validIndexHash.StartsWith("0")) { "1" + $validIndexHash.Substring(1) } else { "0" + $validIndexHash.Substring(1) }
Set-Content -Path $invalidIndexShaPath -Encoding UTF8 -Value @(
    "$invalidIndexHash  $validIndexName"
)

$urlAssetRoot = Join-Path $tempRoot "url-assets"
New-Item -ItemType Directory -Force -Path $urlAssetRoot | Out-Null

$zipUrlName = [System.IO.Path]::GetFileName($resolvedZip)
$manifestUrlName = [System.IO.Path]::GetFileName($resolvedManifest)
$invalidIndexUrlName = [System.IO.Path]::GetFileName($invalidIndexPath)
$validIndexUrlName = [System.IO.Path]::GetFileName($validIndexPath)
$validIndexShaUrlName = [System.IO.Path]::GetFileName($validIndexShaPath)
$invalidIndexShaUrlName = [System.IO.Path]::GetFileName($invalidIndexShaPath)

Copy-Item -Path $resolvedZip -Destination (Join-Path $urlAssetRoot $zipUrlName) -Force
Copy-Item -Path $resolvedManifest -Destination (Join-Path $urlAssetRoot $manifestUrlName) -Force
Copy-Item -Path $invalidIndexPath -Destination (Join-Path $urlAssetRoot $invalidIndexUrlName) -Force
Copy-Item -Path $validIndexPath -Destination (Join-Path $urlAssetRoot $validIndexUrlName) -Force
Copy-Item -Path $validIndexShaPath -Destination (Join-Path $urlAssetRoot $validIndexShaUrlName) -Force
Copy-Item -Path $invalidIndexShaPath -Destination (Join-Path $urlAssetRoot $invalidIndexShaUrlName) -Force

$serverPort = Get-FreeTcpPort
$urlServer = Start-StaticFileServer -RootPath $urlAssetRoot -Port $serverPort
$urlBase = $urlServer.BaseUrl
if (-not $urlBase.EndsWith("/")) {
    $urlBase += "/"
}

$zipFileUri = $urlBase + $zipUrlName
$manifestFileUri = $urlBase + $manifestUrlName
$invalidIndexFileUri = $urlBase + $invalidIndexUrlName
$validIndexFileUri = $urlBase + $validIndexUrlName
$validIndexShaFileUri = $urlBase + $validIndexShaUrlName
$invalidIndexShaFileUri = $urlBase + $invalidIndexShaUrlName
$shaFileUri = ""
if (-not [string]::IsNullOrWhiteSpace($resolvedSha)) {
    $shaUrlName = [System.IO.Path]::GetFileName($resolvedSha)
    Copy-Item -Path $resolvedSha -Destination (Join-Path $urlAssetRoot $shaUrlName) -Force
    $shaFileUri = $urlBase + $shaUrlName
}

$results = New-Object System.Collections.Generic.List[object]

try {
    $results.Add((Run-Case `
        -Name "env-invalid-boolean" `
        -ExpectFailure $true `
        -ExpectedMessagePart "Invalid boolean value for DATAHZ_DEPLOY_REQUIRE_MANIFEST" `
        -Action {
            $env:DATAHZ_DEPLOY_REQUIRE_MANIFEST = "maybe"
            try {
                & $deployApiScript `
                    -PackageZip $resolvedZip `
                    -ReleaseRoot (Join-Path $tempRoot "case-env-invalid") `
                    -SkipServiceInstall `
                    -SkipHealthCheck
            }
            finally {
                Remove-Item Env:DATAHZ_DEPLOY_REQUIRE_MANIFEST -ErrorAction SilentlyContinue
            }
        }))

    $results.Add((Run-Case `
        -Name "api-index-url-without-package-url" `
        -ExpectFailure $true `
        -ExpectedMessagePart "PackageIndexUrl requires PackageUrl" `
        -Action {
            & $deployApiScript `
                -PackageZip $resolvedZip `
                -PackageManifestFile $resolvedManifest `
                -PackageIndexUrl "https://example.com/datahz2-release-v1.index.json" `
                -ReleaseRoot (Join-Path $tempRoot "case-api-index-url-without-package-url") `
                -SkipServiceInstall `
                -SkipHealthCheck
        }))

    $results.Add((Run-Case `
        -Name "api-index-file-url-mutual-exclusive" `
        -ExpectFailure $true `
        -ExpectedMessagePart "PackageIndexFile and PackageIndexUrl are mutually exclusive" `
        -Action {
            & $deployApiScript `
                -PackageZip $resolvedZip `
                -PackageManifestFile $resolvedManifest `
                -PackageIndexFile $validIndexPath `
                -PackageIndexUrl "https://example.com/datahz2-release-v1.index.json" `
                -ReleaseRoot (Join-Path $tempRoot "case-api-index-file-url-mutual-exclusive") `
                -SkipServiceInstall `
                -SkipHealthCheck
        }))

    $results.Add((Run-Case `
        -Name "api-index-sha-url-without-index-url" `
        -ExpectFailure $true `
        -ExpectedMessagePart "PackageIndexSha256Url requires PackageIndexUrl" `
        -Action {
            & $deployApiScript `
                -PackageUrl $zipFileUri `
                -PackageManifestUrl $manifestFileUri `
                -PackageIndexSha256Url $validIndexShaFileUri `
                -ReleaseRoot (Join-Path $tempRoot "case-api-index-sha-url-without-index-url") `
                -SkipServiceInstall `
                -SkipHealthCheck
        }))

    $results.Add((Run-Case `
        -Name "api-index-sha-file-url-mutual-exclusive" `
        -ExpectFailure $true `
        -ExpectedMessagePart "PackageIndexSha256File and PackageIndexSha256Url are mutually exclusive" `
        -Action {
            & $deployApiScript `
                -PackageZip $resolvedZip `
                -PackageManifestFile $resolvedManifest `
                -PackageIndexFile $validIndexPath `
                -PackageIndexSha256File $validIndexShaPath `
                -PackageIndexSha256Url $validIndexShaFileUri `
                -ReleaseRoot (Join-Path $tempRoot "case-api-index-sha-file-url-mutual-exclusive") `
                -SkipServiceInstall `
                -SkipHealthCheck
        }))

    $results.Add((Run-Case `
        -Name "api-url-index-invalid-json" `
        -ExpectFailure $true `
        -ExpectedMessagePart "Package index is invalid JSON" `
        -Action {
            $params = @{
                PackageUrl = $zipFileUri
                PackageManifestUrl = $manifestFileUri
                PackageIndexUrl = $invalidIndexFileUri
                RequireManifest = $true
                ReleaseRoot = (Join-Path $tempRoot "case-api-url-index-invalid-json")
                SkipServiceInstall = $true
                SkipHealthCheck = $true
            }
            if (-not [string]::IsNullOrWhiteSpace($shaFileUri)) {
                $params.PackageSha256Url = $shaFileUri
            }

            & $deployApiScript @params
        }))

    $results.Add((Run-Case `
        -Name "api-url-index-sha-mismatch" `
        -ExpectFailure $true `
        -ExpectedMessagePart "Package index hash mismatch" `
        -Action {
            $params = @{
                PackageUrl = $zipFileUri
                PackageManifestUrl = $manifestFileUri
                PackageIndexUrl = $validIndexFileUri
                PackageIndexSha256Url = $invalidIndexShaFileUri
                RequireManifest = $true
                ReleaseRoot = (Join-Path $tempRoot "case-api-url-index-sha-mismatch")
                SkipServiceInstall = $true
                SkipHealthCheck = $true
            }
            if (-not [string]::IsNullOrWhiteSpace($shaFileUri)) {
                $params.PackageSha256Url = $shaFileUri
            }

            & $deployApiScript @params
        }))

    $results.Add((Run-Case `
        -Name "api-url-index-success" `
        -ExpectFailure $false `
        -ExpectedMessagePart "" `
        -Action {
            $params = @{
                PackageUrl = $zipFileUri
                PackageManifestUrl = $manifestFileUri
                PackageIndexUrl = $validIndexFileUri
                PackageIndexSha256Url = $validIndexShaFileUri
                RequireManifest = $true
                ReleaseRoot = (Join-Path $tempRoot "case-api-url-index-success")
                SkipServiceInstall = $true
                SkipHealthCheck = $true
            }
            if (-not [string]::IsNullOrWhiteSpace($shaFileUri)) {
                $params.PackageSha256Url = $shaFileUri
            }

            & $deployApiScript @params
        }))

    $results.Add((Run-Case `
        -Name "prod-url-missing-manifest-url" `
        -ExpectFailure $true `
        -ExpectedMessagePart "requires PackageManifestUrl" `
        -Action {
            & $deployProdScript `
                -PackageUrl "https://example.com/datahz2-api-win-x64.zip" `
                -ReleaseRoot (Join-Path $tempRoot "case-prod-url-missing-manifest-url")
        }))

    $results.Add((Run-Case `
        -Name "prod-index-url-without-package-url" `
        -ExpectFailure $true `
        -ExpectedMessagePart "PackageIndexUrl requires PackageUrl" `
        -Action {
            & $deployProdScript `
                -PackageZip $resolvedZip `
                -PackageManifestFile $resolvedManifest `
                -PackageIndexUrl "https://example.com/datahz2-release-v1.index.json" `
                -ReleaseRoot (Join-Path $tempRoot "case-prod-index-url-without-package-url")
        }))

    $results.Add((Run-Case `
        -Name "prod-index-file-url-mutual-exclusive" `
        -ExpectFailure $true `
        -ExpectedMessagePart "PackageIndexFile and PackageIndexUrl are mutually exclusive" `
        -Action {
            & $deployProdScript `
                -PackageZip $resolvedZip `
                -PackageManifestFile $resolvedManifest `
                -PackageIndexFile $validIndexPath `
                -PackageIndexUrl "https://example.com/datahz2-release-v1.index.json" `
                -ReleaseRoot (Join-Path $tempRoot "case-prod-index-file-url-mutual-exclusive")
        }))

    $results.Add((Run-Case `
        -Name "prod-index-sha-url-without-index-url" `
        -ExpectFailure $true `
        -ExpectedMessagePart "PackageIndexSha256Url requires PackageIndexUrl" `
        -Action {
            & $deployProdScript `
                -PackageUrl $zipFileUri `
                -PackageManifestUrl $manifestFileUri `
                -PackageIndexSha256Url $validIndexShaFileUri `
                -ReleaseRoot (Join-Path $tempRoot "case-prod-index-sha-url-without-index-url")
        }))

    $results.Add((Run-Case `
        -Name "prod-index-sha-file-url-mutual-exclusive" `
        -ExpectFailure $true `
        -ExpectedMessagePart "PackageIndexSha256File and PackageIndexSha256Url are mutually exclusive" `
        -Action {
            & $deployProdScript `
                -PackageZip $resolvedZip `
                -PackageManifestFile $resolvedManifest `
                -PackageIndexFile $validIndexPath `
                -PackageIndexSha256File $validIndexShaPath `
                -PackageIndexSha256Url $validIndexShaFileUri `
                -ReleaseRoot (Join-Path $tempRoot "case-prod-index-sha-file-url-mutual-exclusive")
        }))

    $results.Add((Run-Case `
        -Name "prod-wrapper-block-unsafe-bypass" `
        -ExpectFailure $true `
        -ExpectedMessagePart "blocked in deploy-prod.ps1" `
        -Action {
            & $deployProdScript `
                -PackageZip $resolvedZip `
                -PackageManifestFile $resolvedManifest `
                -ReleaseRoot (Join-Path $tempRoot "case-prod-wrapper-block-unsafe-bypass") `
                -SkipServiceInstall `
                -SkipHealthCheck
        }))

    $results.Add((Run-Case `
        -Name "prod-auto-wrapper-fail-skip-rollback" `
        -ExpectFailure $false `
        -ExpectedMessagePart "" `
        -Action {
            $logsRoot = Join-Path $tempRoot "case-prod-auto-wrapper-fail-skip-rollback.logs"
            New-Item -ItemType Directory -Force -Path $logsRoot | Out-Null
            $wrapperOutLog = Join-Path $logsRoot "wrapper.out.log"
            $wrapperErrLog = Join-Path $logsRoot "wrapper.err.log"

            $invoke = Invoke-ScriptSubprocess `
                -ScriptPath $deployProdAutoRollbackScript `
                -ArgumentList @(
                    "-ServiceName", "DataHz.Api",
                    "-PackageUrl", "https://example.com/datahz2-api-win-x64.zip",
                    "-LogsRoot", $logsRoot,
                    "-RunLabel", "guard-fail-skip",
                    "-SkipRollback"
                ) `
                -StdOutPath $wrapperOutLog `
                -StdErrPath $wrapperErrLog

            if ($invoke.ExitCode -ne 1) {
                $out = if (Test-Path $wrapperOutLog) { Get-Content -Path $wrapperOutLog -Raw } else { "" }
                $err = if (Test-Path $wrapperErrLog) { Get-Content -Path $wrapperErrLog -Raw } else { "" }
                throw "Expected wrapper exit code 1, got $($invoke.ExitCode). Out='$out' Err='$err'"
            }

            $summary = Get-LatestRunSummary -LogsRootPath $logsRoot
            if ($null -eq $summary) {
                throw "Wrapper run summary was not generated under $logsRoot"
            }

            if ($summary.deploy.succeeded) {
                throw "Wrapper summary expected deploy.succeeded=false for fail-skip case."
            }

            if ($summary.rollback.attempted) {
                throw "Wrapper summary expected rollback.attempted=false when -SkipRollback is set."
            }

            if (-not $summary.rollback.skipped) {
                throw "Wrapper summary expected rollback.skipped=true when -SkipRollback is set."
            }

            if ([string]::IsNullOrWhiteSpace($summary.deploy.logPath) -or -not (Test-Path $summary.deploy.logPath)) {
                throw "Wrapper deploy log path missing or not found."
            }

            if ([string]::IsNullOrWhiteSpace($summary.snapshots.before) -or -not (Test-Path $summary.snapshots.before)) {
                throw "Wrapper status-before snapshot missing."
            }
            if ([string]::IsNullOrWhiteSpace($summary.snapshots.afterDeploy) -or -not (Test-Path $summary.snapshots.afterDeploy)) {
                throw "Wrapper status-after-deploy snapshot missing."
            }
            if ([string]::IsNullOrWhiteSpace($summary.snapshots.afterRollback) -or -not (Test-Path $summary.snapshots.afterRollback)) {
                throw "Wrapper status-after-rollback snapshot missing."
            }

            if ([string]::IsNullOrWhiteSpace($summary.runId)) {
                throw "Wrapper summary runId is empty."
            }

            $archivePath = Join-Path $logsRoot ($summary.runId + ".zip")
            if (-not (Test-Path $archivePath)) {
                throw "Wrapper archive not found: $archivePath"
            }
        }))

    $results.Add((Run-Case `
        -Name "require-manifest-missing" `
        -ExpectFailure $true `
        -ExpectedMessagePart "RequireManifest is enabled, but package manifest file was not found." `
        -Action {
            & $deployApiScript `
                -PackageZip $zipOnlyPath `
                -RequireManifest `
                -ReleaseRoot (Join-Path $tempRoot "case-require-manifest-missing") `
                -SkipServiceInstall `
                -SkipHealthCheck
        }))

    $results.Add((Run-Case `
        -Name "package-index-invalid-json" `
        -ExpectFailure $true `
        -ExpectedMessagePart "Package index is invalid JSON" `
        -Action {
            $params = @{
                PackageZip = $resolvedZip
                PackageManifestFile = $resolvedManifest
                PackageIndexFile = $invalidIndexPath
                ReleaseRoot = (Join-Path $tempRoot "case-package-index-invalid-json")
                SkipServiceInstall = $true
                SkipHealthCheck = $true
            }
            if (-not [string]::IsNullOrWhiteSpace($resolvedSha)) {
                $params.PackageSha256File = $resolvedSha
            }

            & $deployApiScript @params
        }))

    $results.Add((Run-Case `
        -Name "package-index-sha-mismatch" `
        -ExpectFailure $true `
        -ExpectedMessagePart "Package index hash mismatch" `
        -Action {
            $params = @{
                PackageZip = $resolvedZip
                PackageManifestFile = $resolvedManifest
                PackageIndexFile = $validIndexPath
                PackageIndexSha256File = $invalidIndexShaPath
                ReleaseRoot = (Join-Path $tempRoot "case-package-index-sha-mismatch")
                SkipServiceInstall = $true
                SkipHealthCheck = $true
            }
            if (-not [string]::IsNullOrWhiteSpace($resolvedSha)) {
                $params.PackageSha256File = $resolvedSha
            }

            & $deployApiScript @params
        }))

    $results.Add((Run-Case `
        -Name "package-index-valid" `
        -ExpectFailure $false `
        -ExpectedMessagePart "" `
        -Action {
            $params = @{
                PackageZip = $resolvedZip
                PackageManifestFile = $resolvedManifest
                PackageIndexFile = $validIndexPath
                PackageIndexSha256File = $validIndexShaPath
                ReleaseRoot = (Join-Path $tempRoot "case-package-index-valid")
                SkipServiceInstall = $true
                SkipHealthCheck = $true
            }
            if (-not [string]::IsNullOrWhiteSpace($resolvedSha)) {
                $params.PackageSha256File = $resolvedSha
            }

            & $deployApiScript @params
        }))

    $results.Add((Run-Case `
        -Name "require-manifest-success" `
        -ExpectFailure $false `
        -ExpectedMessagePart "" `
        -Action {
            $params = @{
                PackageZip = $resolvedZip
                PackageManifestFile = $resolvedManifest
                RequireManifest = $true
                ReleaseRoot = (Join-Path $tempRoot "case-require-manifest-success")
                SkipServiceInstall = $true
                SkipHealthCheck = $true
            }
            if (-not [string]::IsNullOrWhiteSpace($resolvedSha)) {
                $params.PackageSha256File = $resolvedSha
            }

            & $deployApiScript @params
        }))

    if ($IncludeOnlineSmokeCase) {
        $results.Add((Run-Case `
            -Name "prod-wrapper-smoke-success" `
            -ExpectFailure $false `
            -ExpectedMessagePart "" `
            -Action {
                $effectivePublishDir = $OnlineSmokePublishDir
                if ([string]::IsNullOrWhiteSpace($effectivePublishDir)) {
                    if (-not [string]::IsNullOrWhiteSpace($script:AutoPackagePublishDir)) {
                        $effectivePublishDir = $script:AutoPackagePublishDir
                    }
                    else {
                        $packageName = [System.IO.Path]::GetFileNameWithoutExtension($resolvedZip)
                        $effectivePublishDir = Resolve-PublishDirForAutoPackage -Root $root -PackageName $packageName
                    }
                }

                if ([string]::IsNullOrWhiteSpace($effectivePublishDir)) {
                    throw "OnlineSmokePublishDir is empty and no valid publish directory was found under artifacts\\publish."
                }

                $resolvedPublishDir = [System.IO.Path]::GetFullPath($effectivePublishDir)
                if (-not (Test-Path $resolvedPublishDir)) {
                    throw "OnlineSmokePublishDir not found: $resolvedPublishDir"
                }

                $apiExe = Join-Path $resolvedPublishDir "DataHz.Api.exe"
                if (-not (Test-Path $apiExe)) {
                    throw "DataHz.Api.exe not found in OnlineSmokePublishDir: $resolvedPublishDir"
                }

                $port = Get-FreeTcpPort
                $url = "http://127.0.0.1:$port"
                $hostOutLog = Join-Path $tempRoot "case-prod-wrapper-smoke-success.host.out.log"
                $hostErrLog = Join-Path $tempRoot "case-prod-wrapper-smoke-success.host.err.log"

                $hostProc = $null
                try {
                    $hostProc = Start-Process `
                        -FilePath $apiExe `
                        -ArgumentList @("--contentRoot", $resolvedPublishDir, "--environment", "Production", "--urls", $url) `
                        -PassThru `
                        -WindowStyle Hidden `
                        -RedirectStandardOutput $hostOutLog `
                        -RedirectStandardError $hostErrLog

                    Start-Sleep -Seconds ([Math]::Max(1, $OnlineSmokeStartupSeconds))
                    if ($hostProc.HasExited) {
                        $out = if (Test-Path $hostOutLog) { Get-Content -Path $hostOutLog -Raw } else { "" }
                        $err = if (Test-Path $hostErrLog) { Get-Content -Path $hostErrLog -Raw } else { "" }
                        throw "Online smoke host exited early. Out='$out' Err='$err'"
                    }

                    $prodParams = @{
                        PackageUrl = $zipFileUri
                        PackageManifestUrl = $manifestFileUri
                        PackageIndexUrl = $validIndexFileUri
                        PackageIndexSha256Url = $validIndexShaFileUri
                        AllowUnsafeBypass = $true
                        ReleaseRoot = (Join-Path $tempRoot "case-prod-wrapper-smoke-success")
                        Urls = $url
                        HealthCheckIntervalSeconds = 1
                        SkipServiceInstall = $true
                        SkipHealthCheck = $true
                    }
                    if (-not [string]::IsNullOrWhiteSpace($shaFileUri)) {
                        $prodParams.PackageSha256Url = $shaFileUri
                    }

                    & $deployProdScript @prodParams
                }
                finally {
                    if ($hostProc -and -not $hostProc.HasExited) {
                        Stop-Process -Id $hostProc.Id -Force -ErrorAction SilentlyContinue
                    }
                }
            }))

        $results.Add((Run-Case `
            -Name "prod-auto-wrapper-smoke-success" `
            -ExpectFailure $false `
            -ExpectedMessagePart "" `
            -Action {
                $effectivePublishDir = $OnlineSmokePublishDir
                if ([string]::IsNullOrWhiteSpace($effectivePublishDir)) {
                    if (-not [string]::IsNullOrWhiteSpace($script:AutoPackagePublishDir)) {
                        $effectivePublishDir = $script:AutoPackagePublishDir
                    }
                    else {
                        $packageName = [System.IO.Path]::GetFileNameWithoutExtension($resolvedZip)
                        $effectivePublishDir = Resolve-PublishDirForAutoPackage -Root $root -PackageName $packageName
                    }
                }

                if ([string]::IsNullOrWhiteSpace($effectivePublishDir)) {
                    throw "OnlineSmokePublishDir is empty and no valid publish directory was found under artifacts\\publish."
                }

                $resolvedPublishDir = [System.IO.Path]::GetFullPath($effectivePublishDir)
                if (-not (Test-Path $resolvedPublishDir)) {
                    throw "OnlineSmokePublishDir not found: $resolvedPublishDir"
                }

                $apiExe = Join-Path $resolvedPublishDir "DataHz.Api.exe"
                if (-not (Test-Path $apiExe)) {
                    throw "DataHz.Api.exe not found in OnlineSmokePublishDir: $resolvedPublishDir"
                }

                $port = Get-FreeTcpPort
                $url = "http://127.0.0.1:$port"
                $hostOutLog = Join-Path $tempRoot "case-prod-auto-wrapper-smoke-success.host.out.log"
                $hostErrLog = Join-Path $tempRoot "case-prod-auto-wrapper-smoke-success.host.err.log"
                $wrapperLogsRoot = Join-Path $tempRoot "case-prod-auto-wrapper-smoke-success.wrapper-logs"
                New-Item -ItemType Directory -Force -Path $wrapperLogsRoot | Out-Null
                $wrapperOutLog = Join-Path $wrapperLogsRoot "wrapper.out.log"
                $wrapperErrLog = Join-Path $wrapperLogsRoot "wrapper.err.log"

                $hostProc = $null
                try {
                    $hostProc = Start-Process `
                        -FilePath $apiExe `
                        -ArgumentList @("--contentRoot", $resolvedPublishDir, "--environment", "Production", "--urls", $url) `
                        -PassThru `
                        -WindowStyle Hidden `
                        -RedirectStandardOutput $hostOutLog `
                        -RedirectStandardError $hostErrLog

                    Start-Sleep -Seconds ([Math]::Max(1, $OnlineSmokeStartupSeconds))
                    if ($hostProc.HasExited) {
                        $out = if (Test-Path $hostOutLog) { Get-Content -Path $hostOutLog -Raw } else { "" }
                        $err = if (Test-Path $hostErrLog) { Get-Content -Path $hostErrLog -Raw } else { "" }
                        throw "Online smoke host exited early. Out='$out' Err='$err'"
                    }

                    $wrapperArgs = @(
                        "-ServiceName", "DataHz.Api",
                        "-PackageUrl", $zipFileUri,
                        "-PackageManifestUrl", $manifestFileUri,
                        "-PackageIndexUrl", $validIndexFileUri,
                        "-PackageIndexSha256Url", $validIndexShaFileUri,
                        "-AllowUnsafeBypass",
                        "-ReleaseRoot", (Join-Path $tempRoot "case-prod-auto-wrapper-smoke-success"),
                        "-Urls", $url,
                        "-HealthCheckIntervalSeconds", "1",
                        "-SkipServiceInstall",
                        "-SkipHealthCheck",
                        "-LogsRoot", $wrapperLogsRoot,
                        "-RunLabel", "guard-online-success"
                    )
                    if (-not [string]::IsNullOrWhiteSpace($shaFileUri)) {
                        $wrapperArgs += @("-PackageSha256Url", $shaFileUri)
                    }

                    $invoke = Invoke-ScriptSubprocess `
                        -ScriptPath $deployProdAutoRollbackScript `
                        -ArgumentList $wrapperArgs `
                        -StdOutPath $wrapperOutLog `
                        -StdErrPath $wrapperErrLog

                    if ($invoke.ExitCode -ne 0) {
                        $out = if (Test-Path $wrapperOutLog) { Get-Content -Path $wrapperOutLog -Raw } else { "" }
                        $err = if (Test-Path $wrapperErrLog) { Get-Content -Path $wrapperErrLog -Raw } else { "" }
                        throw "Auto wrapper expected exit code 0, got $($invoke.ExitCode). Out='$out' Err='$err'"
                    }

                    $summary = Get-LatestRunSummary -LogsRootPath $wrapperLogsRoot
                    if ($null -eq $summary) {
                        throw "Auto wrapper run summary was not generated under $wrapperLogsRoot"
                    }

                    if (-not $summary.deploy.succeeded) {
                        throw "Auto wrapper summary expected deploy.succeeded=true for online success case."
                    }

                    if ($summary.rollback.attempted) {
                        throw "Auto wrapper summary expected rollback.attempted=false for online success case."
                    }

                    if ([string]::IsNullOrWhiteSpace($summary.deploy.smokeReportPath) -or -not (Test-Path $summary.deploy.smokeReportPath)) {
                        throw "Auto wrapper smoke report path missing or not found."
                    }

                    if ([string]::IsNullOrWhiteSpace($summary.runId)) {
                        throw "Auto wrapper summary runId is empty."
                    }

                    $archivePath = Join-Path $wrapperLogsRoot ($summary.runId + ".zip")
                    if (-not (Test-Path $archivePath)) {
                        throw "Auto wrapper archive not found: $archivePath"
                    }
                }
                finally {
                    if ($hostProc -and -not $hostProc.HasExited) {
                        Stop-Process -Id $hostProc.Id -Force -ErrorAction SilentlyContinue
                    }
                }
            }))
    }
}
finally {
    if ($urlServer -and $urlServer.Job) {
        Stop-Job -Job $urlServer.Job -ErrorAction SilentlyContinue
        Remove-Job -Job $urlServer.Job -Force -ErrorAction SilentlyContinue
    }

    if (-not $KeepArtifacts) {
        Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    foreach ($generatedFile in $autoGeneratedPackageFiles) {
        if (Test-Path $generatedFile) {
            Remove-Item -Path $generatedFile -Force -ErrorAction SilentlyContinue
        }
    }
}

$maxCaseLen = 4
foreach ($item in $results) {
    if ($item.Case.Length -gt $maxCaseLen) {
        $maxCaseLen = $item.Case.Length
    }
}

Write-Host ""
Write-Host ("{0}  {1}  {2}" -f "Case".PadRight($maxCaseLen), "Pass", "Detail")
Write-Host ("{0}  {1}  {2}" -f ("-" * $maxCaseLen), "----", ("-" * 40))
foreach ($item in $results) {
    $flag = if ($item.Passed) { "true" } else { "false" }
    Write-Host ("{0}  {1}  {2}" -f $item.Case.PadRight($maxCaseLen), $flag.PadRight(4), $item.Detail)
}

$failed = @($results | Where-Object { -not $_.Passed })
if ($failed.Count -gt 0) {
    Write-Host ""
    Write-Host "Deployment guard self-test failed: $($failed.Count) case(s)." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "Deployment guard self-test passed." -ForegroundColor Green
exit 0
