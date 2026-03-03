[CmdletBinding()]
param(
    [string]$RepoRoot = ""
)

$ErrorActionPreference = "Stop"

function Run-Case(
    [string]$Name,
    [scriptblock]$Action
) {
    try {
        & $Action
        return [pscustomobject]@{
            Case = $Name
            Passed = $true
            Detail = "Succeeded."
        }
    }
    catch {
        return [pscustomobject]@{
            Case = $Name
            Passed = $false
            Detail = $_.Exception.Message
        }
    }
}

function Assert-Contains([string]$Path, [string]$Needle, [string]$Label) {
    if (-not (Select-String -Path $Path -Pattern $Needle -SimpleMatch -Quiet)) {
        throw "$Label not found in $(Split-Path -Leaf $Path): $Needle"
    }
}

function Get-FirstLineNumber([string]$Path, [string]$Needle) {
    $match = Select-String -Path $Path -Pattern $Needle -SimpleMatch | Select-Object -First 1
    if ($null -eq $match) {
        return 0
    }

    return [int]$match.LineNumber
}

function Assert-OrderedNeedles([string]$Path, [string]$WorkflowLabel, [string[]]$Needles) {
    if ($null -eq $Needles -or $Needles.Count -lt 2) {
        throw "Assert-OrderedNeedles requires at least 2 needles."
    }

    $previousLine = 0
    $previousNeedle = ""
    foreach ($needle in $Needles) {
        $line = Get-FirstLineNumber -Path $Path -Needle $needle
        if ($line -eq 0) {
            throw "$WorkflowLabel missing required step marker: $needle"
        }
        if ($line -le $previousLine) {
            throw "$WorkflowLabel step order violated: '$needle' (line $line) must be after '$previousNeedle' (line $previousLine)"
        }

        $previousLine = $line
        $previousNeedle = $needle
    }
}

function Get-StepBlock([string]$Path, [string]$StepName) {
    $lines = @(Get-Content -Path $Path)
    if ($lines.Count -eq 0) {
        throw "Workflow file is empty: $Path"
    }

    $stepPattern = "- name: $StepName"
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Contains($stepPattern)) {
            $start = $i
            break
        }
    }

    if ($start -lt 0) {
        throw "Step not found in $(Split-Path -Leaf $Path): $StepName"
    }

    $end = $lines.Count
    for ($j = $start + 1; $j -lt $lines.Count; $j++) {
        if ($lines[$j] -match "^\s*-\s+name:\s+") {
            $end = $j
            break
        }
    }

    return (($lines[$start..($end - 1)]) -join [Environment]::NewLine)
}

function Get-FallbackZipBaseNameFromStep([string]$StepBlock) {
    $zipMatch = [regex]::Match($StepBlock, '-PackageZip\s+"(?<zip>[^"]+\.zip)"')
    if (-not $zipMatch.Success) {
        throw "Fallback step missing -PackageZip '<...>.zip' argument."
    }

    $zipPath = $zipMatch.Groups["zip"].Value
    return [System.IO.Path]::GetFileNameWithoutExtension($zipPath)
}

function Get-CleanupBaseNameFromStep([string]$StepBlock) {
    $baseMatch = [regex]::Match($StepBlock, '\$base\s*=\s*"(?<base>[^"]+)"')
    if (-not $baseMatch.Success) {
        throw "Cleanup step missing `$base assignment."
    }

    $basePath = $baseMatch.Groups["base"].Value
    return [System.IO.Path]::GetFileName($basePath)
}

function Assert-StepWinX64Gate([string]$StepBlock, [string]$StepName, [string]$WorkflowLabel) {
    $ifMatch = [regex]::Match($StepBlock, "if:\s*matrix\.runtime\s*==\s*'win-x64'")
    if (-not $ifMatch.Success) {
        throw "$WorkflowLabel step '$StepName' must gate with: if: matrix.runtime == 'win-x64'"
    }
}

$projectRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent $projectRoot
}

$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
$ciWorkflow = Join-Path $RepoRoot ".github\workflows\datahz2-ci.yml"
$releaseWorkflow = Join-Path $RepoRoot ".github\workflows\datahz2-release.yml"
$deployGuardsScript = Join-Path $projectRoot "scripts\check-deploy-guards.ps1"

