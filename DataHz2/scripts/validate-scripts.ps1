[CmdletBinding()]
param(
    [string]$ScriptsDir = ""
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ScriptsDir)) {
    $ScriptsDir = Join-Path $root "scripts"
}

$ScriptsDir = [System.IO.Path]::GetFullPath($ScriptsDir)
if (-not (Test-Path $ScriptsDir)) {
    throw "Scripts directory not found: $ScriptsDir"
}

$files = Get-ChildItem -Path $ScriptsDir -Filter *.ps1 -File | Sort-Object Name
if ($files.Count -eq 0) {
    Write-Host "No .ps1 files found in $ScriptsDir"
    exit 0
}

$errorCount = 0
foreach ($file in $files) {
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors) | Out-Null

    if ($parseErrors -and $parseErrors.Count -gt 0) {
        $errorCount += $parseErrors.Count
        Write-Host "[FAIL] $($file.Name)" -ForegroundColor Red
        foreach ($err in $parseErrors) {
            Write-Host "  - $($err.Message)"
        }
    }
    else {
        Write-Host "[OK]   $($file.Name)" -ForegroundColor Green
    }
}

if ($errorCount -gt 0) {
    throw "PowerShell script validation failed. ParseErrors=$errorCount"
}

Write-Host "All PowerShell scripts passed syntax validation."
