[CmdletBinding()]
param(
    [string]$ReleaseRoot = "",
    [string]$ServiceName = "DataHz.Api",
    [string]$BaseUrl = "http://127.0.0.1:5080",
    [int]$HistoryTake = 10,
    [switch]$AsJson
)

$ErrorActionPreference = "Stop"

$historyAuditLib = Join-Path $PSScriptRoot "history-audit-lib.ps1"
if (-not (Test-Path $historyAuditLib)) {
    throw "history-audit-lib.ps1 not found: $historyAuditLib"
}
. $historyAuditLib

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

function Get-Health([string]$Url) {
    try {
        $resp = Invoke-WebRequest -Uri "$Url/health" -Method Get -TimeoutSec 8 -UseBasicParsing
        if ($resp.StatusCode -ne 200) {
            return [pscustomobject]@{
                ok = $false
                statusCode = $resp.StatusCode
                detail = "HTTP $($resp.StatusCode)"
            }
        }

        try {
            $obj = $resp.Content | ConvertFrom-Json
            $state = if ($obj.status) { $obj.status } elseif ($obj.Status) { $obj.Status } else { "" }
            return [pscustomobject]@{
                ok = ($state -eq "ok")
                statusCode = 200
                detail = if ($state) { "status=$state" } else { "status field missing" }
            }
        }
        catch {
            return [pscustomobject]@{
                ok = $false
                statusCode = 200
                detail = "response is not valid JSON"
            }
        }
    }
    catch {
        return [pscustomobject]@{
            ok = $false
            statusCode = 0
            detail = $_.Exception.Message
        }
    }
}

$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ReleaseRoot)) {
    $ReleaseRoot = Join-Path $root "artifacts\releases"
}

$ReleaseRoot = [System.IO.Path]::GetFullPath($ReleaseRoot)
$historyFile = Join-Path $ReleaseRoot "deploy-history.json"
$activeFile = Join-Path $ReleaseRoot "active-release.txt"
$lockFile = Join-Path $ReleaseRoot "deploy.lock"

$activeReleaseId = Get-ActiveReleaseId -ActiveFile $activeFile
$history = Load-History -HistoryFile $historyFile |
    Sort-Object startedAtUtc -Descending |
    Select-Object -First ([Math]::Max(1, $HistoryTake))

$serviceInfo = [pscustomobject]@{
    exists = $false
    status = ""
    startType = ""
}

$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($svc) {
    $serviceInfo = [pscustomobject]@{
        exists = $true
        status = [string]$svc.Status
        startType = [string]$svc.StartType
    }
}

$health = Get-Health -Url $BaseUrl.TrimEnd("/")
$historyAudit = @($history | ForEach-Object { Get-DataHzHistoryAuditRow -Item $_ })
$issueRows = @($historyAudit | Where-Object { $_.issueCount -gt 0 })

$summary = [pscustomobject]@{
    utc = (Get-Date).ToUniversalTime().ToString("O")
    releaseRoot = $ReleaseRoot
    activeReleaseId = $activeReleaseId
    lockFileExists = (Test-Path $lockFile)
    service = $serviceInfo
    health = $health
    recentHistory = $history
    recentHistoryAudit = $historyAudit
    audit = [pscustomobject]@{
        auditedEntries = $historyAudit.Count
        issueEntries = $issueRows.Count
        hasIssues = ($issueRows.Count -gt 0)
    }
}

if ($AsJson) {
    $summary | ConvertTo-Json -Depth 12
    exit 0
}

Write-Host "Deployment Status"
Write-Host "  Utc: $($summary.utc)"
Write-Host "  ReleaseRoot: $($summary.releaseRoot)"
Write-Host "  ActiveReleaseId: $($summary.activeReleaseId)"
Write-Host "  DeployLock: $($summary.lockFileExists)"
Write-Host "  Service: exists=$($summary.service.exists) status=$($summary.service.status) startType=$($summary.service.startType)"
Write-Host "  Health: ok=$($summary.health.ok) statusCode=$($summary.health.statusCode) detail=$($summary.health.detail)"
Write-Host "  HistoryAudit: audited=$($summary.audit.auditedEntries) issues=$($summary.audit.issueEntries) hasIssues=$($summary.audit.hasIssues)"
Write-Host ""

if ($summary.recentHistoryAudit.Count -eq 0) {
    Write-Host "No deployment history."
}
else {
    $summary.recentHistoryAudit | Format-Table -AutoSize releaseId, status, source, requireManifest, hasManifest, hasIndex, hasIndexSha, issueCount, startedAtUtc, rollbackTo

    if ($summary.audit.hasIssues) {
        Write-Host ""
        Write-Host "History audit issues:" -ForegroundColor Yellow
        foreach ($row in $issueRows) {
            Write-Host "  [$($row.releaseId)] $($row.issues)" -ForegroundColor Yellow
        }
    }
}
