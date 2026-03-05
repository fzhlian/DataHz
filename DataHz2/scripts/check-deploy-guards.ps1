[CmdletBinding()]
param(
    [string]$PackageZip = "",
    [switch]$IncludeOnlineSmokeCase,
    [string]$OnlineSmokePublishDir = "",
    [int]$OnlineSmokeStartupSeconds = 4,
    [switch]$KeepArtifacts
)

$ErrorActionPreference = "Stop"
$script:AutoPackagePublishDir = ""

function Resolve-ManifestPath([string]$ZipPath) {
    $parent = Split-Path -Parent $ZipPath
    $base = [System.IO.Path]::GetFileNameWithoutExtension($ZipPath)
    $candidate = Join-Path $parent ($base + ".manifest.json")
    if (-not (Test-Path $candidate)) {
        throw "Manifest not found for package zip: $candidate"
    }

    return $candidate
}

function Resolve-ShaPath([string]$ZipPath) {
    $candidate = [System.IO.Path]::ChangeExtension($ZipPath, ".sha256")
    if (-not (Test-Path $candidate)) {
        return ""
    }

    return $candidate
}

function Get-FreeTcpPort {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try {
        return ($listener.LocalEndpoint).Port
    }
    finally {
        $listener.Stop()
    }
}

function Convert-ToFileUri([string]$Path) {
    $resolved = [System.IO.Path]::GetFullPath($Path)
    return ([System.Uri]::new($resolved)).AbsoluteUri
}

