[CmdletBinding()]
param(
    [string]$BaseUrl = "http://127.0.0.1:5080",
    [string]$ServiceName = "",
    [string]$ApiKey = "",
    [string]$BearerToken = "",
    [int]$TimeoutSeconds = 10,
    [int]$CheckRetryCount = 3,
    [int]$CheckRetryDelayMilliseconds = 500,
    [int]$HealthPollDelayMilliseconds = 500,
    [int]$WarnCheckDurationMilliseconds = 0,
    [int]$FailCheckDurationMilliseconds = 0,
    [int]$FailureContentSnippetLength = 240,
    [string]$OutputJsonPath = "",
    [switch]$RequireAuthenticatedApi
)

$ErrorActionPreference = "Stop"

if ($RequireAuthenticatedApi -and [string]::IsNullOrWhiteSpace($ApiKey) -and [string]::IsNullOrWhiteSpace($BearerToken)) {
    throw "RequireAuthenticatedApi is set, but no ApiKey or BearerToken was provided."
}

$base = $BaseUrl.Trim()
if ($base.EndsWith("/")) {
    $base = $base.TrimEnd("/")
}

$effectiveRetryCount = [Math]::Max(1, $CheckRetryCount)
$effectiveRetryDelayMilliseconds = [Math]::Max(0, $CheckRetryDelayMilliseconds)
$effectiveHealthPollDelayMilliseconds = [Math]::Max(0, $HealthPollDelayMilliseconds)
$effectiveWarnCheckDurationMilliseconds = [Math]::Max(0, $WarnCheckDurationMilliseconds)
$effectiveFailCheckDurationMilliseconds = [Math]::Max(0, $FailCheckDurationMilliseconds)
$effectiveFailureContentSnippetLength = [Math]::Max(0, $FailureContentSnippetLength)
$hasApiKey = -not [string]::IsNullOrWhiteSpace($ApiKey)
$hasBearerToken = -not [string]::IsNullOrWhiteSpace($BearerToken)
$hasCredentials = $hasApiKey -or $hasBearerToken
$runStartedAtUtc = (Get-Date).ToUniversalTime()

$displayBase = $base
try {
    $uri = [System.Uri]$base
    if (-not [string]::IsNullOrWhiteSpace($uri.UserInfo)) {
        $builder = [System.UriBuilder]::new($uri)
        $builder.UserName = ""
        $builder.Password = ""
        $displayBase = $builder.Uri.AbsoluteUri.TrimEnd("/")
    }
}
catch {
    $displayBase = $base
}

$sensitiveValues = New-Object System.Collections.Generic.List[string]
if ($hasApiKey) {
    $sensitiveValues.Add($ApiKey)
}
if ($hasBearerToken) {
    $sensitiveValues.Add($BearerToken)
    $sensitiveValues.Add("Bearer $BearerToken")
}
$script:SensitiveValues = @($sensitiveValues | Sort-Object Length -Descending -Unique)

if ($effectiveRetryCount -ne $CheckRetryCount) {
    Write-Host "CheckRetryCount was normalized from $CheckRetryCount to $effectiveRetryCount."
}

if ($effectiveRetryDelayMilliseconds -ne $CheckRetryDelayMilliseconds) {
    Write-Host "CheckRetryDelayMilliseconds was normalized from $CheckRetryDelayMilliseconds to $effectiveRetryDelayMilliseconds."
}

if ($effectiveHealthPollDelayMilliseconds -ne $HealthPollDelayMilliseconds) {
    Write-Host "HealthPollDelayMilliseconds was normalized from $HealthPollDelayMilliseconds to $effectiveHealthPollDelayMilliseconds."
}

if ($effectiveWarnCheckDurationMilliseconds -ne $WarnCheckDurationMilliseconds) {
    Write-Host "WarnCheckDurationMilliseconds was normalized from $WarnCheckDurationMilliseconds to $effectiveWarnCheckDurationMilliseconds."
}

if ($effectiveFailCheckDurationMilliseconds -ne $FailCheckDurationMilliseconds) {
    Write-Host "FailCheckDurationMilliseconds was normalized from $FailCheckDurationMilliseconds to $effectiveFailCheckDurationMilliseconds."
}

if ($effectiveFailureContentSnippetLength -ne $FailureContentSnippetLength) {
    Write-Host "FailureContentSnippetLength was normalized from $FailureContentSnippetLength to $effectiveFailureContentSnippetLength."
}

