function Get-DataHzObjectValue([object]$Obj, [string]$Name) {
    if ($null -eq $Obj) {
        return $null
    }

    $prop = $Obj.PSObject.Properties | Where-Object { $_.Name -ieq $Name } | Select-Object -First 1
    if ($prop) {
        return $prop.Value
    }

    return $null
}

function Test-DataHzHasValue([object]$Value) {
    return -not [string]::IsNullOrWhiteSpace([string]$Value)
}

function ConvertTo-DataHzDateOrMin([object]$Value) {
    if (-not (Test-DataHzHasValue $Value)) {
        return [DateTime]::MinValue
    }

    $parsed = [DateTime]::MinValue
    if ([DateTime]::TryParse([string]$Value, [ref]$parsed)) {
        return $parsed
    }

    return [DateTime]::MinValue
}

function Get-DataHzHistoryAuditRow([object]$Item) {
    $issues = New-Object System.Collections.Generic.List[string]

    $releaseId = [string](Get-DataHzObjectValue -Obj $Item -Name "releaseId")
    $status = [string](Get-DataHzObjectValue -Obj $Item -Name "status")
    $source = [string](Get-DataHzObjectValue -Obj $Item -Name "source")
    $requireManifest = [bool](Get-DataHzObjectValue -Obj $Item -Name "requireManifest")
    $startedAtUtc = [string](Get-DataHzObjectValue -Obj $Item -Name "startedAtUtc")
    $completedAtUtc = [string](Get-DataHzObjectValue -Obj $Item -Name "completedAtUtc")
    $rollbackTo = [string](Get-DataHzObjectValue -Obj $Item -Name "rollbackTo")

    $packageZip = [string](Get-DataHzObjectValue -Obj $Item -Name "packageZip")
    $packageManifestFile = [string](Get-DataHzObjectValue -Obj $Item -Name "packageManifestFile")
    $packageIndexFile = [string](Get-DataHzObjectValue -Obj $Item -Name "packageIndexFile")
    $packageIndexShaFile = [string](Get-DataHzObjectValue -Obj $Item -Name "packageIndexSha256File")
    $packageIndexUrl = [string](Get-DataHzObjectValue -Obj $Item -Name "packageIndexUrl")
    $packageIndexShaUrl = [string](Get-DataHzObjectValue -Obj $Item -Name "packageIndexSha256Url")

    if (-not (Test-DataHzHasValue $releaseId)) {
        $issues.Add("missing releaseId") | Out-Null
    }
    if (-not (Test-DataHzHasValue $status)) {
        $issues.Add("missing status") | Out-Null
    }
    if (-not (Test-DataHzHasValue $startedAtUtc)) {
        $issues.Add("missing startedAtUtc") | Out-Null
    }
    if (-not (Test-DataHzHasValue $completedAtUtc)) {
        $issues.Add("missing completedAtUtc") | Out-Null
    }

    $startedParsed = [DateTime]::MinValue
    $hasStartedParsed = [DateTime]::TryParse($startedAtUtc, [ref]$startedParsed)
    if ((Test-DataHzHasValue $startedAtUtc) -and (-not $hasStartedParsed)) {
        $issues.Add("invalid startedAtUtc format") | Out-Null
    }

    $completedParsed = [DateTime]::MinValue
    $hasCompletedParsed = [DateTime]::TryParse($completedAtUtc, [ref]$completedParsed)
    if ((Test-DataHzHasValue $completedAtUtc) -and (-not $hasCompletedParsed)) {
        $issues.Add("invalid completedAtUtc format") | Out-Null
    }

    if ($hasStartedParsed -and $hasCompletedParsed -and $completedParsed -lt $startedParsed) {
        $issues.Add("completedAtUtc earlier than startedAtUtc") | Out-Null
    }

    if ($status.Equals("failed", [StringComparison]::OrdinalIgnoreCase)) {
        if (-not (Test-DataHzHasValue (Get-DataHzObjectValue -Obj $Item -Name "error"))) {
            $issues.Add("failed status without error") | Out-Null
        }
    }

    if ($status.Equals("rolled-back", [StringComparison]::OrdinalIgnoreCase)) {
        if (-not (Test-DataHzHasValue $rollbackTo)) {
            $issues.Add("rolled-back status without rollbackTo") | Out-Null
        }
    }

    if ($source.Equals("package", [StringComparison]::OrdinalIgnoreCase)) {
        if (-not (Test-DataHzHasValue $packageZip)) {
            $issues.Add("package source without packageZip") | Out-Null
        }
        if ($requireManifest -and -not (Test-DataHzHasValue $packageManifestFile)) {
            $issues.Add("requireManifest=true but packageManifestFile missing") | Out-Null
        }
    }

    if ((Test-DataHzHasValue $packageIndexShaFile) -and (-not (Test-DataHzHasValue $packageIndexFile))) {
        $issues.Add("packageIndexSha256File set without packageIndexFile") | Out-Null
    }
    if ((Test-DataHzHasValue $packageIndexShaUrl) -and (-not (Test-DataHzHasValue $packageIndexUrl))) {
        $issues.Add("packageIndexSha256Url set without packageIndexUrl") | Out-Null
    }

    return [pscustomobject]@{
        releaseId = $releaseId
        status = $status
        source = $source
        requireManifest = $requireManifest
        hasManifest = (Test-DataHzHasValue $packageManifestFile)
        hasIndex = ((Test-DataHzHasValue $packageIndexFile) -or (Test-DataHzHasValue $packageIndexUrl))
        hasIndexSha = ((Test-DataHzHasValue $packageIndexShaFile) -or (Test-DataHzHasValue $packageIndexShaUrl))
        startedAtUtc = $startedAtUtc
        completedAtUtc = $completedAtUtc
        rollbackTo = $rollbackTo
        issueCount = $issues.Count
        issues = [string]::Join("; ", @($issues))
    }
}
