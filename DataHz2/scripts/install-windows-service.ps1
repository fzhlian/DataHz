[CmdletBinding()]
param(
    [string]$ServiceName = "DataHz.Api",
    [string]$DisplayName = "DataHz API Service",
    [string]$Description = "DataHz2 API service",
    [string]$PublishDir = "",
    [string]$ExecutableName = "DataHz.Api.exe",
    [string]$ContentRoot = "",
    [string]$Urls = "http://0.0.0.0:5080",
    [string]$EnvironmentName = "Production",
    [ValidateSet("auto", "demand", "disabled")]
    [string]$StartMode = "auto",
    [switch]$StartAfterInstall,
    [switch]$ForceRecreate
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

function Invoke-Sc([string[]]$Arguments) {
    $output = & sc.exe @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "sc.exe failed: $($Arguments -join ' ')`n$output"
    }

    return $output
}

function Wait-ServiceDeleted([string]$Name, [int]$TimeoutSeconds = 10) {
    $start = Get-Date
    while ((Get-Date) - $start -lt [TimeSpan]::FromSeconds($TimeoutSeconds)) {
        $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if (-not $svc) {
            return
        }

        Start-Sleep -Milliseconds 300
    }

    throw "Service '$Name' still exists after timeout."
}

Assert-Admin

$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($PublishDir)) {
    $PublishDir = Join-Path $root "artifacts\publish\win-x64"
}

$PublishDir = [System.IO.Path]::GetFullPath($PublishDir)
if ([string]::IsNullOrWhiteSpace($ContentRoot)) {
    $ContentRoot = $PublishDir
}
$ContentRoot = [System.IO.Path]::GetFullPath($ContentRoot)

$exePath = Join-Path $PublishDir $ExecutableName
if (-not (Test-Path $exePath)) {
    throw "Executable not found: $exePath"
}

$binPath = "`"$exePath`" --contentRoot `"$ContentRoot`" --environment `"$EnvironmentName`" --urls `"$Urls`""

$existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($existing -and $ForceRecreate) {
    if ($existing.Status -ne "Stopped") {
        Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500
    }

    Invoke-Sc @("delete", $ServiceName) | Out-Null
    Wait-ServiceDeleted -Name $ServiceName
    $existing = $null
}

if (-not $existing) {
    Invoke-Sc @(
        "create", $ServiceName,
        "binPath= $binPath",
        "start= $StartMode",
        "DisplayName= $DisplayName"
    ) | Out-Null
}
else {
    Invoke-Sc @(
        "config", $ServiceName,
        "binPath= $binPath",
        "start= $StartMode",
        "DisplayName= $DisplayName"
    ) | Out-Null
}

Invoke-Sc @("description", $ServiceName, $Description) | Out-Null
Invoke-Sc @("failure", $ServiceName, "reset= 86400", "actions= restart/5000/restart/5000/restart/5000") | Out-Null

if ($StartAfterInstall) {
    Start-Service -Name $ServiceName
}

$service = Get-Service -Name $ServiceName -ErrorAction Stop
Write-Host "Service configured:"
Write-Host "  Name: $($service.Name)"
Write-Host "  Status: $($service.Status)"
Write-Host "  StartType: $($service.StartType)"
Write-Host "  Exe: $exePath"
Write-Host "  Urls: $Urls"