$results = New-Object System.Collections.Generic.List[object]

function Redact-SensitiveText([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) {
        return $Text
    }

    $sanitized = $Text
    foreach ($secret in $script:SensitiveValues) {
        if ([string]::IsNullOrWhiteSpace($secret)) {
            continue
        }

        $sanitized = $sanitized.Replace($secret, "[REDACTED]")
    }

    # Extra guard for common token-bearing fields in responses/errors.
    $sanitized = [System.Text.RegularExpressions.Regex]::Replace(
        $sanitized,
        '(?i)(Authorization\s*:\s*Bearer\s+)[^\s"'';]+',
        '$1[REDACTED]'
    )

    # Guard free-text bearer tokens that may appear in arbitrary diagnostics fields.
    $sanitized = [System.Text.RegularExpressions.Regex]::Replace(
        $sanitized,
        '(?i)(\bBearer\s+)[^\s"'';,]+',
        '$1[REDACTED]'
    )

    # Guard free-text basic credentials that may appear in arbitrary diagnostics fields.
    $sanitized = [System.Text.RegularExpressions.Regex]::Replace(
        $sanitized,
        '(?i)(\bBasic\s+)[^\s"'';,]+',
        '$1[REDACTED]'
    )

    # Normalize JSON-escaped quote sequences so quote-aware key/value redaction can match.
    $sanitized = [System.Text.RegularExpressions.Regex]::Replace($sanitized, '(?i)(?:\\)+u0027', "'")
    $sanitized = [System.Text.RegularExpressions.Regex]::Replace($sanitized, '(?i)(?:\\)+u0022', '"')
    # Normalize JSON-escaped slash sequences (for example \/ and \\/) so URL rules can match.
    $sanitized = [System.Text.RegularExpressions.Regex]::Replace($sanitized, '(?:\\)+/', '/')

    $sanitized = [System.Text.RegularExpressions.Regex]::Replace(
        $sanitized,
        '(?i)(["'']?(?:x[-_. ]?api[-_. ]?key(?:[._-][a-z0-9]+|(?-i:[A-Z][a-z0-9]*))*|api[-_. ]?key(?:[._-][a-z0-9]+|(?-i:[A-Z][a-z0-9]*))*|authorization(?:[._-][a-z0-9]+|(?-i:[A-Z][a-z0-9]*))*|proxy[-_. ]?authorization(?:[._-][a-z0-9]+|(?-i:[A-Z][a-z0-9]*))*|token(?:[._-][a-z0-9]+|(?-i:[A-Z][a-z0-9]*))*|id[._-]?token(?:[._-][a-z0-9]+|(?-i:[A-Z][a-z0-9]*))*|access[._-]?token(?:[._-][a-z0-9]+|(?-i:[A-Z][a-z0-9]*))*|refresh[._-]?token(?:[._-][a-z0-9]+|(?-i:[A-Z][a-z0-9]*))*|jwt(?:[._-][a-z0-9]+|(?-i:[A-Z][a-z0-9]*))*|secret(?:[._-][a-z0-9]+|(?-i:[A-Z][a-z0-9]*))*|client[._-]?secret(?:[._-][a-z0-9]+|(?-i:[A-Z][a-z0-9]*))*|password(?:[._-][a-z0-9]+|(?-i:[A-Z][a-z0-9]*))*|cookie(?:[._-][a-z0-9]+|(?-i:[A-Z][a-z0-9]*))*|set[-_. ]?cookie(?:[._-][a-z0-9]+|(?-i:[A-Z][a-z0-9]*))*|session(?:[._-]?id)?(?:[._-][a-z0-9]+|(?-i:[A-Z][a-z0-9]*))*)(?:(?:\[[a-z0-9_.-]*\])|(?:%(?:25)*5b[a-z0-9_.-]*%(?:25)*5d))*["'']?\s*[:=]\s*["'']?)[^''",&#\r\n]+',
        '$1[REDACTED]'
    )

    # Guard compact JWT values that may be logged without an explicit key.
    $sanitized = [System.Text.RegularExpressions.Regex]::Replace(
        $sanitized,
        '(?i)\beyJ[a-z0-9_-]+\.[a-z0-9_-]+\.[a-z0-9_-]+\b',
        '[REDACTED]'
    )

    # Redact userinfo in URLs: http(s)://user[:pass]@host -> http(s)://[REDACTED]@host
    $sanitized = [System.Text.RegularExpressions.Regex]::Replace(
        $sanitized,
        '(?i)\b(https?://)([^/\s@]+)@',
        '$1[REDACTED]@'
    )

    # Redact sensitive URL query parameters while keeping keys visible.
    $sanitized = [System.Text.RegularExpressions.Regex]::Replace(
        $sanitized,
        '(?i)([?#&;](?:x[-_.]?api[-_.]?key(?:[._-][a-z0-9]+|(?-i:[A-Z][a-z0-9]*))*|api[-_.]?key(?:[._-][a-z0-9]+|(?-i:[A-Z][a-z0-9]*))*|authorization(?:[._-][a-z0-9]+|(?-i:[A-Z][a-z0-9]*))*|proxy[._-]?authorization(?:[._-][a-z0-9]+|(?-i:[A-Z][a-z0-9]*))*|token(?:[._-][a-z0-9]+|(?-i:[A-Z][a-z0-9]*))*|id[._-]?token(?:[._-][a-z0-9]+|(?-i:[A-Z][a-z0-9]*))*|access[._-]?token(?:[._-][a-z0-9]+|(?-i:[A-Z][a-z0-9]*))*|refresh[._-]?token(?:[._-][a-z0-9]+|(?-i:[A-Z][a-z0-9]*))*|jwt(?:[._-][a-z0-9]+|(?-i:[A-Z][a-z0-9]*))*|secret(?:[._-][a-z0-9]+|(?-i:[A-Z][a-z0-9]*))*|client[._-]?secret(?:[._-][a-z0-9]+|(?-i:[A-Z][a-z0-9]*))*|password(?:[._-][a-z0-9]+|(?-i:[A-Z][a-z0-9]*))*|cookie(?:[._-][a-z0-9]+|(?-i:[A-Z][a-z0-9]*))*|set[._-]?cookie(?:[._-][a-z0-9]+|(?-i:[A-Z][a-z0-9]*))*|session(?:[._-]?id)?(?:[._-][a-z0-9]+|(?-i:[A-Z][a-z0-9]*))*)(?:(?:\[[a-z0-9_.-]*\])|(?:%(?:25)*5b[a-z0-9_.-]*%(?:25)*5d))*=)[^&#;\s]+',
        '$1[REDACTED]'
    )

    return $sanitized
}