$results = New-Object System.Collections.Generic.List[object]

$results.Add((Run-Case -Name "workflow-files-exist" -Action {
    if (-not (Test-Path $ciWorkflow)) {
        throw "CI workflow not found: $ciWorkflow"
    }
    if (-not (Test-Path $releaseWorkflow)) {
        throw "Release workflow not found: $releaseWorkflow"
    }
    if (-not (Test-Path $deployGuardsScript)) {
        throw "check-deploy-guards script not found: $deployGuardsScript"
    }
}))

$results.Add((Run-Case -Name "ci-trigger-contracts" -Action {
    Assert-Contains -Path $ciWorkflow -Needle "on:" -Label "workflow trigger root"
    Assert-Contains -Path $ciWorkflow -Needle "push:" -Label "push trigger"
    Assert-Contains -Path $ciWorkflow -Needle "pull_request:" -Label "pull_request trigger"
    Assert-Contains -Path $ciWorkflow -Needle "workflow_dispatch:" -Label "workflow_dispatch trigger"
    Assert-Contains -Path $ciWorkflow -Needle '"DataHz2/**"' -Label "path filter"
    Assert-Contains -Path $ciWorkflow -Needle '".github/workflows/datahz2-ci.yml"' -Label "workflow path filter"
    Assert-Contains -Path $ciWorkflow -Needle '".github/workflows/datahz2-release.yml"' -Label "release workflow path filter"
}))

$results.Add((Run-Case -Name "release-trigger-contracts" -Action {
    Assert-Contains -Path $releaseWorkflow -Needle "on:" -Label "workflow trigger root"
    Assert-Contains -Path $releaseWorkflow -Needle "push:" -Label "push trigger"
    Assert-Contains -Path $releaseWorkflow -Needle "tags:" -Label "tag trigger"
    Assert-Contains -Path $releaseWorkflow -Needle '"datahz2-v*"' -Label "release tag pattern"
}))

$results.Add((Run-Case -Name "ci-concurrency-contracts" -Action {
    Assert-Contains -Path $ciWorkflow -Needle "concurrency:" -Label "concurrency block"
    Assert-Contains -Path $ciWorkflow -Needle 'group: datahz2-ci-${{ github.workflow }}-${{ github.ref }}' -Label "concurrency group"
    Assert-Contains -Path $ciWorkflow -Needle "cancel-in-progress: true" -Label "cancel-in-progress"
}))

$results.Add((Run-Case -Name "release-concurrency-contracts" -Action {
    Assert-Contains -Path $releaseWorkflow -Needle "concurrency:" -Label "concurrency block"
    Assert-Contains -Path $releaseWorkflow -Needle 'group: datahz2-release-${{ github.ref }}' -Label "concurrency group"
    Assert-Contains -Path $releaseWorkflow -Needle "cancel-in-progress: true" -Label "cancel-in-progress"
}))

$results.Add((Run-Case -Name "ci-runtime-matrix-contracts" -Action {
    Assert-Contains -Path $ciWorkflow -Needle 'runtime: ["win-x64", "win-arm64"]' -Label "runtime matrix"
}))

$results.Add((Run-Case -Name "release-runtime-matrix-contracts" -Action {
    Assert-Contains -Path $releaseWorkflow -Needle 'runtime: ["win-x64", "win-arm64"]' -Label "runtime matrix"
}))

$results.Add((Run-Case -Name "ci-build-test-contracts" -Action {
    Assert-Contains -Path $ciWorkflow -Needle "Validate PowerShell scripts" -Label "build-test step"
    Assert-Contains -Path $ciWorkflow -Needle ".\DataHz2\scripts\validate-scripts.ps1" -Label "validate run command"
    Assert-Contains -Path $ciWorkflow -Needle "Check history/deployment-status audits" -Label "build-test step"
    Assert-Contains -Path $ciWorkflow -Needle ".\DataHz2\scripts\check-history-audits.ps1" -Label "history-audit run command"
    Assert-Contains -Path $ciWorkflow -Needle "Check CI workflow contracts" -Label "build-test step"
    Assert-Contains -Path $ciWorkflow -Needle ".\DataHz2\scripts\check-ci-contracts.ps1" -Label "ci-contract run command"
    Assert-Contains -Path $ciWorkflow -Needle "Check documentation sync" -Label "build-test step"
    Assert-Contains -Path $ciWorkflow -Needle ".\DataHz2\scripts\check-docs-sync.ps1" -Label "docs-sync run command"
}))

