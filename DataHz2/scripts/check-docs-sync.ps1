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

$changedCode = @($allChanged | Where-Object { MatchesAnyPattern -PathValue $_ -Patterns $codePatterns })
$changedDocs = @($allChanged | Where-Object { MatchesAnyPattern -PathValue $_ -Patterns $docPatterns })

Write-Host "Changed files detected: $($allChanged.Count)"
Write-Host "Code/script/workflow changes: $($changedCode.Count)"
Write-Host "Documentation changes: $($changedDocs.Count)"

if ($changedCode.Count -gt 0 -and $changedDocs.Count -eq 0) {
    Write-Host ""
    Write-Host "Documentation sync check failed." -ForegroundColor Red
    Write-Host "Code or workflow changes were detected without any markdown updates."
    Write-Host "Please update related docs (README/docs/SECURITY/CONTRIBUTING, etc.)."
    Write-Host ""
    Write-Host "Changed code/workflow files:"
    foreach ($path in $changedCode | Select-Object -First 30) {
        Write-Host "  - $path"
    }
    exit 1
}

Write-Host "Documentation sync check passed." -ForegroundColor Green
exit 0
