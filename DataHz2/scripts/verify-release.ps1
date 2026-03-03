[CmdletBinding()]
param(
    [string]$PackageZip = "",
    [string]$PackageSha256File = "",
    [string]$PackageManifestFile = ""
)

$ErrorActionPreference = "Stop"

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

function Read-PackageShaExpected([string]$ShaFile) {
    if ([string]::IsNullOrWhiteSpace($ShaFile)) {
        return ""
    }

    $firstLine = Get-Content $ShaFile | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($firstLine)) {
        throw "Invalid sha256 file (empty): $ShaFile"
    }

    $expected = ($firstLine -split "\s+")[0].Trim()
    if ([string]::IsNullOrWhiteSpace($expected) -or $expected.Length -lt 32) {
        throw "Invalid sha256 content: $ShaFile"
    }

    return $expected
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

function Validate-Manifest(
    [string]$ManifestFile,
    [string]$ZipPath,
    [long]$ZipSize,
    [string]$ActualHash,
    [string]$ShaExpected,
    [hashtable]$EntryMap
) {
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

    if ($null -eq $manifest.formatVersion -or [int]$manifest.formatVersion -lt 1) {
        throw "Manifest formatVersion is missing or invalid: $ManifestFile"
    }

    if ($null -eq $manifest.package) {
        throw "Manifest missing 'package' object: $ManifestFile"
    }

    $zipName = [System.IO.Path]::GetFileName($ZipPath)
    $manifestPackageFile = [string]$manifest.package.file
    if (-not [string]::IsNullOrWhiteSpace($manifestPackageFile) -and -not $manifestPackageFile.Equals($zipName, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Manifest package.file mismatch. expected=$zipName actual=$manifestPackageFile"
    }

    $manifestHash = [string]$manifest.package.sha256
    if ([string]::IsNullOrWhiteSpace($manifestHash)) {
        throw "Manifest missing package.sha256: $ManifestFile"
    }

    if (-not $manifestHash.Equals($ActualHash, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Manifest hash mismatch. expected=$manifestHash actual=$ActualHash"
    }

    if (-not [string]::IsNullOrWhiteSpace($ShaExpected) -and -not $manifestHash.Equals($ShaExpected, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Manifest sha256 does not match sha256 file. manifest=$manifestHash shaFile=$ShaExpected"
    }

    if ($null -ne $manifest.package.sizeBytes -and ([long]$manifest.package.sizeBytes) -gt 0) {
        if ([long]$manifest.package.sizeBytes -ne $ZipSize) {
            throw "Manifest package.sizeBytes mismatch. expected=$($manifest.package.sizeBytes) actual=$ZipSize"
        }
    }

    if ($null -ne $manifest.contents -and $null -ne $manifest.contents.files) {
        $files = @($manifest.contents.files)
        if ($null -ne $manifest.contents.fileCount -and [int]$manifest.contents.fileCount -ge 0) {
            if ([int]$manifest.contents.fileCount -ne $files.Count) {
                throw "Manifest contents.fileCount mismatch. expected=$($manifest.contents.fileCount) actual=$($files.Count)"
            }
        }

        if ($EntryMap.Count -ne $files.Count) {
            throw "Manifest files count mismatch with zip entries. manifest=$($files.Count) zip=$($EntryMap.Count)"
        }

        foreach ($item in $files) {
            $path = [string]$item.path
            if ([string]::IsNullOrWhiteSpace($path)) {
                throw "Manifest contains file entry without path: $ManifestFile"
            }

            $normalized = $path.Replace("\", "/")
            if (-not $EntryMap.ContainsKey($normalized)) {
                throw "Manifest file not found in zip: $normalized"
            }

            if ($null -ne $item.sizeBytes -and ([long]$item.sizeBytes) -ge 0) {
                $zipEntrySize = [long]$EntryMap[$normalized]
                if ([long]$item.sizeBytes -ne $zipEntrySize) {
                    throw "Manifest file size mismatch for '$normalized'. expected=$($item.sizeBytes) actual=$zipEntrySize"
                }
            }
        }
    }
}

if ([string]::IsNullOrWhiteSpace($PackageZip)) {
    throw "PackageZip is required."
}

$resolvedZip = [System.IO.Path]::GetFullPath($PackageZip)
if (-not (Test-Path $resolvedZip)) {
    throw "Package zip not found: $resolvedZip"
}

$resolvedSha = Resolve-PackageShaFile -ZipPath $resolvedZip -ExplicitShaPath $PackageSha256File
$resolvedManifest = Resolve-PackageManifestFile -ZipPath $resolvedZip -ExplicitManifestPath $PackageManifestFile
$entryMap = Get-ZipEntrySizeMap -ZipPath $resolvedZip

if (-not $entryMap.ContainsKey("DataHz.Api.exe")) {
    throw "Package layout check failed: DataHz.Api.exe not found inside zip."
}

$actualHash = (Get-FileHash -Path $resolvedZip -Algorithm SHA256).Hash
$zipSize = (Get-Item -Path $resolvedZip).Length

if (-not [string]::IsNullOrWhiteSpace($resolvedSha)) {
    $shaExpected = Read-PackageShaExpected -ShaFile $resolvedSha
    if (-not $actualHash.Equals($shaExpected, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Package hash mismatch. expected=$shaExpected actual=$actualHash"
    }
}
else {
    $shaExpected = ""
}

if (-not [string]::IsNullOrWhiteSpace($resolvedManifest)) {
    Validate-Manifest `
        -ManifestFile $resolvedManifest `
        -ZipPath $resolvedZip `
        -ZipSize $zipSize `
        -ActualHash $actualHash `
        -ShaExpected $shaExpected `
        -EntryMap $entryMap
}

Write-Host "Release package verified."
Write-Host "  Zip: $resolvedZip"
Write-Host "  Sha256: $actualHash"
Write-Host "  EntryCount: $($entryMap.Count)"
Write-Host "  ShaFile: $(if ([string]::IsNullOrWhiteSpace($resolvedSha)) { '<none>' } else { $resolvedSha })"
Write-Host "  Manifest: $(if ([string]::IsNullOrWhiteSpace($resolvedManifest)) { '<none>' } else { $resolvedManifest })"