$results.Add((Run-Case -Name "release-build-test-contracts" -Action {
    Assert-Contains -Path $releaseWorkflow -Needle "Validate PowerShell scripts" -Label "build-test step"
    Assert-Contains -Path $releaseWorkflow -Needle ".\DataHz2\scripts\validate-scripts.ps1" -Label "validate run command"
    Assert-Contains -Path $releaseWorkflow -Needle "Check history/deployment-status audits" -Label "build-test step"
    Assert-Contains -Path $releaseWorkflow -Needle ".\DataHz2\scripts\check-history-audits.ps1" -Label "history-audit run command"
    Assert-Contains -Path $releaseWorkflow -Needle "Check CI workflow contracts" -Label "build-test step"
    Assert-Contains -Path $releaseWorkflow -Needle ".\DataHz2\scripts\check-ci-contracts.ps1" -Label "ci-contract run command"
    Assert-Contains -Path $releaseWorkflow -Needle "Check documentation sync" -Label "build-test step"
    Assert-Contains -Path $releaseWorkflow -Needle ".\DataHz2\scripts\check-docs-sync.ps1" -Label "docs-sync run command"
}))

$results.Add((Run-Case -Name "ci-build-test-order-contract" -Action {
    Assert-OrderedNeedles -Path $ciWorkflow -WorkflowLabel "CI workflow" -Needles @(
        "- name: Validate PowerShell scripts",
        "- name: Check history/deployment-status audits",
        "- name: Check CI workflow contracts",
        "- name: Check documentation sync",
        "- name: Restore",
        "- name: Build",
        "- name: Test"
    )
}))

$results.Add((Run-Case -Name "release-build-test-order-contract" -Action {
    Assert-OrderedNeedles -Path $releaseWorkflow -WorkflowLabel "Release workflow" -Needles @(
        "- name: Validate PowerShell scripts",
        "- name: Check history/deployment-status audits",
        "- name: Check CI workflow contracts",
        "- name: Check documentation sync",
        "- name: Restore",
        "- name: Build",
        "- name: Test"
    )
}))

$results.Add((Run-Case -Name "ci-fallback-smoke-contracts" -Action {
    Assert-Contains -Path $ciWorkflow -Needle "Check deploy guards auto-package fallback" -Label "fallback step"
    Assert-Contains -Path $ciWorkflow -Needle "datahz2-api-win-x64-fallback.zip" -Label "fallback package name"
    Assert-Contains -Path $ciWorkflow -Needle "-IncludeOnlineSmokeCase" -Label "fallback smoke flag"
    Assert-Contains -Path $ciWorkflow -Needle "-OnlineSmokeStartupSeconds 6" -Label "fallback startup seconds"
}))

$results.Add((Run-Case -Name "release-fallback-smoke-contracts" -Action {
    Assert-Contains -Path $releaseWorkflow -Needle "Check deploy guards auto-package fallback" -Label "fallback step"
    Assert-Contains -Path $releaseWorkflow -Needle "datahz2-api-win-x64-release-fallback.zip" -Label "fallback package name"
    Assert-Contains -Path $releaseWorkflow -Needle "-IncludeOnlineSmokeCase" -Label "fallback smoke flag"
    Assert-Contains -Path $releaseWorkflow -Needle "-OnlineSmokeStartupSeconds 6" -Label "fallback startup seconds"
}))

$results.Add((Run-Case -Name "ci-fallback-cleanup-assert-contract" -Action {
    Assert-Contains -Path $ciWorkflow -Needle "Assert fallback package cleanup" -Label "cleanup assert step"
    Assert-Contains -Path $ciWorkflow -Needle "Fallback package cleanup failed." -Label "cleanup assert failure message"
    Assert-Contains -Path $ciWorkflow -Needle "datahz2-api-win-x64-fallback" -Label "cleanup assert package base"
}))