function Start-StaticFileServer([string]$RootPath, [int]$Port) {
    $resolvedRoot = [System.IO.Path]::GetFullPath($RootPath)
    $prefix = "http://127.0.0.1:$Port/"

    $job = Start-Job -ArgumentList $resolvedRoot, $prefix -ScriptBlock {
        param($serverRoot, $serverPrefix)

        $rootResolved = [System.IO.Path]::GetFullPath($serverRoot)
        if (-not $rootResolved.EndsWith("\")) {
            $rootResolved += "\"
        }

        $listener = [System.Net.HttpListener]::new()
        $listener.Prefixes.Add($serverPrefix)
        $listener.Start()
        try {
            while ($true) {
                $ctx = $listener.GetContext()
                $resp = $ctx.Response
                try {
                    $path = [string]$ctx.Request.Url.AbsolutePath
                    if ($path.Equals("/__shutdown", [System.StringComparison]::OrdinalIgnoreCase)) {
                        $bytes = [System.Text.Encoding]::UTF8.GetBytes("shutdown")
                        $resp.StatusCode = 200
                        $resp.ContentType = "text/plain; charset=utf-8"
                        $resp.ContentLength64 = $bytes.LongLength
                        if (-not $ctx.Request.HttpMethod.Equals("HEAD", [System.StringComparison]::OrdinalIgnoreCase)) {
                            $resp.OutputStream.Write($bytes, 0, $bytes.Length)
                        }
                        break
                    }

                    $relative = [System.Uri]::UnescapeDataString($ctx.Request.Url.AbsolutePath.TrimStart('/'))
                    $relative = $relative.Replace("/", "\")
                    $fullPath = [System.IO.Path]::GetFullPath((Join-Path $rootResolved $relative))

                    $insideRoot = $fullPath.StartsWith($rootResolved, [System.StringComparison]::OrdinalIgnoreCase)
                    if ((-not $insideRoot) -or (-not (Test-Path $fullPath -PathType Leaf))) {
                        $resp.StatusCode = 404
                    }
                    else {
                        $bytes = [System.IO.File]::ReadAllBytes($fullPath)
                        $resp.StatusCode = 200
                        $resp.ContentLength64 = $bytes.LongLength
                        $resp.OutputStream.Write($bytes, 0, $bytes.Length)
                    }
                }
                catch {
                    $resp.StatusCode = 500
                }
                finally {
                    $resp.OutputStream.Close()
                }
            }
        }
        finally {
            if ($listener.IsListening) {
                $listener.Stop()
            }
            $listener.Close()
        }
    }

    Start-Sleep -Milliseconds 300
    return [pscustomobject]@{
        Job = $job
        BaseUrl = $prefix
    }
}

function Start-SmokeMockServer([int]$Port) {
    $prefix = "http://127.0.0.1:$Port/"

    $job = Start-Job -ArgumentList $prefix -ScriptBlock {
        param($serverPrefix)

        $listener = [System.Net.HttpListener]::new()
        $listener.Prefixes.Add($serverPrefix)
        $listener.Start()
        try {
            while ($true) {
                $ctx = $listener.GetContext()
                $resp = $ctx.Response
                try {
                    $path = $ctx.Request.Url.AbsolutePath
                    if ($path.Equals("/__shutdown", [System.StringComparison]::OrdinalIgnoreCase)) {
                        $bytes = [System.Text.Encoding]::UTF8.GetBytes("{""status"":""shutdown""}")
                        $resp.StatusCode = 200
                        $resp.ContentType = "application/json; charset=utf-8"
                        $resp.ContentLength64 = $bytes.LongLength
                        if (-not $ctx.Request.HttpMethod.Equals("HEAD", [System.StringComparison]::OrdinalIgnoreCase)) {
                            $resp.OutputStream.Write($bytes, 0, $bytes.Length)
                        }
                        break
                    }

                    $statusCode = 200
                    $contentType = "application/json; charset=utf-8"
                    $body = "{""status"":""ok""}"

                    switch -Regex ($path) {
                        "^/health/?$" {
                            $body = "{""status"":""ok""}"
                            break
                        }
                        "^/swagger/index\.html$" {
                            $contentType = "text/html; charset=utf-8"
                            $body = "<html><body>swagger-ui</body></html>"
                            break
                        }
                        "^/dashboard/?$" {
                            $contentType = "text/html; charset=utf-8"
                            $body = "<html><body>DataHz Monitor Board</body></html>"
                            break
                        }
                        "^/api/security/whoami$" {
                            $body = "{""user"":""guard""}"
                            break
                        }
                        "^/api/jobs/stats$" {
                            $body = "{""running"":0}"
                            break
                        }
                        "^/api/monitor/overview$" {
                            $body = "{""jobs"":[],""audit"":[]}"
                            break
                        }
                        default {
                            $statusCode = 404
                            $body = "{""error"":""not found""}"
                            break
                        }
                    }

                    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
                    $resp.StatusCode = $statusCode
                    $resp.ContentType = $contentType
                    $resp.ContentLength64 = $bytes.LongLength
                    if (-not $ctx.Request.HttpMethod.Equals("HEAD", [System.StringComparison]::OrdinalIgnoreCase)) {
                        $resp.OutputStream.Write($bytes, 0, $bytes.Length)
                    }
                }
                catch {
                    $resp.StatusCode = 500
                }
                finally {
                    $resp.OutputStream.Close()
                }
            }
        }
        finally {
            if ($listener.IsListening) {
                $listener.Stop()
            }
            $listener.Close()
        }
    }

    Start-Sleep -Milliseconds 300
    return [pscustomobject]@{
        Job = $job
        BaseUrl = $prefix
    }
}

function Start-BinarySmokeServer([int]$Port) {
    $prefix = "http://127.0.0.1:$Port/"

    $job = Start-Job -ArgumentList $prefix -ScriptBlock {
        param($serverPrefix)

        $listener = [System.Net.HttpListener]::new()
        $listener.Prefixes.Add($serverPrefix)
        $listener.Start()
        try {
            while ($true) {
                $ctx = $listener.GetContext()
                $resp = $ctx.Response
                try {
                    $path = $ctx.Request.Url.AbsolutePath
                    if ($path.Equals("/__shutdown", [System.StringComparison]::OrdinalIgnoreCase)) {
                        $bytes = [System.Text.Encoding]::UTF8.GetBytes("{""status"":""shutdown""}")
                        $resp.StatusCode = 200
                        $resp.ContentType = "application/json; charset=utf-8"
                        $resp.ContentLength64 = $bytes.LongLength
                        if (-not $ctx.Request.HttpMethod.Equals("HEAD", [System.StringComparison]::OrdinalIgnoreCase)) {
                            $resp.OutputStream.Write($bytes, 0, $bytes.Length)
                        }
                        break
                    }

                    $statusCode = 500
                    $contentType = "application/octet-stream"
                    $bytes = [byte[]](0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 255, 254, 253)

                    if ($path -match "^/health/?$") {
                        $statusCode = 200
                        $contentType = "application/json; charset=utf-8"
                        $bytes = [System.Text.Encoding]::UTF8.GetBytes("{""status"":""ok""}")
                    }

                    $resp.StatusCode = $statusCode
                    $resp.ContentType = $contentType
                    $resp.ContentLength64 = $bytes.LongLength
                    if (-not $ctx.Request.HttpMethod.Equals("HEAD", [System.StringComparison]::OrdinalIgnoreCase)) {
                        $resp.OutputStream.Write($bytes, 0, $bytes.Length)
                    }
                }
                catch {
                    $resp.StatusCode = 500
                }
                finally {
                    $resp.OutputStream.Close()
                }
            }
        }
        finally {
            if ($listener.IsListening) {
                $listener.Stop()
            }
            $listener.Close()
        }
    }

    Start-Sleep -Milliseconds 300
    return [pscustomobject]@{
        Job = $job
        BaseUrl = $prefix
    }
}

function Start-SecretEchoSmokeServer([int]$Port) {
    $prefix = "http://127.0.0.1:$Port/"

    $job = Start-Job -ArgumentList $prefix -ScriptBlock {
        param($serverPrefix)

        $listener = [System.Net.HttpListener]::new()
        $listener.Prefixes.Add($serverPrefix)
        $listener.Start()
        try {
            while ($true) {
                $ctx = $listener.GetContext()
                $resp = $ctx.Response
                try {
                    $path = $ctx.Request.Url.AbsolutePath
                    if ($path.Equals("/__shutdown", [System.StringComparison]::OrdinalIgnoreCase)) {
                        $bytes = [System.Text.Encoding]::UTF8.GetBytes("{""status"":""shutdown""}")
                        $resp.StatusCode = 200
                        $resp.ContentType = "application/json; charset=utf-8"
                        $resp.ContentLength64 = $bytes.LongLength
                        if (-not $ctx.Request.HttpMethod.Equals("HEAD", [System.StringComparison]::OrdinalIgnoreCase)) {
                            $resp.OutputStream.Write($bytes, 0, $bytes.Length)
                        }
                        break
                    }

                    $statusCode = 500
                    $contentType = "application/json; charset=utf-8"
                    $body = ""
                    $authHeader = [string]$ctx.Request.Headers["Authorization"]
                    $apiKeyHeader = [string]$ctx.Request.Headers["X-Api-Key"]
                    if ([string]::IsNullOrWhiteSpace($authHeader)) {
                        $authHeader = "<none>"
                    }
                    if ([string]::IsNullOrWhiteSpace($apiKeyHeader)) {
                        $apiKeyHeader = "<none>"
                    }

                    if ($path -match "^/health/?$") {
                        $statusCode = 200
                        $payload = [ordered]@{
                            status = "warming"
                            authorization = $authHeader
                            authorization_alt = "Bearer guard-alt-authorization-should-redact"
                            authorization_alt_stage = "Bearer guard-alt-stage-authorization-should-redact"
                            proxy_authorization = "Bearer guard-proxy-authorization-should-redact"
                            cookie = "guard-cookie-header-should-redact"
                            cookie_alt = "guard-cookie-alt-header-should-redact"
                            "cookie.alt" = "guard-cookie-dot-alt-header-should-redact"
                            "set-cookie" = "sessionid=guard-cookie-session-should-redact; Path=/; HttpOnly"
                            "set-cookie-alt" = "sessionid=guard-cookie-alt-session-should-redact; Path=/; HttpOnly"
                            "set-cookie.alt" = "sessionid=guard-cookie-dot-alt-session-should-redact; Path=/; HttpOnly"
                            note = "free-text bearer=Bearer guard-freeform-bearer-should-redact jwt=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.guardpayload.guardsignature"
                            note_api_key = "X-Api-Key: guard-freeform-xapikey-should-redact"
                            note_basic = "free-text basic=Basic guard-freeform-basic-should-redact"
                            single_quote_note = "single-quote pairs: 'api_key'='guard-single-quote-apikey-should-redact'; 'sessionIdBackup%5Bmeta%5D'='guard-single-quote-sessionid-encoded-meta-should-redact'; 'client_secret_stage': 'guard-single-quote-client-secret-stage-should-redact'"
                            escaped_unicode_quote_note = "escaped unicode quote pairs: \u0027api_key\u0027=\u0027guard-escaped-unicode-quote-apikey-should-redact\u0027; \u0027sessionIdBackup%5Bmeta%5D\u0027:\u0027guard-escaped-unicode-quote-sessionid-meta-should-redact\u0027"
                            double_escaped_unicode_quote_note = "double escaped unicode quote pairs: \\u0027api_key\\u0027=\\u0027guard-double-escaped-unicode-quote-apikey-should-redact\\u0027; \\u0027client_secret_stage\\u0027=\\u0027guard-double-escaped-unicode-quote-client-secret-stage-should-redact\\u0027"
                            escaped_target_url = "http:\\/\\/guard-escaped-url-user:guard-escaped-url-pass@127.0.0.1\\/escaped?api_key=guard-escaped-url-apikey-should-redact&sessionIdBackup=guard-escaped-url-sessionid-should-redact#access_token=guard-escaped-url-fragment-token-should-redact"
                            escaped_delimiter_target_url = "http:\u002f\u002fguard-escaped-delim-url-user:guard-escaped-delim-url-pass\u0040127.0.0.1\u002fescaped\u003fapi_key\u003dguard-escaped-delim-url-apikey-should-redact\u0026sessionIdBackup\u003dguard-escaped-delim-url-sessionid-should-redact\u003baccess_token\u003dguard-escaped-delim-url-semicolon-token-should-redact\u0023access_token\u003dguard-escaped-delim-url-fragment-token-should-redact"
                            x_api_key = $apiKeyHeader
                            "x.api.key.alt" = "guard-x-dot-api-key-alt-should-redact"
                            "api.key.alt" = "guard-api-dot-key-alt-should-redact"
                            apiKeyAlt = "guard-api-key-camel-alt-should-redact"
                            x_api_key_alt = "guard-x-api-key-should-redact"
                            x_api_key_alt_backup = "guard-x-api-key-backup-should-redact"
                            "api_key[0]" = "guard-apikey-bracket-index-should-redact"
                            "api_key%5B0%5D" = "guard-apikey-encoded-bracket-index-should-redact"
                            "api_key%5B0%5D%5Bleaf%5D" = "guard-apikey-encoded-bracket-nested-should-redact"
                            "api_key%255B0%255D" = "guard-apikey-double-encoded-bracket-index-should-redact"
                            "api_key%255B0%255D%255Bleaf%255D" = "guard-apikey-double-encoded-bracket-nested-should-redact"
                            "api_key%25255B0%25255D" = "guard-apikey-triple-encoded-bracket-index-should-redact"
                            "api_key%25255B0%25255D%25255Bleaf%25255D" = "guard-apikey-triple-encoded-bracket-nested-should-redact"
                            "api_key%2525255B0%2525255D" = "guard-apikey-quadruple-encoded-bracket-index-should-redact"
                            "api_key%2525255B0%2525255D%2525255Bleaf%2525255D" = "guard-apikey-quadruple-encoded-bracket-nested-should-redact"
                            access_token_alt_stage = "guard-access-token-alt-stage-should-redact"
                            "access.token.stage" = "guard-access-dot-token-stage-should-redact"
                            id_token_backup = "guard-id-token-backup-should-redact"
                            "id.token.backup" = "guard-id-dot-token-backup-should-redact"
                            jwt_stage = "guard-jwt-stage-should-redact"
                            token = $apiKeyHeader
                            access_token = $authHeader
                            refresh_token = "guard-refresh-token-should-redact"
                            "refresh.token.alt" = "guard-refresh-dot-token-alt-should-redact"
                            "proxy.authorization.alt" = "Bearer guard-proxy-dot-authorization-alt-should-redact"
                            client_secret = "guard-client-secret-should-redact"
                            client_secret_stage = "guard-client-secret-stage-should-redact"
                            "client_secret.stage" = "guard-client-secret-dot-stage-should-redact"
                            "client.secret.stage" = "guard-client-dot-secret-stage-should-redact"
                            secret = "guard-plain-secret-should-redact"
                            secret_backup = "guard-plain-secret-backup-should-redact"
                            "secret.backup" = "guard-plain-secret-dot-backup-should-redact"
                            password = "guard-password-should-redact"
                            password_temp = "guard-password-temp-should-redact"
                            "password.temp" = "guard-password-dot-temp-should-redact"
                            sessionid_backup = "guard-sessionid-backup-should-redact"
                            "sessionid.backup" = "guard-sessionid-dot-backup-should-redact"
                            "session.id.backup" = "guard-session-dot-id-backup-should-redact"
                            sessionIdBackup = "guard-session-id-camel-backup-should-redact"
                            "sessionIdBackup[meta]" = "guard-sessionid-camel-bracket-meta-should-redact"
                            "sessionIdBackup%5Bmeta%5D" = "guard-sessionid-camel-encoded-bracket-meta-should-redact"
                            "sessionIdBackup%5Bmeta%5D%5B0%5D" = "guard-sessionid-camel-encoded-bracket-nested-should-redact"
                            "sessionIdBackup%255Bmeta%255D" = "guard-sessionid-camel-double-encoded-bracket-meta-should-redact"
                            "sessionIdBackup%255Bmeta%255D%255B0%255D" = "guard-sessionid-camel-double-encoded-bracket-nested-should-redact"
                            "sessionIdBackup%25255Bmeta%25255D" = "guard-sessionid-camel-triple-encoded-bracket-meta-should-redact"
                            "sessionIdBackup%25255Bmeta%25255D%25255B0%25255D" = "guard-sessionid-camel-triple-encoded-bracket-nested-should-redact"
                            "sessionIdBackup%2525255Bmeta%2525255D" = "guard-sessionid-camel-quadruple-encoded-bracket-meta-should-redact"
                            "sessionIdBackup%2525255Bmeta%2525255D%2525255B0%2525255D" = "guard-sessionid-camel-quadruple-encoded-bracket-nested-should-redact"
                            nested_secret_fields = [ordered]@{
                                api_key = "guard-nested-apikey-should-redact"
                                "api_key%255B0%255D" = "guard-nested-apikey-double-encoded-bracket-index-should-redact"
                                client_secret_stage = "guard-nested-client-secret-stage-should-redact"
                                "sessionIdBackup%5Bmeta%5D" = "guard-nested-sessionid-encoded-bracket-meta-should-redact"
                                "sessionIdBackup%255Bmeta%255D%255B0%255D" = "guard-nested-sessionid-double-encoded-bracket-nested-should-redact"
                            }
                            nested_secret_items = @(
                                [ordered]@{
                                    password_temp = "guard-nested-password-temp-should-redact"
                                    cookie_alt = "guard-nested-cookie-alt-should-redact"
                                }
                            )
                            "set.cookie.alt" = "sessionid=guard-set-dot-cookie-alt-session-should-redact; Path=/; HttpOnly"
                            jwt = $authHeader
                            target_url = "http://guard-url-user:guard-url-pass@127.0.0.1/internal?access_token=guard-url-token-should-redact&access_token_alt_stage=guard-url-access-token-alt-stage-should-redact&access.token.stage=guard-url-access-dot-token-stage-should-redact&id_token_backup=guard-url-id-token-backup-should-redact&id.token.backup=guard-url-id-dot-token-backup-should-redact&jwt_stage=guard-url-jwt-stage-should-redact&api_key=guard-url-apikey-should-redact&api.key.alt=guard-url-api-dot-key-alt-should-redact&apiKeyAlt=guard-url-api-key-camel-alt-should-redact&x_api_key=guard-url-xapikey-should-redact&x_api_key_alt_backup=guard-url-xapikey-backup-should-redact&x.api.key.alt=guard-url-x-dot-api-key-alt-should-redact&api_key[0]=guard-url-apikey-bracket-index-should-redact&api_key%5B0%5D=guard-url-apikey-encoded-bracket-index-should-redact&api_key%5B0%5D%5Bleaf%5D=guard-url-apikey-encoded-bracket-nested-should-redact&api_key%255B0%255D=guard-url-apikey-double-encoded-bracket-index-should-redact&api_key%255B0%255D%255Bleaf%255D=guard-url-apikey-double-encoded-bracket-nested-should-redact&api_key%25255B0%25255D=guard-url-apikey-triple-encoded-bracket-index-should-redact&api_key%25255B0%25255D%25255Bleaf%25255D=guard-url-apikey-triple-encoded-bracket-nested-should-redact&api_key%2525255B0%2525255D=guard-url-apikey-quadruple-encoded-bracket-index-should-redact&api_key%2525255B0%2525255D%2525255Bleaf%2525255D=guard-url-apikey-quadruple-encoded-bracket-nested-should-redact&api_key%2525255b0%2525255d=guard-url-apikey-quadruple-encoded-bracket-lowerhex-index-should-redact&api_key%2525255b0%2525255d%2525255bleaf%2525255d=guard-url-apikey-quadruple-encoded-bracket-lowerhex-nested-should-redact&api_key%25255b0%25255d=guard-url-apikey-triple-encoded-bracket-lowerhex-index-should-redact&api_key%25255b0%25255d%25255bleaf%25255d=guard-url-apikey-triple-encoded-bracket-lowerhex-nested-should-redact&api_key%255b0%255d=guard-url-apikey-double-encoded-bracket-lowerhex-index-should-redact&api_key%255b0%255d%255bleaf%255d=guard-url-apikey-double-encoded-bracket-lowerhex-nested-should-redact&api_key%5b0%5d=guard-url-apikey-encoded-bracket-lowerhex-index-should-redact&api_key%5b0%5d%5bleaf%5d=guard-url-apikey-encoded-bracket-lowerhex-nested-should-redact&client_secret=guard-client-secret-should-redact&client_secret_stage=guard-url-client-secret-stage-should-redact&client_secret.stage=guard-url-client-secret-dot-stage-should-redact&client.secret.stage=guard-url-client-dot-secret-stage-should-redact&secret_backup=guard-url-secret-backup-should-redact&secret.backup=guard-url-secret-dot-backup-should-redact&password=guard-url-password-should-redact&password_temp=guard-url-password-temp-should-redact&password.temp=guard-url-password-dot-temp-should-redact&refresh.token.alt=guard-url-refresh-dot-token-alt-should-redact&authorization=guard-url-authorization-should-redact&authorization_alt_stage=guard-url-authorization-alt-stage-should-redact&proxy_authorization=Basic%20guard-url-basic-should-redact&proxy.authorization.alt=guard-url-proxy-dot-authorization-alt-should-redact&cookie=guard-url-cookie-should-redact&cookie_alt=guard-url-cookie-alt-should-redact&cookie.alt=guard-url-cookie-dot-alt-should-redact&set-cookie-alt=guard-url-set-cookie-alt-should-redact&set-cookie.alt=guard-url-set-cookie-dot-alt-should-redact&set.cookie.alt=guard-url-set-dot-cookie-alt-should-redact&sessionid=guard-url-session-should-redact&sessionid_backup=guard-url-sessionid-backup-should-redact&sessionid.backup=guard-url-sessionid-dot-backup-should-redact&session.id.backup=guard-url-session-dot-id-backup-should-redact&sessionIdBackup=guard-url-session-id-camel-backup-should-redact&sessionIdBackup[meta]=guard-url-sessionid-camel-bracket-meta-should-redact&sessionIdBackup%5Bmeta%5D=guard-url-sessionid-camel-encoded-bracket-meta-should-redact&sessionIdBackup%5Bmeta%5D%5B0%5D=guard-url-sessionid-camel-encoded-bracket-nested-should-redact&sessionIdBackup%255Bmeta%255D=guard-url-sessionid-camel-double-encoded-bracket-meta-should-redact&sessionIdBackup%255Bmeta%255D%255B0%255D=guard-url-sessionid-camel-double-encoded-bracket-nested-should-redact&sessionIdBackup%25255Bmeta%25255D=guard-url-sessionid-camel-triple-encoded-bracket-meta-should-redact&sessionIdBackup%25255Bmeta%25255D%25255B0%25255D=guard-url-sessionid-camel-triple-encoded-bracket-nested-should-redact&sessionIdBackup%2525255Bmeta%2525255D=guard-url-sessionid-camel-quadruple-encoded-bracket-meta-should-redact&sessionIdBackup%2525255Bmeta%2525255D%2525255B0%2525255D=guard-url-sessionid-camel-quadruple-encoded-bracket-nested-should-redact&sessionIdBackup%2525255bmeta%2525255d=guard-url-sessionid-camel-quadruple-encoded-bracket-lowerhex-meta-should-redact&sessionIdBackup%2525255bmeta%2525255d%2525255b0%2525255d=guard-url-sessionid-camel-quadruple-encoded-bracket-lowerhex-nested-should-redact&sessionIdBackup%25255bmeta%25255d=guard-url-sessionid-camel-triple-encoded-bracket-lowerhex-meta-should-redact&sessionIdBackup%25255bmeta%25255d%25255b0%25255d=guard-url-sessionid-camel-triple-encoded-bracket-lowerhex-nested-should-redact&sessionIdBackup%255bmeta%255d=guard-url-sessionid-camel-double-encoded-bracket-lowerhex-meta-should-redact&sessionIdBackup%255bmeta%255d%255b0%255d=guard-url-sessionid-camel-double-encoded-bracket-lowerhex-nested-should-redact&sessionIdBackup%5bmeta%5d=guard-url-sessionid-camel-encoded-bracket-lowerhex-meta-should-redact&sessionIdBackup%5bmeta%5d%5b0%5d=guard-url-sessionid-camel-encoded-bracket-lowerhex-nested-should-redact;access_token=guard-url-semicolon-token-should-redact;apiKeyAlt=guard-url-semicolon-apikey-camel-alt-should-redact#access_token=guard-url-fragment-token-should-redact&apiKeyAlt=guard-url-fragment-apikey-camel-alt-should-redact&sessionIdBackup=guard-url-fragment-sessionid-camel-backup-should-redact&api_key%5B0%5D=guard-url-fragment-apikey-encoded-bracket-index-should-redact&sessionIdBackup%5Bmeta%5D=guard-url-fragment-sessionid-encoded-bracket-meta-should-redact&api_key%5B0%5D%5Bleaf%5D=guard-url-fragment-apikey-encoded-bracket-nested-should-redact&sessionIdBackup%5Bmeta%5D%5B0%5D=guard-url-fragment-sessionid-encoded-bracket-nested-should-redact&api_key%255B0%255D=guard-url-fragment-apikey-double-encoded-bracket-index-should-redact&sessionIdBackup%255Bmeta%255D=guard-url-fragment-sessionid-double-encoded-bracket-meta-should-redact&api_key%255B0%255D%255Bleaf%255D=guard-url-fragment-apikey-double-encoded-bracket-nested-should-redact&sessionIdBackup%255Bmeta%255D%255B0%255D=guard-url-fragment-sessionid-double-encoded-bracket-nested-should-redact&api_key%25255B0%25255D=guard-url-fragment-apikey-triple-encoded-bracket-index-should-redact&sessionIdBackup%25255Bmeta%25255D=guard-url-fragment-sessionid-triple-encoded-bracket-meta-should-redact&api_key%25255B0%25255D%25255Bleaf%25255D=guard-url-fragment-apikey-triple-encoded-bracket-nested-should-redact&sessionIdBackup%25255Bmeta%25255D%25255B0%25255D=guard-url-fragment-sessionid-triple-encoded-bracket-nested-should-redact&api_key%2525255B0%2525255D=guard-url-fragment-apikey-quadruple-encoded-bracket-index-should-redact&sessionIdBackup%2525255Bmeta%2525255D=guard-url-fragment-sessionid-quadruple-encoded-bracket-meta-should-redact&api_key%2525255B0%2525255D%2525255Bleaf%2525255D=guard-url-fragment-apikey-quadruple-encoded-bracket-nested-should-redact&sessionIdBackup%2525255Bmeta%2525255D%2525255B0%2525255D=guard-url-fragment-sessionid-quadruple-encoded-bracket-nested-should-redact&api_key%2525255b0%2525255d=guard-url-fragment-apikey-quadruple-encoded-bracket-lowerhex-index-should-redact&sessionIdBackup%2525255bmeta%2525255d=guard-url-fragment-sessionid-quadruple-encoded-bracket-lowerhex-meta-should-redact&api_key%2525255b0%2525255d%2525255bleaf%2525255d=guard-url-fragment-apikey-quadruple-encoded-bracket-lowerhex-nested-should-redact&sessionIdBackup%2525255bmeta%2525255d%2525255b0%2525255d=guard-url-fragment-sessionid-quadruple-encoded-bracket-lowerhex-nested-should-redact&api_key%25255b0%25255d=guard-url-fragment-apikey-triple-encoded-bracket-lowerhex-index-should-redact&sessionIdBackup%25255bmeta%25255d=guard-url-fragment-sessionid-triple-encoded-bracket-lowerhex-meta-should-redact&api_key%25255b0%25255d%25255bleaf%25255d=guard-url-fragment-apikey-triple-encoded-bracket-lowerhex-nested-should-redact&sessionIdBackup%25255bmeta%25255d%25255b0%25255d=guard-url-fragment-sessionid-triple-encoded-bracket-lowerhex-nested-should-redact&api_key%255b0%255d=guard-url-fragment-apikey-double-encoded-bracket-lowerhex-index-should-redact&sessionIdBackup%255bmeta%255d=guard-url-fragment-sessionid-double-encoded-bracket-lowerhex-meta-should-redact&api_key%255b0%255d%255bleaf%255d=guard-url-fragment-apikey-double-encoded-bracket-lowerhex-nested-should-redact&sessionIdBackup%255bmeta%255d%255b0%255d=guard-url-fragment-sessionid-double-encoded-bracket-lowerhex-nested-should-redact&api_key%5b0%5d=guard-url-fragment-apikey-encoded-bracket-lowerhex-index-should-redact&sessionIdBackup%5bmeta%5d=guard-url-fragment-sessionid-encoded-bracket-lowerhex-meta-should-redact&api_key%5b0%5d%5bleaf%5d=guard-url-fragment-apikey-encoded-bracket-lowerhex-nested-should-redact&sessionIdBackup%5bmeta%5d%5b0%5d=guard-url-fragment-sessionid-encoded-bracket-lowerhex-nested-should-redact;access_token=guard-url-fragment-semicolon-token-should-redact;apiKeyAlt=guard-url-fragment-semicolon-apikey-camel-alt-should-redact"
                        }
                        $body = ($payload | ConvertTo-Json -Compress -Depth 12)
                    }
                    else {
                        $payload = [ordered]@{
                            error = "simulated-failure"
                            authorization = $authHeader
                            authorization_alt = "Bearer guard-alt-authorization-should-redact"
                            authorization_alt_stage = "Bearer guard-alt-stage-authorization-should-redact"
                            proxy_authorization = "Bearer guard-proxy-authorization-should-redact"
                            cookie = "guard-cookie-header-should-redact"
                            cookie_alt = "guard-cookie-alt-header-should-redact"
                            "cookie.alt" = "guard-cookie-dot-alt-header-should-redact"
                            "set-cookie" = "sessionid=guard-cookie-session-should-redact; Path=/; HttpOnly"
                            "set-cookie-alt" = "sessionid=guard-cookie-alt-session-should-redact; Path=/; HttpOnly"
                            "set-cookie.alt" = "sessionid=guard-cookie-dot-alt-session-should-redact; Path=/; HttpOnly"
                            note = "free-text bearer=Bearer guard-freeform-bearer-should-redact jwt=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.guardpayload.guardsignature"
                            note_api_key = "X-Api-Key: guard-freeform-xapikey-should-redact"
                            note_basic = "free-text basic=Basic guard-freeform-basic-should-redact"
                            single_quote_note = "single-quote pairs: 'api_key'='guard-single-quote-apikey-should-redact'; 'sessionIdBackup%5Bmeta%5D'='guard-single-quote-sessionid-encoded-meta-should-redact'; 'client_secret_stage': 'guard-single-quote-client-secret-stage-should-redact'"
                            escaped_unicode_quote_note = "escaped unicode quote pairs: \u0027api_key\u0027=\u0027guard-escaped-unicode-quote-apikey-should-redact\u0027; \u0027sessionIdBackup%5Bmeta%5D\u0027:\u0027guard-escaped-unicode-quote-sessionid-meta-should-redact\u0027"
                            double_escaped_unicode_quote_note = "double escaped unicode quote pairs: \\u0027api_key\\u0027=\\u0027guard-double-escaped-unicode-quote-apikey-should-redact\\u0027; \\u0027client_secret_stage\\u0027=\\u0027guard-double-escaped-unicode-quote-client-secret-stage-should-redact\\u0027"
                            escaped_target_url = "http:\\/\\/guard-escaped-url-user:guard-escaped-url-pass@127.0.0.1\\/escaped?api_key=guard-escaped-url-apikey-should-redact&sessionIdBackup=guard-escaped-url-sessionid-should-redact#access_token=guard-escaped-url-fragment-token-should-redact"
                            escaped_delimiter_target_url = "http:\u002f\u002fguard-escaped-delim-url-user:guard-escaped-delim-url-pass\u0040127.0.0.1\u002fescaped\u003fapi_key\u003dguard-escaped-delim-url-apikey-should-redact\u0026sessionIdBackup\u003dguard-escaped-delim-url-sessionid-should-redact\u003baccess_token\u003dguard-escaped-delim-url-semicolon-token-should-redact\u0023access_token\u003dguard-escaped-delim-url-fragment-token-should-redact"
                            x_api_key = $apiKeyHeader
                            "x.api.key.alt" = "guard-x-dot-api-key-alt-should-redact"
                            "api.key.alt" = "guard-api-dot-key-alt-should-redact"
                            apiKeyAlt = "guard-api-key-camel-alt-should-redact"
                            x_api_key_alt = "guard-x-api-key-should-redact"
                            x_api_key_alt_backup = "guard-x-api-key-backup-should-redact"
                            "api_key[0]" = "guard-apikey-bracket-index-should-redact"
                            "api_key%5b0%5d" = "guard-apikey-encoded-bracket-lowerhex-index-should-redact"
                            "api_key%5b0%5d%5bleaf%5d" = "guard-apikey-encoded-bracket-lowerhex-nested-should-redact"
                            "api_key%255b0%255d" = "guard-apikey-double-encoded-bracket-lowerhex-index-should-redact"
                            "api_key%255b0%255d%255bleaf%255d" = "guard-apikey-double-encoded-bracket-lowerhex-nested-should-redact"
                            "api_key%25255b0%25255d" = "guard-apikey-triple-encoded-bracket-lowerhex-index-should-redact"
                            "api_key%25255b0%25255d%25255bleaf%25255d" = "guard-apikey-triple-encoded-bracket-lowerhex-nested-should-redact"
                            "api_key%2525255b0%2525255d" = "guard-apikey-quadruple-encoded-bracket-lowerhex-index-should-redact"
                            "api_key%2525255b0%2525255d%2525255bleaf%2525255d" = "guard-apikey-quadruple-encoded-bracket-lowerhex-nested-should-redact"
                            access_token_alt_stage = "guard-access-token-alt-stage-should-redact"
                            "access.token.stage" = "guard-access-dot-token-stage-should-redact"
                            id_token_backup = "guard-id-token-backup-should-redact"
                            "id.token.backup" = "guard-id-dot-token-backup-should-redact"
                            jwt_stage = "guard-jwt-stage-should-redact"
                            token = $apiKeyHeader
                            access_token = $authHeader
                            refresh_token = "guard-refresh-token-should-redact"
                            "refresh.token.alt" = "guard-refresh-dot-token-alt-should-redact"
                            "proxy.authorization.alt" = "Bearer guard-proxy-dot-authorization-alt-should-redact"
                            client_secret = "guard-client-secret-should-redact"
                            client_secret_stage = "guard-client-secret-stage-should-redact"
                            "client_secret.stage" = "guard-client-secret-dot-stage-should-redact"
                            "client.secret.stage" = "guard-client-dot-secret-stage-should-redact"
                            secret = "guard-plain-secret-should-redact"
                            secret_backup = "guard-plain-secret-backup-should-redact"
                            "secret.backup" = "guard-plain-secret-dot-backup-should-redact"
                            password = "guard-password-should-redact"
                            password_temp = "guard-password-temp-should-redact"
                            "password.temp" = "guard-password-dot-temp-should-redact"
                            sessionid_backup = "guard-sessionid-backup-should-redact"
                            "sessionid.backup" = "guard-sessionid-dot-backup-should-redact"
                            "session.id.backup" = "guard-session-dot-id-backup-should-redact"
                            sessionIdBackup = "guard-session-id-camel-backup-should-redact"
                            "sessionIdBackup[meta]" = "guard-sessionid-camel-bracket-meta-should-redact"
                            "sessionIdBackup%5bmeta%5d" = "guard-sessionid-camel-encoded-bracket-lowerhex-meta-should-redact"
                            "sessionIdBackup%5bmeta%5d%5b0%5d" = "guard-sessionid-camel-encoded-bracket-lowerhex-nested-should-redact"
                            "sessionIdBackup%255bmeta%255d" = "guard-sessionid-camel-double-encoded-bracket-lowerhex-meta-should-redact"
                            "sessionIdBackup%255bmeta%255d%255b0%255d" = "guard-sessionid-camel-double-encoded-bracket-lowerhex-nested-should-redact"
                            "sessionIdBackup%25255bmeta%25255d" = "guard-sessionid-camel-triple-encoded-bracket-lowerhex-meta-should-redact"
                            "sessionIdBackup%25255bmeta%25255d%25255b0%25255d" = "guard-sessionid-camel-triple-encoded-bracket-lowerhex-nested-should-redact"
                            "sessionIdBackup%2525255bmeta%2525255d" = "guard-sessionid-camel-quadruple-encoded-bracket-lowerhex-meta-should-redact"
                            "sessionIdBackup%2525255bmeta%2525255d%2525255b0%2525255d" = "guard-sessionid-camel-quadruple-encoded-bracket-lowerhex-nested-should-redact"
                            nested_secret_fields = [ordered]@{
                                api_key = "guard-nested-apikey-should-redact"
                                "api_key%255B0%255D" = "guard-nested-apikey-double-encoded-bracket-index-should-redact"
                                client_secret_stage = "guard-nested-client-secret-stage-should-redact"
                                "sessionIdBackup%5Bmeta%5D" = "guard-nested-sessionid-encoded-bracket-meta-should-redact"
                                "sessionIdBackup%255Bmeta%255D%255B0%255D" = "guard-nested-sessionid-double-encoded-bracket-nested-should-redact"
                            }
                            nested_secret_items = @(
                                [ordered]@{
                                    password_temp = "guard-nested-password-temp-should-redact"
                                    cookie_alt = "guard-nested-cookie-alt-should-redact"
                                }
                            )
                            "set.cookie.alt" = "sessionid=guard-set-dot-cookie-alt-session-should-redact; Path=/; HttpOnly"
                            jwt = $authHeader
                            target_url = "http://guard-url-user:guard-url-pass@127.0.0.1/internal?access_token=guard-url-token-should-redact&access_token_alt_stage=guard-url-access-token-alt-stage-should-redact&access.token.stage=guard-url-access-dot-token-stage-should-redact&id_token_backup=guard-url-id-token-backup-should-redact&id.token.backup=guard-url-id-dot-token-backup-should-redact&jwt_stage=guard-url-jwt-stage-should-redact&api_key=guard-url-apikey-should-redact&api.key.alt=guard-url-api-dot-key-alt-should-redact&apiKeyAlt=guard-url-api-key-camel-alt-should-redact&x_api_key=guard-url-xapikey-should-redact&x_api_key_alt_backup=guard-url-xapikey-backup-should-redact&x.api.key.alt=guard-url-x-dot-api-key-alt-should-redact&api_key[0]=guard-url-apikey-bracket-index-should-redact&api_key%5B0%5D=guard-url-apikey-encoded-bracket-index-should-redact&api_key%5B0%5D%5Bleaf%5D=guard-url-apikey-encoded-bracket-nested-should-redact&api_key%255B0%255D=guard-url-apikey-double-encoded-bracket-index-should-redact&api_key%255B0%255D%255Bleaf%255D=guard-url-apikey-double-encoded-bracket-nested-should-redact&api_key%25255B0%25255D=guard-url-apikey-triple-encoded-bracket-index-should-redact&api_key%25255B0%25255D%25255Bleaf%25255D=guard-url-apikey-triple-encoded-bracket-nested-should-redact&api_key%2525255B0%2525255D=guard-url-apikey-quadruple-encoded-bracket-index-should-redact&api_key%2525255B0%2525255D%2525255Bleaf%2525255D=guard-url-apikey-quadruple-encoded-bracket-nested-should-redact&api_key%2525255b0%2525255d=guard-url-apikey-quadruple-encoded-bracket-lowerhex-index-should-redact&api_key%2525255b0%2525255d%2525255bleaf%2525255d=guard-url-apikey-quadruple-encoded-bracket-lowerhex-nested-should-redact&api_key%25255b0%25255d=guard-url-apikey-triple-encoded-bracket-lowerhex-index-should-redact&api_key%25255b0%25255d%25255bleaf%25255d=guard-url-apikey-triple-encoded-bracket-lowerhex-nested-should-redact&api_key%255b0%255d=guard-url-apikey-double-encoded-bracket-lowerhex-index-should-redact&api_key%255b0%255d%255bleaf%255d=guard-url-apikey-double-encoded-bracket-lowerhex-nested-should-redact&api_key%5b0%5d=guard-url-apikey-encoded-bracket-lowerhex-index-should-redact&api_key%5b0%5d%5bleaf%5d=guard-url-apikey-encoded-bracket-lowerhex-nested-should-redact&client_secret=guard-client-secret-should-redact&client_secret_stage=guard-url-client-secret-stage-should-redact&client_secret.stage=guard-url-client-secret-dot-stage-should-redact&client.secret.stage=guard-url-client-dot-secret-stage-should-redact&secret_backup=guard-url-secret-backup-should-redact&secret.backup=guard-url-secret-dot-backup-should-redact&password=guard-url-password-should-redact&password_temp=guard-url-password-temp-should-redact&password.temp=guard-url-password-dot-temp-should-redact&refresh.token.alt=guard-url-refresh-dot-token-alt-should-redact&authorization=guard-url-authorization-should-redact&authorization_alt_stage=guard-url-authorization-alt-stage-should-redact&proxy_authorization=Basic%20guard-url-basic-should-redact&proxy.authorization.alt=guard-url-proxy-dot-authorization-alt-should-redact&cookie=guard-url-cookie-should-redact&cookie_alt=guard-url-cookie-alt-should-redact&cookie.alt=guard-url-cookie-dot-alt-should-redact&set-cookie-alt=guard-url-set-cookie-alt-should-redact&set-cookie.alt=guard-url-set-cookie-dot-alt-should-redact&set.cookie.alt=guard-url-set-dot-cookie-alt-should-redact&sessionid=guard-url-session-should-redact&sessionid_backup=guard-url-sessionid-backup-should-redact&sessionid.backup=guard-url-sessionid-dot-backup-should-redact&session.id.backup=guard-url-session-dot-id-backup-should-redact&sessionIdBackup=guard-url-session-id-camel-backup-should-redact&sessionIdBackup[meta]=guard-url-sessionid-camel-bracket-meta-should-redact&sessionIdBackup%5Bmeta%5D=guard-url-sessionid-camel-encoded-bracket-meta-should-redact&sessionIdBackup%5Bmeta%5D%5B0%5D=guard-url-sessionid-camel-encoded-bracket-nested-should-redact&sessionIdBackup%255Bmeta%255D=guard-url-sessionid-camel-double-encoded-bracket-meta-should-redact&sessionIdBackup%255Bmeta%255D%255B0%255D=guard-url-sessionid-camel-double-encoded-bracket-nested-should-redact&sessionIdBackup%25255Bmeta%25255D=guard-url-sessionid-camel-triple-encoded-bracket-meta-should-redact&sessionIdBackup%25255Bmeta%25255D%25255B0%25255D=guard-url-sessionid-camel-triple-encoded-bracket-nested-should-redact&sessionIdBackup%2525255Bmeta%2525255D=guard-url-sessionid-camel-quadruple-encoded-bracket-meta-should-redact&sessionIdBackup%2525255Bmeta%2525255D%2525255B0%2525255D=guard-url-sessionid-camel-quadruple-encoded-bracket-nested-should-redact&sessionIdBackup%2525255bmeta%2525255d=guard-url-sessionid-camel-quadruple-encoded-bracket-lowerhex-meta-should-redact&sessionIdBackup%2525255bmeta%2525255d%2525255b0%2525255d=guard-url-sessionid-camel-quadruple-encoded-bracket-lowerhex-nested-should-redact&sessionIdBackup%25255bmeta%25255d=guard-url-sessionid-camel-triple-encoded-bracket-lowerhex-meta-should-redact&sessionIdBackup%25255bmeta%25255d%25255b0%25255d=guard-url-sessionid-camel-triple-encoded-bracket-lowerhex-nested-should-redact&sessionIdBackup%255bmeta%255d=guard-url-sessionid-camel-double-encoded-bracket-lowerhex-meta-should-redact&sessionIdBackup%255bmeta%255d%255b0%255d=guard-url-sessionid-camel-double-encoded-bracket-lowerhex-nested-should-redact&sessionIdBackup%5bmeta%5d=guard-url-sessionid-camel-encoded-bracket-lowerhex-meta-should-redact&sessionIdBackup%5bmeta%5d%5b0%5d=guard-url-sessionid-camel-encoded-bracket-lowerhex-nested-should-redact;access_token=guard-url-semicolon-token-should-redact;apiKeyAlt=guard-url-semicolon-apikey-camel-alt-should-redact#access_token=guard-url-fragment-token-should-redact&apiKeyAlt=guard-url-fragment-apikey-camel-alt-should-redact&sessionIdBackup=guard-url-fragment-sessionid-camel-backup-should-redact&api_key%5B0%5D=guard-url-fragment-apikey-encoded-bracket-index-should-redact&sessionIdBackup%5Bmeta%5D=guard-url-fragment-sessionid-encoded-bracket-meta-should-redact&api_key%5B0%5D%5Bleaf%5D=guard-url-fragment-apikey-encoded-bracket-nested-should-redact&sessionIdBackup%5Bmeta%5D%5B0%5D=guard-url-fragment-sessionid-encoded-bracket-nested-should-redact&api_key%255B0%255D=guard-url-fragment-apikey-double-encoded-bracket-index-should-redact&sessionIdBackup%255Bmeta%255D=guard-url-fragment-sessionid-double-encoded-bracket-meta-should-redact&api_key%255B0%255D%255Bleaf%255D=guard-url-fragment-apikey-double-encoded-bracket-nested-should-redact&sessionIdBackup%255Bmeta%255D%255B0%255D=guard-url-fragment-sessionid-double-encoded-bracket-nested-should-redact&api_key%25255B0%25255D=guard-url-fragment-apikey-triple-encoded-bracket-index-should-redact&sessionIdBackup%25255Bmeta%25255D=guard-url-fragment-sessionid-triple-encoded-bracket-meta-should-redact&api_key%25255B0%25255D%25255Bleaf%25255D=guard-url-fragment-apikey-triple-encoded-bracket-nested-should-redact&sessionIdBackup%25255Bmeta%25255D%25255B0%25255D=guard-url-fragment-sessionid-triple-encoded-bracket-nested-should-redact&api_key%2525255B0%2525255D=guard-url-fragment-apikey-quadruple-encoded-bracket-index-should-redact&sessionIdBackup%2525255Bmeta%2525255D=guard-url-fragment-sessionid-quadruple-encoded-bracket-meta-should-redact&api_key%2525255B0%2525255D%2525255Bleaf%2525255D=guard-url-fragment-apikey-quadruple-encoded-bracket-nested-should-redact&sessionIdBackup%2525255Bmeta%2525255D%2525255B0%2525255D=guard-url-fragment-sessionid-quadruple-encoded-bracket-nested-should-redact&api_key%2525255b0%2525255d=guard-url-fragment-apikey-quadruple-encoded-bracket-lowerhex-index-should-redact&sessionIdBackup%2525255bmeta%2525255d=guard-url-fragment-sessionid-quadruple-encoded-bracket-lowerhex-meta-should-redact&api_key%2525255b0%2525255d%2525255bleaf%2525255d=guard-url-fragment-apikey-quadruple-encoded-bracket-lowerhex-nested-should-redact&sessionIdBackup%2525255bmeta%2525255d%2525255b0%2525255d=guard-url-fragment-sessionid-quadruple-encoded-bracket-lowerhex-nested-should-redact&api_key%25255b0%25255d=guard-url-fragment-apikey-triple-encoded-bracket-lowerhex-index-should-redact&sessionIdBackup%25255bmeta%25255d=guard-url-fragment-sessionid-triple-encoded-bracket-lowerhex-meta-should-redact&api_key%25255b0%25255d%25255bleaf%25255d=guard-url-fragment-apikey-triple-encoded-bracket-lowerhex-nested-should-redact&sessionIdBackup%25255bmeta%25255d%25255b0%25255d=guard-url-fragment-sessionid-triple-encoded-bracket-lowerhex-nested-should-redact&api_key%255b0%255d=guard-url-fragment-apikey-double-encoded-bracket-lowerhex-index-should-redact&sessionIdBackup%255bmeta%255d=guard-url-fragment-sessionid-double-encoded-bracket-lowerhex-meta-should-redact&api_key%255b0%255d%255bleaf%255d=guard-url-fragment-apikey-double-encoded-bracket-lowerhex-nested-should-redact&sessionIdBackup%255bmeta%255d%255b0%255d=guard-url-fragment-sessionid-double-encoded-bracket-lowerhex-nested-should-redact&api_key%5b0%5d=guard-url-fragment-apikey-encoded-bracket-lowerhex-index-should-redact&sessionIdBackup%5bmeta%5d=guard-url-fragment-sessionid-encoded-bracket-lowerhex-meta-should-redact&api_key%5b0%5d%5bleaf%5d=guard-url-fragment-apikey-encoded-bracket-lowerhex-nested-should-redact&sessionIdBackup%5bmeta%5d%5b0%5d=guard-url-fragment-sessionid-encoded-bracket-lowerhex-nested-should-redact;access_token=guard-url-fragment-semicolon-token-should-redact;apiKeyAlt=guard-url-fragment-semicolon-apikey-camel-alt-should-redact"
                        }
                        $body = ($payload | ConvertTo-Json -Compress -Depth 12)
                    }

                    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
                    $resp.StatusCode = $statusCode
                    $resp.ContentType = $contentType
                    $resp.ContentLength64 = $bytes.LongLength
                    if (-not $ctx.Request.HttpMethod.Equals("HEAD", [System.StringComparison]::OrdinalIgnoreCase)) {
                        $resp.OutputStream.Write($bytes, 0, $bytes.Length)
                    }
                }
                catch {
                    $resp.StatusCode = 500
                }
                finally {
                    $resp.OutputStream.Close()
                }
            }
        }
        finally {
            if ($listener.IsListening) {
                $listener.Stop()
            }
            $listener.Close()
        }
    }

    Start-Sleep -Milliseconds 300
    return [pscustomobject]@{
        Job = $job
        BaseUrl = $prefix
    }
}

function Test-IsValidPublishDir([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    if (-not (Test-Path $Path)) {
        return $false
    }

    $exe = Join-Path $Path "DataHz.Api.exe"
    $dll = Join-Path $Path "DataHz.Api.dll"
    return (Test-Path $exe) -or (Test-Path $dll)
}

function Stop-ListenerServer([psobject]$Server) {
    if ($null -eq $Server) {
        return
    }

    $baseUrl = ""
    if ($Server.PSObject.Properties.Match("BaseUrl").Count -gt 0) {
        $baseUrl = [string]$Server.BaseUrl
    }

    if (-not [string]::IsNullOrWhiteSpace($baseUrl)) {
        $shutdownUrl = $baseUrl
        if (-not $shutdownUrl.EndsWith("/")) {
            $shutdownUrl += "/"
        }
        $shutdownUrl += "__shutdown"
        try {
            Invoke-WebRequest -Uri $shutdownUrl -Method Get -UseBasicParsing -TimeoutSec 2 | Out-Null
        }
        catch {
        }
    }

    if ($Server.PSObject.Properties.Match("Job").Count -gt 0 -and $Server.Job) {
        Stop-Job -Job $Server.Job -ErrorAction SilentlyContinue
        Remove-Job -Job $Server.Job -Force -ErrorAction SilentlyContinue
    }
}

function Resolve-PublishDirForAutoPackage([string]$Root, [string]$PackageName) {
    $publishRoot = Join-Path $Root "artifacts\publish"
    if (-not (Test-Path $publishRoot)) {
        return ""
    }

    $candidates = New-Object System.Collections.Generic.List[string]
    $named = Join-Path $publishRoot $PackageName
    if (Test-Path $named) {
        $candidates.Add([System.IO.Path]::GetFullPath($named))
    }

    $verifyFd = Join-Path $publishRoot "verify-fd"
    if (Test-Path $verifyFd) {
        $candidates.Add([System.IO.Path]::GetFullPath($verifyFd))
    }

    $candidates.Add([System.IO.Path]::GetFullPath($publishRoot))

    $childDirs = @(Get-ChildItem -Path $publishRoot -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending)
    foreach ($dir in $childDirs) {
        $candidates.Add([System.IO.Path]::GetFullPath($dir.FullName))
    }

    foreach ($candidate in $candidates | Select-Object -Unique) {
        if (Test-IsValidPublishDir -Path $candidate) {
            return $candidate
        }
    }

    return ""
}

function Ensure-PackageZipAvailable([string]$ZipPath, [string]$Root, [string]$ScriptsRoot) {
    if (Test-Path $ZipPath) {
        $script:AutoPackagePublishDir = ""
        return @()
    }

    $packageName = [System.IO.Path]::GetFileNameWithoutExtension($ZipPath)
    $outputDir = Split-Path -Parent $ZipPath
    New-Item -ItemType Directory -Force -Path $outputDir | Out-Null

    $publishDir = Resolve-PublishDirForAutoPackage -Root $Root -PackageName $packageName
    if ([string]::IsNullOrWhiteSpace($publishDir)) {
        throw "Package zip not found: $ZipPath. Auto-package fallback could not find a publish directory with DataHz.Api.exe/DataHz.Api.dll under artifacts\\publish."
    }

    $packageScript = Join-Path $ScriptsRoot "package-release.ps1"
    if (-not (Test-Path $packageScript)) {
        throw "Package zip not found: $ZipPath. package-release.ps1 not found: $packageScript"
    }

    Write-Host "Package zip not found, auto-generating from publish directory: $publishDir"
    & $packageScript -InputDir $publishDir -OutputDir $outputDir -Name $packageName -Overwrite
    $script:AutoPackagePublishDir = $publishDir

    $generated = New-Object System.Collections.Generic.List[string]
    $generated.Add($ZipPath) | Out-Null

    $shaPath = [System.IO.Path]::ChangeExtension($ZipPath, ".sha256")
    if (Test-Path $shaPath) {
        $generated.Add($shaPath) | Out-Null
    }

    $manifestPath = Join-Path $outputDir ($packageName + ".manifest.json")
    if (Test-Path $manifestPath) {
        $generated.Add($manifestPath) | Out-Null
    }

    return @($generated.ToArray())
}

function Run-Case(
    [string]$Name,
    [scriptblock]$Action,
    [bool]$ExpectFailure,
    [string]$ExpectedMessagePart,
    [int]$MaxAttempts = 2,
    [int]$RetryDelayMilliseconds = 200,
    [string[]]$RetryOnMessageParts = @("already been disposed")
) {
    $attemptLimit = [Math]::Max(1, $MaxAttempts)
    for ($attempt = 1; $attempt -le $attemptLimit; $attempt++) {
        try {
            & $Action
            if ($ExpectFailure) {
                return [pscustomobject]@{
                    Case = $Name
                    Passed = $false
                    Detail = "Expected failure but command succeeded."
                }
            }

            $successDetail = "Succeeded."
            if ($attempt -gt 1) {
                $successDetail = "Succeeded after transient retry (attempt=$attempt)."
            }

            return [pscustomobject]@{
                Case = $Name
                Passed = $true
                Detail = $successDetail
            }
        }
        catch {
            $message = [string]$_.Exception.Message

            if (-not $ExpectFailure -and $attempt -lt $attemptLimit -and $RetryOnMessageParts.Count -gt 0) {
                $retryable = $false
                foreach ($marker in $RetryOnMessageParts) {
                    if ([string]::IsNullOrWhiteSpace($marker)) {
                        continue
                    }

                    if ($message -like "*$marker*") {
                        $retryable = $true
                        break
                    }
                }

                if ($retryable) {
                    if ($RetryDelayMilliseconds -gt 0) {
                        Start-Sleep -Milliseconds $RetryDelayMilliseconds
                    }
                    continue
                }
            }

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

    return [pscustomobject]@{
        Case = $Name
        Passed = $false
        Detail = "Unexpected failure: exhausted retry attempts."
    }
}

function Get-PowerShellExecutablePath {
    $pwshInPsHome = Join-Path $PSHOME "pwsh.exe"
    if (Test-Path $pwshInPsHome) {
        return $pwshInPsHome
    }

    $powershellInPsHome = Join-Path $PSHOME "powershell.exe"
    if (Test-Path $powershellInPsHome) {
        return $powershellInPsHome
    }

    $pwshCmd = Get-Command -Name "pwsh" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pwshCmd) {
        return $pwshCmd.Source
    }

    $powershellCmd = Get-Command -Name "powershell" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($powershellCmd) {
        return $powershellCmd.Source
    }

    throw "Unable to locate a PowerShell executable for subprocess invocation."
}

function Invoke-ScriptSubprocess(
    [string]$ScriptPath,
    [string[]]$ArgumentList,
    [string]$StdOutPath,
    [string]$StdErrPath
) {
    $fullScriptPath = [System.IO.Path]::GetFullPath($ScriptPath)
    if (-not (Test-Path $fullScriptPath)) {
        throw "Script not found for subprocess invocation: $fullScriptPath"
    }

    $stdoutDir = Split-Path -Parent $StdOutPath
    if (-not [string]::IsNullOrWhiteSpace($stdoutDir)) {
        New-Item -ItemType Directory -Force -Path $stdoutDir | Out-Null
    }

    $stderrDir = Split-Path -Parent $StdErrPath
    if (-not [string]::IsNullOrWhiteSpace($stderrDir)) {
        New-Item -ItemType Directory -Force -Path $stderrDir | Out-Null
    }

    $arguments = @("-NoProfile", "-NonInteractive", "-File", $fullScriptPath)
    if ($ArgumentList) {
        $arguments += $ArgumentList
    }

    $proc = Start-Process `
        -FilePath $script:PowerShellExecutable `
        -ArgumentList $arguments `
        -Wait `
        -PassThru `
        -WindowStyle Hidden `
        -RedirectStandardOutput $StdOutPath `
        -RedirectStandardError $StdErrPath

    return [pscustomobject]@{
        ExitCode = [int]$proc.ExitCode
        StdOutPath = $StdOutPath
        StdErrPath = $StdErrPath
    }
}

function Get-LatestRunSummary([string]$LogsRootPath) {
    if ([string]::IsNullOrWhiteSpace($LogsRootPath)) {
        return $null
    }

    if (-not (Test-Path $LogsRootPath)) {
        return $null
    }

    $latestRunDir = Get-ChildItem -Path $LogsRootPath -Directory -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1

    if (-not $latestRunDir) {
        return $null
    }

    $summaryPath = Join-Path $latestRunDir.FullName "run-summary.json"
    if (-not (Test-Path $summaryPath)) {
        return $null
    }

    return Get-Content -Path $summaryPath -Raw | ConvertFrom-Json
}

function Convert-DryRunOutputToObject([object[]]$OutputLines) {
    if ($null -eq $OutputLines -or $OutputLines.Count -eq 0) {
        throw "DryRun produced no JSON output."
    }

    $text = ($OutputLines | ForEach-Object { "$_" }) -join [Environment]::NewLine
    if ([string]::IsNullOrWhiteSpace($text)) {
        throw "DryRun produced empty output."
    }

    $jsonStart = $text.IndexOf("{")
    if ($jsonStart -lt 0) {
        throw "DryRun output does not contain JSON payload."
    }

    $jsonText = $text.Substring($jsonStart)
    return $jsonText | ConvertFrom-Json
}

function Assert-TextLogHasNoNulBytes(
    [string]$LogPath,
    [string]$Label
) {
    if ([string]::IsNullOrWhiteSpace($LogPath) -or -not (Test-Path $LogPath)) {
        throw "$Label not found: $LogPath"
    }

    $bytes = [System.IO.File]::ReadAllBytes([System.IO.Path]::GetFullPath($LogPath))
    foreach ($value in $bytes) {
        if ($value -eq 0) {
            throw "$Label contains NUL bytes (possible mixed encoding): $LogPath"
        }
    }
}

function Assert-StringHasNoControlChars(
    [string]$Value,
    [string]$Label
) {
    if ([string]::IsNullOrEmpty($Value)) {
        return
    }

    if ([System.Text.RegularExpressions.Regex]::IsMatch($Value, "[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]")) {
        throw "$Label contains control characters."
    }
}

function Assert-StringDoesNotContain(
    [string]$Value,
    [string]$Forbidden,
    [string]$Label
) {
    if ([string]::IsNullOrEmpty($Forbidden) -or [string]::IsNullOrEmpty($Value)) {
        return
    }

    if ($Value.IndexOf($Forbidden, [System.StringComparison]::Ordinal) -ge 0) {
        throw "$Label contains forbidden value."
    }
}

function New-RunId {
    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMdd-HHmmss-fff")
    $suffix = [Guid]::NewGuid().ToString("N").Substring(0, 8)
    return "$timestamp-$suffix"
}

$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($PackageZip)) {
    $PackageZip = Join-Path $root "artifacts\packages\datahz2-api-win-x64.zip"
}

$resolvedZip = [System.IO.Path]::GetFullPath($PackageZip)
$autoGeneratedPackageFiles = @(Ensure-PackageZipAvailable -ZipPath $resolvedZip -Root $root -ScriptsRoot $PSScriptRoot)
if (-not (Test-Path $resolvedZip)) {
    throw "Package zip not found: $resolvedZip"
}

$resolvedManifest = Resolve-ManifestPath -ZipPath $resolvedZip
$resolvedSha = Resolve-ShaPath -ZipPath $resolvedZip

$deployApiScript = Join-Path $PSScriptRoot "deploy-api.ps1"
$deployProdScript = Join-Path $PSScriptRoot "deploy-prod.ps1"
$deployProdAutoRollbackScript = Join-Path $PSScriptRoot "deploy-prod-with-auto-rollback.ps1"
$deployProdFromReleaseScript = Join-Path $PSScriptRoot "deploy-prod-from-release.ps1"
$smokeTestScript = Join-Path $PSScriptRoot "smoke-test-api.ps1"
$verifyReleaseAssetsScript = Join-Path $PSScriptRoot "verify-release-assets.ps1"
if (-not $script:PowerShellExecutable) {
    $script:PowerShellExecutable = Get-PowerShellExecutablePath
}
if (-not (Test-Path $deployApiScript)) {
    throw "deploy-api.ps1 not found: $deployApiScript"
}
if (-not (Test-Path $deployProdScript)) {
    throw "deploy-prod.ps1 not found: $deployProdScript"
}
if (-not (Test-Path $deployProdAutoRollbackScript)) {
    throw "deploy-prod-with-auto-rollback.ps1 not found: $deployProdAutoRollbackScript"
}
if (-not (Test-Path $deployProdFromReleaseScript)) {
    throw "deploy-prod-from-release.ps1 not found: $deployProdFromReleaseScript"
}
if (-not (Test-Path $smokeTestScript)) {
    throw "smoke-test-api.ps1 not found: $smokeTestScript"
}
if (-not (Test-Path $verifyReleaseAssetsScript)) {
    throw "verify-release-assets.ps1 not found: $verifyReleaseAssetsScript"
}

$runId = New-RunId
$tempRoot = Join-Path $root ("artifacts\selftest\deploy-guards-" + $runId)
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

$caseZipDir = Join-Path $tempRoot "case-require-manifest-missing"
New-Item -ItemType Directory -Force -Path $caseZipDir | Out-Null
$zipOnlyPath = Join-Path $caseZipDir ([System.IO.Path]::GetFileName($resolvedZip))
Copy-Item -Path $resolvedZip -Destination $zipOnlyPath -Force

$caseInvalidIndexDir = Join-Path $tempRoot "case-package-index-invalid-json"
New-Item -ItemType Directory -Force -Path $caseInvalidIndexDir | Out-Null
$invalidIndexPath = Join-Path $caseInvalidIndexDir "release.invalid.index.json"
Set-Content -Path $invalidIndexPath -Value "{ invalid json" -Encoding UTF8

$caseValidIndexDir = Join-Path $tempRoot "case-package-index-valid"
New-Item -ItemType Directory -Force -Path $caseValidIndexDir | Out-Null
$validIndexPath = Join-Path $caseValidIndexDir "release.valid.index.json"

$zipName = [System.IO.Path]::GetFileName($resolvedZip)
$zipInfo = Get-Item -Path $resolvedZip
$zipSha = (Get-FileHash -Path $resolvedZip -Algorithm SHA256).Hash.ToLowerInvariant()

$runtimeEntry = [ordered]@{
    Runtime = "selftest"
    Zip = $zipName
    PackageSha256 = $zipSha
}

$assetMetadata = @([ordered]@{
    file = $zipName
    sizeBytes = $zipInfo.Length
    sha256 = $zipSha
})

$manifestName = [System.IO.Path]::GetFileName($resolvedManifest)
$manifestInfo = Get-Item -Path $resolvedManifest
$manifestSha = (Get-FileHash -Path $resolvedManifest -Algorithm SHA256).Hash.ToLowerInvariant()
$runtimeEntry.Manifest = $manifestName
$assetMetadata += [ordered]@{
    file = $manifestName
    sizeBytes = $manifestInfo.Length
    sha256 = $manifestSha
}

if (-not [string]::IsNullOrWhiteSpace($resolvedSha)) {
    $shaName = [System.IO.Path]::GetFileName($resolvedSha)
    $shaInfo = Get-Item -Path $resolvedSha
    $shaHash = (Get-FileHash -Path $resolvedSha -Algorithm SHA256).Hash.ToLowerInvariant()
    $runtimeEntry.Sha256 = $shaName
    $assetMetadata += [ordered]@{
        file = $shaName
        sizeBytes = $shaInfo.Length
        sha256 = $shaHash
    }
}

$validIndex = [ordered]@{
    formatVersion = 1
    tag = "selftest-$runId"
    generatedUtc = (Get-Date).ToUniversalTime().ToString("o")
    runtimeCount = 1
    runtimes = @([pscustomobject]$runtimeEntry)
    assets = $assetMetadata
}
$validIndex | ConvertTo-Json -Depth 8 | Set-Content -Path $validIndexPath -Encoding UTF8

$validIndexName = [System.IO.Path]::GetFileName($validIndexPath)
$validIndexHash = (Get-FileHash -Path $validIndexPath -Algorithm SHA256).Hash.ToLowerInvariant()
$validIndexShaPath = Join-Path $caseValidIndexDir "release.valid.sha256"
Set-Content -Path $validIndexShaPath -Encoding UTF8 -Value @(
    "$zipSha  $zipName"
    "$validIndexHash  $validIndexName"
)

$invalidIndexShaPath = Join-Path $tempRoot "invalid-index.sha256"
$invalidIndexHash = if ($validIndexHash.StartsWith("0")) { "1" + $validIndexHash.Substring(1) } else { "0" + $validIndexHash.Substring(1) }
Set-Content -Path $invalidIndexShaPath -Encoding UTF8 -Value @(
    "$invalidIndexHash  $validIndexName"
)

$urlAssetRoot = Join-Path $tempRoot "url-assets"
New-Item -ItemType Directory -Force -Path $urlAssetRoot | Out-Null

$zipUrlName = [System.IO.Path]::GetFileName($resolvedZip)
$manifestUrlName = [System.IO.Path]::GetFileName($resolvedManifest)
$invalidIndexUrlName = [System.IO.Path]::GetFileName($invalidIndexPath)
$validIndexUrlName = [System.IO.Path]::GetFileName($validIndexPath)
$validIndexShaUrlName = [System.IO.Path]::GetFileName($validIndexShaPath)
$invalidIndexShaUrlName = [System.IO.Path]::GetFileName($invalidIndexShaPath)

Copy-Item -Path $resolvedZip -Destination (Join-Path $urlAssetRoot $zipUrlName) -Force
Copy-Item -Path $resolvedManifest -Destination (Join-Path $urlAssetRoot $manifestUrlName) -Force
Copy-Item -Path $invalidIndexPath -Destination (Join-Path $urlAssetRoot $invalidIndexUrlName) -Force
Copy-Item -Path $validIndexPath -Destination (Join-Path $urlAssetRoot $validIndexUrlName) -Force
Copy-Item -Path $validIndexShaPath -Destination (Join-Path $urlAssetRoot $validIndexShaUrlName) -Force
Copy-Item -Path $invalidIndexShaPath -Destination (Join-Path $urlAssetRoot $invalidIndexShaUrlName) -Force

$fromReleaseRuntime = if ($zipName -like "*arm64*") { "win-arm64" } elseif ($zipName -like "*x64*") { "win-x64" } else { "win-x64" }
$fromReleaseTag = "datahz2-v9.9.9-selftest"
$fromReleaseZipName = "datahz2-api-$fromReleaseRuntime-$fromReleaseTag.zip"
$fromReleaseShaName = "datahz2-api-$fromReleaseRuntime-$fromReleaseTag.sha256"
$fromReleaseManifestName = "datahz2-api-$fromReleaseRuntime-$fromReleaseTag.manifest.json"
$fromReleaseIndexName = "datahz2-release-$fromReleaseTag.index.json"
$fromReleaseIndexShaName = "datahz2-release-$fromReleaseTag.sha256"

Copy-Item -Path $resolvedZip -Destination (Join-Path $urlAssetRoot $fromReleaseZipName) -Force
$fromReleaseShaPath = Join-Path $urlAssetRoot $fromReleaseShaName
Set-Content -Path $fromReleaseShaPath -Encoding UTF8 -Value "$zipSha  $fromReleaseZipName"

$fromReleaseManifestPath = Join-Path $urlAssetRoot $fromReleaseManifestName
$fromReleaseManifestRaw = Get-Content -Path $resolvedManifest -Raw
$fromReleaseManifest = $fromReleaseManifestRaw | ConvertFrom-Json
if ($null -eq $fromReleaseManifest -or $null -eq $fromReleaseManifest.package) {
    throw "Resolved manifest for from-release guard case is invalid: $resolvedManifest"
}

$fromReleaseManifest.packageName = "datahz2-api-$fromReleaseRuntime-$fromReleaseTag"
$fromReleaseManifest.package.file = $fromReleaseZipName
$fromReleaseManifest.package.sha256 = $zipSha
$fromReleaseManifest.package.sha256File = $fromReleaseShaName
$fromReleaseManifest.package.sizeBytes = [long]$zipInfo.Length
$fromReleaseManifest | ConvertTo-Json -Depth 20 | Set-Content -Path $fromReleaseManifestPath -Encoding UTF8

$fromReleaseIndexPath = Join-Path $urlAssetRoot $fromReleaseIndexName
$fromReleaseIndexShaPath = Join-Path $urlAssetRoot $fromReleaseIndexShaName
& $verifyReleaseAssetsScript `
    -AssetsDir $urlAssetRoot `
    -Tag $fromReleaseTag `
    -Runtimes @($fromReleaseRuntime) `
    -OutputIndexFile $fromReleaseIndexPath `
    -OutputSha256ListFile $fromReleaseIndexShaPath

$serverPort = Get-FreeTcpPort
$urlServer = Start-StaticFileServer -RootPath $urlAssetRoot -Port $serverPort
$urlBase = $urlServer.BaseUrl
if (-not $urlBase.EndsWith("/")) {
    $urlBase += "/"
}

$fromReleaseBaseUrl = $urlBase.TrimEnd("/")

$zipFileUri = $urlBase + $zipUrlName
$manifestFileUri = $urlBase + $manifestUrlName
$invalidIndexFileUri = $urlBase + $invalidIndexUrlName
$validIndexFileUri = $urlBase + $validIndexUrlName
$validIndexShaFileUri = $urlBase + $validIndexShaUrlName
$invalidIndexShaFileUri = $urlBase + $invalidIndexShaUrlName
$shaFileUri = ""
if (-not [string]::IsNullOrWhiteSpace($resolvedSha)) {
    $shaUrlName = [System.IO.Path]::GetFileName($resolvedSha)
    Copy-Item -Path $resolvedSha -Destination (Join-Path $urlAssetRoot $shaUrlName) -Force
    $shaFileUri = $urlBase + $shaUrlName
}

$results = New-Object System.Collections.Generic.List[object]

try {
    $results.Add((Run-Case `
        -Name "env-invalid-boolean" `
        -ExpectFailure $true `
        -ExpectedMessagePart "Invalid boolean value for DATAHZ_DEPLOY_REQUIRE_MANIFEST" `
        -Action {
            $env:DATAHZ_DEPLOY_REQUIRE_MANIFEST = "maybe"
            try {
                & $deployApiScript `
                    -PackageZip $resolvedZip `
                    -ReleaseRoot (Join-Path $tempRoot "case-env-invalid") `
                    -SkipServiceInstall `
                    -SkipHealthCheck
            }
            finally {
                Remove-Item Env:DATAHZ_DEPLOY_REQUIRE_MANIFEST -ErrorAction SilentlyContinue
            }
        }))

    $results.Add((Run-Case `
        -Name "api-index-url-without-package-url" `
        -ExpectFailure $true `
        -ExpectedMessagePart "PackageIndexUrl requires PackageUrl" `
        -Action {
            & $deployApiScript `
                -PackageZip $resolvedZip `
                -PackageManifestFile $resolvedManifest `
                -PackageIndexUrl "https://example.com/datahz2-release-v1.index.json" `
                -ReleaseRoot (Join-Path $tempRoot "case-api-index-url-without-package-url") `
                -SkipServiceInstall `
                -SkipHealthCheck
        }))

    $results.Add((Run-Case `
        -Name "api-index-file-url-mutual-exclusive" `
        -ExpectFailure $true `
        -ExpectedMessagePart "PackageIndexFile and PackageIndexUrl are mutually exclusive" `
        -Action {
            & $deployApiScript `
                -PackageZip $resolvedZip `
                -PackageManifestFile $resolvedManifest `
                -PackageIndexFile $validIndexPath `
                -PackageIndexUrl "https://example.com/datahz2-release-v1.index.json" `
                -ReleaseRoot (Join-Path $tempRoot "case-api-index-file-url-mutual-exclusive") `
                -SkipServiceInstall `
                -SkipHealthCheck
        }))

    $results.Add((Run-Case `
        -Name "api-index-sha-url-without-index-url" `
        -ExpectFailure $true `
        -ExpectedMessagePart "PackageIndexSha256Url requires PackageIndexUrl" `
        -Action {
            & $deployApiScript `
                -PackageUrl $zipFileUri `
                -PackageManifestUrl $manifestFileUri `
                -PackageIndexSha256Url $validIndexShaFileUri `
                -ReleaseRoot (Join-Path $tempRoot "case-api-index-sha-url-without-index-url") `
                -SkipServiceInstall `
                -SkipHealthCheck
        }))

    $results.Add((Run-Case `
        -Name "api-index-sha-file-url-mutual-exclusive" `
        -ExpectFailure $true `
        -ExpectedMessagePart "PackageIndexSha256File and PackageIndexSha256Url are mutually exclusive" `
        -Action {
            & $deployApiScript `
                -PackageZip $resolvedZip `
                -PackageManifestFile $resolvedManifest `
                -PackageIndexFile $validIndexPath `
                -PackageIndexSha256File $validIndexShaPath `
                -PackageIndexSha256Url $validIndexShaFileUri `
                -ReleaseRoot (Join-Path $tempRoot "case-api-index-sha-file-url-mutual-exclusive") `
                -SkipServiceInstall `
                -SkipHealthCheck
        }))

    $results.Add((Run-Case `
        -Name "api-url-index-invalid-json" `
        -ExpectFailure $true `
        -ExpectedMessagePart "Package index is invalid JSON" `
        -Action {
            $params = @{
                PackageUrl = $zipFileUri
                PackageManifestUrl = $manifestFileUri
                PackageIndexUrl = $invalidIndexFileUri
                RequireManifest = $true
                ReleaseRoot = (Join-Path $tempRoot "case-api-url-index-invalid-json")
                SkipServiceInstall = $true
                SkipHealthCheck = $true
            }
            if (-not [string]::IsNullOrWhiteSpace($shaFileUri)) {
                $params.PackageSha256Url = $shaFileUri
            }

            & $deployApiScript @params
        }))

    $results.Add((Run-Case `
        -Name "api-url-index-sha-mismatch" `
        -ExpectFailure $true `
        -ExpectedMessagePart "Package index hash mismatch" `
        -Action {
            $params = @{
                PackageUrl = $zipFileUri
                PackageManifestUrl = $manifestFileUri
                PackageIndexUrl = $validIndexFileUri
                PackageIndexSha256Url = $invalidIndexShaFileUri
                RequireManifest = $true
                ReleaseRoot = (Join-Path $tempRoot "case-api-url-index-sha-mismatch")
                SkipServiceInstall = $true
                SkipHealthCheck = $true
            }
            if (-not [string]::IsNullOrWhiteSpace($shaFileUri)) {
                $params.PackageSha256Url = $shaFileUri
            }

            & $deployApiScript @params
        }))

    $results.Add((Run-Case `
        -Name "api-url-index-success" `
        -ExpectFailure $false `
        -ExpectedMessagePart "" `
        -Action {
            $params = @{
                PackageUrl = $zipFileUri
                PackageManifestUrl = $manifestFileUri
                PackageIndexUrl = $validIndexFileUri
                PackageIndexSha256Url = $validIndexShaFileUri
                RequireManifest = $true
                ReleaseRoot = (Join-Path $tempRoot "case-api-url-index-success")
                SkipServiceInstall = $true
                SkipHealthCheck = $true
            }
            if (-not [string]::IsNullOrWhiteSpace($shaFileUri)) {
                $params.PackageSha256Url = $shaFileUri
            }

            & $deployApiScript @params
        }))

    $results.Add((Run-Case `
        -Name "prod-url-missing-manifest-url" `
        -ExpectFailure $true `
        -ExpectedMessagePart "requires PackageManifestUrl" `
        -Action {
            & $deployProdScript `
                -PackageUrl "https://example.com/datahz2-api-win-x64.zip" `
                -ReleaseRoot (Join-Path $tempRoot "case-prod-url-missing-manifest-url")
        }))

    $results.Add((Run-Case `
        -Name "prod-index-url-without-package-url" `
        -ExpectFailure $true `
        -ExpectedMessagePart "PackageIndexUrl requires PackageUrl" `
        -Action {
            & $deployProdScript `
                -PackageZip $resolvedZip `
                -PackageManifestFile $resolvedManifest `
                -PackageIndexUrl "https://example.com/datahz2-release-v1.index.json" `
                -ReleaseRoot (Join-Path $tempRoot "case-prod-index-url-without-package-url")
        }))

    $results.Add((Run-Case `
        -Name "prod-index-file-url-mutual-exclusive" `
        -ExpectFailure $true `
        -ExpectedMessagePart "PackageIndexFile and PackageIndexUrl are mutually exclusive" `
        -Action {
            & $deployProdScript `
                -PackageZip $resolvedZip `
                -PackageManifestFile $resolvedManifest `
                -PackageIndexFile $validIndexPath `
                -PackageIndexUrl "https://example.com/datahz2-release-v1.index.json" `
                -ReleaseRoot (Join-Path $tempRoot "case-prod-index-file-url-mutual-exclusive")
        }))

    $results.Add((Run-Case `
        -Name "prod-index-sha-url-without-index-url" `
        -ExpectFailure $true `
        -ExpectedMessagePart "PackageIndexSha256Url requires PackageIndexUrl" `
        -Action {
            & $deployProdScript `
                -PackageUrl $zipFileUri `
                -PackageManifestUrl $manifestFileUri `
                -PackageIndexSha256Url $validIndexShaFileUri `
                -ReleaseRoot (Join-Path $tempRoot "case-prod-index-sha-url-without-index-url")
        }))

    $results.Add((Run-Case `
        -Name "prod-index-sha-file-url-mutual-exclusive" `
        -ExpectFailure $true `
        -ExpectedMessagePart "PackageIndexSha256File and PackageIndexSha256Url are mutually exclusive" `
        -Action {
            & $deployProdScript `
                -PackageZip $resolvedZip `
                -PackageManifestFile $resolvedManifest `
                -PackageIndexFile $validIndexPath `
                -PackageIndexSha256File $validIndexShaPath `
                -PackageIndexSha256Url $validIndexShaFileUri `
                -ReleaseRoot (Join-Path $tempRoot "case-prod-index-sha-file-url-mutual-exclusive")
        }))

    $results.Add((Run-Case `
        -Name "prod-wrapper-block-unsafe-bypass" `
        -ExpectFailure $true `
        -ExpectedMessagePart "blocked in deploy-prod.ps1" `
        -Action {
            & $deployProdScript `
                -PackageZip $resolvedZip `
                -PackageManifestFile $resolvedManifest `
                -ReleaseRoot (Join-Path $tempRoot "case-prod-wrapper-block-unsafe-bypass") `
                -SkipServiceInstall `
                -SkipHealthCheck
        }))

    $results.Add((Run-Case `
        -Name "prod-auto-wrapper-fail-skip-rollback" `
        -ExpectFailure $false `
        -ExpectedMessagePart "" `
        -Action {
            $logsRoot = Join-Path $tempRoot "case-prod-auto-wrapper-fail-skip-rollback.logs"
            New-Item -ItemType Directory -Force -Path $logsRoot | Out-Null
            $wrapperOutLog = Join-Path $logsRoot "wrapper.out.log"
            $wrapperErrLog = Join-Path $logsRoot "wrapper.err.log"

            $invoke = Invoke-ScriptSubprocess `
                -ScriptPath $deployProdAutoRollbackScript `
                -ArgumentList @(
                    "-ServiceName", "DataHz.Api",
                    "-PackageUrl", "https://example.com/datahz2-api-win-x64.zip",
                    "-LogsRoot", $logsRoot,
                    "-RunLabel", "guard-fail-skip",
                    "-SkipRollback"
                ) `
                -StdOutPath $wrapperOutLog `
                -StdErrPath $wrapperErrLog

            if ($invoke.ExitCode -ne 1) {
                $out = if (Test-Path $wrapperOutLog) { Get-Content -Path $wrapperOutLog -Raw } else { "" }
                $err = if (Test-Path $wrapperErrLog) { Get-Content -Path $wrapperErrLog -Raw } else { "" }
                throw "Expected wrapper exit code 1, got $($invoke.ExitCode). Out='$out' Err='$err'"
            }

            $summary = Get-LatestRunSummary -LogsRootPath $logsRoot
            if ($null -eq $summary) {
                throw "Wrapper run summary was not generated under $logsRoot"
            }

            if ($summary.deploy.succeeded) {
                throw "Wrapper summary expected deploy.succeeded=false for fail-skip case."
            }

            if ($summary.rollback.attempted) {
                throw "Wrapper summary expected rollback.attempted=false when -SkipRollback is set."
            }

            if (-not $summary.rollback.skipped) {
                throw "Wrapper summary expected rollback.skipped=true when -SkipRollback is set."
            }

            if ([string]::IsNullOrWhiteSpace($summary.deploy.logPath) -or -not (Test-Path $summary.deploy.logPath)) {
                throw "Wrapper deploy log path missing or not found."
            }
            Assert-TextLogHasNoNulBytes -LogPath $summary.deploy.logPath -Label "Wrapper deploy log"

            if ([string]::IsNullOrWhiteSpace($summary.snapshots.before) -or -not (Test-Path $summary.snapshots.before)) {
                throw "Wrapper status-before snapshot missing."
            }
            if ([string]::IsNullOrWhiteSpace($summary.snapshots.afterDeploy) -or -not (Test-Path $summary.snapshots.afterDeploy)) {
                throw "Wrapper status-after-deploy snapshot missing."
            }
            if ([string]::IsNullOrWhiteSpace($summary.snapshots.afterRollback) -or -not (Test-Path $summary.snapshots.afterRollback)) {
                throw "Wrapper status-after-rollback snapshot missing."
            }

            if ([string]::IsNullOrWhiteSpace($summary.runId)) {
                throw "Wrapper summary runId is empty."
            }
        }))

    $results.Add((Run-Case `
        -Name "prod-from-release-invalid-tag" `
        -ExpectFailure $true `
        -ExpectedMessagePart "Tag must start with 'datahz2-v'" `
        -Action {
            & $deployProdFromReleaseScript `
                -Tag "v1.0.8" `
                -Runtime "win-x64" `
                -DryRun
        }))

    $results.Add((Run-Case `
        -Name "prod-from-release-dryrun-x64" `
        -ExpectFailure $false `
        -ExpectedMessagePart "" `
        -Action {
            $tag = "datahz2-v1.0.8"
            $repo = "fzhlian/DataHz"
            $dryRunOutput = & $deployProdFromReleaseScript `
                -Tag $tag `
                -Runtime "win-x64" `
                -Repository $repo `
                -DryRun

            $dryRun = Convert-DryRunOutputToObject -OutputLines $dryRunOutput
            if (-not $dryRun -or -not $dryRun.params) {
                throw "DryRun payload missing params."
            }

            $base = "https://github.com/$repo/releases/download/$tag"
            $p = $dryRun.params
            if ($p.PackageUrl -ne "$base/datahz2-api-win-x64-$tag.zip") {
                throw "Unexpected PackageUrl in dryrun-x64 case: $($p.PackageUrl)"
            }
            if ($p.PackageSha256Url -ne "$base/datahz2-api-win-x64-$tag.sha256") {
                throw "Unexpected PackageSha256Url in dryrun-x64 case: $($p.PackageSha256Url)"
            }
            if ($p.PackageManifestUrl -ne "$base/datahz2-api-win-x64-$tag.manifest.json") {
                throw "Unexpected PackageManifestUrl in dryrun-x64 case: $($p.PackageManifestUrl)"
            }
            if ($p.PackageIndexUrl -ne "$base/datahz2-release-$tag.index.json") {
                throw "Unexpected PackageIndexUrl in dryrun-x64 case: $($p.PackageIndexUrl)"
            }
            if ($p.PackageIndexSha256Url -ne "$base/datahz2-release-$tag.sha256") {
                throw "Unexpected PackageIndexSha256Url in dryrun-x64 case: $($p.PackageIndexSha256Url)"
            }
            if ($p.RunLabel -ne "release-win-x64-$tag") {
                throw "Unexpected RunLabel in dryrun-x64 case: $($p.RunLabel)"
            }
        }))

    $results.Add((Run-Case `
        -Name "prod-from-release-dryrun-arm64" `
        -ExpectFailure $false `
        -ExpectedMessagePart "" `
        -Action {
            $tag = "datahz2-v1.0.8"
            $repo = "fzhlian/DataHz"
            $dryRunOutput = & $deployProdFromReleaseScript `
                -Tag $tag `
                -Runtime "win-arm64" `
                -Repository $repo `
                -DryRun

            $dryRun = Convert-DryRunOutputToObject -OutputLines $dryRunOutput
            if (-not $dryRun -or -not $dryRun.params) {
                throw "DryRun payload missing params."
            }

            $base = "https://github.com/$repo/releases/download/$tag"
            $p = $dryRun.params
            if ($p.PackageUrl -ne "$base/datahz2-api-win-arm64-$tag.zip") {
                throw "Unexpected PackageUrl in dryrun-arm64 case: $($p.PackageUrl)"
            }
            if ($p.PackageManifestUrl -ne "$base/datahz2-api-win-arm64-$tag.manifest.json") {
                throw "Unexpected PackageManifestUrl in dryrun-arm64 case: $($p.PackageManifestUrl)"
            }
            if ($p.RunLabel -ne "release-win-arm64-$tag") {
                throw "Unexpected RunLabel in dryrun-arm64 case: $($p.RunLabel)"
            }
        }))

    $results.Add((Run-Case `
        -Name "prod-from-release-dryrun-env-token" `
        -ExpectFailure $false `
        -ExpectedMessagePart "" `
        -Action {
            $hadToken = Test-Path Env:GITHUB_TOKEN
            $previousToken = if ($hadToken) { $env:GITHUB_TOKEN } else { "" }
            try {
                $env:GITHUB_TOKEN = "guard-token-value"
                $dryRunOutput = & $deployProdFromReleaseScript `
                    -Tag "datahz2-v1.0.8" `
                    -Runtime "win-x64" `
                    -DryRun
                $dryRun = Convert-DryRunOutputToObject -OutputLines $dryRunOutput
                if ($dryRun.params.PackageBearerToken -ne "guard-token-value") {
                    throw "DryRun did not propagate env GITHUB_TOKEN into PackageBearerToken."
                }
            }
            finally {
                if ($hadToken) {
                    $env:GITHUB_TOKEN = $previousToken
                }
                else {
                    Remove-Item Env:GITHUB_TOKEN -ErrorAction SilentlyContinue
                }
            }
        }))

    $results.Add((Run-Case `
        -Name "prod-from-release-validate-assets-local-success" `
        -ExpectFailure $false `
        -ExpectedMessagePart "" `
        -Action {
            $dryRunOutput = & $deployProdFromReleaseScript `
                -Tag $fromReleaseTag `
                -Runtime $fromReleaseRuntime `
                -ReleaseDownloadBaseUrl $fromReleaseBaseUrl `
                -ValidateAssetUrls `
                -ValidateAssetTimeoutSeconds 5 `
                -ValidateAssetRetryCount 1 `
                -DryRun

            $dryRun = Convert-DryRunOutputToObject -OutputLines $dryRunOutput
            if (-not $dryRun -or -not $dryRun.params) {
                throw "DryRun payload missing params."
            }

            $p = $dryRun.params
            if ($p.PackageUrl -ne "$fromReleaseBaseUrl/$fromReleaseZipName") {
                throw "Unexpected PackageUrl in local validate success case: $($p.PackageUrl)"
            }
            if ($p.PackageSha256Url -ne "$fromReleaseBaseUrl/$fromReleaseShaName") {
                throw "Unexpected PackageSha256Url in local validate success case: $($p.PackageSha256Url)"
            }
            if ($p.PackageManifestUrl -ne "$fromReleaseBaseUrl/$fromReleaseManifestName") {
                throw "Unexpected PackageManifestUrl in local validate success case: $($p.PackageManifestUrl)"
            }
            if ($p.PackageIndexUrl -ne "$fromReleaseBaseUrl/$fromReleaseIndexName") {
                throw "Unexpected PackageIndexUrl in local validate success case: $($p.PackageIndexUrl)"
            }
            if ($p.PackageIndexSha256Url -ne "$fromReleaseBaseUrl/$fromReleaseIndexShaName") {
                throw "Unexpected PackageIndexSha256Url in local validate success case: $($p.PackageIndexSha256Url)"
            }

            $assetValidation = @($dryRun.assetValidation)
            if ($assetValidation.Count -ne 5) {
                throw "Expected 5 asset validation entries, got $($assetValidation.Count)."
            }

            $failed = @($assetValidation | Where-Object { -not $_.Passed })
            if ($failed.Count -gt 0) {
                throw "Expected all local asset validation entries to pass."
            }
        }))

    $results.Add((Run-Case `
        -Name "prod-from-release-validate-assets-local-failure" `
        -ExpectFailure $true `
        -ExpectedMessagePart "Asset URL validation failed" `
        -Action {
            & $deployProdFromReleaseScript `
                -Tag "$fromReleaseTag-missing" `
                -Runtime $fromReleaseRuntime `
                -ReleaseDownloadBaseUrl $fromReleaseBaseUrl `
                -ValidateAssetUrls `
                -ValidateAssetTimeoutSeconds 5 `
                -ValidateAssetRetryCount 1 `
                -DryRun
        }))

    $results.Add((Run-Case `
        -Name "prod-from-release-validate-assets-summary" `
        -ExpectFailure $false `
        -ExpectedMessagePart "" `
        -Action {
            $logsRoot = Join-Path $tempRoot "case-prod-from-release-validate-assets-summary.logs"
            $releaseRoot = Join-Path $tempRoot "case-prod-from-release-validate-assets-summary.release"
            New-Item -ItemType Directory -Force -Path $logsRoot | Out-Null
            New-Item -ItemType Directory -Force -Path $releaseRoot | Out-Null
            $wrapperOutLog = Join-Path $logsRoot "wrapper.out.log"
            $wrapperErrLog = Join-Path $logsRoot "wrapper.err.log"

            $smokePort = Get-FreeTcpPort
            $smokeServer = Start-SmokeMockServer -Port $smokePort
            $smokeBaseUrl = $smokeServer.BaseUrl.TrimEnd("/")
            try {
                $invoke = Invoke-ScriptSubprocess `
                    -ScriptPath $deployProdFromReleaseScript `
                    -ArgumentList @(
                        "-Tag", $fromReleaseTag,
                        "-Runtime", $fromReleaseRuntime,
                        "-ReleaseDownloadBaseUrl", $fromReleaseBaseUrl,
                        "-ValidateAssetUrls",
                        "-ValidateAssetTimeoutSeconds", "5",
                        "-ValidateAssetRetryCount", "1",
                        "-AllowUnsafeBypass",
                        "-SkipServiceInstall",
                        "-SkipHealthCheck",
                        "-SkipRollback",
                        "-Urls", $smokeBaseUrl,
                        "-LogsRoot", $logsRoot,
                        "-RunLabel", "guard-asset-summary",
                        "-ReleaseRoot", $releaseRoot
                    ) `
                    -StdOutPath $wrapperOutLog `
                    -StdErrPath $wrapperErrLog
            }
            finally {
                Stop-ListenerServer -Server $smokeServer
            }

            if ($invoke.ExitCode -ne 0) {
                $out = if (Test-Path $wrapperOutLog) { Get-Content -Path $wrapperOutLog -Raw } else { "" }
                $err = if (Test-Path $wrapperErrLog) { Get-Content -Path $wrapperErrLog -Raw } else { "" }
                throw "Expected from-release wrapper exit code 0, got $($invoke.ExitCode). Out='$out' Err='$err'"
            }

            $summary = Get-LatestRunSummary -LogsRootPath $logsRoot
            if ($null -eq $summary) {
                throw "From-release wrapper run summary was not generated under $logsRoot"
            }

            if ([string]::IsNullOrWhiteSpace($summary.deploy.logPath) -or -not (Test-Path $summary.deploy.logPath)) {
                throw "From-release wrapper deploy log path missing or not found."
            }
            Assert-TextLogHasNoNulBytes -LogPath $summary.deploy.logPath -Label "From-release wrapper deploy log"

            if (-not [bool]$summary.deploy.succeeded) {
                throw "Expected from-release wrapper deploy.succeeded=true in summary."
            }

            if ([bool]$summary.rollback.attempted) {
                throw "Expected from-release wrapper rollback.attempted=false in summary."
            }

            $assetValidation = @($summary.assetValidation)
            if ($assetValidation.Count -ne 5) {
                throw "Expected 5 assetValidation entries in summary, got $($assetValidation.Count)."
            }

            $failed = @($assetValidation | Where-Object { -not $_.passed })
            if ($failed.Count -gt 0) {
                throw "Expected all assetValidation entries in summary to pass."
            }

            $expectedManifestUrl = "$fromReleaseBaseUrl/$fromReleaseManifestName"
            $manifestRow = $assetValidation | Where-Object { $_.url -eq $expectedManifestUrl } | Select-Object -First 1
            if (-not $manifestRow) {
                throw "Expected assetValidation to include manifest URL: $expectedManifestUrl"
            }
        }))

    $results.Add((Run-Case `
        -Name "smoke-binary-error-detail-sanitized" `
        -ExpectFailure $false `
        -ExpectedMessagePart "" `
        -Action {
            $smokePort = Get-FreeTcpPort
            $binaryServer = Start-BinarySmokeServer -Port $smokePort
            $binaryBaseUrl = $binaryServer.BaseUrl.TrimEnd("/")
            $caseRoot = Join-Path $tempRoot "case-smoke-binary-error-detail-sanitized"
            New-Item -ItemType Directory -Force -Path $caseRoot | Out-Null
            $reportPath = Join-Path $caseRoot "smoke.report.json"
            $stdoutPath = Join-Path $caseRoot "smoke.stdout.log"
            $stderrPath = Join-Path $caseRoot "smoke.stderr.log"
            try {
                $invoke = Invoke-ScriptSubprocess `
                    -ScriptPath $smokeTestScript `
                    -ArgumentList @(
                        "-BaseUrl", $binaryBaseUrl,
                        "-TimeoutSeconds", "3",
                        "-CheckRetryCount", "1",
                        "-CheckRetryDelayMilliseconds", "25",
                        "-HealthPollDelayMilliseconds", "25",
                        "-FailureContentSnippetLength", "200",
                        "-OutputJsonPath", $reportPath
                    ) `
                    -StdOutPath $stdoutPath `
                    -StdErrPath $stderrPath

                if ($invoke.ExitCode -ne 1) {
                    $out = if (Test-Path $stdoutPath) { Get-Content -Path $stdoutPath -Raw } else { "" }
                    $err = if (Test-Path $stderrPath) { Get-Content -Path $stderrPath -Raw } else { "" }
                    throw "Expected smoke subprocess exit code 1, got $($invoke.ExitCode). Out='$out' Err='$err'"
                }

                Assert-TextLogHasNoNulBytes -LogPath $stdoutPath -Label "Smoke stdout log"
                Assert-TextLogHasNoNulBytes -LogPath $stderrPath -Label "Smoke stderr log"

                if (-not (Test-Path $reportPath)) {
                    throw "Smoke report was not generated: $reportPath"
                }

                $report = Get-Content -Path $reportPath -Raw | ConvertFrom-Json
                if ([int]$report.failedChecks -le 0) {
                    throw "Expected failedChecks > 0 for binary smoke case."
                }

                $details = @($report.results | ForEach-Object { [string]$_.Detail })
                foreach ($detail in $details) {
                    Assert-StringHasNoControlChars -Value $detail -Label "Smoke report detail"
                }

                $endpoints = @($report.results | ForEach-Object { [string]$_.Endpoint })
                foreach ($endpoint in $endpoints) {
                    Assert-StringHasNoControlChars -Value $endpoint -Label "Smoke report endpoint"
                }

                $binaryHintRows = @($details | Where-Object {
                    $_ -like "*binary response body omitted*" -or
                    $_ -like "*non-text response body omitted*" -or
                    $_ -like "*response body unavailable*"
                })
                if ($binaryHintRows.Count -eq 0) {
                    throw "Expected at least one smoke detail with binary/non-text/unavailable body placeholder."
                }
            }
            finally {
                Stop-ListenerServer -Server $binaryServer
            }
        }))

    $results.Add((Run-Case `
        -Name "smoke-detail-redacts-secrets" `
        -ExpectFailure $false `
        -ExpectedMessagePart "" `
        -Action {
            $smokePort = Get-FreeTcpPort
            $secretServer = Start-SecretEchoSmokeServer -Port $smokePort
            $secretBaseUrl = $secretServer.BaseUrl.TrimEnd("/")
            $caseRoot = Join-Path $tempRoot "case-smoke-detail-redacts-secrets"
            New-Item -ItemType Directory -Force -Path $caseRoot | Out-Null
            $reportPath = Join-Path $caseRoot "smoke.report.json"
            $stdoutPath = Join-Path $caseRoot "smoke.stdout.log"
            $stderrPath = Join-Path $caseRoot "smoke.stderr.log"
            $apiKeySecret = "guard-api-key-should-redact"
            $jwtSecret = "guard-bearer-token-should-redact"
            try {
                $invoke = Invoke-ScriptSubprocess `
                    -ScriptPath $smokeTestScript `
                    -ArgumentList @(
                        "-BaseUrl", $secretBaseUrl,
                        "-TimeoutSeconds", "3",
                        "-CheckRetryCount", "1",
                        "-CheckRetryDelayMilliseconds", "25",
                        "-HealthPollDelayMilliseconds", "25",
                        "-FailureContentSnippetLength", "4000",
                        "-ApiKey", $apiKeySecret,
                        "-BearerToken", $jwtSecret,
                        "-RequireAuthenticatedApi",
                        "-OutputJsonPath", $reportPath
                    ) `
                    -StdOutPath $stdoutPath `
                    -StdErrPath $stderrPath

                if ($invoke.ExitCode -ne 1) {
                    $out = if (Test-Path $stdoutPath) { Get-Content -Path $stdoutPath -Raw } else { "" }
                    $err = if (Test-Path $stderrPath) { Get-Content -Path $stderrPath -Raw } else { "" }
                    throw "Expected smoke subprocess exit code 1, got $($invoke.ExitCode). Out='$out' Err='$err'"
                }

                Assert-TextLogHasNoNulBytes -LogPath $stdoutPath -Label "Smoke stdout log"
                Assert-TextLogHasNoNulBytes -LogPath $stderrPath -Label "Smoke stderr log"

                if (-not (Test-Path $reportPath)) {
                    throw "Smoke report was not generated: $reportPath"
                }

                $report = Get-Content -Path $reportPath -Raw | ConvertFrom-Json
                if ([int]$report.failedChecks -le 0) {
                    throw "Expected failedChecks > 0 for secret-redaction smoke case."
                }

                $details = @($report.results | ForEach-Object { [string]$_.Detail })
                $detailText = [string]::Join(" ", $details)
                $stdoutText = if (Test-Path $stdoutPath) { Get-Content -Path $stdoutPath -Raw } else { "" }
                $stderrText = if (Test-Path $stderrPath) { Get-Content -Path $stderrPath -Raw } else { "" }
                $combinedText = "$detailText`n$stdoutText`n$stderrText"

                foreach ($forbidden in @(
                    $apiKeySecret,
                    $jwtSecret,
                    "Bearer $jwtSecret",
                    "guard-alt-authorization-should-redact",
                    "guard-alt-stage-authorization-should-redact",
                    "guard-proxy-authorization-should-redact",
                    "guard-freeform-xapikey-should-redact",
                    "guard-x-api-key-should-redact",
                    "guard-x-api-key-backup-should-redact",
                    "guard-x-dot-api-key-alt-should-redact",
                    "guard-api-dot-key-alt-should-redact",
                    "guard-api-key-camel-alt-should-redact",
                    "guard-apikey-bracket-index-should-redact",
                    "guard-apikey-encoded-bracket-index-should-redact",
                    "guard-apikey-encoded-bracket-nested-should-redact",
                    "guard-apikey-double-encoded-bracket-index-should-redact",
                    "guard-apikey-double-encoded-bracket-nested-should-redact",
                    "guard-apikey-triple-encoded-bracket-index-should-redact",
                    "guard-apikey-triple-encoded-bracket-nested-should-redact",
                    "guard-apikey-quadruple-encoded-bracket-index-should-redact",
                    "guard-apikey-quadruple-encoded-bracket-nested-should-redact",
                    "guard-apikey-encoded-bracket-lowerhex-index-should-redact",
                    "guard-apikey-encoded-bracket-lowerhex-nested-should-redact",
                    "guard-apikey-double-encoded-bracket-lowerhex-index-should-redact",
                    "guard-apikey-double-encoded-bracket-lowerhex-nested-should-redact",
                    "guard-apikey-triple-encoded-bracket-lowerhex-index-should-redact",
                    "guard-apikey-triple-encoded-bracket-lowerhex-nested-should-redact",
                    "guard-apikey-quadruple-encoded-bracket-lowerhex-index-should-redact",
                    "guard-apikey-quadruple-encoded-bracket-lowerhex-nested-should-redact",
                    "guard-access-token-alt-stage-should-redact",
                    "guard-access-dot-token-stage-should-redact",
                    "guard-id-token-backup-should-redact",
                    "guard-id-dot-token-backup-should-redact",
                    "guard-jwt-stage-should-redact",
                    "guard-refresh-dot-token-alt-should-redact",
                    "guard-proxy-dot-authorization-alt-should-redact",
                    "guard-freeform-basic-should-redact",
                    "guard-cookie-header-should-redact",
                    "guard-cookie-alt-header-should-redact",
                    "guard-cookie-dot-alt-header-should-redact",
                    "guard-cookie-session-should-redact",
                    "guard-cookie-alt-session-should-redact",
                    "guard-cookie-dot-alt-session-should-redact",
                    "guard-set-dot-cookie-alt-session-should-redact",
                    "guard-sessionid-backup-should-redact",
                    "guard-sessionid-dot-backup-should-redact",
                    "guard-session-dot-id-backup-should-redact",
                    "guard-sessionid-camel-bracket-meta-should-redact",
                    "guard-sessionid-camel-encoded-bracket-meta-should-redact",
                    "guard-sessionid-camel-encoded-bracket-nested-should-redact",
                    "guard-sessionid-camel-double-encoded-bracket-meta-should-redact",
                    "guard-sessionid-camel-double-encoded-bracket-nested-should-redact",
                    "guard-sessionid-camel-triple-encoded-bracket-meta-should-redact",
                    "guard-sessionid-camel-triple-encoded-bracket-nested-should-redact",
                    "guard-sessionid-camel-quadruple-encoded-bracket-meta-should-redact",
                    "guard-sessionid-camel-quadruple-encoded-bracket-nested-should-redact",
                    "guard-sessionid-camel-encoded-bracket-lowerhex-meta-should-redact",
                    "guard-sessionid-camel-encoded-bracket-lowerhex-nested-should-redact",
                    "guard-sessionid-camel-double-encoded-bracket-lowerhex-meta-should-redact",
                    "guard-sessionid-camel-double-encoded-bracket-lowerhex-nested-should-redact",
                    "guard-sessionid-camel-triple-encoded-bracket-lowerhex-meta-should-redact",
                    "guard-sessionid-camel-triple-encoded-bracket-lowerhex-nested-should-redact",
                    "guard-sessionid-camel-quadruple-encoded-bracket-lowerhex-meta-should-redact",
                    "guard-sessionid-camel-quadruple-encoded-bracket-lowerhex-nested-should-redact",
                    "guard-nested-apikey-should-redact",
                    "guard-nested-apikey-double-encoded-bracket-index-should-redact",
                    "guard-nested-client-secret-stage-should-redact",
                    "guard-nested-sessionid-encoded-bracket-meta-should-redact",
                    "guard-nested-sessionid-double-encoded-bracket-nested-should-redact",
                    "guard-nested-password-temp-should-redact",
                    "guard-nested-cookie-alt-should-redact",
                    "guard-single-quote-apikey-should-redact",
                    "guard-single-quote-sessionid-encoded-meta-should-redact",
                    "guard-single-quote-client-secret-stage-should-redact",
                    "guard-escaped-unicode-quote-apikey-should-redact",
                    "guard-escaped-unicode-quote-sessionid-meta-should-redact",
                    "guard-double-escaped-unicode-quote-apikey-should-redact",
                    "guard-double-escaped-unicode-quote-client-secret-stage-should-redact",
                    "guard-escaped-url-user",
                    "guard-escaped-url-pass",
                    "guard-escaped-url-user:guard-escaped-url-pass@",
                    "guard-escaped-url-apikey-should-redact",
                    "guard-escaped-url-sessionid-should-redact",
                    "guard-escaped-url-fragment-token-should-redact",
                    "guard-escaped-delim-url-user",
                    "guard-escaped-delim-url-pass",
                    "guard-escaped-delim-url-user:guard-escaped-delim-url-pass@",
                    "guard-escaped-delim-url-apikey-should-redact",
                    "guard-escaped-delim-url-sessionid-should-redact",
                    "guard-escaped-delim-url-semicolon-token-should-redact",
                    "guard-escaped-delim-url-fragment-token-should-redact",
                    "guard-client-dot-secret-stage-should-redact",
                    "guard-freeform-bearer-should-redact",
                    "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.guardpayload.guardsignature",
                    "guardpayload",
                    "guardsignature",
                    "guard-url-user",
                    "guard-url-pass",
                    "guard-url-user:guard-url-pass@",
                    "guard-url-token-should-redact",
                    "guard-url-access-token-alt-stage-should-redact",
                    "guard-url-access-dot-token-stage-should-redact",
                    "guard-url-id-token-backup-should-redact",
                    "guard-url-id-dot-token-backup-should-redact",
                    "guard-url-jwt-stage-should-redact",
                    "guard-url-apikey-should-redact",
                    "guard-url-api-dot-key-alt-should-redact",
                    "guard-url-api-key-camel-alt-should-redact",
                    "guard-url-apikey-bracket-index-should-redact",
                    "guard-url-apikey-encoded-bracket-index-should-redact",
                    "guard-url-apikey-encoded-bracket-nested-should-redact",
                    "guard-url-apikey-double-encoded-bracket-index-should-redact",
                    "guard-url-apikey-double-encoded-bracket-nested-should-redact",
                    "guard-url-apikey-triple-encoded-bracket-index-should-redact",
                    "guard-url-apikey-triple-encoded-bracket-nested-should-redact",
                    "guard-url-apikey-quadruple-encoded-bracket-index-should-redact",
                    "guard-url-apikey-quadruple-encoded-bracket-nested-should-redact",
                    "guard-url-apikey-encoded-bracket-lowerhex-index-should-redact",
                    "guard-url-apikey-encoded-bracket-lowerhex-nested-should-redact",
                    "guard-url-apikey-double-encoded-bracket-lowerhex-index-should-redact",
                    "guard-url-apikey-double-encoded-bracket-lowerhex-nested-should-redact",
                    "guard-url-apikey-triple-encoded-bracket-lowerhex-index-should-redact",
                    "guard-url-apikey-triple-encoded-bracket-lowerhex-nested-should-redact",
                    "guard-url-apikey-quadruple-encoded-bracket-lowerhex-index-should-redact",
                    "guard-url-apikey-quadruple-encoded-bracket-lowerhex-nested-should-redact",
                    "guard-url-xapikey-should-redact",
                    "guard-url-xapikey-backup-should-redact",
                    "guard-url-x-dot-api-key-alt-should-redact",
                    "guard-url-authorization-should-redact",
                    "guard-url-authorization-alt-stage-should-redact",
                    "guard-url-proxy-auth-should-redact",
                    "guard-url-basic-should-redact",
                    "guard-url-proxy-dot-authorization-alt-should-redact",
                    "guard-url-cookie-should-redact",
                    "guard-url-cookie-alt-should-redact",
                    "guard-url-cookie-dot-alt-should-redact",
                    "guard-url-set-cookie-alt-should-redact",
                    "guard-url-set-cookie-dot-alt-should-redact",
                    "guard-url-set-dot-cookie-alt-should-redact",
                    "guard-url-session-should-redact",
                    "guard-url-sessionid-backup-should-redact",
                    "guard-url-sessionid-dot-backup-should-redact",
                    "guard-url-session-dot-id-backup-should-redact",
                    "guard-url-sessionid-camel-bracket-meta-should-redact",
                    "guard-url-sessionid-camel-encoded-bracket-meta-should-redact",
                    "guard-url-sessionid-camel-encoded-bracket-nested-should-redact",
                    "guard-url-sessionid-camel-double-encoded-bracket-meta-should-redact",
                    "guard-url-sessionid-camel-double-encoded-bracket-nested-should-redact",
                    "guard-url-sessionid-camel-triple-encoded-bracket-meta-should-redact",
                    "guard-url-sessionid-camel-triple-encoded-bracket-nested-should-redact",
                    "guard-url-sessionid-camel-quadruple-encoded-bracket-meta-should-redact",
                    "guard-url-sessionid-camel-quadruple-encoded-bracket-nested-should-redact",
                    "guard-url-sessionid-camel-encoded-bracket-lowerhex-meta-should-redact",
                    "guard-url-sessionid-camel-encoded-bracket-lowerhex-nested-should-redact",
                    "guard-url-sessionid-camel-double-encoded-bracket-lowerhex-meta-should-redact",
                    "guard-url-sessionid-camel-double-encoded-bracket-lowerhex-nested-should-redact",
                    "guard-url-sessionid-camel-triple-encoded-bracket-lowerhex-meta-should-redact",
                    "guard-url-sessionid-camel-triple-encoded-bracket-lowerhex-nested-should-redact",
                    "guard-url-sessionid-camel-quadruple-encoded-bracket-lowerhex-meta-should-redact",
                    "guard-url-sessionid-camel-quadruple-encoded-bracket-lowerhex-nested-should-redact",
                    "guard-url-fragment-token-should-redact",
                    "guard-url-fragment-apikey-camel-alt-should-redact",
                    "guard-url-fragment-sessionid-camel-backup-should-redact",
                    "guard-url-fragment-apikey-encoded-bracket-index-should-redact",
                    "guard-url-fragment-sessionid-encoded-bracket-meta-should-redact",
                    "guard-url-fragment-apikey-encoded-bracket-nested-should-redact",
                    "guard-url-fragment-sessionid-encoded-bracket-nested-should-redact",
                    "guard-url-fragment-apikey-double-encoded-bracket-index-should-redact",
                    "guard-url-fragment-sessionid-double-encoded-bracket-meta-should-redact",
                    "guard-url-fragment-apikey-double-encoded-bracket-nested-should-redact",
                    "guard-url-fragment-sessionid-double-encoded-bracket-nested-should-redact",
                    "guard-url-fragment-apikey-triple-encoded-bracket-index-should-redact",
                    "guard-url-fragment-sessionid-triple-encoded-bracket-meta-should-redact",
                    "guard-url-fragment-apikey-triple-encoded-bracket-nested-should-redact",
                    "guard-url-fragment-sessionid-triple-encoded-bracket-nested-should-redact",
                    "guard-url-fragment-apikey-quadruple-encoded-bracket-index-should-redact",
                    "guard-url-fragment-sessionid-quadruple-encoded-bracket-meta-should-redact",
                    "guard-url-fragment-apikey-quadruple-encoded-bracket-nested-should-redact",
                    "guard-url-fragment-sessionid-quadruple-encoded-bracket-nested-should-redact",
                    "guard-url-fragment-apikey-encoded-bracket-lowerhex-index-should-redact",
                    "guard-url-fragment-apikey-encoded-bracket-lowerhex-nested-should-redact",
                    "guard-url-fragment-apikey-double-encoded-bracket-lowerhex-index-should-redact",
                    "guard-url-fragment-apikey-double-encoded-bracket-lowerhex-nested-should-redact",
                    "guard-url-fragment-apikey-triple-encoded-bracket-lowerhex-index-should-redact",
                    "guard-url-fragment-apikey-triple-encoded-bracket-lowerhex-nested-should-redact",
                    "guard-url-fragment-apikey-quadruple-encoded-bracket-lowerhex-index-should-redact",
                    "guard-url-fragment-apikey-quadruple-encoded-bracket-lowerhex-nested-should-redact",
                    "guard-url-fragment-sessionid-encoded-bracket-lowerhex-meta-should-redact",
                    "guard-url-fragment-sessionid-encoded-bracket-lowerhex-nested-should-redact",
                    "guard-url-fragment-sessionid-double-encoded-bracket-lowerhex-meta-should-redact",
                    "guard-url-fragment-sessionid-double-encoded-bracket-lowerhex-nested-should-redact",
                    "guard-url-fragment-sessionid-triple-encoded-bracket-lowerhex-meta-should-redact",
                    "guard-url-fragment-sessionid-triple-encoded-bracket-lowerhex-nested-should-redact",
                    "guard-url-fragment-sessionid-quadruple-encoded-bracket-lowerhex-meta-should-redact",
                    "guard-url-fragment-sessionid-quadruple-encoded-bracket-lowerhex-nested-should-redact",
                    "guard-url-semicolon-token-should-redact",
                    "guard-url-semicolon-apikey-camel-alt-should-redact",
                    "guard-url-fragment-semicolon-token-should-redact",
                    "guard-url-fragment-semicolon-apikey-camel-alt-should-redact",
                    "guard-url-session-id-camel-backup-should-redact",
                    "guard-url-password-should-redact",
                    "guard-url-password-temp-should-redact",
                    "guard-url-password-dot-temp-should-redact",
                    "guard-client-secret-should-redact",
                    "guard-client-secret-stage-should-redact",
                    "guard-client-secret-dot-stage-should-redact",
                    "guard-url-client-secret-stage-should-redact",
                    "guard-url-client-secret-dot-stage-should-redact",
                    "guard-url-client-dot-secret-stage-should-redact",
                    "guard-refresh-token-should-redact",
                    "guard-url-refresh-dot-token-alt-should-redact",
                    "guard-plain-secret-should-redact",
                    "guard-plain-secret-backup-should-redact",
                    "guard-plain-secret-dot-backup-should-redact",
                    "guard-url-secret-backup-should-redact",
                    "guard-url-secret-dot-backup-should-redact",
                    "guard-password-should-redact",
                    "guard-session-id-camel-backup-should-redact"
                )) {
                    Assert-StringDoesNotContain -Value $combinedText -Forbidden $forbidden -Label "Smoke outputs"
                }

                if ($detailText.IndexOf("set-cookie", [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
                    throw "Expected smoke details to include set-cookie key for redaction validation."
                }

                if ($detailText.IndexOf("[REDACTED]", [System.StringComparison]::Ordinal) -lt 0) {
                    throw "Expected smoke details to include [REDACTED] marker."
                }

                if ($detailText.IndexOf("http://[REDACTED]@", [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
                    throw "Expected smoke details to redact URL userinfo as http://[REDACTED]@..."
                }
            }
            finally {
                Stop-ListenerServer -Server $secretServer
            }
        }))

    $results.Add((Run-Case `
        -Name "smoke-baseurl-userinfo-redacted" `
        -ExpectFailure $false `
        -ExpectedMessagePart "" `
        -Action {
            $smokePort = Get-FreeTcpPort
            $smokeServer = Start-SmokeMockServer -Port $smokePort
            $rawBaseUrl = "http://guard-user:guard-pass@127.0.0.1:$smokePort"
            $safeBaseUrl = "http://127.0.0.1:$smokePort"
            $caseRoot = Join-Path $tempRoot "case-smoke-baseurl-userinfo-redacted"
            New-Item -ItemType Directory -Force -Path $caseRoot | Out-Null
            $reportPath = Join-Path $caseRoot "smoke.report.json"
            $stdoutPath = Join-Path $caseRoot "smoke.stdout.log"
            $stderrPath = Join-Path $caseRoot "smoke.stderr.log"
            try {
                $invoke = Invoke-ScriptSubprocess `
                    -ScriptPath $smokeTestScript `
                    -ArgumentList @(
                        "-BaseUrl", $rawBaseUrl,
                        "-TimeoutSeconds", "3",
                        "-CheckRetryCount", "1",
                        "-CheckRetryDelayMilliseconds", "25",
                        "-HealthPollDelayMilliseconds", "25",
                        "-FailureContentSnippetLength", "200",
                        "-OutputJsonPath", $reportPath
                    ) `
                    -StdOutPath $stdoutPath `
                    -StdErrPath $stderrPath

                if ($invoke.ExitCode -ne 0) {
                    $out = if (Test-Path $stdoutPath) { Get-Content -Path $stdoutPath -Raw } else { "" }
                    $err = if (Test-Path $stderrPath) { Get-Content -Path $stderrPath -Raw } else { "" }
                    throw "Expected smoke subprocess exit code 0, got $($invoke.ExitCode). Out='$out' Err='$err'"
                }

                Assert-TextLogHasNoNulBytes -LogPath $stdoutPath -Label "Smoke stdout log"
                Assert-TextLogHasNoNulBytes -LogPath $stderrPath -Label "Smoke stderr log"

                if (-not (Test-Path $reportPath)) {
                    throw "Smoke report was not generated: $reportPath"
                }

                $reportText = Get-Content -Path $reportPath -Raw
                $report = $reportText | ConvertFrom-Json
                if ([int]$report.failedChecks -ne 0) {
                    throw "Expected failedChecks=0 for userinfo base URL case, got $($report.failedChecks)."
                }

                if ([string]$report.baseUrl -ne $safeBaseUrl) {
                    throw "Expected report.baseUrl='$safeBaseUrl', got '$($report.baseUrl)'."
                }

                $stdoutText = if (Test-Path $stdoutPath) { Get-Content -Path $stdoutPath -Raw } else { "" }
                $stderrText = if (Test-Path $stderrPath) { Get-Content -Path $stderrPath -Raw } else { "" }
                $combinedText = "$reportText`n$stdoutText`n$stderrText"

                foreach ($forbidden in @("guard-user", "guard-pass", "guard-user:guard-pass@")) {
                    Assert-StringDoesNotContain -Value $combinedText -Forbidden $forbidden -Label "Smoke outputs"
                }

                $expectedContext = "BaseUrl: $safeBaseUrl"
                if ($stdoutText.IndexOf($expectedContext, [System.StringComparison]::Ordinal) -lt 0) {
                    throw "Expected smoke stdout context to include sanitized base URL: $expectedContext"
                }
            }
            finally {
                Stop-ListenerServer -Server $smokeServer
            }
        }))

    $results.Add((Run-Case `
        -Name "smoke-baseurl-whitespace-injection-sanitized" `
        -ExpectFailure $false `
        -ExpectedMessagePart "" `
        -MaxAttempts 2 `
        -RetryDelayMilliseconds 200 `
        -RetryOnMessageParts @("already been disposed") `
        -Action {
            $smokePort = Get-FreeTcpPort
            $smokeServer = Start-SmokeMockServer -Port $smokePort
            $safeBaseUrl = $smokeServer.BaseUrl.TrimEnd("/")
            $rawBaseUrl = "$safeBaseUrl`r`nX-Injected: guard"
            $caseRoot = Join-Path $tempRoot "case-smoke-baseurl-whitespace-injection-sanitized"
            New-Item -ItemType Directory -Force -Path $caseRoot | Out-Null
            $reportPath = Join-Path $caseRoot "smoke.report.json"
            $stdoutPath = Join-Path $caseRoot "smoke.stdout.log"
            $stderrPath = Join-Path $caseRoot "smoke.stderr.log"
            try {
                $invoke = Invoke-ScriptSubprocess `
                    -ScriptPath $smokeTestScript `
                    -ArgumentList @(
                        "-BaseUrl", $rawBaseUrl,
                        "-TimeoutSeconds", "1",
                        "-CheckRetryCount", "1",
                        "-CheckRetryDelayMilliseconds", "25",
                        "-HealthPollDelayMilliseconds", "25",
                        "-FailureContentSnippetLength", "120",
                        "-OutputJsonPath", $reportPath
                    ) `
                    -StdOutPath $stdoutPath `
                    -StdErrPath $stderrPath

                if ($invoke.ExitCode -ne 1) {
                    $out = if (Test-Path $stdoutPath) { Get-Content -Path $stdoutPath -Raw } else { "" }
                    $err = if (Test-Path $stderrPath) { Get-Content -Path $stderrPath -Raw } else { "" }
                    throw "Expected smoke subprocess exit code 1, got $($invoke.ExitCode). Out='$out' Err='$err'"
                }

                Assert-TextLogHasNoNulBytes -LogPath $stdoutPath -Label "Smoke stdout log"
                Assert-TextLogHasNoNulBytes -LogPath $stderrPath -Label "Smoke stderr log"

                if (-not (Test-Path $reportPath)) {
                    throw "Smoke report was not generated: $reportPath"
                }

                $reportText = Get-Content -Path $reportPath -Raw
                $report = $reportText | ConvertFrom-Json
                Assert-StringHasNoControlChars -Value ([string]$report.baseUrl) -Label "Smoke report baseUrl"
                if ([string]$report.baseUrl -ne $safeBaseUrl) {
                    throw "Expected report.baseUrl='$safeBaseUrl', got '$($report.baseUrl)'."
                }

                $stdoutText = if (Test-Path $stdoutPath) { Get-Content -Path $stdoutPath -Raw } else { "" }
                $stderrText = if (Test-Path $stderrPath) { Get-Content -Path $stderrPath -Raw } else { "" }
                $combinedText = "$reportText`n$stdoutText`n$stderrText"
                Assert-StringDoesNotContain -Value $combinedText -Forbidden "X-Injected: guard" -Label "Smoke outputs"

                $expectedContext = "BaseUrl: $safeBaseUrl"
                if ($stdoutText.IndexOf($expectedContext, [System.StringComparison]::Ordinal) -lt 0) {
                    throw "Expected smoke stdout context to include sanitized base URL: $expectedContext"
                }
            }
            finally {
                Stop-ListenerServer -Server $smokeServer
            }
        }))

    $results.Add((Run-Case `
        -Name "smoke-baseurl-query-secrets-redacted" `
        -ExpectFailure $false `
        -ExpectedMessagePart "" `
        -Action {
            $smokePort = Get-FreeTcpPort
            $smokeServer = Start-SmokeMockServer -Port $smokePort
            $queryApiKeySecret = "guard-baseurl-query-secret"
            $queryPasswordSecret = "guard-baseurl-password-secret"
            $queryClientSecret = "guard-baseurl-client-secret"
            $queryRefreshSecret = "guard-baseurl-refresh-secret"
            $queryCookieSecret = "guard-baseurl-cookie-secret"
            $querySessionSecret = "guard-baseurl-session-secret"
            $queryAuthorizationSecret = "guard-baseurl-authorization-secret"
            $queryIdTokenSecret = "guard-baseurl-idtoken-secret"
            $queryIdTokenBackupSecret = "guard-baseurl-idtoken-backup-secret"
            $queryXApiKeySecret = "guard-baseurl-xapikey-secret"
            $queryXApiKeyBackupSecret = "guard-baseurl-xapikey-backup-secret"
            $queryAccessTokenStageSecret = "guard-baseurl-access-token-stage-secret"
            $queryApiKeyCamelAltSecret = "guard-baseurl-api-key-camel-alt-secret"
            $queryPasswordTempSecret = "guard-baseurl-password-temp-secret"
            $queryClientSecretStageSecret = "guard-baseurl-client-secret-stage-secret"
            $querySecretBackupSecret = "guard-baseurl-secret-backup-secret"
            $queryCookieAltSecret = "guard-baseurl-cookie-alt-secret"
            $querySetCookieAltSecret = "guard-baseurl-set-cookie-alt-secret"
            $querySessionBackupSecret = "guard-baseurl-sessionid-backup-secret"
            $querySessionIdCamelBackupSecret = "guard-baseurl-session-id-camel-backup-secret"
            $queryApiKeyEncodedBracketIndexSecret = "guard-baseurl-apikey-encoded-bracket-index-secret"
            $querySessionIdEncodedBracketMetaSecret = "guard-baseurl-sessionid-encoded-bracket-meta-secret"
            $queryApiKeyEncodedBracketNestedSecret = "guard-baseurl-apikey-encoded-bracket-nested-secret"
            $querySessionIdEncodedBracketNestedSecret = "guard-baseurl-sessionid-encoded-bracket-nested-secret"
            $queryApiKeyDoubleEncodedBracketIndexSecret = "guard-baseurl-apikey-double-encoded-bracket-index-secret"
            $querySessionIdDoubleEncodedBracketMetaSecret = "guard-baseurl-sessionid-double-encoded-bracket-meta-secret"
            $queryApiKeyDoubleEncodedBracketNestedSecret = "guard-baseurl-apikey-double-encoded-bracket-nested-secret"
            $querySessionIdDoubleEncodedBracketNestedSecret = "guard-baseurl-sessionid-double-encoded-bracket-nested-secret"
            $queryApiKeyTripleEncodedBracketIndexSecret = "guard-baseurl-apikey-triple-encoded-bracket-index-secret"
            $querySessionIdTripleEncodedBracketMetaSecret = "guard-baseurl-sessionid-triple-encoded-bracket-meta-secret"
            $queryApiKeyTripleEncodedBracketNestedSecret = "guard-baseurl-apikey-triple-encoded-bracket-nested-secret"
            $querySessionIdTripleEncodedBracketNestedSecret = "guard-baseurl-sessionid-triple-encoded-bracket-nested-secret"
            $queryApiKeyQuadrupleEncodedBracketIndexSecret = "guard-baseurl-apikey-quadruple-encoded-bracket-index-secret"
            $querySessionIdQuadrupleEncodedBracketMetaSecret = "guard-baseurl-sessionid-quadruple-encoded-bracket-meta-secret"
            $queryApiKeyQuadrupleEncodedBracketNestedSecret = "guard-baseurl-apikey-quadruple-encoded-bracket-nested-secret"
            $querySessionIdQuadrupleEncodedBracketNestedSecret = "guard-baseurl-sessionid-quadruple-encoded-bracket-nested-secret"
            $queryApiKeyEncodedLowerHexBracketIndexSecret = "guard-baseurl-apikey-encoded-lowerhex-bracket-index-secret"
            $querySessionIdEncodedLowerHexBracketMetaSecret = "guard-baseurl-sessionid-encoded-lowerhex-bracket-meta-secret"
            $queryApiKeyDoubleEncodedLowerHexBracketIndexSecret = "guard-baseurl-apikey-double-encoded-lowerhex-bracket-index-secret"
            $querySessionIdDoubleEncodedLowerHexBracketMetaSecret = "guard-baseurl-sessionid-double-encoded-lowerhex-bracket-meta-secret"
            $queryApiKeyTripleEncodedLowerHexBracketIndexSecret = "guard-baseurl-apikey-triple-encoded-lowerhex-bracket-index-secret"
            $querySessionIdTripleEncodedLowerHexBracketMetaSecret = "guard-baseurl-sessionid-triple-encoded-lowerhex-bracket-meta-secret"
            $queryApiKeyQuadrupleEncodedLowerHexBracketIndexSecret = "guard-baseurl-apikey-quadruple-encoded-lowerhex-bracket-index-secret"
            $querySessionIdQuadrupleEncodedLowerHexBracketMetaSecret = "guard-baseurl-sessionid-quadruple-encoded-lowerhex-bracket-meta-secret"
            $queryPasswordDotTempSecret = "guard-baseurl-password-dot-temp-secret"
            $queryClientSecretDotStageSecret = "guard-baseurl-client-secret-dot-stage-secret"
            $querySecretDotBackupSecret = "guard-baseurl-secret-dot-backup-secret"
            $queryCookieDotAltSecret = "guard-baseurl-cookie-dot-alt-secret"
            $querySetCookieDotAltSecret = "guard-baseurl-set-cookie-dot-alt-secret"
            $querySessionDotBackupSecret = "guard-baseurl-sessionid-dot-backup-secret"
            $queryApiDotKeyAltSecret = "guard-baseurl-api-dot-key-alt-secret"
            $queryXDotApiKeyAltSecret = "guard-baseurl-x-dot-api-key-alt-secret"
            $queryAccessDotTokenStageSecret = "guard-baseurl-access-dot-token-stage-secret"
            $queryIdDotTokenBackupSecret = "guard-baseurl-id-dot-token-backup-secret"
            $queryRefreshDotTokenAltSecret = "guard-baseurl-refresh-dot-token-alt-secret"
            $queryProxyDotAuthorizationAltSecret = "guard-baseurl-proxy-dot-authorization-alt-secret"
            $queryClientDotSecretStageSecret = "guard-baseurl-client-dot-secret-stage-secret"
            $querySetDotCookieAltSecret = "guard-baseurl-set-dot-cookie-alt-secret"
            $querySessionDotIdBackupSecret = "guard-baseurl-session-dot-id-backup-secret"
            $queryFragmentTokenSecret = "guard-baseurl-fragment-token-secret"
            $queryFragmentApiKeyCamelAltSecret = "guard-baseurl-fragment-apikey-camel-alt-secret"
            $queryFragmentSessionIdCamelBackupSecret = "guard-baseurl-fragment-sessionid-camel-backup-secret"
            $queryFragmentApiKeyEncodedBracketIndexSecret = "guard-baseurl-fragment-apikey-encoded-bracket-index-secret"
            $queryFragmentSessionIdEncodedBracketMetaSecret = "guard-baseurl-fragment-sessionid-encoded-bracket-meta-secret"
            $queryFragmentApiKeyEncodedBracketNestedSecret = "guard-baseurl-fragment-apikey-encoded-bracket-nested-secret"
            $queryFragmentSessionIdEncodedBracketNestedSecret = "guard-baseurl-fragment-sessionid-encoded-bracket-nested-secret"
            $queryFragmentApiKeyDoubleEncodedBracketIndexSecret = "guard-baseurl-fragment-apikey-double-encoded-bracket-index-secret"
            $queryFragmentSessionIdDoubleEncodedBracketMetaSecret = "guard-baseurl-fragment-sessionid-double-encoded-bracket-meta-secret"
            $queryFragmentApiKeyDoubleEncodedBracketNestedSecret = "guard-baseurl-fragment-apikey-double-encoded-bracket-nested-secret"
            $queryFragmentSessionIdDoubleEncodedBracketNestedSecret = "guard-baseurl-fragment-sessionid-double-encoded-bracket-nested-secret"
            $queryFragmentApiKeyTripleEncodedBracketIndexSecret = "guard-baseurl-fragment-apikey-triple-encoded-bracket-index-secret"
            $queryFragmentSessionIdTripleEncodedBracketMetaSecret = "guard-baseurl-fragment-sessionid-triple-encoded-bracket-meta-secret"
            $queryFragmentApiKeyTripleEncodedBracketNestedSecret = "guard-baseurl-fragment-apikey-triple-encoded-bracket-nested-secret"
            $queryFragmentSessionIdTripleEncodedBracketNestedSecret = "guard-baseurl-fragment-sessionid-triple-encoded-bracket-nested-secret"
            $queryFragmentApiKeyQuadrupleEncodedBracketIndexSecret = "guard-baseurl-fragment-apikey-quadruple-encoded-bracket-index-secret"
            $queryFragmentSessionIdQuadrupleEncodedBracketMetaSecret = "guard-baseurl-fragment-sessionid-quadruple-encoded-bracket-meta-secret"
            $queryFragmentApiKeyQuadrupleEncodedBracketNestedSecret = "guard-baseurl-fragment-apikey-quadruple-encoded-bracket-nested-secret"
            $queryFragmentSessionIdQuadrupleEncodedBracketNestedSecret = "guard-baseurl-fragment-sessionid-quadruple-encoded-bracket-nested-secret"
            $queryFragmentApiKeyEncodedLowerHexBracketIndexSecret = "guard-baseurl-fragment-apikey-encoded-lowerhex-bracket-index-secret"
            $queryFragmentSessionIdEncodedLowerHexBracketMetaSecret = "guard-baseurl-fragment-sessionid-encoded-lowerhex-bracket-meta-secret"
            $queryFragmentApiKeyDoubleEncodedLowerHexBracketIndexSecret = "guard-baseurl-fragment-apikey-double-encoded-lowerhex-bracket-index-secret"
            $queryFragmentSessionIdDoubleEncodedLowerHexBracketMetaSecret = "guard-baseurl-fragment-sessionid-double-encoded-lowerhex-bracket-meta-secret"
            $queryFragmentApiKeyTripleEncodedLowerHexBracketIndexSecret = "guard-baseurl-fragment-apikey-triple-encoded-lowerhex-bracket-index-secret"
            $queryFragmentSessionIdTripleEncodedLowerHexBracketMetaSecret = "guard-baseurl-fragment-sessionid-triple-encoded-lowerhex-bracket-meta-secret"
            $queryFragmentApiKeyQuadrupleEncodedLowerHexBracketIndexSecret = "guard-baseurl-fragment-apikey-quadruple-encoded-lowerhex-bracket-index-secret"
            $queryFragmentSessionIdQuadrupleEncodedLowerHexBracketMetaSecret = "guard-baseurl-fragment-sessionid-quadruple-encoded-lowerhex-bracket-meta-secret"
            $rawBaseUrl = ('http://127.0.0.1:{0}?api_key={1}&x_api_key={2}&x_api_key_alt_backup={3}&password={4}&password_temp={5}&client_secret={6}&client_secret_stage={7}&secret_backup={8}&refresh_token={9}&access_token_alt_stage={10}&cookie={11}&cookie_alt={12}&set-cookie-alt={13}&sessionid={14}&sessionid_backup={15}&authorization={16}&id_token={17}&id_token_backup={18}' -f `
                $smokePort, `
                $queryApiKeySecret, `
                $queryXApiKeySecret, `
                $queryXApiKeyBackupSecret, `
                $queryPasswordSecret, `
                $queryPasswordTempSecret, `
                $queryClientSecret, `
                $queryClientSecretStageSecret, `
                $querySecretBackupSecret, `
                $queryRefreshSecret, `
                $queryAccessTokenStageSecret, `
                $queryCookieSecret, `
                $queryCookieAltSecret, `
                $querySetCookieAltSecret, `
                $querySessionSecret, `
                $querySessionBackupSecret, `
                $queryAuthorizationSecret, `
                $queryIdTokenSecret, `
                $queryIdTokenBackupSecret)
            $rawBaseUrl += ('&password.temp={0}&client_secret.stage={1}&secret.backup={2}&cookie.alt={3}&set-cookie.alt={4}&sessionid.backup={5}' -f `
                $queryPasswordDotTempSecret, `
                $queryClientSecretDotStageSecret, `
                $querySecretDotBackupSecret, `
                $queryCookieDotAltSecret, `
                $querySetCookieDotAltSecret, `
                $querySessionDotBackupSecret)
            $rawBaseUrl += ('&apiKeyAlt={0}&sessionIdBackup={1}&api_key%5B0%5D={2}&sessionIdBackup%5Bmeta%5D={3}&api_key%5B0%5D%5Bleaf%5D={4}&sessionIdBackup%5Bmeta%5D%5B0%5D={5}&api_key%255B0%255D={6}&sessionIdBackup%255Bmeta%255D={7}&api_key%255B0%255D%255Bleaf%255D={8}&sessionIdBackup%255Bmeta%255D%255B0%255D={9}&api_key%25255B0%25255D={10}&sessionIdBackup%25255Bmeta%25255D={11}&api_key%25255B0%25255D%25255Bleaf%25255D={12}&sessionIdBackup%25255Bmeta%25255D%25255B0%25255D={13}&api_key%2525255B0%2525255D={14}&sessionIdBackup%2525255Bmeta%2525255D={15}&api_key%2525255B0%2525255D%2525255Bleaf%2525255D={16}&sessionIdBackup%2525255Bmeta%2525255D%2525255B0%2525255D={17}' -f `
                $queryApiKeyCamelAltSecret, `
                $querySessionIdCamelBackupSecret, `
                $queryApiKeyEncodedBracketIndexSecret, `
                $querySessionIdEncodedBracketMetaSecret, `
                $queryApiKeyEncodedBracketNestedSecret, `
                $querySessionIdEncodedBracketNestedSecret, `
                $queryApiKeyDoubleEncodedBracketIndexSecret, `
                $querySessionIdDoubleEncodedBracketMetaSecret, `
                $queryApiKeyDoubleEncodedBracketNestedSecret, `
                $querySessionIdDoubleEncodedBracketNestedSecret, `
                $queryApiKeyTripleEncodedBracketIndexSecret, `
                $querySessionIdTripleEncodedBracketMetaSecret, `
                $queryApiKeyTripleEncodedBracketNestedSecret, `
                $querySessionIdTripleEncodedBracketNestedSecret, `
                $queryApiKeyQuadrupleEncodedBracketIndexSecret, `
                $querySessionIdQuadrupleEncodedBracketMetaSecret, `
                $queryApiKeyQuadrupleEncodedBracketNestedSecret, `
                $querySessionIdQuadrupleEncodedBracketNestedSecret)
            $rawBaseUrl += ('&api_key%5b0%5d={0}&sessionIdBackup%5bmeta%5d={1}&api_key%255b0%255d={2}&sessionIdBackup%255bmeta%255d={3}&api_key%25255b0%25255d={4}&sessionIdBackup%25255bmeta%25255d={5}&api_key%2525255b0%2525255d={6}&sessionIdBackup%2525255bmeta%2525255d={7}' -f `
                $queryApiKeyEncodedLowerHexBracketIndexSecret, `
                $querySessionIdEncodedLowerHexBracketMetaSecret, `
                $queryApiKeyDoubleEncodedLowerHexBracketIndexSecret, `
                $querySessionIdDoubleEncodedLowerHexBracketMetaSecret, `
                $queryApiKeyTripleEncodedLowerHexBracketIndexSecret, `
                $querySessionIdTripleEncodedLowerHexBracketMetaSecret, `
                $queryApiKeyQuadrupleEncodedLowerHexBracketIndexSecret, `
                $querySessionIdQuadrupleEncodedLowerHexBracketMetaSecret)
            $rawBaseUrl += ('&api.key.alt={0}&x.api.key.alt={1}&access.token.stage={2}&id.token.backup={3}&refresh.token.alt={4}&proxy.authorization.alt={5}&client.secret.stage={6}&set.cookie.alt={7}&session.id.backup={8}' -f `
                $queryApiDotKeyAltSecret, `
                $queryXDotApiKeyAltSecret, `
                $queryAccessDotTokenStageSecret, `
                $queryIdDotTokenBackupSecret, `
                $queryRefreshDotTokenAltSecret, `
                $queryProxyDotAuthorizationAltSecret, `
                $queryClientDotSecretStageSecret, `
                $querySetDotCookieAltSecret, `
                $querySessionDotIdBackupSecret)
            $rawBaseUrl += ('#access_token={0}&apiKeyAlt={1}&sessionIdBackup={2}&api_key%5B0%5D={3}&sessionIdBackup%5Bmeta%5D={4}&api_key%5B0%5D%5Bleaf%5D={5}&sessionIdBackup%5Bmeta%5D%5B0%5D={6}&api_key%255B0%255D={7}&sessionIdBackup%255Bmeta%255D={8}&api_key%255B0%255D%255Bleaf%255D={9}&sessionIdBackup%255Bmeta%255D%255B0%255D={10}&api_key%25255B0%25255D={11}&sessionIdBackup%25255Bmeta%25255D={12}&api_key%25255B0%25255D%25255Bleaf%25255D={13}&sessionIdBackup%25255Bmeta%25255D%25255B0%25255D={14}&api_key%2525255B0%2525255D={15}&sessionIdBackup%2525255Bmeta%2525255D={16}&api_key%2525255B0%2525255D%2525255Bleaf%2525255D={17}&sessionIdBackup%2525255Bmeta%2525255D%2525255B0%2525255D={18}' -f `
                $queryFragmentTokenSecret, `
                $queryFragmentApiKeyCamelAltSecret, `
                $queryFragmentSessionIdCamelBackupSecret, `
                $queryFragmentApiKeyEncodedBracketIndexSecret, `
                $queryFragmentSessionIdEncodedBracketMetaSecret, `
                $queryFragmentApiKeyEncodedBracketNestedSecret, `
                $queryFragmentSessionIdEncodedBracketNestedSecret, `
                $queryFragmentApiKeyDoubleEncodedBracketIndexSecret, `
                $queryFragmentSessionIdDoubleEncodedBracketMetaSecret, `
                $queryFragmentApiKeyDoubleEncodedBracketNestedSecret, `
                $queryFragmentSessionIdDoubleEncodedBracketNestedSecret, `
                $queryFragmentApiKeyTripleEncodedBracketIndexSecret, `
                $queryFragmentSessionIdTripleEncodedBracketMetaSecret, `
                $queryFragmentApiKeyTripleEncodedBracketNestedSecret, `
                $queryFragmentSessionIdTripleEncodedBracketNestedSecret, `
                $queryFragmentApiKeyQuadrupleEncodedBracketIndexSecret, `
                $queryFragmentSessionIdQuadrupleEncodedBracketMetaSecret, `
                $queryFragmentApiKeyQuadrupleEncodedBracketNestedSecret, `
                $queryFragmentSessionIdQuadrupleEncodedBracketNestedSecret)
            $rawBaseUrl += ('&api_key%5b0%5d={0}&sessionIdBackup%5bmeta%5d={1}&api_key%255b0%255d={2}&sessionIdBackup%255bmeta%255d={3}&api_key%25255b0%25255d={4}&sessionIdBackup%25255bmeta%25255d={5}&api_key%2525255b0%2525255d={6}&sessionIdBackup%2525255bmeta%2525255d={7}' -f `
                $queryFragmentApiKeyEncodedLowerHexBracketIndexSecret, `
                $queryFragmentSessionIdEncodedLowerHexBracketMetaSecret, `
                $queryFragmentApiKeyDoubleEncodedLowerHexBracketIndexSecret, `
                $queryFragmentSessionIdDoubleEncodedLowerHexBracketMetaSecret, `
                $queryFragmentApiKeyTripleEncodedLowerHexBracketIndexSecret, `
                $queryFragmentSessionIdTripleEncodedLowerHexBracketMetaSecret, `
                $queryFragmentApiKeyQuadrupleEncodedLowerHexBracketIndexSecret, `
                $queryFragmentSessionIdQuadrupleEncodedLowerHexBracketMetaSecret)
            $expectedBaseUrl = ('http://127.0.0.1:{0}?api_key=[REDACTED]&x_api_key=[REDACTED]&x_api_key_alt_backup=[REDACTED]&password=[REDACTED]&password_temp=[REDACTED]&client_secret=[REDACTED]&client_secret_stage=[REDACTED]&secret_backup=[REDACTED]&refresh_token=[REDACTED]&access_token_alt_stage=[REDACTED]&cookie=[REDACTED]&cookie_alt=[REDACTED]&set-cookie-alt=[REDACTED]&sessionid=[REDACTED]&sessionid_backup=[REDACTED]&authorization=[REDACTED]&id_token=[REDACTED]&id_token_backup=[REDACTED]' -f $smokePort)
            $expectedBaseUrl += '&password.temp=[REDACTED]&client_secret.stage=[REDACTED]&secret.backup=[REDACTED]&cookie.alt=[REDACTED]&set-cookie.alt=[REDACTED]&sessionid.backup=[REDACTED]'
            $expectedBaseUrl += '&apiKeyAlt=[REDACTED]&sessionIdBackup=[REDACTED]&api_key%5B0%5D=[REDACTED]&sessionIdBackup%5Bmeta%5D=[REDACTED]&api_key%5B0%5D%5Bleaf%5D=[REDACTED]&sessionIdBackup%5Bmeta%5D%5B0%5D=[REDACTED]&api_key%255B0%255D=[REDACTED]&sessionIdBackup%255Bmeta%255D=[REDACTED]&api_key%255B0%255D%255Bleaf%255D=[REDACTED]&sessionIdBackup%255Bmeta%255D%255B0%255D=[REDACTED]&api_key%25255B0%25255D=[REDACTED]&sessionIdBackup%25255Bmeta%25255D=[REDACTED]&api_key%25255B0%25255D%25255Bleaf%25255D=[REDACTED]&sessionIdBackup%25255Bmeta%25255D%25255B0%25255D=[REDACTED]&api_key%2525255B0%2525255D=[REDACTED]&sessionIdBackup%2525255Bmeta%2525255D=[REDACTED]&api_key%2525255B0%2525255D%2525255Bleaf%2525255D=[REDACTED]&sessionIdBackup%2525255Bmeta%2525255D%2525255B0%2525255D=[REDACTED]'
            $expectedBaseUrl += '&api_key%5b0%5d=[REDACTED]&sessionIdBackup%5bmeta%5d=[REDACTED]&api_key%255b0%255d=[REDACTED]&sessionIdBackup%255bmeta%255d=[REDACTED]&api_key%25255b0%25255d=[REDACTED]&sessionIdBackup%25255bmeta%25255d=[REDACTED]&api_key%2525255b0%2525255d=[REDACTED]&sessionIdBackup%2525255bmeta%2525255d=[REDACTED]'
            $expectedBaseUrl += '&api.key.alt=[REDACTED]&x.api.key.alt=[REDACTED]&access.token.stage=[REDACTED]&id.token.backup=[REDACTED]&refresh.token.alt=[REDACTED]&proxy.authorization.alt=[REDACTED]&client.secret.stage=[REDACTED]&set.cookie.alt=[REDACTED]&session.id.backup=[REDACTED]'
            $expectedBaseUrl += '#access_token=[REDACTED]&apiKeyAlt=[REDACTED]&sessionIdBackup=[REDACTED]&api_key%5B0%5D=[REDACTED]&sessionIdBackup%5Bmeta%5D=[REDACTED]&api_key%5B0%5D%5Bleaf%5D=[REDACTED]&sessionIdBackup%5Bmeta%5D%5B0%5D=[REDACTED]&api_key%255B0%255D=[REDACTED]&sessionIdBackup%255Bmeta%255D=[REDACTED]&api_key%255B0%255D%255Bleaf%255D=[REDACTED]&sessionIdBackup%255Bmeta%255D%255B0%255D=[REDACTED]&api_key%25255B0%25255D=[REDACTED]&sessionIdBackup%25255Bmeta%25255D=[REDACTED]&api_key%25255B0%25255D%25255Bleaf%25255D=[REDACTED]&sessionIdBackup%25255Bmeta%25255D%25255B0%25255D=[REDACTED]&api_key%2525255B0%2525255D=[REDACTED]&sessionIdBackup%2525255Bmeta%2525255D=[REDACTED]&api_key%2525255B0%2525255D%2525255Bleaf%2525255D=[REDACTED]&sessionIdBackup%2525255Bmeta%2525255D%2525255B0%2525255D=[REDACTED]'
            $expectedBaseUrl += '&api_key%5b0%5d=[REDACTED]&sessionIdBackup%5bmeta%5d=[REDACTED]&api_key%255b0%255d=[REDACTED]&sessionIdBackup%255bmeta%255d=[REDACTED]&api_key%25255b0%25255d=[REDACTED]&sessionIdBackup%25255bmeta%25255d=[REDACTED]&api_key%2525255b0%2525255d=[REDACTED]&sessionIdBackup%2525255bmeta%2525255d=[REDACTED]'
            $caseRoot = Join-Path $tempRoot "case-smoke-baseurl-query-secrets-redacted"
            New-Item -ItemType Directory -Force -Path $caseRoot | Out-Null
            $reportPath = Join-Path $caseRoot "smoke.report.json"
            $stdoutPath = Join-Path $caseRoot "smoke.stdout.log"
            $stderrPath = Join-Path $caseRoot "smoke.stderr.log"
            try {
                $invoke = Invoke-ScriptSubprocess `
                    -ScriptPath $smokeTestScript `
                    -ArgumentList @(
                        "-BaseUrl", $rawBaseUrl,
                        "-TimeoutSeconds", "2",
                        "-CheckRetryCount", "1",
                        "-CheckRetryDelayMilliseconds", "25",
                        "-HealthPollDelayMilliseconds", "25",
                        "-FailureContentSnippetLength", "160",
                        "-OutputJsonPath", $reportPath
                    ) `
                    -StdOutPath $stdoutPath `
                    -StdErrPath $stderrPath

                if ($invoke.ExitCode -ne 1) {
                    $out = if (Test-Path $stdoutPath) { Get-Content -Path $stdoutPath -Raw } else { "" }
                    $err = if (Test-Path $stderrPath) { Get-Content -Path $stderrPath -Raw } else { "" }
                    throw "Expected smoke subprocess exit code 1, got $($invoke.ExitCode). Out='$out' Err='$err'"
                }

                Assert-TextLogHasNoNulBytes -LogPath $stdoutPath -Label "Smoke stdout log"
                Assert-TextLogHasNoNulBytes -LogPath $stderrPath -Label "Smoke stderr log"

                if (-not (Test-Path $reportPath)) {
                    throw "Smoke report was not generated: $reportPath"
                }

                $reportText = Get-Content -Path $reportPath -Raw
                $report = $reportText | ConvertFrom-Json
                Assert-StringHasNoControlChars -Value ([string]$report.baseUrl) -Label "Smoke report baseUrl"
                if ([string]$report.baseUrl -ne $expectedBaseUrl) {
                    throw "Expected report.baseUrl='$expectedBaseUrl', got '$($report.baseUrl)'."
                }

                $stdoutText = if (Test-Path $stdoutPath) { Get-Content -Path $stdoutPath -Raw } else { "" }
                $stderrText = if (Test-Path $stderrPath) { Get-Content -Path $stderrPath -Raw } else { "" }
                $combinedText = "$reportText`n$stdoutText`n$stderrText"

                foreach ($forbidden in @(
                    $queryApiKeySecret,
                    $queryXApiKeySecret,
                    $queryXApiKeyBackupSecret,
                    $queryApiKeyCamelAltSecret,
                    $queryPasswordSecret,
                    $queryPasswordTempSecret,
                    $queryClientSecret,
                    $queryClientSecretStageSecret,
                    $querySecretBackupSecret,
                    $queryRefreshSecret,
                    $queryAccessTokenStageSecret,
                    $queryCookieSecret,
                    $queryCookieAltSecret,
                    $querySetCookieAltSecret,
                    $querySessionSecret,
                    $querySessionBackupSecret,
                    $querySessionIdCamelBackupSecret,
                    $queryApiKeyEncodedBracketIndexSecret,
                    $querySessionIdEncodedBracketMetaSecret,
                    $queryApiKeyEncodedBracketNestedSecret,
                    $querySessionIdEncodedBracketNestedSecret,
                    $queryApiKeyDoubleEncodedBracketIndexSecret,
                    $querySessionIdDoubleEncodedBracketMetaSecret,
                    $queryApiKeyDoubleEncodedBracketNestedSecret,
                    $querySessionIdDoubleEncodedBracketNestedSecret,
                    $queryApiKeyTripleEncodedBracketIndexSecret,
                    $querySessionIdTripleEncodedBracketMetaSecret,
                    $queryApiKeyTripleEncodedBracketNestedSecret,
                    $querySessionIdTripleEncodedBracketNestedSecret,
                    $queryApiKeyQuadrupleEncodedBracketIndexSecret,
                    $querySessionIdQuadrupleEncodedBracketMetaSecret,
                    $queryApiKeyQuadrupleEncodedBracketNestedSecret,
                    $querySessionIdQuadrupleEncodedBracketNestedSecret,
                    $queryApiKeyEncodedLowerHexBracketIndexSecret,
                    $querySessionIdEncodedLowerHexBracketMetaSecret,
                    $queryApiKeyDoubleEncodedLowerHexBracketIndexSecret,
                    $querySessionIdDoubleEncodedLowerHexBracketMetaSecret,
                    $queryApiKeyTripleEncodedLowerHexBracketIndexSecret,
                    $querySessionIdTripleEncodedLowerHexBracketMetaSecret,
                    $queryApiKeyQuadrupleEncodedLowerHexBracketIndexSecret,
                    $querySessionIdQuadrupleEncodedLowerHexBracketMetaSecret,
                    $queryPasswordDotTempSecret,
                    $queryClientSecretDotStageSecret,
                    $querySecretDotBackupSecret,
                    $queryCookieDotAltSecret,
                    $querySetCookieDotAltSecret,
                    $querySessionDotBackupSecret,
                    $queryApiDotKeyAltSecret,
                    $queryXDotApiKeyAltSecret,
                    $queryAccessDotTokenStageSecret,
                    $queryIdDotTokenBackupSecret,
                    $queryRefreshDotTokenAltSecret,
                    $queryProxyDotAuthorizationAltSecret,
                    $queryClientDotSecretStageSecret,
                    $querySetDotCookieAltSecret,
                    $querySessionDotIdBackupSecret,
                    $queryFragmentTokenSecret,
                    $queryFragmentApiKeyCamelAltSecret,
                    $queryFragmentSessionIdCamelBackupSecret,
                    $queryFragmentApiKeyEncodedBracketIndexSecret,
                    $queryFragmentSessionIdEncodedBracketMetaSecret,
                    $queryFragmentApiKeyEncodedBracketNestedSecret,
                    $queryFragmentSessionIdEncodedBracketNestedSecret,
                    $queryFragmentApiKeyDoubleEncodedBracketIndexSecret,
                    $queryFragmentSessionIdDoubleEncodedBracketMetaSecret,
                    $queryFragmentApiKeyDoubleEncodedBracketNestedSecret,
                    $queryFragmentSessionIdDoubleEncodedBracketNestedSecret,
                    $queryFragmentApiKeyTripleEncodedBracketIndexSecret,
                    $queryFragmentSessionIdTripleEncodedBracketMetaSecret,
                    $queryFragmentApiKeyTripleEncodedBracketNestedSecret,
                    $queryFragmentSessionIdTripleEncodedBracketNestedSecret,
                    $queryFragmentApiKeyQuadrupleEncodedBracketIndexSecret,
                    $queryFragmentSessionIdQuadrupleEncodedBracketMetaSecret,
                    $queryFragmentApiKeyQuadrupleEncodedBracketNestedSecret,
                    $queryFragmentSessionIdQuadrupleEncodedBracketNestedSecret,
                    $queryFragmentApiKeyEncodedLowerHexBracketIndexSecret,
                    $queryFragmentSessionIdEncodedLowerHexBracketMetaSecret,
                    $queryFragmentApiKeyDoubleEncodedLowerHexBracketIndexSecret,
                    $queryFragmentSessionIdDoubleEncodedLowerHexBracketMetaSecret,
                    $queryFragmentApiKeyTripleEncodedLowerHexBracketIndexSecret,
                    $queryFragmentSessionIdTripleEncodedLowerHexBracketMetaSecret,
                    $queryFragmentApiKeyQuadrupleEncodedLowerHexBracketIndexSecret,
                    $queryFragmentSessionIdQuadrupleEncodedLowerHexBracketMetaSecret,
                    $queryAuthorizationSecret,
                    $queryIdTokenSecret,
                    $queryIdTokenBackupSecret
                )) {
                    Assert-StringDoesNotContain -Value $combinedText -Forbidden $forbidden -Label "Smoke outputs"
                }

                $expectedContext = "BaseUrl: $expectedBaseUrl"
                if ($stdoutText.IndexOf($expectedContext, [System.StringComparison]::Ordinal) -lt 0) {
                    throw "Expected smoke stdout context to include redacted base URL: $expectedContext"
                }
            }
            finally {
                Stop-ListenerServer -Server $smokeServer
            }
        }))

    $results.Add((Run-Case `
        -Name "require-manifest-missing" `
        -ExpectFailure $true `
        -ExpectedMessagePart "RequireManifest is enabled, but package manifest file was not found." `
        -Action {
            & $deployApiScript `
                -PackageZip $zipOnlyPath `
                -RequireManifest `
                -ReleaseRoot (Join-Path $tempRoot "case-require-manifest-missing") `
                -SkipServiceInstall `
                -SkipHealthCheck
        }))

    $results.Add((Run-Case `
        -Name "package-index-invalid-json" `
        -ExpectFailure $true `
        -ExpectedMessagePart "Package index is invalid JSON" `
        -Action {
            $params = @{
                PackageZip = $resolvedZip
                PackageManifestFile = $resolvedManifest
                PackageIndexFile = $invalidIndexPath
                ReleaseRoot = (Join-Path $tempRoot "case-package-index-invalid-json")
                SkipServiceInstall = $true
                SkipHealthCheck = $true
            }
            if (-not [string]::IsNullOrWhiteSpace($resolvedSha)) {
                $params.PackageSha256File = $resolvedSha
            }

            & $deployApiScript @params
        }))

    $results.Add((Run-Case `
        -Name "package-index-sha-mismatch" `
        -ExpectFailure $true `
        -ExpectedMessagePart "Package index hash mismatch" `
        -Action {
            $params = @{
                PackageZip = $resolvedZip
                PackageManifestFile = $resolvedManifest
                PackageIndexFile = $validIndexPath
                PackageIndexSha256File = $invalidIndexShaPath
                ReleaseRoot = (Join-Path $tempRoot "case-package-index-sha-mismatch")
                SkipServiceInstall = $true
                SkipHealthCheck = $true
            }
            if (-not [string]::IsNullOrWhiteSpace($resolvedSha)) {
                $params.PackageSha256File = $resolvedSha
            }

            & $deployApiScript @params
        }))

    $results.Add((Run-Case `
        -Name "package-index-valid" `
        -ExpectFailure $false `
        -ExpectedMessagePart "" `
        -Action {
            $params = @{
                PackageZip = $resolvedZip
                PackageManifestFile = $resolvedManifest
                PackageIndexFile = $validIndexPath
                PackageIndexSha256File = $validIndexShaPath
                ReleaseRoot = (Join-Path $tempRoot "case-package-index-valid")
                SkipServiceInstall = $true
                SkipHealthCheck = $true
            }
            if (-not [string]::IsNullOrWhiteSpace($resolvedSha)) {
                $params.PackageSha256File = $resolvedSha
            }

            & $deployApiScript @params
        }))

    $results.Add((Run-Case `
        -Name "require-manifest-success" `
        -ExpectFailure $false `
        -ExpectedMessagePart "" `
        -Action {
            $params = @{
                PackageZip = $resolvedZip
                PackageManifestFile = $resolvedManifest
                RequireManifest = $true
                ReleaseRoot = (Join-Path $tempRoot "case-require-manifest-success")
                SkipServiceInstall = $true
                SkipHealthCheck = $true
            }
            if (-not [string]::IsNullOrWhiteSpace($resolvedSha)) {
                $params.PackageSha256File = $resolvedSha
            }

            & $deployApiScript @params
        }))

    if ($IncludeOnlineSmokeCase) {
        $results.Add((Run-Case `
            -Name "prod-wrapper-smoke-success" `
            -ExpectFailure $false `
            -ExpectedMessagePart "" `
            -Action {
                $effectivePublishDir = $OnlineSmokePublishDir
                if ([string]::IsNullOrWhiteSpace($effectivePublishDir)) {
                    if (-not [string]::IsNullOrWhiteSpace($script:AutoPackagePublishDir)) {
                        $effectivePublishDir = $script:AutoPackagePublishDir
                    }
                    else {
                        $packageName = [System.IO.Path]::GetFileNameWithoutExtension($resolvedZip)
                        $effectivePublishDir = Resolve-PublishDirForAutoPackage -Root $root -PackageName $packageName
                    }
                }

                if ([string]::IsNullOrWhiteSpace($effectivePublishDir)) {
                    throw "OnlineSmokePublishDir is empty and no valid publish directory was found under artifacts\\publish."
                }

                $resolvedPublishDir = [System.IO.Path]::GetFullPath($effectivePublishDir)
                if (-not (Test-Path $resolvedPublishDir)) {
                    throw "OnlineSmokePublishDir not found: $resolvedPublishDir"
                }

                $apiExe = Join-Path $resolvedPublishDir "DataHz.Api.exe"
                if (-not (Test-Path $apiExe)) {
                    throw "DataHz.Api.exe not found in OnlineSmokePublishDir: $resolvedPublishDir"
                }

                $port = Get-FreeTcpPort
                $url = "http://127.0.0.1:$port"
                $hostOutLog = Join-Path $tempRoot "case-prod-wrapper-smoke-success.host.out.log"
                $hostErrLog = Join-Path $tempRoot "case-prod-wrapper-smoke-success.host.err.log"

                $hostProc = $null
                try {
                    $hostProc = Start-Process `
                        -FilePath $apiExe `
                        -ArgumentList @("--contentRoot", $resolvedPublishDir, "--environment", "Production", "--urls", $url) `
                        -PassThru `
                        -WindowStyle Hidden `
                        -RedirectStandardOutput $hostOutLog `
                        -RedirectStandardError $hostErrLog

                    Start-Sleep -Seconds ([Math]::Max(1, $OnlineSmokeStartupSeconds))
                    if ($hostProc.HasExited) {
                        $out = if (Test-Path $hostOutLog) { Get-Content -Path $hostOutLog -Raw } else { "" }
                        $err = if (Test-Path $hostErrLog) { Get-Content -Path $hostErrLog -Raw } else { "" }
                        throw "Online smoke host exited early. Out='$out' Err='$err'"
                    }

                    $prodParams = @{
                        PackageUrl = $zipFileUri
                        PackageManifestUrl = $manifestFileUri
                        PackageIndexUrl = $validIndexFileUri
                        PackageIndexSha256Url = $validIndexShaFileUri
                        AllowUnsafeBypass = $true
                        ReleaseRoot = (Join-Path $tempRoot "case-prod-wrapper-smoke-success")
                        Urls = $url
                        HealthCheckIntervalSeconds = 1
                        SkipServiceInstall = $true
                        SkipHealthCheck = $true
                    }
                    if (-not [string]::IsNullOrWhiteSpace($shaFileUri)) {
                        $prodParams.PackageSha256Url = $shaFileUri
                    }

                    & $deployProdScript @prodParams
                }
                finally {
                    if ($hostProc -and -not $hostProc.HasExited) {
                        Stop-Process -Id $hostProc.Id -Force -ErrorAction SilentlyContinue
                    }
                }
            }))

        $results.Add((Run-Case `
            -Name "prod-auto-wrapper-smoke-success" `
            -ExpectFailure $false `
            -ExpectedMessagePart "" `
            -Action {
                $effectivePublishDir = $OnlineSmokePublishDir
                if ([string]::IsNullOrWhiteSpace($effectivePublishDir)) {
                    if (-not [string]::IsNullOrWhiteSpace($script:AutoPackagePublishDir)) {
                        $effectivePublishDir = $script:AutoPackagePublishDir
                    }
                    else {
                        $packageName = [System.IO.Path]::GetFileNameWithoutExtension($resolvedZip)
                        $effectivePublishDir = Resolve-PublishDirForAutoPackage -Root $root -PackageName $packageName
                    }
                }

                if ([string]::IsNullOrWhiteSpace($effectivePublishDir)) {
                    throw "OnlineSmokePublishDir is empty and no valid publish directory was found under artifacts\\publish."
                }

                $resolvedPublishDir = [System.IO.Path]::GetFullPath($effectivePublishDir)
                if (-not (Test-Path $resolvedPublishDir)) {
                    throw "OnlineSmokePublishDir not found: $resolvedPublishDir"
                }

                $apiExe = Join-Path $resolvedPublishDir "DataHz.Api.exe"
                if (-not (Test-Path $apiExe)) {
                    throw "DataHz.Api.exe not found in OnlineSmokePublishDir: $resolvedPublishDir"
                }

                $port = Get-FreeTcpPort
                $url = "http://127.0.0.1:$port"
                $hostOutLog = Join-Path $tempRoot "case-prod-auto-wrapper-smoke-success.host.out.log"
                $hostErrLog = Join-Path $tempRoot "case-prod-auto-wrapper-smoke-success.host.err.log"
                $wrapperLogsRoot = Join-Path $tempRoot "case-prod-auto-wrapper-smoke-success.wrapper-logs"
                New-Item -ItemType Directory -Force -Path $wrapperLogsRoot | Out-Null
                $wrapperOutLog = Join-Path $wrapperLogsRoot "wrapper.out.log"
                $wrapperErrLog = Join-Path $wrapperLogsRoot "wrapper.err.log"

                $hostProc = $null
                try {
                    $hostProc = Start-Process `
                        -FilePath $apiExe `
                        -ArgumentList @("--contentRoot", $resolvedPublishDir, "--environment", "Production", "--urls", $url) `
                        -PassThru `
                        -WindowStyle Hidden `
                        -RedirectStandardOutput $hostOutLog `
                        -RedirectStandardError $hostErrLog

                    Start-Sleep -Seconds ([Math]::Max(1, $OnlineSmokeStartupSeconds))
                    if ($hostProc.HasExited) {
                        $out = if (Test-Path $hostOutLog) { Get-Content -Path $hostOutLog -Raw } else { "" }
                        $err = if (Test-Path $hostErrLog) { Get-Content -Path $hostErrLog -Raw } else { "" }
                        throw "Online smoke host exited early. Out='$out' Err='$err'"
                    }

                    $wrapperArgs = @(
                        "-ServiceName", "DataHz.Api",
                        "-PackageUrl", $zipFileUri,
                        "-PackageManifestUrl", $manifestFileUri,
                        "-PackageIndexUrl", $validIndexFileUri,
                        "-PackageIndexSha256Url", $validIndexShaFileUri,
                        "-AllowUnsafeBypass",
                        "-ReleaseRoot", (Join-Path $tempRoot "case-prod-auto-wrapper-smoke-success"),
                        "-Urls", $url,
                        "-HealthCheckIntervalSeconds", "1",
                        "-SkipServiceInstall",
                        "-SkipHealthCheck",
                        "-LogsRoot", $wrapperLogsRoot,
                        "-RunLabel", "guard-online-success"
                    )
                    if (-not [string]::IsNullOrWhiteSpace($shaFileUri)) {
                        $wrapperArgs += @("-PackageSha256Url", $shaFileUri)
                    }

                    $invoke = Invoke-ScriptSubprocess `
                        -ScriptPath $deployProdAutoRollbackScript `
                        -ArgumentList $wrapperArgs `
                        -StdOutPath $wrapperOutLog `
                        -StdErrPath $wrapperErrLog

                    if ($invoke.ExitCode -ne 0) {
                        $out = if (Test-Path $wrapperOutLog) { Get-Content -Path $wrapperOutLog -Raw } else { "" }
                        $err = if (Test-Path $wrapperErrLog) { Get-Content -Path $wrapperErrLog -Raw } else { "" }
                        throw "Auto wrapper expected exit code 0, got $($invoke.ExitCode). Out='$out' Err='$err'"
                    }

                    $summary = Get-LatestRunSummary -LogsRootPath $wrapperLogsRoot
                    if ($null -eq $summary) {
                        throw "Auto wrapper run summary was not generated under $wrapperLogsRoot"
                    }

                    if (-not $summary.deploy.succeeded) {
                        throw "Auto wrapper summary expected deploy.succeeded=true for online success case."
                    }

                    if ($summary.rollback.attempted) {
                        throw "Auto wrapper summary expected rollback.attempted=false for online success case."
                    }

                    if ([string]::IsNullOrWhiteSpace($summary.deploy.smokeReportPath) -or -not (Test-Path $summary.deploy.smokeReportPath)) {
                        throw "Auto wrapper smoke report path missing or not found."
                    }

                    if ([string]::IsNullOrWhiteSpace($summary.runId)) {
                        throw "Auto wrapper summary runId is empty."
                    }
                }
                finally {
                    if ($hostProc -and -not $hostProc.HasExited) {
                        Stop-Process -Id $hostProc.Id -Force -ErrorAction SilentlyContinue
                    }
                }
            }))
    }
}
finally {
    Stop-ListenerServer -Server $urlServer

    if (-not $KeepArtifacts) {
        Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    foreach ($generatedFile in $autoGeneratedPackageFiles) {
        if (Test-Path $generatedFile) {
            Remove-Item -Path $generatedFile -Force -ErrorAction SilentlyContinue
        }
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
    Write-Host "Deployment guard self-test failed: $($failed.Count) case(s)." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "Deployment guard self-test passed." -ForegroundColor Green
exit 0