function Normalize-DisplayText([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) {
        return $Text
    }

    $normalized = Redact-SensitiveText -Text $Text
    $normalized = [System.Text.RegularExpressions.Regex]::Replace(
        $normalized,
        "[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]",
        " "
    )
    $normalized = $normalized.Replace("`r", " ").Replace("`n", " ").Trim()
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return ""
    }

    return [System.Text.RegularExpressions.Regex]::Replace($normalized, "\s+", " ")
}

function Normalize-DisplayBaseUrl([string]$BaseValue) {
    $normalized = Normalize-DisplayText -Text $BaseValue
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return $normalized
    }

    $parts = $normalized -split "\s+", 2
    return [string]$parts[0]
}

$safeDisplayBase = Normalize-DisplayBaseUrl -BaseValue $displayBase
Write-Host "Smoke context:"
Write-Host "  BaseUrl: $safeDisplayBase"
Write-Host "  TimeoutSeconds: $TimeoutSeconds"
Write-Host "  RequireAuthenticatedApi: $([bool]$RequireAuthenticatedApi)"
Write-Host "  HasApiKey: $hasApiKey"
Write-Host "  HasBearerToken: $hasBearerToken"
Write-Host "  CheckRetryCount: $effectiveRetryCount"
Write-Host "  CheckRetryDelayMilliseconds: $effectiveRetryDelayMilliseconds"
Write-Host "  HealthPollDelayMilliseconds: $effectiveHealthPollDelayMilliseconds"
Write-Host "  WarnCheckDurationMilliseconds: $effectiveWarnCheckDurationMilliseconds"
Write-Host "  FailCheckDurationMilliseconds: $effectiveFailCheckDurationMilliseconds"
Write-Host "  FailureContentSnippetLength: $effectiveFailureContentSnippetLength"

function Add-Result(
    [string]$Check,
    [bool]$Passed,
    [string]$Detail,
    [int]$Attempts = 1,
    [string]$Endpoint = "",
    [int]$DurationMs = 0
) {
    $safeDetail = Normalize-DisplayText -Text $Detail
    $safeEndpoint = Normalize-DisplayText -Text $Endpoint
    $script:results.Add([pscustomobject]@{
        Check = $Check
        Passed = $Passed
        Attempts = [Math]::Max(1, $Attempts)
        DurationMs = [Math]::Max(0, [int]$DurationMs)
        Endpoint = $safeEndpoint
        Detail = $safeDetail
    })
}