$results.Add((Run-Case -Name "release-fallback-cleanup-assert-contract" -Action {
    Assert-Contains -Path $releaseWorkflow -Needle "Assert fallback package cleanup" -Label "cleanup assert step"
    Assert-Contains -Path $releaseWorkflow -Needle "Fallback package cleanup failed." -Label "cleanup assert failure message"
    Assert-Contains -Path $releaseWorkflow -Needle "datahz2-api-win-x64-release-fallback" -Label "cleanup assert package base"
}))

$results.Add((Run-Case -Name "ci-fallback-order" -Action {
    $fallbackLine = Get-FirstLineNumber -Path $ciWorkflow -Needle "Check deploy guards auto-package fallback"
    $cleanupLine = Get-FirstLineNumber -Path $ciWorkflow -Needle "Assert fallback package cleanup"
    if ($fallbackLine -eq 0 -or $cleanupLine -eq 0) {
        throw "Fallback or cleanup step not found."
    }
    if ($cleanupLine -le $fallbackLine) {
        throw "Cleanup assert step must be after fallback step. fallbackLine=$fallbackLine cleanupLine=$cleanupLine"
    }
}))

$results.Add((Run-Case -Name "release-fallback-order" -Action {
    $fallbackLine = Get-FirstLineNumber -Path $releaseWorkflow -Needle "Check deploy guards auto-package fallback"
    $cleanupLine = Get-FirstLineNumber -Path $releaseWorkflow -Needle "Assert fallback package cleanup"
    if ($fallbackLine -eq 0 -or $cleanupLine -eq 0) {
        throw "Fallback or cleanup step not found."
    }
    if ($cleanupLine -le $fallbackLine) {
        throw "Cleanup assert step must be after fallback step. fallbackLine=$fallbackLine cleanupLine=$cleanupLine"
    }
}))

$results.Add((Run-Case -Name "ci-fallback-pipeline-order-contract" -Action {
    Assert-OrderedNeedles -Path $ciWorkflow -WorkflowLabel "CI workflow" -Needles @(
        "- name: Check deploy guards auto-package fallback",
        "- name: Assert fallback package cleanup",
        "- name: Smoke test"
    )
}))

$results.Add((Run-Case -Name "release-fallback-pipeline-order-contract" -Action {
    Assert-OrderedNeedles -Path $releaseWorkflow -WorkflowLabel "Release workflow" -Needles @(
        "- name: Check deploy guards auto-package fallback",
        "- name: Assert fallback package cleanup",
        "- name: Smoke test"
    )
}))

$results.Add((Run-Case -Name "ci-fallback-step-args-contract" -Action {
    $fallbackBlock = Get-StepBlock -Path $ciWorkflow -StepName "Check deploy guards auto-package fallback"
    Assert-StepWinX64Gate -StepBlock $fallbackBlock -StepName "Check deploy guards auto-package fallback" -WorkflowLabel "CI workflow"
    if ($fallbackBlock -match "-OnlineSmokePublishDir") {
        throw "Fallback step must not set -OnlineSmokePublishDir (should auto-select publish directory)."
    }

    $cleanupBlock = Get-StepBlock -Path $ciWorkflow -StepName "Assert fallback package cleanup"
    Assert-StepWinX64Gate -StepBlock $cleanupBlock -StepName "Assert fallback package cleanup" -WorkflowLabel "CI workflow"
    $fallbackBase = Get-FallbackZipBaseNameFromStep -StepBlock $fallbackBlock
    $cleanupBase = Get-CleanupBaseNameFromStep -StepBlock $cleanupBlock
    if ($fallbackBase -ne $cleanupBase) {
        throw "Fallback package base mismatch in CI workflow. fallback='$fallbackBase' cleanup='$cleanupBase'"
    }
}))

