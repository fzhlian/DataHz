[CmdletBinding()]
param(
    [string]$RepoRoot = ""
)

$ErrorActionPreference = "Stop"

function Normalize-RepoPath([string]$PathValue) {
    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return ""
    }

    $normalized = $PathValue.Trim().Replace("\", "/")
    if ($normalized.StartsWith("./", [System.StringComparison]::Ordinal)) {
        $normalized = $normalized.Substring(2)
    }

    return $normalized.Trim('"')
}

function Invoke-GitOrEmpty([string]$WorkingDirectory, [string[]]$Arguments) {
    $output = & git -C $WorkingDirectory @Arguments 2>$null
    if ($LASTEXITCODE -ne 0) {
        return @()
    }

    if ($null -eq $output) {
        return @()
    }

    return @($output)
}

function MatchesAnyPattern([string]$PathValue, [string[]]$Patterns) {
    foreach ($pattern in $Patterns) {
        if ($PathValue -match $pattern) {
            return $true
        }
    }

    return $false
}

function Get-MatchedRequiredDocs([string[]]$ChangedPaths, [string[]]$RequiredPaths) {
    $matched = New-Object System.Collections.Generic.List[string]
    foreach ($required in $RequiredPaths) {
        if ($ChangedPaths -contains $required) {
            $matched.Add($required)
        }
    }

    return @($matched)
}

$projectRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent $projectRoot
}

$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
if (-not (Test-Path $RepoRoot)) {
    throw "Repository root not found: $RepoRoot"
}

$gitCheckRaw = & git -C $RepoRoot rev-parse --is-inside-work-tree 2>$null
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($gitCheckRaw) -or $gitCheckRaw.ToString().Trim().ToLowerInvariant() -ne "true") {
    throw "Current directory is not a Git repository: $RepoRoot"
}

$requiredDocs = @(
    "README.md",
    "AGENTS.md",
    "CONTRIBUTING.md",
    "SECURITY.md",
    "CHANGELOG.md",
    ".github/PULL_REQUEST_TEMPLATE.md",
    "DataHz2/README.md",
    "DataHz2/docs/README.md",
    "DataHz2/docs/ARCHITECTURE.md",
    "DataHz2/docs/API.md",
    "DataHz2/docs/CONFIGURATION.md",
    "DataHz2/docs/DEVELOPMENT.md",
    "DataHz2/docs/TESTING_AND_RELEASE.md",
    "DataHz2/docs/OPERATIONS.md",
    "DataHz2/docs/DOCUMENTATION_POLICY.md",
    "DataHz2/docs/FAQ.md",
    "DataHz2/docs/MIGRATION.md",
    "DataHz2/docs/SSO_HARDENING_RUNBOOK.md"
)

$missingDocs = New-Object System.Collections.Generic.List[string]
foreach ($doc in $requiredDocs) {
    $fullPath = Join-Path $RepoRoot $doc
    if (-not (Test-Path $fullPath)) {
        $missingDocs.Add($doc)
    }
}

if ($missingDocs.Count -gt 0) {
    Write-Host "Required documentation files are missing:" -ForegroundColor Red
    foreach ($doc in $missingDocs) {
        Write-Host "  - $doc"
    }
    exit 1
}

$changedFiles = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)

$baseRef = $env:GITHUB_BASE_REF
if (-not [string]::IsNullOrWhiteSpace($baseRef)) {
    $baseRef = $baseRef.Trim()
    & git -C $RepoRoot show-ref --verify --quiet "refs/remotes/origin/$baseRef" 2>$null
    if ($LASTEXITCODE -eq 0) {
        $fromBase = Invoke-GitOrEmpty -WorkingDirectory $RepoRoot -Arguments @("diff", "--name-only", "--diff-filter=ACMR", "origin/$baseRef...HEAD")
        foreach ($path in $fromBase) {
            $normalized = Normalize-RepoPath -PathValue $path
            if (-not [string]::IsNullOrWhiteSpace($normalized)) {
                [void]$changedFiles.Add($normalized)
            }
        }
    }
}