function Test-IsTextContentType([string]$ContentType) {
    if ([string]::IsNullOrWhiteSpace($ContentType)) {
        return $true
    }

    $ct = $ContentType.Trim().ToLowerInvariant()
    if ($ct.StartsWith("text/")) {
        return $true
    }

    foreach ($marker in @("json", "xml", "html", "javascript", "x-www-form-urlencoded", "yaml")) {
        if ($ct.Contains($marker)) {
            return $true
        }
    }

    return $false
}

function Test-IsLikelyTextBytes([byte[]]$Bytes) {
    if ($null -eq $Bytes -or $Bytes.Length -eq 0) {
        return $true
    }

    $sampleSize = [Math]::Min($Bytes.Length, 2048)
    $controlCount = 0
    for ($i = 0; $i -lt $sampleSize; $i++) {
        $value = [int]$Bytes[$i]
        if ($value -eq 0) {
            return $false
        }

        if (($value -lt 9) -or ($value -gt 13 -and $value -lt 32) -or $value -eq 127) {
            $controlCount++
        }
    }

    return $controlCount -le [Math]::Ceiling($sampleSize * 0.10)
}

function Resolve-ResponseEncoding([string]$ContentType) {
    if (-not [string]::IsNullOrWhiteSpace($ContentType)) {
        $match = [System.Text.RegularExpressions.Regex]::Match($ContentType, "(?i)charset\s*=\s*[""']?(?<name>[^;""'\s]+)")
        if ($match.Success) {
            $charset = $match.Groups["name"].Value.Trim()
            if (-not [string]::IsNullOrWhiteSpace($charset)) {
                try {
                    return [System.Text.Encoding]::GetEncoding($charset)
                }
                catch {
                }
            }
        }
    }

    return [System.Text.Encoding]::UTF8
}

function Read-ResponseBody([object]$Response) {
    if ($null -eq $Response) {
        return ""
    }

    $bytes = $null
    $contentType = ""

    # Windows PowerShell (HttpWebResponse path).
    if ($Response.PSObject.Methods.Name -contains "GetResponseStream") {
        $stream = $null
        try {
            $stream = $Response.GetResponseStream()
        }
        catch {
            $stream = $null
        }

        if ($null -ne $stream) {
            $memory = New-Object System.IO.MemoryStream
            try {
                $stream.CopyTo($memory)
                $bytes = $memory.ToArray()
            }
            finally {
                $memory.Dispose()
                try { $stream.Dispose() } catch { }
            }
        }

        try {
            $contentType = [string]$Response.ContentType
        }
        catch {
            $contentType = ""
        }
    }

    # PowerShell 7+ (HttpResponseMessage path).
    if ($null -eq $bytes -and $Response.PSObject.Properties.Name -contains "Content" -and $null -ne $Response.Content) {
        try {
            $bytes = $Response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        }
        catch {
            $bytes = $null
        }

        try {
            if ($Response.Content.Headers -and $Response.Content.Headers.ContentType) {
                $contentType = [string]$Response.Content.Headers.ContentType
            }
        }
        catch {
        }
    }

    if ($null -eq $bytes) {
        if (-not [string]::IsNullOrWhiteSpace($contentType)) {
            return "[response body unavailable; contentType=$contentType]"
        }

        return "[response body unavailable]"
    }

    if ([string]::IsNullOrWhiteSpace($contentType)) {
        try {
            $contentType = [string]$Response.ContentType
        }
        catch {
            $contentType = ""
        }
    }

    if (-not (Test-IsTextContentType -ContentType $contentType)) {
        return "[non-text response body omitted; contentType=$contentType; bytes=$($bytes.Length)]"
    }

    if (-not (Test-IsLikelyTextBytes -Bytes $bytes)) {
        return "[binary response body omitted; bytes=$($bytes.Length)]"
    }

    $encoding = Resolve-ResponseEncoding -ContentType $contentType
    try {
        return $encoding.GetString($bytes)
    }
    catch {
        return [System.Text.Encoding]::UTF8.GetString($bytes)
    }
}