$results.Add((Run-Case -Name "release-fallback-step-args-contract" -Action {
    $fallbackBlock = Get-StepBlock -Path $releaseWorkflow -StepName "Check deploy guards auto-package fallback"
    Assert-StepWinX64Gate -StepBlock $fallbackBlock -StepName "Check deploy guards auto-package fallback" -WorkflowLabel "Release workflow"
    if ($fallbackBlock -match "-OnlineSmokePublishDir") {
        throw "Fallback step must not set -OnlineSmokePublishDir (should auto-select publish directory)."
    }

    $cleanupBlock = Get-StepBlock -Path $releaseWorkflow -StepName "Assert fallback package cleanup"
    Assert-StepWinX64Gate -StepBlock $cleanupBlock -StepName "Assert fallback package cleanup" -WorkflowLabel "Release workflow"
    $fallbackBase = Get-FallbackZipBaseNameFromStep -StepBlock $fallbackBlock
    $cleanupBase = Get-CleanupBaseNameFromStep -StepBlock $cleanupBlock
    if ($fallbackBase -ne $cleanupBase) {
        throw "Fallback package base mismatch in release workflow. fallback='$fallbackBase' cleanup='$cleanupBase'"
    }
}))

$results.Add((Run-Case -Name "ci-smoke-step-gate-contract" -Action {
    $smokeBlock = Get-StepBlock -Path $ciWorkflow -StepName "Smoke test"
    Assert-StepWinX64Gate -StepBlock $smokeBlock -StepName "Smoke test" -WorkflowLabel "CI workflow"
    if (-not ($smokeBlock -like "*-TimeoutSeconds 120*")) {
        throw "CI workflow Smoke test step must use -TimeoutSeconds 120."
    }
    if (-not ($smokeBlock -like "*-CheckRetryCount 5*")) {
        throw "CI workflow Smoke test step must use -CheckRetryCount 5."
    }
    if (-not ($smokeBlock -like "*-CheckRetryDelayMilliseconds 800*")) {
        throw "CI workflow Smoke test step must use -CheckRetryDelayMilliseconds 800."
    }
    if (-not ($smokeBlock -like "*-HealthPollDelayMilliseconds 500*")) {
        throw "CI workflow Smoke test step must use -HealthPollDelayMilliseconds 500."
    }
    if (-not ($smokeBlock -like "*-WarnCheckDurationMilliseconds 3000*")) {
        throw "CI workflow Smoke test step must use -WarnCheckDurationMilliseconds 3000."
    }
    if (-not ($smokeBlock -like "*-FailCheckDurationMilliseconds 0*")) {
        throw "CI workflow Smoke test step must use -FailCheckDurationMilliseconds 0."
    }
    if (-not ($smokeBlock -like "*-OutputJsonPath `$reportLog*")) {
        throw "CI workflow Smoke test step must pass -OutputJsonPath `$reportLog."
    }
    if (-not ($smokeBlock -like "*Start-Sleep -Seconds 6*")) {
        throw "CI workflow Smoke test step must wait at least 6 seconds before probing."
    }
    if (-not ($smokeBlock -like "*Start-Process*")) {
        throw "CI workflow Smoke test step must start API process inline."
    }
    if (-not ($smokeBlock -like "*-RedirectStandardOutput `$outLog*")) {
        throw "CI workflow Smoke test step must redirect stdout to `$outLog."
    }
    if (-not ($smokeBlock -like "*-RedirectStandardError `$errLog*")) {
        throw "CI workflow Smoke test step must redirect stderr to `$errLog."
    }
    if (-not ($smokeBlock -like "*Get-Content `$outLog*")) {
        throw "CI workflow Smoke test step must dump stdout on failure."
    }
    if (-not ($smokeBlock -like "*Get-Content `$errLog*")) {
        throw "CI workflow Smoke test step must dump stderr on failure."
    }
    if (-not ($smokeBlock -like "*Get-Content `$reportLog*")) {
        throw "CI workflow Smoke test step must dump structured report on failure."
    }
}))