if ($changedFiles.Count -eq 0) {
    $headParent = Invoke-GitOrEmpty -WorkingDirectory $RepoRoot -Arguments @("rev-parse", "--verify", "--quiet", "HEAD~1")
    if ($headParent.Count -gt 0) {
        $fromHead = Invoke-GitOrEmpty -WorkingDirectory $RepoRoot -Arguments @("diff", "--name-only", "--diff-filter=ACMR", "HEAD~1..HEAD")
        foreach ($path in $fromHead) {
            $normalized = Normalize-RepoPath -PathValue $path
            if (-not [string]::IsNullOrWhiteSpace($normalized)) {
                [void]$changedFiles.Add($normalized)
            }
        }
    }
}

if ($changedFiles.Count -eq 0) {
    $fromHeadTree = Invoke-GitOrEmpty -WorkingDirectory $RepoRoot -Arguments @("diff-tree", "--no-commit-id", "--name-only", "-r", "--diff-filter=ACMR", "HEAD")
    foreach ($path in $fromHeadTree) {
        $normalized = Normalize-RepoPath -PathValue $path
        if (-not [string]::IsNullOrWhiteSpace($normalized)) {
            [void]$changedFiles.Add($normalized)
        }
    }
}

$workingTree = Invoke-GitOrEmpty -WorkingDirectory $RepoRoot -Arguments @("status", "--porcelain")
foreach ($line in $workingTree) {
    if ([string]::IsNullOrWhiteSpace($line) -or $line.Length -lt 4) {
        continue
    }

    $pathPart = $line.Substring(3).Trim()
    if ($pathPart.Contains(" -> ")) {
        $pathPart = $pathPart.Split(" -> ")[1].Trim()
    }

    $normalized = Normalize-RepoPath -PathValue $pathPart
    if (-not [string]::IsNullOrWhiteSpace($normalized)) {
        [void]$changedFiles.Add($normalized)
    }
}

$allChanged = @($changedFiles | Sort-Object)
if ($allChanged.Count -eq 0) {
    Write-Host "No changed files detected. Documentation sync check skipped."
    exit 0
}

$ignorePatterns = @(
    "(^|/)bin(/|$)",
    "(^|/)obj(/|$)"
)

$allChanged = @($allChanged | Where-Object {
    -not (MatchesAnyPattern -PathValue $_ -Patterns $ignorePatterns)
})

if ($allChanged.Count -eq 0) {
    Write-Host "Only ignored build outputs changed (bin/obj). Documentation sync check skipped."
    exit 0
}

$codePatterns = @(
    "^DataHz2/src/",
    "^DataHz2/tests/",
    "^DataHz2/scripts/",
    "^DataHz2/DataHz2\.sln$",
    "^\.github/workflows/datahz2-ci\.yml$",
    "^\.github/workflows/datahz2-release\.yml$"
)

$docPatterns = @(
    "^README\.md$",
    "^AGENTS\.md$",
    "^CONTRIBUTING\.md$",
    "^SECURITY\.md$",
    "^CHANGELOG\.md$",
    "^DataHz2/README\.md$",
    "^DataHz2/docs/.+\.md$",
    "^\.github/PULL_REQUEST_TEMPLATE\.md$"
)

$srcChangePatterns = @(
    "^DataHz2/src/"
)

$scriptsOrWorkflowChangePatterns = @(
    "^DataHz2/scripts/",
    "^\.github/workflows/"
)

$securityAuthChangePatterns = @(
    "^DataHz2/src/.+/Security/",
    "^DataHz2/src/.+/(Authentication|Authorization)/",
    "^DataHz2/src/.+/(Auth|Security|Jwt|ApiKey|Token|Sso|SSO)[^/]*\.(cs|json)$"
)

$requiredDocsForSrcChanges = @(
    "DataHz2/README.md",
    "DataHz2/docs/ARCHITECTURE.md",
    "DataHz2/docs/API.md",
    "DataHz2/docs/CONFIGURATION.md",
    "DataHz2/docs/OPERATIONS.md"
)

$requiredDocsForScriptsOrWorkflowChanges = @(
    "DataHz2/docs/TESTING_AND_RELEASE.md",
    "DataHz2/docs/DEVELOPMENT.md",
    "DataHz2/docs/DOCUMENTATION_POLICY.md"
)

