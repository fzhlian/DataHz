[CmdletBinding()]
param(
    [switch]$KeepArtifacts
)

$ErrorActionPreference = "Stop"

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

function New-RunId {
    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMdd-HHmmss-fff")
    $suffix = [Guid]::NewGuid().ToString("N").Substring(0, 8)
    return "$timestamp-$suffix"
}

$root = Split-Path -Parent $PSScriptRoot
$auditHistoryScript = Join-Path $PSScriptRoot "audit-deploy-history.ps1"
$deploymentStatusScript = Join-Path $PSScriptRoot "deployment-status.ps1"
if (-not (Test-Path $auditHistoryScript)) {
    throw "audit-deploy-history.ps1 not found: $auditHistoryScript"
}
if (-not (Test-Path $deploymentStatusScript)) {
    throw "deployment-status.ps1 not found: $deploymentStatusScript"
}

$runId = New-RunId
$tempRoot = Join-Path $root ("artifacts\selftest\history-audits-" + $runId)
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

$validRoot = Join-Path $tempRoot "valid"
$validReleaseId = "20990101-010101"
$validReleaseDir = Join-Path $validRoot $validReleaseId
New-Item -ItemType Directory -Force -Path $validReleaseDir | Out-Null
Set-Content -Path (Join-Path $validRoot "active-release.txt") -Encoding UTF8 -Value $validReleaseId
$validHistory = @(
    [pscustomobject]@{
        releaseId = $validReleaseId
        releaseDir = $validReleaseDir
        serviceName = "DataHz.Api"
        startedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        completedAtUtc = (Get-Date).ToUniversalTime().AddSeconds(3).ToString("o")
        previousActiveReleaseId = ""
        healthUrl = "http://127.0.0.1:5080/health"
        status = "published-only"
        source = "package"
        requireManifest = $true
        packageZip = "C:\fake\datahz2-api-win-x64.zip"
        packageSha256File = "C:\fake\datahz2-api-win-x64.sha256"
        packageManifestFile = "C:\fake\datahz2-api-win-x64.manifest.json"
        packageIndexFile = "C:\fake\datahz2-release-datahz2-v1.index.json"
        packageIndexSha256File = "C:\fake\datahz2-release-datahz2-v1.sha256"
    }
)
$validHistory | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $validRoot "deploy-history.json") -Encoding UTF8

$invalidRoot = Join-Path $tempRoot "invalid"
$invalidReleaseId = "20990101-000000"
$invalidReleaseDir = Join-Path $invalidRoot $invalidReleaseId
New-Item -ItemType Directory -Force -Path $invalidReleaseDir | Out-Null
Set-Content -Path (Join-Path $invalidRoot "active-release.txt") -Encoding UTF8 -Value $invalidReleaseId
$invalidHistory = @(
    [pscustomobject]@{
        releaseId = $invalidReleaseId
        releaseDir = $invalidReleaseDir
        serviceName = "DataHz.Api"
        startedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        completedAtUtc = ""
        status = "failed"
        source = "package"
        requireManifest = $true
        healthUrl = "http://127.0.0.1:5080/health"
        packageZip = ""
        packageIndexSha256Url = "https://example.com/datahz2-release-v1.sha256"
    }
)
$invalidHistory | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $invalidRoot "deploy-history.json") -Encoding UTF8