$results.Add((Run-Case -Name "release-smoke-step-gate-contract" -Action {
    $smokeBlock = Get-StepBlock -Path $releaseWorkflow -StepName "Smoke test"
    Assert-StepWinX64Gate -StepBlock $smokeBlock -StepName "Smoke test" -WorkflowLabel "Release workflow"
    if (-not ($smokeBlock -like "*-TimeoutSeconds 120*")) {
        throw "Release workflow Smoke test step must use -TimeoutSeconds 120."
    }
    if (-not ($smokeBlock -like "*-CheckRetryCount 5*")) {
        throw "Release workflow Smoke test step must use -CheckRetryCount 5."
    }
    if (-not ($smokeBlock -like "*-CheckRetryDelayMilliseconds 800*")) {
        throw "Release workflow Smoke test step must use -CheckRetryDelayMilliseconds 800."
    }
    if (-not ($smokeBlock -like "*-HealthPollDelayMilliseconds 500*")) {
        throw "Release workflow Smoke test step must use -HealthPollDelayMilliseconds 500."
    }
    if (-not ($smokeBlock -like "*-WarnCheckDurationMilliseconds 3000*")) {
        throw "Release workflow Smoke test step must use -WarnCheckDurationMilliseconds 3000."
    }
    if (-not ($smokeBlock -like "*-FailCheckDurationMilliseconds 0*")) {
        throw "Release workflow Smoke test step must use -FailCheckDurationMilliseconds 0."
    }
    if (-not ($smokeBlock -like "*-OutputJsonPath `$reportLog*")) {
        throw "Release workflow Smoke test step must pass -OutputJsonPath `$reportLog."
    }
    if (-not ($smokeBlock -like "*Start-Sleep -Seconds 6*")) {
        throw "Release workflow Smoke test step must wait at least 6 seconds before probing."
    }
    if (-not ($smokeBlock -like "*Start-Process*")) {
        throw "Release workflow Smoke test step must start API process inline."
    }
    if (-not ($smokeBlock -like "*-RedirectStandardOutput `$outLog*")) {
        throw "Release workflow Smoke test step must redirect stdout to `$outLog."
    }
    if (-not ($smokeBlock -like "*-RedirectStandardError `$errLog*")) {
        throw "Release workflow Smoke test step must redirect stderr to `$errLog."
    }
    if (-not ($smokeBlock -like "*Get-Content `$outLog*")) {
        throw "Release workflow Smoke test step must dump stdout on failure."
    }
    if (-not ($smokeBlock -like "*Get-Content `$errLog*")) {
        throw "Release workflow Smoke test step must dump stderr on failure."
    }
    if (-not ($smokeBlock -like "*Get-Content `$reportLog*")) {
        throw "Release workflow Smoke test step must dump structured report on failure."
    }
}))

$results.Add((Run-Case -Name "ci-smoke-diagnostics-artifact-contract" -Action {
    $diagBlock = Get-StepBlock -Path $ciWorkflow -StepName "Upload smoke diagnostics"
    Assert-StepWinX64Gate -StepBlock $diagBlock -StepName "Upload smoke diagnostics" -WorkflowLabel "CI workflow"
    if (-not ($diagBlock -like "*always()*")) {
        throw "CI workflow 'Upload smoke diagnostics' step must include always()."
    }
    if (-not ($diagBlock -like "*uses: actions/upload-artifact@v4*")) {
        throw "CI workflow 'Upload smoke diagnostics' step must use actions/upload-artifact@v4."
    }
    if (-not ($diagBlock -like '*datahz2-${{ matrix.runtime }}-smoke-diagnostics*')) {
        throw "CI workflow 'Upload smoke diagnostics' step must use expected artifact name."
    }
    if (-not ($diagBlock -like "*datahz2-api-smoke.out.log*")) {
        throw "CI workflow 'Upload smoke diagnostics' step must include stdout log path."
    }
    if (-not ($diagBlock -like "*datahz2-api-smoke.err.log*")) {
        throw "CI workflow 'Upload smoke diagnostics' step must include stderr log path."
    }
    if (-not ($diagBlock -like "*datahz2-api-smoke.report.json*")) {
        throw "CI workflow 'Upload smoke diagnostics' step must include report path."
    }
    if (-not ($diagBlock -like "*if-no-files-found: warn*")) {
        throw "CI workflow 'Upload smoke diagnostics' step must use if-no-files-found: warn."
    }
}))