function Invoke-Get([string]$Url, [int]$Timeout, [string]$ApiKeyValue, [string]$JwtValue) {
    $headers = @{}
    if (-not [string]::IsNullOrWhiteSpace($ApiKeyValue)) {
        $headers["X-Api-Key"] = $ApiKeyValue
    }

    if (-not [string]::IsNullOrWhiteSpace($JwtValue)) {
        $headers["Authorization"] = "Bearer $JwtValue"
    }

    try {
        $response = Invoke-WebRequest `
            -Uri $Url `
            -Method Get `
            -Headers $headers `
            -TimeoutSec ([Math]::Max(1, $Timeout)) `
            -UseBasicParsing

        return [pscustomobject]@{
            StatusCode = [int]$response.StatusCode
            Content = [string]$response.Content
        }
    }
    catch {
        $status = 0
        $content = ""
        if ($_.Exception -and $_.Exception.Response) {
            try {
                $status = [int]$_.Exception.Response.StatusCode
            }
            catch {
                $status = 0
            }

            try {
                $content = Read-ResponseBody -Response $_.Exception.Response
            }
            catch {
                $content = ""
            }
        }

        if ($status -gt 0) {
            return [pscustomobject]@{
                StatusCode = $status
                Content = $content
            }
        }

        throw
    }
}

function Test-Status([int]$Code, [int[]]$Allowed) {
    return $Allowed -contains $Code
}

function Get-ContentSnippet([string]$Content, [int]$MaxLength) {
    if ([string]::IsNullOrWhiteSpace($Content) -or $MaxLength -le 0) {
        return ""
    }

    $normalized = Normalize-DisplayText -Text $Content
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return ""
    }

    if ($normalized.Length -le $MaxLength) {
        return $normalized
    }

    return $normalized.Substring(0, $MaxLength) + "..."
}

function Compose-DetailWithSnippet([string]$Message, [string]$Content, [int]$MaxLength) {
    $detail = $Message
    $snippet = Get-ContentSnippet -Content $Content -MaxLength $MaxLength
    if (-not [string]::IsNullOrWhiteSpace($snippet)) {
        $detail = "$detail bodySnippet=$snippet"
    }

    return $detail
}

function Invoke-CheckWithRetry([scriptblock]$CheckOperation, [int]$MaxAttempts, [int]$DelayMilliseconds) {
    $startedAt = Get-Date
    $attemptLimit = [Math]::Max(1, $MaxAttempts)
    $attempt = 0
    $last = $null

    while ($attempt -lt $attemptLimit) {
        $attempt++
        $last = & $CheckOperation

        if ($null -eq $last) {
            $last = [pscustomobject]@{
                Passed = $false
                Detail = "Check operation returned no result."
            }
        }

        if ($last.Passed) {
            $durationMilliseconds = [int][Math]::Round(((Get-Date) - $startedAt).TotalMilliseconds)
            return [pscustomobject]@{
                Passed = $true
                Detail = [string]$last.Detail
                Attempts = $attempt
                DurationMilliseconds = [Math]::Max(0, $durationMilliseconds)
            }
        }

        if ($attempt -lt $attemptLimit -and $DelayMilliseconds -gt 0) {
            Start-Sleep -Milliseconds $DelayMilliseconds
        }
    }

    $durationMilliseconds = [int][Math]::Round(((Get-Date) - $startedAt).TotalMilliseconds)
    return [pscustomobject]@{
        Passed = $false
        Detail = [string]$last.Detail
        Attempts = $attemptLimit
        DurationMilliseconds = [Math]::Max(0, $durationMilliseconds)
    }
}

function Wait-ForHealthReady([string]$Url, [int]$MaxWaitSeconds, [int]$PollDelayMilliseconds, [string]$ApiKeyValue, [string]$JwtValue) {
    $startedAt = Get-Date
    $deadline = (Get-Date).AddSeconds([Math]::Max(1, $MaxWaitSeconds))
    $lastError = ""
    $attempts = 0

    while ((Get-Date) -lt $deadline) {
        $attempts++
        try {
            $resp = Invoke-Get -Url $Url -Timeout 3 -ApiKeyValue $ApiKeyValue -JwtValue $JwtValue
            if ($resp.StatusCode -eq 200) {
                try {
                    $obj = $resp.Content | ConvertFrom-Json
                    if ($null -ne $obj -and ($obj.status -eq "ok" -or $obj.Status -eq "ok")) {
                        $durationMilliseconds = [int][Math]::Round(((Get-Date) - $startedAt).TotalMilliseconds)
                        return [pscustomobject]@{
                            Ready = $true
                            Detail = "status=ok"
                            Attempts = $attempts
                            DurationMilliseconds = [Math]::Max(0, $durationMilliseconds)
                        }
                    }

                    $lastError = Compose-DetailWithSnippet `
                        -Message "Health endpoint returned HTTP 200 but status is not ok." `
                        -Content $resp.Content `
                        -MaxLength $effectiveFailureContentSnippetLength
                }
                catch {
                    $lastError = Compose-DetailWithSnippet `
                        -Message "Health endpoint returned HTTP 200 but response is not valid JSON." `
                        -Content $resp.Content `
                        -MaxLength $effectiveFailureContentSnippetLength
                }
            }
            else {
                $lastError = Compose-DetailWithSnippet `
                    -Message "Health endpoint returned HTTP $($resp.StatusCode)." `
                    -Content $resp.Content `
                    -MaxLength $effectiveFailureContentSnippetLength
            }
        }
        catch {
            $lastError = $_.Exception.Message
        }

        if ($PollDelayMilliseconds -gt 0) {
            Start-Sleep -Milliseconds $PollDelayMilliseconds
        }
    }

    if ([string]::IsNullOrWhiteSpace($lastError)) {
        $lastError = "Health endpoint did not become ready before timeout."
    }

    $durationMilliseconds = [int][Math]::Round(((Get-Date) - $startedAt).TotalMilliseconds)
    return [pscustomobject]@{
        Ready = $false
        Detail = $lastError
        Attempts = $attempts
        DurationMilliseconds = [Math]::Max(0, $durationMilliseconds)
    }
}