$requiredDocsForSecurityAuthChanges = @(
    "SECURITY.md",
    "DataHz2/docs/SSO_HARDENING_RUNBOOK.md"
)

$changedCode = @($allChanged | Where-Object { MatchesAnyPattern -PathValue $_ -Patterns $codePatterns })
$changedDocs = @($allChanged | Where-Object { MatchesAnyPattern -PathValue $_ -Patterns $docPatterns })
$changedSrc = @($allChanged | Where-Object { MatchesAnyPattern -PathValue $_ -Patterns $srcChangePatterns })
$changedScriptsOrWorkflow = @($allChanged | Where-Object { MatchesAnyPattern -PathValue $_ -Patterns $scriptsOrWorkflowChangePatterns })
$changedSecurityAuth = @($allChanged | Where-Object { MatchesAnyPattern -PathValue $_ -Patterns $securityAuthChangePatterns })

$failures = New-Object System.Collections.Generic.List[string]

if ($changedCode.Count -gt 0 -and $changedDocs.Count -eq 0) {
    $failures.Add("Code/workflow changes were detected, but no markdown documentation was updated.")
}

if ($changedSrc.Count -gt 0) {
    $matchedForSrc = Get-MatchedRequiredDocs -ChangedPaths $changedDocs -RequiredPaths $requiredDocsForSrcChanges
    if ($matchedForSrc.Count -eq 0) {
        $failures.Add(
            "Changes under DataHz2/src/** require at least one of: $($requiredDocsForSrcChanges -join ', ')"
        )
    }
}

if ($changedScriptsOrWorkflow.Count -gt 0) {
    $matchedForScriptsOrWorkflow = Get-MatchedRequiredDocs -ChangedPaths $changedDocs -RequiredPaths $requiredDocsForScriptsOrWorkflowChanges
    if ($matchedForScriptsOrWorkflow.Count -eq 0) {
        $failures.Add(
            "Changes under DataHz2/scripts/** or .github/workflows/** require at least one of: $($requiredDocsForScriptsOrWorkflowChanges -join ', ')"
        )
    }
}

if ($changedSecurityAuth.Count -gt 0) {
    $missingSecurityDocs = @($requiredDocsForSecurityAuthChanges | Where-Object { -not ($changedDocs -contains $_) })
    if ($missingSecurityDocs.Count -gt 0) {
        $failures.Add(
            "Security/authentication logic changes require both docs to be updated: $($requiredDocsForSecurityAuthChanges -join ', ')"
        )
    }
}

Write-Host "Changed files detected: $($allChanged.Count)"
Write-Host "Code/script/workflow changes: $($changedCode.Count)"
Write-Host "Documentation changes: $($changedDocs.Count)"
Write-Host "Rule trigger count (src/**): $($changedSrc.Count)"
Write-Host "Rule trigger count (scripts/workflows): $($changedScriptsOrWorkflow.Count)"
Write-Host "Rule trigger count (security/auth): $($changedSecurityAuth.Count)"

if ($failures.Count -gt 0) {
    Write-Host ""
    Write-Host "Documentation sync check failed." -ForegroundColor Red
    foreach ($message in $failures) {
        Write-Host "  - $message"
    }
    Write-Host ""

    if ($changedSrc.Count -gt 0) {
        Write-Host "Changed DataHz2/src files:"
        foreach ($path in $changedSrc | Select-Object -First 20) {
            Write-Host "  - $path"
        }
    }

    if ($changedScriptsOrWorkflow.Count -gt 0) {
        Write-Host "Changed script/workflow files:"
        foreach ($path in $changedScriptsOrWorkflow | Select-Object -First 20) {
            Write-Host "  - $path"
        }
    }

    if ($changedSecurityAuth.Count -gt 0) {
        Write-Host "Changed security/auth files:"
        foreach ($path in $changedSecurityAuth | Select-Object -First 20) {
            Write-Host "  - $path"
        }
    }

    if ($changedDocs.Count -gt 0) {
        Write-Host "Changed documentation files:"
        foreach ($path in $changedDocs | Select-Object -First 20) {
            Write-Host "  - $path"
        }
    }

    exit 1
}

Write-Host "Documentation sync check passed." -ForegroundColor Green
exit 0
