[CmdletBinding()]
param(
    [string]$ServiceName = "DataHz.Api",
    [string]$Configuration = "Release",
    [string]$Runtime = "win-x64",
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
    [switch]$RequireManifest,
    [string]$ReleaseRoot = "",
    [string]$Urls = "http://0.0.0.0:5080",
    [string]$EnvironmentName = "Production",
    [string]$HealthEndpoint = "/health",
    [int]$HealthTimeoutSeconds = 60,
    [int]$HealthCheckIntervalSeconds = 2,
    [int]$KeepReleases = 5,
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
    [switch]$FrameworkDependent,
    [switch]$MultiFile,
    [switch]$ReadyToRun,
    [switch]$Trimmed,
    [switch]$NoRestore,
    [switch]$SkipServiceInstall,
    [switch]$SkipHealthCheck
)

$ErrorActionPreference = "Stop"

function ConvertTo-StrictBoolean([string]$Name, [string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    $normalized = $Value.Trim().ToLowerInvariant()
    if ($normalized -in @("1", "true", "yes", "y", "on")) {
        return $true
    }

    if ($normalized -in @("0", "false", "no", "n", "off")) {
        return $false
    }

    throw "Invalid boolean value for ${Name}: '$Value'. Supported: true/false, 1/0, yes/no, on/off."
}

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
    if ([string]::IsNullOrWhiteSpace($value)) {
        return ""
    }

    return $value.Trim()
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

function Remove-OldReleases([string]$Root, [int]$KeepCount, [string]$CurrentReleaseId) {
    if ($KeepCount -lt 1) {
        return
    }

    $releaseDirs = Get-ChildItem -Path $Root -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match "^\d{8}-\d{6}$" } |
        Sort-Object Name -Descending

    if ($releaseDirs.Count -le $KeepCount) {
        return
    }

    $removeList = $releaseDirs | Select-Object -Skip $KeepCount
    foreach ($dir in $removeList) {
        if ($dir.Name -eq $CurrentReleaseId) {
            continue
        }

        Remove-Item -Path $dir.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Resolve-PackageShaFile([string]$ZipPath, [string]$ExplicitShaPath) {
    if (-not [string]::IsNullOrWhiteSpace($ExplicitShaPath)) {
        $resolved = [System.IO.Path]::GetFullPath($ExplicitShaPath)
        if (-not (Test-Path $resolved)) {
            throw "Package sha256 file not found: $resolved"
        }

        return $resolved
    }

    $candidate = [System.IO.Path]::ChangeExtension($ZipPath, ".sha256")
    if (Test-Path $candidate) {
        return $candidate
    }

    return ""
}

function Read-PackageShaExpected([string]$ShaFile, [string]$TargetFileName = "") {
    if ([string]::IsNullOrWhiteSpace($ShaFile)) {
        return ""
    }

    $firstHash = ""
    $hasNamedEntries = $false
    foreach ($line in (Get-Content $ShaFile)) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith("#")) {
            continue
        }

        if ($trimmed -match "^(?<hash>[A-Fa-f0-9]{32,})\s+(?<name>.+)$") {
            $hash = $matches["hash"].Trim()
            $name = $matches["name"].Trim()
            if ($name.StartsWith("*")) {
                $name = $name.Substring(1).Trim()
            }
            if ($name.StartsWith("./")) {
                $name = $name.Substring(2)
            }
            $name = $name.Trim("`"").Trim("'")
            $name = $name.Replace("\", "/")
            $fileName = [System.IO.Path]::GetFileName($name)

            if ([string]::IsNullOrWhiteSpace($firstHash)) {
                $firstHash = $hash
            }

            if (-not [string]::IsNullOrWhiteSpace($fileName)) {
                $hasNamedEntries = $true
                if (-not [string]::IsNullOrWhiteSpace($TargetFileName) -and $fileName.Equals($TargetFileName, [StringComparison]::OrdinalIgnoreCase)) {
                    return $hash
                }
            }

            continue
        }

        if ($trimmed -match "^(?<hash>[A-Fa-f0-9]{32,})$") {
            $hash = $matches["hash"].Trim()
            if ([string]::IsNullOrWhiteSpace($firstHash)) {
                $firstHash = $hash
            }
            continue
        }
    }

    if ([string]::IsNullOrWhiteSpace($firstHash)) {
        throw "Invalid sha256 file (empty): $ShaFile"
    }

    if (-not [string]::IsNullOrWhiteSpace($TargetFileName) -and $hasNamedEntries) {
        throw "sha256 file does not contain hash entry for '$TargetFileName': $ShaFile"
    }

    return $firstHash
}

function Validate-PackageHash([string]$ZipPath, [string]$ShaFile) {
    if ([string]::IsNullOrWhiteSpace($ShaFile)) {
        return
    }

    $zipName = [System.IO.Path]::GetFileName($ZipPath)
    $expected = Read-PackageShaExpected -ShaFile $ShaFile -TargetFileName $zipName
    $actual = (Get-FileHash -Path $ZipPath -Algorithm SHA256).Hash
    if (-not $actual.Equals($expected, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Package hash mismatch. expected=$expected actual=$actual"
    }
}

function Resolve-PackageManifestFile([string]$ZipPath, [string]$ExplicitManifestPath) {
    if (-not [string]::IsNullOrWhiteSpace($ExplicitManifestPath)) {
        $resolved = [System.IO.Path]::GetFullPath($ExplicitManifestPath)
        if (-not (Test-Path $resolved)) {
            throw "Package manifest file not found: $resolved"
        }

        return $resolved
    }

    $parent = Split-Path -Parent $ZipPath
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($ZipPath)
    $candidate = Join-Path $parent ($baseName + ".manifest.json")
    if (Test-Path $candidate) {
        return $candidate
    }

    return ""
}

function Resolve-PackageIndexFile([string]$ZipPath, [string]$ExplicitIndexPath) {
    if (-not [string]::IsNullOrWhiteSpace($ExplicitIndexPath)) {
        $resolved = [System.IO.Path]::GetFullPath($ExplicitIndexPath)
        if (-not (Test-Path $resolved)) {
            throw "Package index file not found: $resolved"
        }

        return $resolved
    }

    $parent = Split-Path -Parent $ZipPath
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($ZipPath)
    $candidate = Join-Path $parent ($baseName + ".index.json")
    if (Test-Path $candidate) {
        return $candidate
    }

    $indexes = @(Get-ChildItem -Path $parent -Filter "datahz2-release-*.index.json" -File -ErrorAction SilentlyContinue)
    if ($indexes.Count -eq 1) {
        return $indexes[0].FullName
    }

    return ""
}

function Resolve-PackageIndexShaFile([string]$IndexFile, [string]$ExplicitIndexShaPath) {
    if ([string]::IsNullOrWhiteSpace($IndexFile)) {
        if (-not [string]::IsNullOrWhiteSpace($ExplicitIndexShaPath)) {
            throw "Package index sha256 file provided but package index file was not resolved."
        }

        return ""
    }

    if (-not [string]::IsNullOrWhiteSpace($ExplicitIndexShaPath)) {
        $resolved = [System.IO.Path]::GetFullPath($ExplicitIndexShaPath)
        if (-not (Test-Path $resolved)) {
            throw "Package index sha256 file not found: $resolved"
        }

        return $resolved
    }

    $parent = Split-Path -Parent $IndexFile
    $indexName = [System.IO.Path]::GetFileName($IndexFile)
    $candidates = New-Object System.Collections.Generic.List[string]
    $candidates.Add([System.IO.Path]::ChangeExtension($IndexFile, ".sha256")) | Out-Null

    if ($indexName -match "^(?<prefix>.+)\.index\.json$") {
        $candidates.Add((Join-Path $parent ($matches["prefix"] + ".sha256"))) | Out-Null
    }

    foreach ($candidate in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path $candidate)) {
            return $candidate
        }
    }

    $shaFiles = @(Get-ChildItem -Path $parent -Filter "datahz2-release-*.sha256" -File -ErrorAction SilentlyContinue)
    if ($shaFiles.Count -eq 1) {
        return $shaFiles[0].FullName
    }

    return ""
}

function Get-ObjectValue([object]$Obj, [string]$Name) {
    if ($null -eq $Obj) {
        return $null
    }

    $prop = $Obj.PSObject.Properties | Where-Object { $_.Name -ieq $Name } | Select-Object -First 1
    if ($prop) {
        return $prop.Value
    }

    return $null
}

function Validate-PackageIndexHash([string]$IndexFile, [string]$IndexShaFile) {
    if ([string]::IsNullOrWhiteSpace($IndexFile) -or [string]::IsNullOrWhiteSpace($IndexShaFile)) {
        return
    }

    $indexName = [System.IO.Path]::GetFileName($IndexFile)
    $expected = Read-PackageShaExpected -ShaFile $IndexShaFile -TargetFileName $indexName
    $actual = (Get-FileHash -Path $IndexFile -Algorithm SHA256).Hash
    if (-not $actual.Equals($expected, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Package index hash mismatch. expected=$expected actual=$actual"
    }
}

function Get-ZipEntrySizeMap([string]$ZipPath) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue | Out-Null

    $map = @{}
    $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        foreach ($entry in $zip.Entries) {
            if ([string]::IsNullOrWhiteSpace($entry.FullName)) {
                continue
            }

            if ($entry.FullName.EndsWith("/")) {
                continue
            }

            $normalizedPath = $entry.FullName.Replace("\", "/")
            $map[$normalizedPath] = [long]$entry.Length
        }
    }
    finally {
        $zip.Dispose()
    }

    return $map
}

function Validate-PackageManifest([string]$ZipPath, [string]$ShaFile, [string]$ManifestFile) {
    if ([string]::IsNullOrWhiteSpace($ManifestFile)) {
        return
    }

    $raw = Get-Content -Path $ManifestFile -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "Package manifest is empty: $ManifestFile"
    }

    try {
        $manifest = $raw | ConvertFrom-Json
    }
    catch {
        throw "Package manifest is invalid JSON: $ManifestFile"
    }

    if ($null -eq $manifest.package) {
        throw "Manifest missing 'package' object: $ManifestFile"
    }

    $zipName = [System.IO.Path]::GetFileName($ZipPath)
    $manifestFileName = [string]$manifest.package.file
    if (-not [string]::IsNullOrWhiteSpace($manifestFileName) -and -not $manifestFileName.Equals($zipName, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Manifest package.file mismatch. expected=$zipName actual=$manifestFileName"
    }

    $manifestHash = [string]$manifest.package.sha256
    if ([string]::IsNullOrWhiteSpace($manifestHash)) {
        throw "Manifest missing package.sha256: $ManifestFile"
    }

    $actualHash = (Get-FileHash -Path $ZipPath -Algorithm SHA256).Hash
    if (-not $actualHash.Equals($manifestHash, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Manifest hash mismatch. expected=$manifestHash actual=$actualHash"
    }

    $shaExpected = Read-PackageShaExpected -ShaFile $ShaFile -TargetFileName $zipName
    if (-not [string]::IsNullOrWhiteSpace($shaExpected) -and -not $manifestHash.Equals($shaExpected, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Manifest sha256 does not match sha256 file. manifest=$manifestHash shaFile=$shaExpected"
    }

    $zipSize = (Get-Item -Path $ZipPath).Length
    if ($null -ne $manifest.package.sizeBytes -and ([long]$manifest.package.sizeBytes) -gt 0) {
        if ([long]$manifest.package.sizeBytes -ne [long]$zipSize) {
            throw "Manifest package.sizeBytes mismatch. expected=$($manifest.package.sizeBytes) actual=$zipSize"
        }
    }

    if ($null -ne $manifest.contents -and $null -ne $manifest.contents.files) {
        $files = @($manifest.contents.files)
        $entryMap = Get-ZipEntrySizeMap -ZipPath $ZipPath

        if ($null -ne $manifest.contents.fileCount -and [int]$manifest.contents.fileCount -ge 0) {
            if ([int]$manifest.contents.fileCount -ne $files.Count) {
                throw "Manifest contents.fileCount mismatch. expected=$($manifest.contents.fileCount) actual=$($files.Count)"
            }
        }

        if ($entryMap.Count -ne $files.Count) {
            throw "Manifest files count mismatch with zip entries. manifest=$($files.Count) zip=$($entryMap.Count)"
        }

        foreach ($item in $files) {
            $path = [string]$item.path
            if ([string]::IsNullOrWhiteSpace($path)) {
                throw "Manifest contains file entry without path: $ManifestFile"
            }

            $normalized = $path.Replace("\", "/")
            if (-not $entryMap.ContainsKey($normalized)) {
                throw "Manifest file not found in zip: $normalized"
            }

            if ($null -ne $item.sizeBytes -and ([long]$item.sizeBytes) -ge 0) {
                $zipEntrySize = [long]$entryMap[$normalized]
                if ([long]$item.sizeBytes -ne $zipEntrySize) {
                    throw "Manifest file size mismatch for '$normalized'. expected=$($item.sizeBytes) actual=$zipEntrySize"
                }
            }
        }
    }
}

function Validate-PackageIndex(
    [string]$ZipPath,
    [string]$ShaFile,
    [string]$ManifestFile,
    [string]$IndexFile
) {
    if ([string]::IsNullOrWhiteSpace($IndexFile)) {
        return
    }

    $raw = Get-Content -Path $IndexFile -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "Package index is empty: $IndexFile"
    }

    try {
        $index = $raw | ConvertFrom-Json
    }
    catch {
        throw "Package index is invalid JSON: $IndexFile"
    }

    $runtimeEntries = @(Get-ObjectValue -Obj $index -Name "runtimes")
    if ($runtimeEntries.Count -eq 0) {
        throw "Package index missing runtimes: $IndexFile"
    }

    $zipName = [System.IO.Path]::GetFileName($ZipPath)
    $matched = $null
    foreach ($entry in $runtimeEntries) {
        $entryZip = [string](Get-ObjectValue -Obj $entry -Name "Zip")
        if (-not [string]::IsNullOrWhiteSpace($entryZip) -and $entryZip.Equals($zipName, [StringComparison]::OrdinalIgnoreCase)) {
            $matched = $entry
            break
        }
    }

    if ($null -eq $matched) {
        throw "Package index has no runtime entry for zip '$zipName': $IndexFile"
    }

    $actualZipHash = (Get-FileHash -Path $ZipPath -Algorithm SHA256).Hash
    $entryPackageSha = [string](Get-ObjectValue -Obj $matched -Name "PackageSha256")
    if (-not [string]::IsNullOrWhiteSpace($entryPackageSha) -and -not $entryPackageSha.Equals($actualZipHash, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Package index PackageSha256 mismatch. expected=$entryPackageSha actual=$actualZipHash"
    }

    if (-not [string]::IsNullOrWhiteSpace($ShaFile)) {
        $shaName = [System.IO.Path]::GetFileName($ShaFile)
        $entrySha = [string](Get-ObjectValue -Obj $matched -Name "Sha256")
        if (-not [string]::IsNullOrWhiteSpace($entrySha) -and -not $entrySha.Equals($shaName, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Package index Sha256 file mismatch. expected=$entrySha actual=$shaName"
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($ManifestFile)) {
        $manifestName = [System.IO.Path]::GetFileName($ManifestFile)
        $entryManifest = [string](Get-ObjectValue -Obj $matched -Name "Manifest")
        if (-not [string]::IsNullOrWhiteSpace($entryManifest) -and -not $entryManifest.Equals($manifestName, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Package index manifest file mismatch. expected=$entryManifest actual=$manifestName"
        }
    }

    $assetEntries = @(Get-ObjectValue -Obj $index -Name "assets")
    if ($assetEntries.Count -eq 0) {
        return
    }

    $filesToValidate = New-Object System.Collections.Generic.List[object]
    $filesToValidate.Add([pscustomobject]@{
        Name = [System.IO.Path]::GetFileName($ZipPath)
        Path = $ZipPath
    }) | Out-Null

    if (-not [string]::IsNullOrWhiteSpace($ShaFile)) {
        $filesToValidate.Add([pscustomobject]@{
            Name = [System.IO.Path]::GetFileName($ShaFile)
            Path = $ShaFile
        }) | Out-Null
    }

    if (-not [string]::IsNullOrWhiteSpace($ManifestFile)) {
        $filesToValidate.Add([pscustomobject]@{
            Name = [System.IO.Path]::GetFileName($ManifestFile)
            Path = $ManifestFile
        }) | Out-Null
    }

    foreach ($file in $filesToValidate) {
        $asset = $null
        foreach ($candidate in $assetEntries) {
            $name = [string](Get-ObjectValue -Obj $candidate -Name "file")
            if (-not [string]::IsNullOrWhiteSpace($name) -and $name.Equals($file.Name, [StringComparison]::OrdinalIgnoreCase)) {
                $asset = $candidate
                break
            }
        }

        if ($null -eq $asset) {
            throw "Package index assets missing file '$($file.Name)'."
        }

        $actualSize = (Get-Item -Path $file.Path).Length
        $assetSize = Get-ObjectValue -Obj $asset -Name "sizeBytes"
        if ($null -ne $assetSize -and ([long]$assetSize) -ge 0 -and ([long]$assetSize -ne [long]$actualSize)) {
            throw "Package index asset size mismatch for '$($file.Name)'. expected=$assetSize actual=$actualSize"
        }

        $assetHash = [string](Get-ObjectValue -Obj $asset -Name "sha256")
        if (-not [string]::IsNullOrWhiteSpace($assetHash)) {
            $actualHash = (Get-FileHash -Path $file.Path -Algorithm SHA256).Hash
            if (-not $actualHash.Equals($assetHash, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Package index asset hash mismatch for '$($file.Name)'. expected=$assetHash actual=$actualHash"
            }
        }
    }
}

function Expand-PackageToRelease([string]$ZipPath, [string]$ReleaseDir) {
    if (Test-Path $ReleaseDir) {
        Remove-Item -Path $ReleaseDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    New-Item -ItemType Directory -Force -Path $ReleaseDir | Out-Null
    Expand-Archive -Path $ZipPath -DestinationPath $ReleaseDir -Force

    $rootExe = Join-Path $ReleaseDir "DataHz.Api.exe"
    if (Test-Path $rootExe) {
        return
    }

    $found = Get-ChildItem -Path $ReleaseDir -Filter "DataHz.Api.exe" -File -Recurse -ErrorAction SilentlyContinue
    if ($found.Count -eq 0) {
        throw "DataHz.Api.exe not found after package extraction: $ReleaseDir"
    }

    if ($found.Count -gt 1) {
        throw "Multiple DataHz.Api.exe found after package extraction: $ReleaseDir"
    }

    $sourceDir = $found[0].Directory.FullName
    if (-not $sourceDir.Equals($ReleaseDir, [StringComparison]::OrdinalIgnoreCase)) {
        Get-ChildItem -Path $sourceDir -Force | ForEach-Object {
            Copy-Item -Path $_.FullName -Destination $ReleaseDir -Force -Recurse
        }
    }

    if (-not (Test-Path $rootExe)) {
        throw "Failed to normalize package layout. Missing DataHz.Api.exe in: $ReleaseDir"
    }
}

function Acquire-DeployLock([string]$LockFile) {
    $parent = Split-Path -Parent $LockFile
    if (-not (Test-Path $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        try {
            $stream = [System.IO.File]::Open(
                $LockFile,
                [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None)

            $payload = "pid=$PID`nstartedUtc=$((Get-Date).ToUniversalTime().ToString('O'))"
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush()
            return $stream
        }
        catch [System.IO.IOException] {
            if ($attempt -eq 0 -and (TryRemove-StaleDeployLock -LockFile $LockFile)) {
                continue
            }

            $holder = ""
            if (Test-Path $LockFile) {
                try { $holder = Get-Content $LockFile -Raw } catch { $holder = "" }
            }

            throw "Another deployment is in progress. Lock: $LockFile $holder"
        }
    }

    throw "Failed to acquire deploy lock: $LockFile"
}

function Release-DeployLock([System.IO.FileStream]$LockHandle, [string]$LockFile) {
    if ($LockHandle) {
        try { $LockHandle.Dispose() } catch { }
    }

    if (Test-Path $LockFile) {
        Remove-Item -Path $LockFile -Force -ErrorAction SilentlyContinue
    }
}

function TryRemove-StaleDeployLock([string]$LockFile) {
    if (-not (Test-Path $LockFile)) {
        return $false
    }

    $raw = ""
    try { $raw = Get-Content $LockFile -Raw } catch { $raw = "" }
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $false
    }

    $ownerPid = 0
    foreach ($line in ($raw -split "`r?`n")) {
        if ($line -match "^\s*pid\s*=\s*(\d+)\s*$") {
            $ownerPid = [int]$matches[1]
            break
        }
    }

    if ($ownerPid -le 0) {
        return $false
    }

    $proc = Get-Process -Id $ownerPid -ErrorAction SilentlyContinue
    if ($proc) {
        return $false
    }

    Remove-Item -Path $LockFile -Force -ErrorAction SilentlyContinue
    return -not (Test-Path $LockFile)
}

function Download-File([string]$Url, [string]$OutputPath, [string]$BearerToken) {
    if ([string]::IsNullOrWhiteSpace($Url)) {
        throw "Download URL is empty."
    }

    $headers = @{}
    if (-not [string]::IsNullOrWhiteSpace($BearerToken)) {
        $headers["Authorization"] = "Bearer $BearerToken"
    }

    $parent = Split-Path -Parent $OutputPath
    if (-not (Test-Path $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    Invoke-WebRequest `
        -Uri $Url `
        -OutFile $OutputPath `
        -Headers $headers `
        -TimeoutSec 120 `
        -UseBasicParsing
}

function Resolve-DownloadFileName([string]$Url, [string]$DefaultName) {
    if ([string]::IsNullOrWhiteSpace($Url)) {
        return $DefaultName
    }

    $uri = $null
    if (-not [System.Uri]::TryCreate($Url, [System.UriKind]::Absolute, [ref]$uri)) {
        return $DefaultName
    }

    $candidate = [System.IO.Path]::GetFileName($uri.LocalPath)
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        return $DefaultName
    }

    foreach ($ch in [System.IO.Path]::GetInvalidFileNameChars()) {
        $candidate = $candidate.Replace([string]$ch, "_")
    }

    if ([string]::IsNullOrWhiteSpace($candidate)) {
        return $DefaultName
    }

    return $candidate
}

function Invoke-SmokeScript([string]$ScriptPath, [hashtable]$SmokeParams) {
    & $ScriptPath @SmokeParams
    if ($LASTEXITCODE -ne 0) {
        throw "Smoke test failed. ExitCode=$LASTEXITCODE"
    }
}

function Remove-OldDownloads([string]$DownloadRoot, [int]$KeepCount, [string]$CurrentReleaseId) {
    if ($KeepCount -lt 1) {
        return
    }

    if (-not (Test-Path $DownloadRoot)) {
        return
    }

    $dirs = Get-ChildItem -Path $DownloadRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match "^\d{8}-\d{6}$" } |
        Sort-Object Name -Descending

    if ($dirs.Count -le $KeepCount) {
        return
    }

    $remove = $dirs | Select-Object -Skip $KeepCount
    foreach ($dir in $remove) {
        if ($dir.Name -eq $CurrentReleaseId) {
            continue
        }

        Remove-Item -Path $dir.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if (-not $SkipServiceInstall) {
    Assert-Admin
}

$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ReleaseRoot)) {
    $ReleaseRoot = Join-Path $root "artifacts\releases"
}

$ReleaseRoot = [System.IO.Path]::GetFullPath($ReleaseRoot)
New-Item -ItemType Directory -Force -Path $ReleaseRoot | Out-Null

$publishScript = Join-Path $PSScriptRoot "publish-api.ps1"
$installScript = Join-Path $PSScriptRoot "install-windows-service.ps1"
$smokeScript = Join-Path $PSScriptRoot "smoke-test-api.ps1"

$historyFile = Join-Path $ReleaseRoot "deploy-history.json"
$activeFile = Join-Path $ReleaseRoot "active-release.txt"
$downloadRoot = Join-Path $ReleaseRoot "_downloads"
$lockFile = Join-Path $ReleaseRoot "deploy.lock"
$history = Load-History -HistoryFile $historyFile

$previousActive = Get-ActiveReleaseId -ActiveFile $activeFile
$releaseId = Get-Date -Format "yyyyMMdd-HHmmss"
$releaseDir = Join-Path $ReleaseRoot $releaseId
$healthUrl = Resolve-HealthUrl -UrlsText $Urls -HealthPath $HealthEndpoint
$startedAtUtc = (Get-Date).ToUniversalTime().ToString("O")

$requireManifestFromEnv = $false
$envRequireManifest = $env:DATAHZ_DEPLOY_REQUIRE_MANIFEST
if (-not [string]::IsNullOrWhiteSpace($envRequireManifest)) {
    $requireManifestFromEnv = ConvertTo-StrictBoolean -Name "DATAHZ_DEPLOY_REQUIRE_MANIFEST" -Value $envRequireManifest
}

$effectiveRequireManifest = $RequireManifest.IsPresent
if (-not $PSBoundParameters.ContainsKey("RequireManifest")) {
    $effectiveRequireManifest = $requireManifestFromEnv
}

$entry = [ordered]@{
    releaseId = $releaseId
    releaseDir = $releaseDir
    serviceName = $ServiceName
    startedAtUtc = $startedAtUtc
    previousActiveReleaseId = $previousActive
    healthUrl = $healthUrl
    requireManifest = [bool]$effectiveRequireManifest
    status = "in-progress"
}

$rollbackPerformed = $false
$deployLock = $null
$deployLock = Acquire-DeployLock -LockFile $lockFile

try {
    if (-not [string]::IsNullOrWhiteSpace($PackageZip) -and -not [string]::IsNullOrWhiteSpace($PackageUrl)) {
        throw "PackageZip and PackageUrl are mutually exclusive. Use only one."
    }

    if (-not [string]::IsNullOrWhiteSpace($PackageManifestFile) -and -not [string]::IsNullOrWhiteSpace($PackageManifestUrl)) {
        throw "PackageManifestFile and PackageManifestUrl are mutually exclusive. Use only one."
    }

    if (-not [string]::IsNullOrWhiteSpace($PackageManifestUrl) -and [string]::IsNullOrWhiteSpace($PackageUrl)) {
        throw "PackageManifestUrl requires PackageUrl."
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

    $effectivePackageZip = $PackageZip
    $effectivePackageShaFile = $PackageSha256File
    $effectivePackageManifestFile = $PackageManifestFile
    $effectivePackageIndexFile = $PackageIndexFile
    $effectivePackageIndexShaFile = $PackageIndexSha256File
    if (-not [string]::IsNullOrWhiteSpace($PackageUrl)) {
        $downloadDir = Join-Path $downloadRoot $releaseId
        $downloadZipName = Resolve-DownloadFileName -Url $PackageUrl -DefaultName "package.zip"
        $downloadZip = Join-Path $downloadDir $downloadZipName
        Download-File -Url $PackageUrl -OutputPath $downloadZip -BearerToken $PackageBearerToken
        $effectivePackageZip = $downloadZip

        if (-not [string]::IsNullOrWhiteSpace($PackageSha256Url)) {
            $downloadShaName = Resolve-DownloadFileName -Url $PackageSha256Url -DefaultName "package.sha256"
            $downloadSha = Join-Path $downloadDir $downloadShaName
            Download-File -Url $PackageSha256Url -OutputPath $downloadSha -BearerToken $PackageBearerToken
            $effectivePackageShaFile = $downloadSha
        }

        if (-not [string]::IsNullOrWhiteSpace($PackageManifestUrl)) {
            $downloadManifestName = Resolve-DownloadFileName -Url $PackageManifestUrl -DefaultName "package.manifest.json"
            $downloadManifest = Join-Path $downloadDir $downloadManifestName
            Download-File -Url $PackageManifestUrl -OutputPath $downloadManifest -BearerToken $PackageBearerToken
            $effectivePackageManifestFile = $downloadManifest
        }

        if (-not [string]::IsNullOrWhiteSpace($PackageIndexUrl)) {
            $downloadIndexName = Resolve-DownloadFileName -Url $PackageIndexUrl -DefaultName "release.index.json"
            $downloadIndex = Join-Path $downloadDir $downloadIndexName
            Download-File -Url $PackageIndexUrl -OutputPath $downloadIndex -BearerToken $PackageBearerToken
            $effectivePackageIndexFile = $downloadIndex
        }

        if (-not [string]::IsNullOrWhiteSpace($PackageIndexSha256Url)) {
            $downloadIndexShaName = Resolve-DownloadFileName -Url $PackageIndexSha256Url -DefaultName "release.index.sha256"
            $downloadIndexSha = Join-Path $downloadDir $downloadIndexShaName
            Download-File -Url $PackageIndexSha256Url -OutputPath $downloadIndexSha -BearerToken $PackageBearerToken
            $effectivePackageIndexShaFile = $downloadIndexSha
        }

        $entry.packageUrl = $PackageUrl
        if (-not [string]::IsNullOrWhiteSpace($PackageSha256Url)) {
            $entry.packageSha256Url = $PackageSha256Url
        }
        if (-not [string]::IsNullOrWhiteSpace($PackageManifestUrl)) {
            $entry.packageManifestUrl = $PackageManifestUrl
        }
        if (-not [string]::IsNullOrWhiteSpace($PackageIndexUrl)) {
            $entry.packageIndexUrl = $PackageIndexUrl
        }
        if (-not [string]::IsNullOrWhiteSpace($PackageIndexSha256Url)) {
            $entry.packageIndexSha256Url = $PackageIndexSha256Url
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($effectivePackageZip)) {
        $resolvedPackageZip = [System.IO.Path]::GetFullPath($effectivePackageZip)
        if (-not (Test-Path $resolvedPackageZip)) {
            throw "Package zip not found: $resolvedPackageZip"
        }

        $resolvedPackageSha = Resolve-PackageShaFile -ZipPath $resolvedPackageZip -ExplicitShaPath $effectivePackageShaFile
        $resolvedPackageManifest = Resolve-PackageManifestFile -ZipPath $resolvedPackageZip -ExplicitManifestPath $effectivePackageManifestFile
        $resolvedPackageIndex = Resolve-PackageIndexFile -ZipPath $resolvedPackageZip -ExplicitIndexPath $effectivePackageIndexFile
        $resolvedPackageIndexSha = Resolve-PackageIndexShaFile -IndexFile $resolvedPackageIndex -ExplicitIndexShaPath $effectivePackageIndexShaFile
        if ($effectiveRequireManifest -and [string]::IsNullOrWhiteSpace($resolvedPackageManifest)) {
            throw "RequireManifest is enabled, but package manifest file was not found."
        }
        Validate-PackageHash -ZipPath $resolvedPackageZip -ShaFile $resolvedPackageSha
        Validate-PackageManifest -ZipPath $resolvedPackageZip -ShaFile $resolvedPackageSha -ManifestFile $resolvedPackageManifest
        Validate-PackageIndexHash -IndexFile $resolvedPackageIndex -IndexShaFile $resolvedPackageIndexSha
        Validate-PackageIndex -ZipPath $resolvedPackageZip -ShaFile $resolvedPackageSha -ManifestFile $resolvedPackageManifest -IndexFile $resolvedPackageIndex
        Expand-PackageToRelease -ZipPath $resolvedPackageZip -ReleaseDir $releaseDir

        $entry.source = "package"
        $entry.packageZip = $resolvedPackageZip
        if (-not [string]::IsNullOrWhiteSpace($resolvedPackageSha)) {
            $entry.packageSha256File = $resolvedPackageSha
        }
        if (-not [string]::IsNullOrWhiteSpace($resolvedPackageManifest)) {
            $entry.packageManifestFile = $resolvedPackageManifest
        }
        if (-not [string]::IsNullOrWhiteSpace($resolvedPackageIndex)) {
            $entry.packageIndexFile = $resolvedPackageIndex
        }
        if (-not [string]::IsNullOrWhiteSpace($resolvedPackageIndexSha)) {
            $entry.packageIndexSha256File = $resolvedPackageIndexSha
        }
    }
    else {
        $publishParams = @{
            Configuration = $Configuration
            Runtime = $Runtime
            OutputDir = $releaseDir
        }
        if ($FrameworkDependent) { $publishParams.FrameworkDependent = $true }
        if ($MultiFile) { $publishParams.MultiFile = $true }
        if ($ReadyToRun) { $publishParams.ReadyToRun = $true }
        if ($Trimmed) { $publishParams.Trimmed = $true }
        if ($NoRestore) { $publishParams.NoRestore = $true }

        & $publishScript @publishParams
        $entry.source = "publish"
    }

    if (-not $SkipServiceInstall) {
        $installParams = @{
            ServiceName = $ServiceName
            PublishDir = $releaseDir
            Urls = $Urls
            EnvironmentName = $EnvironmentName
            StartAfterInstall = $true
        }
        & $installScript @installParams
    }

    if (-not $SkipServiceInstall -and -not $SkipHealthCheck) {
        $healthy = Wait-ForHealth -Url $healthUrl -TimeoutSeconds $HealthTimeoutSeconds -IntervalSeconds $HealthCheckIntervalSeconds
        if (-not $healthy) {
            throw "Health check timed out: $healthUrl"
        }
    }

    if ($RunSmokeTest) {
        $healthUri = [Uri]$healthUrl
        $smokeBaseUrl = "{0}://{1}:{2}" -f $healthUri.Scheme, $healthUri.Host, $healthUri.Port

        $smokeParams = @{
            BaseUrl = $smokeBaseUrl
            TimeoutSeconds = [Math]::Max(5, $HealthCheckIntervalSeconds * 5)
            CheckRetryCount = $SmokeCheckRetryCount
            CheckRetryDelayMilliseconds = $SmokeCheckRetryDelayMilliseconds
            HealthPollDelayMilliseconds = $SmokeHealthPollDelayMilliseconds
            WarnCheckDurationMilliseconds = $SmokeWarnCheckDurationMilliseconds
            FailCheckDurationMilliseconds = $SmokeFailCheckDurationMilliseconds
            FailureContentSnippetLength = $SmokeFailureContentSnippetLength
        }
        if (-not $SkipServiceInstall) {
            $smokeParams.ServiceName = $ServiceName
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

        Invoke-SmokeScript -ScriptPath $smokeScript -SmokeParams $smokeParams
    }

    if (-not $SkipServiceInstall) {
        Set-ActiveReleaseId -ActiveFile $activeFile -ReleaseId $releaseId
    }
    Remove-OldReleases -Root $ReleaseRoot -KeepCount $KeepReleases -CurrentReleaseId $releaseId
    Remove-OldDownloads -DownloadRoot $downloadRoot -KeepCount $KeepReleases -CurrentReleaseId $releaseId

    $entry.status = if ($SkipServiceInstall) { "published-only" } else { "succeeded" }
}
catch {
    $entry.status = "failed"
    $entry.error = $_.Exception.Message

    if (-not $SkipServiceInstall -and -not [string]::IsNullOrWhiteSpace($previousActive)) {
        $previousDir = Join-Path $ReleaseRoot $previousActive
        if (Test-Path (Join-Path $previousDir "DataHz.Api.exe")) {
            try {
                $rollbackParams = @{
                    ServiceName = $ServiceName
                    PublishDir = $previousDir
                    Urls = $Urls
                    EnvironmentName = $EnvironmentName
                    StartAfterInstall = $true
                }
                & $installScript @rollbackParams

                if (-not $SkipHealthCheck) {
                    $rollbackHealthy = Wait-ForHealth -Url $healthUrl -TimeoutSeconds $HealthTimeoutSeconds -IntervalSeconds $HealthCheckIntervalSeconds
                    if (-not $rollbackHealthy) {
                        throw "Rollback health check timed out: $healthUrl"
                    }
                }

                if ($RunSmokeTest) {
                    $healthUri = [Uri]$healthUrl
                    $smokeBaseUrl = "{0}://{1}:{2}" -f $healthUri.Scheme, $healthUri.Host, $healthUri.Port

                    $smokeParams = @{
                        BaseUrl = $smokeBaseUrl
                        TimeoutSeconds = [Math]::Max(5, $HealthCheckIntervalSeconds * 5)
                        CheckRetryCount = $SmokeCheckRetryCount
                        CheckRetryDelayMilliseconds = $SmokeCheckRetryDelayMilliseconds
                        HealthPollDelayMilliseconds = $SmokeHealthPollDelayMilliseconds
                        WarnCheckDurationMilliseconds = $SmokeWarnCheckDurationMilliseconds
                        FailCheckDurationMilliseconds = $SmokeFailCheckDurationMilliseconds
                        FailureContentSnippetLength = $SmokeFailureContentSnippetLength
                    }
                    if (-not $SkipServiceInstall) {
                        $smokeParams.ServiceName = $ServiceName
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

                    Invoke-SmokeScript -ScriptPath $smokeScript -SmokeParams $smokeParams
                }

                Set-ActiveReleaseId -ActiveFile $activeFile -ReleaseId $previousActive
                $rollbackPerformed = $true
                $entry.rollbackTo = $previousActive
                $entry.status = "rolled-back"
            }
            catch {
                $entry.rollbackError = $_.Exception.Message
            }
        }
    }
}
finally {
    $entry.completedAtUtc = (Get-Date).ToUniversalTime().ToString("O")
    $history = @($history) + [pscustomobject]$entry
    Save-History -HistoryFile $historyFile -HistoryItems $history
    Release-DeployLock -LockHandle $deployLock -LockFile $lockFile
}

if ($entry.status -eq "failed") {
    throw "Deployment failed. $($entry.error)"
}

if ($rollbackPerformed) {
    throw "Deployment failed and rolled back to release '$($entry.rollbackTo)'."
}

Write-Host "Deployment completed."
Write-Host "  ReleaseId: $releaseId"
Write-Host "  ReleaseDir: $releaseDir"
Write-Host "  Status: $($entry.status)"
Write-Host "  RequireManifest: $effectiveRequireManifest"
Write-Host "  HealthUrl: $healthUrl"