$results.Add((Run-Case -Name "release-smoke-diagnostics-artifact-contract" -Action {
    $diagBlock = Get-StepBlock -Path $releaseWorkflow -StepName "Upload smoke diagnostics"
    Assert-StepWinX64Gate -StepBlock $diagBlock -StepName "Upload smoke diagnostics" -WorkflowLabel "Release workflow"
    if (-not ($diagBlock -like "*always()*")) {
        throw "Release workflow 'Upload smoke diagnostics' step must include always()."
    }
    if (-not ($diagBlock -like "*uses: actions/upload-artifact@v4*")) {
        throw "Release workflow 'Upload smoke diagnostics' step must use actions/upload-artifact@v4."
    }
    if (-not ($diagBlock -like '*datahz2-release-${{ matrix.runtime }}-smoke-diagnostics-${{ github.ref_name }}*')) {
        throw "Release workflow 'Upload smoke diagnostics' step must use expected artifact name."
    }
    if (-not ($diagBlock -like "*datahz2-api-release-smoke.out.log*")) {
        throw "Release workflow 'Upload smoke diagnostics' step must include stdout log path."
    }
    if (-not ($diagBlock -like "*datahz2-api-release-smoke.err.log*")) {
        throw "Release workflow 'Upload smoke diagnostics' step must include stderr log path."
    }
    if (-not ($diagBlock -like "*datahz2-api-release-smoke.report.json*")) {
        throw "Release workflow 'Upload smoke diagnostics' step must include report path."
    }
    if (-not ($diagBlock -like "*if-no-files-found: warn*")) {
        throw "Release workflow 'Upload smoke diagnostics' step must use if-no-files-found: warn."
    }
}))

$results.Add((Run-Case -Name "ci-smoke-summary-contract" -Action {
    $summaryBlock = Get-StepBlock -Path $ciWorkflow -StepName "Publish smoke summary"
    Assert-StepWinX64Gate -StepBlock $summaryBlock -StepName "Publish smoke summary" -WorkflowLabel "CI workflow"
    if (-not ($summaryBlock -like "*always()*")) {
        throw "CI workflow 'Publish smoke summary' step must include always()."
    }
    if (-not ($summaryBlock -like "*datahz2-api-smoke.report.json*")) {
        throw "CI workflow 'Publish smoke summary' step must use smoke report json path."
    }
    if (-not ($summaryBlock -like "*ConvertFrom-Json*")) {
        throw "CI workflow 'Publish smoke summary' step must parse JSON report."
    }
    if (-not ($summaryBlock -like "*$env:GITHUB_STEP_SUMMARY*")) {
        throw "CI workflow 'Publish smoke summary' step must write into GITHUB_STEP_SUMMARY."
    }
    if (-not ($summaryBlock -like "*averageCheckDurationMs*")) {
        throw "CI workflow 'Publish smoke summary' step must include average check duration."
    }
    if (-not ($summaryBlock -like "*maxCheckDurationMs*")) {
        throw "CI workflow 'Publish smoke summary' step must include max check duration."
    }
    if (-not ($summaryBlock -like "*healthPollDelayMilliseconds*")) {
        throw "CI workflow 'Publish smoke summary' step must include health poll delay."
    }
    if (-not ($summaryBlock -like "*warnCheckDurationMilliseconds*")) {
        throw "CI workflow 'Publish smoke summary' step must include warn slow threshold."
    }
    if (-not ($summaryBlock -like "*warnSlowCheckCount*")) {
        throw "CI workflow 'Publish smoke summary' step must include warn slow count."
    }
    if (-not ($summaryBlock -like "*failCheckDurationMilliseconds*")) {
        throw "CI workflow 'Publish smoke summary' step must include fail slow threshold."
    }
    if (-not ($summaryBlock -like "*failSlowCheckCount*")) {
        throw "CI workflow 'Publish smoke summary' step must include fail slow count."
    }
    if (-not ($summaryBlock -like "*warnSlowChecks*")) {
        throw "CI workflow 'Publish smoke summary' step must include warn slow checks details."
    }
    if (-not ($summaryBlock -like "*Sort-Object DurationMs -Descending*")) {
        throw "CI workflow 'Publish smoke summary' step must include slow-check ranking."
    }
}))