function Write-SmokeReport([string]$PathValue, [object]$Payload) {
    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return
    }

    $targetPath = $PathValue
    if (-not [System.IO.Path]::IsPathRooted($targetPath)) {
        $targetPath = Join-Path (Get-Location).Path $targetPath
    }

    $parent = Split-Path -Parent $targetPath
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path $parent)) {
        [void](New-Item -ItemType Directory -Path $parent -Force)
    }

    $json = $Payload | ConvertTo-Json -Depth 10
    Set-Content -Path $targetPath -Value $json -Encoding UTF8
    Write-Host "Smoke report written to: $targetPath"
}

if (-not [string]::IsNullOrWhiteSpace($ServiceName)) {
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $svc) {
        Add-Result -Check "windows-service" -Passed $false -Detail "Service '$ServiceName' not found." -Endpoint "service://$ServiceName" -DurationMs 0
    }
    elseif ($svc.Status -ne "Running") {
        Add-Result -Check "windows-service" -Passed $false -Detail "Service '$ServiceName' status is $($svc.Status)." -Endpoint "service://$ServiceName" -DurationMs 0
    }
    else {
        Add-Result -Check "windows-service" -Passed $true -Detail "Service '$ServiceName' is running." -Endpoint "service://$ServiceName" -DurationMs 0
    }
}