$timeInvalidRoot = Join-Path $tempRoot "time-invalid"
$timeInvalidReleaseId = "20990101-020202"
$timeInvalidReleaseDir = Join-Path $timeInvalidRoot $timeInvalidReleaseId
New-Item -ItemType Directory -Force -Path $timeInvalidReleaseDir | Out-Null
Set-Content -Path (Join-Path $timeInvalidRoot "active-release.txt") -Encoding UTF8 -Value $timeInvalidReleaseId
$timeInvalidHistory = @(
    [pscustomobject]@{
        releaseId = $timeInvalidReleaseId
        releaseDir = $timeInvalidReleaseDir
        serviceName = "DataHz.Api"
        startedAtUtc = "not-a-time"
        completedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        status = "published-only"
        source = "package"
        requireManifest = $true
        healthUrl = "http://127.0.0.1:5080/health"
        packageZip = "C:\fake\datahz2-api-win-x64.zip"
        packageManifestFile = "C:\fake\datahz2-api-win-x64.manifest.json"
        packageIndexFile = "C:\fake\datahz2-release-datahz2-v1.index.json"
        packageIndexSha256File = "C:\fake\datahz2-release-datahz2-v1.sha256"
    },
    [pscustomobject]@{
        releaseId = "20990101-020203"
        releaseDir = (Join-Path $timeInvalidRoot "20990101-020203")
        serviceName = "DataHz.Api"
        startedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        completedAtUtc = (Get-Date).ToUniversalTime().AddMinutes(-5).ToString("o")
        status = "published-only"
        source = "package"
        requireManifest = $true
        healthUrl = "http://127.0.0.1:5080/health"
        packageZip = "C:\fake\datahz2-api-win-x64.zip"
        packageManifestFile = "C:\fake\datahz2-api-win-x64.manifest.json"
        packageIndexFile = "C:\fake\datahz2-release-datahz2-v1.index.json"
        packageIndexSha256File = "C:\fake\datahz2-release-datahz2-v1.sha256"
    }
)
$timeInvalidHistory | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $timeInvalidRoot "deploy-history.json") -Encoding UTF8

$results = New-Object System.Collections.Generic.List[object]

