[CmdletBinding()]
param(
    [string]$BaseUrl = "http://127.0.0.1:5080",
    [string]$ServiceName = "",
    [string]$ApiKey = "",
    [string]$BearerToken = "",
    [int]$TimeoutSeconds = 10,
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

$results = New-Object System.Collections.Generic.List[object]

function Add-Result([string]$Check, [bool]$Passed, [string]$Detail) {
    $script:results.Add([pscustomobject]@{
        Check = $Check
        Passed = $Passed
        Detail = $Detail
    })
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
                $stream = $_.Exception.Response.GetResponseStream()
                if ($stream) {
                    $reader = New-Object System.IO.StreamReader($stream)
                    $content = $reader.ReadToEnd()
                    $reader.Dispose()
                }
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

function Wait-ForHealthReady([string]$Url, [int]$MaxWaitSeconds, [string]$ApiKeyValue, [string]$JwtValue) {
    $deadline = (Get-Date).AddSeconds([Math]::Max(1, $MaxWaitSeconds))
    $lastError = ""

    while ((Get-Date) -lt $deadline) {
        try {
            $resp = Invoke-Get -Url $Url -Timeout 3 -ApiKeyValue $ApiKeyValue -JwtValue $JwtValue
            if ($resp.StatusCode -eq 200) {
                try {
                    $obj = $resp.Content | ConvertFrom-Json
                    if ($null -ne $obj -and ($obj.status -eq "ok" -or $obj.Status -eq "ok")) {
                        return $true
                    }

                    $lastError = "Health endpoint returned HTTP 200 but status is not ok."
                }
                catch {
                    $lastError = "Health endpoint returned HTTP 200 but response is not valid JSON."
                }
            }
            else {
                $lastError = "Health endpoint returned HTTP $($resp.StatusCode)."
            }
        }
        catch {
            $lastError = $_.Exception.Message
        }

        Start-Sleep -Milliseconds 500
    }

    return $lastError
}

if (-not [string]::IsNullOrWhiteSpace($ServiceName)) {
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $svc) {
        Add-Result -Check "windows-service" -Passed $false -Detail "Service '$ServiceName' not found."
    }
    elseif ($svc.Status -ne "Running") {
        Add-Result -Check "windows-service" -Passed $false -Detail "Service '$ServiceName' status is $($svc.Status)."
    }
    else {
        Add-Result -Check "windows-service" -Passed $true -Detail "Service '$ServiceName' is running."
    }
}

$healthUrl = "$base/health"
$healthReady = Wait-ForHealthReady -Url $healthUrl -MaxWaitSeconds $TimeoutSeconds -ApiKeyValue $ApiKey -JwtValue $BearerToken
if ($healthReady -is [string]) {
    Add-Result -Check "health" -Passed $false -Detail $healthReady
}
else {
try {
    $health = Invoke-Get -Url $healthUrl -Timeout $TimeoutSeconds -ApiKeyValue $ApiKey -JwtValue $BearerToken
    if ($health.StatusCode -ne 200) {
        Add-Result -Check "health" -Passed $false -Detail "HTTP $($health.StatusCode)."
    }
    else {
        try {
            $obj = $health.Content | ConvertFrom-Json
            if ($null -ne $obj -and ($obj.status -eq "ok" -or $obj.Status -eq "ok")) {
                Add-Result -Check "health" -Passed $true -Detail "status=ok"
            }
            else {
                Add-Result -Check "health" -Passed $false -Detail "HTTP 200 but status is not ok."
            }
        }
        catch {
            Add-Result -Check "health" -Passed $false -Detail "HTTP 200 but response is not valid JSON."
        }
    }
}
catch {
    Add-Result -Check "health" -Passed $false -Detail $_.Exception.Message
}
}

foreach ($item in @(
    @{ Name = "swagger"; Path = "/swagger/index.html"; Contains = "Swagger UI" },
    @{ Name = "dashboard"; Path = "/dashboard/index.html"; Contains = "DataHz Monitor Board" }
)) {
    try {
        $resp = Invoke-Get -Url "$base$($item.Path)" -Timeout $TimeoutSeconds -ApiKeyValue $ApiKey -JwtValue $BearerToken
        if ($resp.StatusCode -ne 200) {
            Add-Result -Check $item.Name -Passed $false -Detail "HTTP $($resp.StatusCode)."
            continue
        }

        if ($resp.Content -like "*$($item.Contains)*") {
            Add-Result -Check $item.Name -Passed $true -Detail "HTTP 200."
        }
        else {
            Add-Result -Check $item.Name -Passed $false -Detail "HTTP 200 but expected marker '$($item.Contains)' not found."
        }
    }
    catch {
        Add-Result -Check $item.Name -Passed $false -Detail $_.Exception.Message
    }
}

$apiChecks = @(
    @{ Name = "whoami"; Path = "/api/security/whoami" },
    @{ Name = "jobs-stats"; Path = "/api/jobs/stats" },
    @{ Name = "monitor-overview"; Path = "/api/monitor/overview?jobs=3&audit=3" }
)

$hasCredentials = -not [string]::IsNullOrWhiteSpace($ApiKey) -or -not [string]::IsNullOrWhiteSpace($BearerToken)

foreach ($item in $apiChecks) {
    try {
        $resp = Invoke-Get -Url "$base$($item.Path)" -Timeout $TimeoutSeconds -ApiKeyValue $ApiKey -JwtValue $BearerToken

        $allowed = if ($RequireAuthenticatedApi -or $hasCredentials) {
            @(200)
        }
        else {
            @(200, 401)
        }

        if (Test-Status -Code $resp.StatusCode -Allowed $allowed) {
            Add-Result -Check $item.Name -Passed $true -Detail "HTTP $($resp.StatusCode)."
        }
        else {
            Add-Result -Check $item.Name -Passed $false -Detail "HTTP $($resp.StatusCode), allowed: $($allowed -join ',')."
        }
    }
    catch {
        Add-Result -Check $item.Name -Passed $false -Detail $_.Exception.Message
    }
}

$failed = $results | Where-Object { -not $_.Passed }
$results | Format-Table -AutoSize Check, Passed, Detail

if ($failed.Count -gt 0) {
    Write-Host ""
    Write-Host "Smoke test failed: $($failed.Count) check(s)." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "Smoke test passed." -ForegroundColor Green
exit 0