$healthUrl = "$base/health"
$healthReady = Wait-ForHealthReady `
    -Url $healthUrl `
    -MaxWaitSeconds $TimeoutSeconds `
    -PollDelayMilliseconds $effectiveHealthPollDelayMilliseconds `
    -ApiKeyValue $ApiKey `
    -JwtValue $BearerToken
if (-not $healthReady.Ready) {
    Add-Result -Check "health" -Passed $false -Detail $healthReady.Detail -Attempts $healthReady.Attempts -Endpoint "/health" -DurationMs $healthReady.DurationMilliseconds
}
else {
    Add-Result -Check "health" -Passed $true -Detail $healthReady.Detail -Attempts $healthReady.Attempts -Endpoint "/health" -DurationMs $healthReady.DurationMilliseconds
}

foreach ($item in @(
    @{ Name = "swagger"; Path = "/swagger/index.html"; Contains = "swagger-ui"; AllowRedirect = $false },
    @{ Name = "dashboard"; Path = "/dashboard/"; Contains = "DataHz Monitor Board"; AllowRedirect = $true }
)) {
    $outcome = Invoke-CheckWithRetry `
        -MaxAttempts $effectiveRetryCount `
        -DelayMilliseconds $effectiveRetryDelayMilliseconds `
        -CheckOperation {
            try {
                $resp = Invoke-Get -Url "$base$($item.Path)" -Timeout $TimeoutSeconds -ApiKeyValue $ApiKey -JwtValue $BearerToken
                if ($resp.StatusCode -eq 200) {
                    if ($resp.Content -like "*$($item.Contains)*") {
                        return [pscustomobject]@{
                            Passed = $true
                            Detail = "HTTP 200."
                        }
                    }

                    return [pscustomobject]@{
                        Passed = $false
                        Detail = Compose-DetailWithSnippet `
                            -Message "HTTP 200 but expected marker '$($item.Contains)' not found." `
                            -Content $resp.Content `
                            -MaxLength $effectiveFailureContentSnippetLength
                    }
                }

                if ($item.AllowRedirect -and (Test-Status -Code $resp.StatusCode -Allowed @(301, 302, 307, 308))) {
                    return [pscustomobject]@{
                        Passed = $true
                        Detail = "HTTP $($resp.StatusCode) redirect."
                    }
                }

                return [pscustomobject]@{
                    Passed = $false
                    Detail = Compose-DetailWithSnippet `
                        -Message "HTTP $($resp.StatusCode)." `
                        -Content $resp.Content `
                        -MaxLength $effectiveFailureContentSnippetLength
                }
            }
            catch {
                return [pscustomobject]@{
                    Passed = $false
                    Detail = $_.Exception.Message
                }
            }

        }

    Add-Result -Check $item.Name -Passed $outcome.Passed -Detail $outcome.Detail -Attempts $outcome.Attempts -Endpoint $item.Path -DurationMs $outcome.DurationMilliseconds
}

$apiChecks = @(
    @{ Name = "whoami"; Path = "/api/security/whoami" },
    @{ Name = "jobs-stats"; Path = "/api/jobs/stats" },
    @{ Name = "monitor-overview"; Path = "/api/monitor/overview?jobs=3&audit=3" }
)

foreach ($item in $apiChecks) {
    $outcome = Invoke-CheckWithRetry `
        -MaxAttempts $effectiveRetryCount `
        -DelayMilliseconds $effectiveRetryDelayMilliseconds `
        -CheckOperation {
            try {
                $resp = Invoke-Get -Url "$base$($item.Path)" -Timeout $TimeoutSeconds -ApiKeyValue $ApiKey -JwtValue $BearerToken

                $allowed = if ($RequireAuthenticatedApi -or $hasCredentials) {
                    @(200)
                }
                else {
                    @(200, 401)
                }

                if (Test-Status -Code $resp.StatusCode -Allowed $allowed) {
                    return [pscustomobject]@{
                        Passed = $true
                        Detail = "HTTP $($resp.StatusCode)."
                    }
                }

                return [pscustomobject]@{
                    Passed = $false
                    Detail = Compose-DetailWithSnippet `
                        -Message "HTTP $($resp.StatusCode), allowed: $($allowed -join ',')." `
                        -Content $resp.Content `
                        -MaxLength $effectiveFailureContentSnippetLength
                }
            }
            catch {
                return [pscustomobject]@{
                    Passed = $false
                    Detail = $_.Exception.Message
                }
            }
        }

    Add-Result -Check $item.Name -Passed $outcome.Passed -Detail $outcome.Detail -Attempts $outcome.Attempts -Endpoint $item.Path -DurationMs $outcome.DurationMilliseconds
}

$failed = @($results | Where-Object { -not $_.Passed })
$runFinishedAtUtc = (Get-Date).ToUniversalTime()
$elapsedMilliseconds = [int][Math]::Round(($runFinishedAtUtc - $runStartedAtUtc).TotalMilliseconds)
$averageCheckDurationMs = 0
if ($results.Count -gt 0) {
    $averageCheckDurationMs = [int][Math]::Round((($results | Measure-Object -Property DurationMs -Average).Average))
}

$maxDurationItem = $results | Sort-Object DurationMs -Descending | Select-Object -First 1
$maxCheckDurationMs = if ($null -ne $maxDurationItem) { [int]$maxDurationItem.DurationMs } else { 0 }
$maxCheckName = if ($null -ne $maxDurationItem) { [string]$maxDurationItem.Check } else { "" }
$slowWarnChecks = @()
if ($effectiveWarnCheckDurationMilliseconds -gt 0) {
    $slowWarnChecks = @($results | Where-Object { $_.DurationMs -gt $effectiveWarnCheckDurationMilliseconds })
}

$slowFailChecks = @()
if ($effectiveFailCheckDurationMilliseconds -gt 0) {
    $slowFailChecks = @($results | Where-Object { $_.DurationMs -gt $effectiveFailCheckDurationMilliseconds })
}