$results.Add((Run-Case -Name "release-smoke-summary-contract" -Action {
    $summaryBlock = Get-StepBlock -Path $releaseWorkflow -StepName "Publish smoke summary"
    Assert-StepWinX64Gate -StepBlock $summaryBlock -StepName "Publish smoke summary" -WorkflowLabel "Release workflow"
    if (-not ($summaryBlock -like "*always()*")) {
        throw "Release workflow 'Publish smoke summary' step must include always()."
    }
    if (-not ($summaryBlock -like "*datahz2-api-release-smoke.report.json*")) {
        throw "Release workflow 'Publish smoke summary' step must use smoke report json path."
    }
    if (-not ($summaryBlock -like "*ConvertFrom-Json*")) {
        throw "Release workflow 'Publish smoke summary' step must parse JSON report."
    }
    if (-not ($summaryBlock -like "*$env:GITHUB_STEP_SUMMARY*")) {
        throw "Release workflow 'Publish smoke summary' step must write into GITHUB_STEP_SUMMARY."
    }
    if (-not ($summaryBlock -like "*averageCheckDurationMs*")) {
        throw "Release workflow 'Publish smoke summary' step must include average check duration."
    }
    if (-not ($summaryBlock -like "*maxCheckDurationMs*")) {
        throw "Release workflow 'Publish smoke summary' step must include max check duration."
    }
    if (-not ($summaryBlock -like "*healthPollDelayMilliseconds*")) {
        throw "Release workflow 'Publish smoke summary' step must include health poll delay."
    }
    if (-not ($summaryBlock -like "*warnCheckDurationMilliseconds*")) {
        throw "Release workflow 'Publish smoke summary' step must include warn slow threshold."
    }
    if (-not ($summaryBlock -like "*warnSlowCheckCount*")) {
        throw "Release workflow 'Publish smoke summary' step must include warn slow count."
    }
    if (-not ($summaryBlock -like "*failCheckDurationMilliseconds*")) {
        throw "Release workflow 'Publish smoke summary' step must include fail slow threshold."
    }
    if (-not ($summaryBlock -like "*failSlowCheckCount*")) {
        throw "Release workflow 'Publish smoke summary' step must include fail slow count."
    }
    if (-not ($summaryBlock -like "*warnSlowChecks*")) {
        throw "Release workflow 'Publish smoke summary' step must include warn slow checks details."
    }
    if (-not ($summaryBlock -like "*Sort-Object DurationMs -Descending*")) {
        throw "Release workflow 'Publish smoke summary' step must include slow-check ranking."
    }
}))

$results.Add((Run-Case -Name "ci-smoke-diagnostics-order-contract" -Action {
    Assert-OrderedNeedles -Path $ciWorkflow -WorkflowLabel "CI workflow" -Needles @(
        "- name: Smoke test",
        "- name: Publish smoke summary",
        "- name: Upload smoke diagnostics",
        "- name: Upload publish artifact"
    )
}))

$results.Add((Run-Case -Name "release-smoke-diagnostics-order-contract" -Action {
    Assert-OrderedNeedles -Path $releaseWorkflow -WorkflowLabel "Release workflow" -Needles @(
        "- name: Smoke test",
        "- name: Publish smoke summary",
        "- name: Upload smoke diagnostics",
        "- name: Upload build artifact"
    )
}))

$results.Add((Run-Case -Name "deploy-guards-fallback-source-contract" -Action {
    Assert-Contains -Path $deployGuardsScript -Needle '$script:AutoPackagePublishDir = $publishDir' -Label "auto package source assignment"
    Assert-Contains -Path $deployGuardsScript -Needle 'Resolve-PublishDirForAutoPackage -Root $root -PackageName $packageName' -Label "online smoke publish-dir resolver"
    Assert-Contains -Path $deployGuardsScript -Needle 'OnlineSmokePublishDir is empty and no valid publish directory was found under artifacts\\publish.' -Label "online smoke missing-dir guard"
}))

$results.Add((Run-Case -Name "deploy-guards-fallback-cleanup-contract" -Action {
    Assert-Contains -Path $deployGuardsScript -Needle '$autoGeneratedPackageFiles = @(Ensure-PackageZipAvailable' -Label "auto generated file list"
    Assert-Contains -Path $deployGuardsScript -Needle 'foreach ($generatedFile in $autoGeneratedPackageFiles)' -Label "cleanup loop"
    Assert-Contains -Path $deployGuardsScript -Needle 'Remove-Item -Path $generatedFile -Force -ErrorAction SilentlyContinue' -Label "cleanup delete"
}))

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
    Write-Host "CI workflow contract self-test failed: $($failed.Count) case(s)." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "CI workflow contract self-test passed." -ForegroundColor Green
exit 0
