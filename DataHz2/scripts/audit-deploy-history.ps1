[CmdletBinding()]
param(
    [string]$ReleaseRoot = "",
    [int]$Take = 20,
    [string[]]$Statuses = @(),
    [switch]$AsJson,
    [switch]$FailOnIssues
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

function In-Statuses([string]$Status, [string[]]$AllowedStatuses) {
    if ($AllowedStatuses.Count -eq 0) {
        return $true
    }

    foreach ($allowed in $AllowedStatuses) {
        if ([string]::IsNullOrWhiteSpace($allowed)) {
            continue
        }

        if ($Status.Equals($allowed, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ReleaseRoot)) {
    $ReleaseRoot = Join-Path $root "artifacts\releases"
}

$ReleaseRoot = [System.IO.Path]::GetFullPath($ReleaseRoot)
if (-not (Test-Path $ReleaseRoot)) {
    Write-Host "Release root not found: $ReleaseRoot"
    exit 0
}

$historyFile = Join-Path $ReleaseRoot "deploy-history.json"
$history = Load-History -HistoryFile $historyFile
if ($history.Count -eq 0) {
    Write-Host "No deployment history found: $historyFile"
    exit 0
}

$normalizedStatuses = @($Statuses | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

$sorted = @($history | Sort-Object -Property @{ Expression = { ConvertTo-DataHzDateOrMin (Get-DataHzObjectValue -Obj $_ -Name "startedAtUtc") } } -Descending)
$filtered = @($sorted | Where-Object { In-Statuses -Status ([string](Get-DataHzObjectValue -Obj $_ -Name "status")) -AllowedStatuses $normalizedStatuses })
if ($Take -gt 0) {
    $filtered = @($filtered | Select-Object -First $Take)
}

$rows = New-Object System.Collections.Generic.List[object]
foreach ($item in $filtered) {
    $audit = Get-DataHzHistoryAuditRow -Item $item
    $rows.Add([pscustomobject]@{
        ReleaseId = $audit.releaseId
        Status = $audit.status
        Source = $audit.source
        RequireManifest = $audit.requireManifest
        HasManifest = $audit.hasManifest
        HasIndex = $audit.hasIndex
        HasIndexSha = $audit.hasIndexSha
        StartedAtUtc = $audit.startedAtUtc
        CompletedAtUtc = $audit.completedAtUtc
        IssueCount = $audit.issueCount
        Issues = $audit.issues
    }) | Out-Null
}

$rowArray = $rows.ToArray()
$issueRows = @($rowArray | Where-Object { $_.IssueCount -gt 0 })

if ($AsJson) {
    [pscustomobject]@{
        releaseRoot = $ReleaseRoot
        totalHistoryEntries = @($history).Count
        auditedEntries = $rowArray.Count
        issueEntries = $issueRows.Count
        hasIssues = ($issueRows.Count -gt 0)
        items = $rowArray
    } | ConvertTo-Json -Depth 8
}
else {
    if ($rowArray.Count -eq 0) {
        Write-Host "No deploy-history entries matched current filters."
        exit 0
    }

    $rowArray | Format-Table -AutoSize ReleaseId, Status, Source, RequireManifest, HasManifest, HasIndex, HasIndexSha, IssueCount, StartedAtUtc

    Write-Host ""
    Write-Host "Audited entries: $($rowArray.Count) / $(@($history).Count)"
    Write-Host "Entries with issues: $($issueRows.Count)"

    if ($issueRows.Count -gt 0) {
        Write-Host ""
        Write-Host "Issue details:" -ForegroundColor Yellow
        foreach ($row in $issueRows) {
            $id = if ([string]::IsNullOrWhiteSpace($row.ReleaseId)) { "<missing-releaseId>" } else { $row.ReleaseId }
            Write-Host "  [$id] $($row.Issues)" -ForegroundColor Yellow
        }
    }
}

if ($FailOnIssues -and $issueRows.Count -gt 0) {
    exit 1
}

exit 0