$resultItems = $results.ToArray()

$reportPayload = [pscustomobject]@{
    startedUtc = $runStartedAtUtc.ToString("o")
    finishedUtc = $runFinishedAtUtc.ToString("o")
    elapsedMilliseconds = $elapsedMilliseconds
    baseUrl = $safeDisplayBase
    timeoutSeconds = $TimeoutSeconds
    requireAuthenticatedApi = [bool]$RequireAuthenticatedApi
    hasApiKey = $hasApiKey
    hasBearerToken = $hasBearerToken
    checkRetryCount = $effectiveRetryCount
    checkRetryDelayMilliseconds = $effectiveRetryDelayMilliseconds
    healthPollDelayMilliseconds = $effectiveHealthPollDelayMilliseconds
    warnCheckDurationMilliseconds = $effectiveWarnCheckDurationMilliseconds
    failCheckDurationMilliseconds = $effectiveFailCheckDurationMilliseconds
    failureContentSnippetLength = $effectiveFailureContentSnippetLength
    totalChecks = $results.Count
    failedChecks = $failed.Count
    averageCheckDurationMs = $averageCheckDurationMs
    maxCheckDurationMs = $maxCheckDurationMs
    maxCheckName = $maxCheckName
    warnSlowCheckCount = $slowWarnChecks.Count
    failSlowCheckCount = $slowFailChecks.Count
    warnSlowChecks = @($slowWarnChecks | Select-Object Check, DurationMs, Attempts, Endpoint)
    failSlowChecks = @($slowFailChecks | Select-Object Check, DurationMs, Attempts, Endpoint)
    results = $resultItems
}

Write-SmokeReport -PathValue $OutputJsonPath -Payload $reportPayload

$results | Format-Table -AutoSize Check, Passed, Attempts, DurationMs, Endpoint, Detail

Write-Host ""
Write-Host "Smoke summary: total=$($results.Count), failed=$($failed.Count), elapsedMs=$elapsedMilliseconds"
Write-Host "Smoke durations: avgCheckMs=$averageCheckDurationMs, maxCheckMs=$maxCheckDurationMs, maxCheck=$maxCheckName"

$slowestChecks = @($results | Sort-Object DurationMs -Descending | Select-Object -First 3)
if ($slowestChecks.Count -gt 0) {
    Write-Host "Slowest checks:"
    foreach ($item in $slowestChecks) {
        Write-Host "  - $($item.Check) | durationMs=$($item.DurationMs) | attempts=$($item.Attempts) | endpoint=$($item.Endpoint)"
    }
}

if ($slowWarnChecks.Count -gt 0) {
    Write-Host "Slow check warning threshold exceeded: thresholdMs=$effectiveWarnCheckDurationMilliseconds, count=$($slowWarnChecks.Count)"
}

if ($slowFailChecks.Count -gt 0) {
    Write-Host "Slow check failure threshold exceeded: thresholdMs=$effectiveFailCheckDurationMilliseconds, count=$($slowFailChecks.Count)"
}

if ($failed.Count -gt 0 -or $slowFailChecks.Count -gt 0) {
    Write-Host ""
    if ($failed.Count -gt 0) {
        Write-Host "Failed checks detail:"
        foreach ($item in $failed) {
            Write-Host "  - $($item.Check) | attempts=$($item.Attempts) | durationMs=$($item.DurationMs) | endpoint=$($item.Endpoint) | $($item.Detail)"
        }
    }

    if ($slowFailChecks.Count -gt 0) {
        Write-Host "Slow check threshold violations:"
        foreach ($item in $slowFailChecks) {
            Write-Host "  - $($item.Check) | durationMs=$($item.DurationMs) | thresholdMs=$effectiveFailCheckDurationMilliseconds | attempts=$($item.Attempts) | endpoint=$($item.Endpoint)"
        }
    }

    Write-Host ""
    $reasonParts = New-Object System.Collections.Generic.List[string]
    if ($failed.Count -gt 0) {
        $reasonParts.Add("failed checks=$($failed.Count)")
    }
    if ($slowFailChecks.Count -gt 0) {
        $reasonParts.Add("slow check violations=$($slowFailChecks.Count)")
    }
    Write-Host "Smoke test failed: $($reasonParts -join ', ')." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "Smoke test passed." -ForegroundColor Green
exit 0