try {
    $results.Add((Run-Case `
        -Name "history-audit-fail-on-issues-success" `
        -ExpectFailure $false `
        -ExpectedMessagePart "" `
        -Action {
            & powershell -ExecutionPolicy Bypass -File $auditHistoryScript -ReleaseRoot $validRoot -Take 20 -FailOnIssues
            if ($LASTEXITCODE -ne 0) {
                throw "audit-deploy-history.ps1 exited with code $LASTEXITCODE"
            }
        }))

    $results.Add((Run-Case `
        -Name "history-audit-fail-on-issues-detects-invalid" `
        -ExpectFailure $true `
        -ExpectedMessagePart "audit-deploy-history.ps1 exited with code 1" `
        -Action {
            & powershell -ExecutionPolicy Bypass -File $auditHistoryScript -ReleaseRoot $invalidRoot -Take 20 -FailOnIssues
            if ($LASTEXITCODE -ne 0) {
                throw "audit-deploy-history.ps1 exited with code $LASTEXITCODE"
            }
        }))

    $results.Add((Run-Case `
        -Name "deployment-status-audit-valid-root" `
        -ExpectFailure $false `
        -ExpectedMessagePart "" `
        -Action {
            $jsonText = & powershell -ExecutionPolicy Bypass -File $deploymentStatusScript -ReleaseRoot $validRoot -HistoryTake 20 -AsJson
            if ($LASTEXITCODE -ne 0) {
                throw "deployment-status.ps1 exited with code $LASTEXITCODE"
            }

            $payload = ($jsonText | Out-String).Trim()
            if ([string]::IsNullOrWhiteSpace($payload)) {
                throw "deployment-status.ps1 produced empty JSON output."
            }

            $obj = $payload | ConvertFrom-Json
            if ($null -eq $obj.audit) {
                throw "deployment-status JSON missing audit object."
            }
            if ($obj.audit.hasIssues) {
                throw "deployment-status JSON audit.hasIssues expected false for valid root."
            }
            if ($obj.audit.issueEntries -ne 0) {
                throw "deployment-status JSON audit.issueEntries expected 0 for valid root."
            }
            if ($null -eq $obj.recentHistoryAudit -or @($obj.recentHistoryAudit).Count -lt 1) {
                throw "deployment-status JSON recentHistoryAudit is empty for valid root."
            }
        }))

    $results.Add((Run-Case `
        -Name "deployment-status-audit-detects-invalid" `
        -ExpectFailure $false `
        -ExpectedMessagePart "" `
        -Action {
            $jsonText = & powershell -ExecutionPolicy Bypass -File $deploymentStatusScript -ReleaseRoot $invalidRoot -HistoryTake 20 -AsJson
            if ($LASTEXITCODE -ne 0) {
                throw "deployment-status.ps1 exited with code $LASTEXITCODE"
            }

            $payload = ($jsonText | Out-String).Trim()
            if ([string]::IsNullOrWhiteSpace($payload)) {
                throw "deployment-status.ps1 produced empty JSON output."
            }

            $obj = $payload | ConvertFrom-Json
            if ($null -eq $obj.audit) {
                throw "deployment-status JSON missing audit object."
            }
            if (-not $obj.audit.hasIssues) {
                throw "deployment-status JSON audit.hasIssues expected true for invalid root."
            }
            if ([int]$obj.audit.issueEntries -lt 1) {
                throw "deployment-status JSON audit.issueEntries expected >=1 for invalid root."
            }
        }))

    $results.Add((Run-Case `
        -Name "history-audit-json-flags-time-rules" `
        -ExpectFailure $false `
        -ExpectedMessagePart "" `
        -Action {
            $jsonText = & powershell -ExecutionPolicy Bypass -File $auditHistoryScript -ReleaseRoot $timeInvalidRoot -Take 20 -AsJson
            if ($LASTEXITCODE -ne 0) {
                throw "audit-deploy-history.ps1 exited with code $LASTEXITCODE"
            }

            $payload = ($jsonText | Out-String).Trim()
            if ([string]::IsNullOrWhiteSpace($payload)) {
                throw "audit-deploy-history.ps1 produced empty JSON output."
            }

            $obj = $payload | ConvertFrom-Json
            if ($null -eq $obj -or $null -eq $obj.items) {
                throw "audit-deploy-history JSON missing items."
            }
            if ([int]$obj.issueEntries -lt 2) {
                throw "audit-deploy-history JSON issueEntries expected >=2 for time-invalid root."
            }

            $rows = @($obj.items)
            $hasInvalidFormatIssue = $false
            $hasOrderIssue = $false
            foreach ($row in $rows) {
                $issuesText = [string]$row.Issues
                if ($issuesText -like "*invalid startedAtUtc format*") {
                    $hasInvalidFormatIssue = $true
                }
                if ($issuesText -like "*completedAtUtc earlier than startedAtUtc*") {
                    $hasOrderIssue = $true
                }
            }

            if (-not $hasInvalidFormatIssue) {
                throw "Expected 'invalid startedAtUtc format' issue not found."
            }
            if (-not $hasOrderIssue) {
                throw "Expected 'completedAtUtc earlier than startedAtUtc' issue not found."
            }
        }))

    $results.Add((Run-Case `
        -Name "deployment-status-audit-flags-time-rules" `
        -ExpectFailure $false `
        -ExpectedMessagePart "" `
        -Action {
            $jsonText = & powershell -ExecutionPolicy Bypass -File $deploymentStatusScript -ReleaseRoot $timeInvalidRoot -HistoryTake 20 -AsJson
            if ($LASTEXITCODE -ne 0) {
                throw "deployment-status.ps1 exited with code $LASTEXITCODE"
            }

            $payload = ($jsonText | Out-String).Trim()
            if ([string]::IsNullOrWhiteSpace($payload)) {
                throw "deployment-status.ps1 produced empty JSON output."
            }

            $obj = $payload | ConvertFrom-Json
            if ($null -eq $obj.audit) {
                throw "deployment-status JSON missing audit object."
            }
            if (-not $obj.audit.hasIssues) {
                throw "deployment-status JSON audit.hasIssues expected true for time-invalid root."
            }
            if ([int]$obj.audit.issueEntries -lt 2) {
                throw "deployment-status JSON audit.issueEntries expected >=2 for time-invalid root."
            }
        }))
}
finally {
    if (-not $KeepArtifacts) {
        Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
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
    Write-Host "History/deployment-status audit self-test failed: $($failed.Count) case(s)." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "History/deployment-status audit self-test passed." -ForegroundColor Green
exit 0
