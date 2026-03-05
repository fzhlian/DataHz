using DataHz.Api.Audit;
using DataHz.Api.Contracts;
using DataHz.Api.Jobs;
using DataHz.Api.Monitoring;
using DataHz.Api.Security;
using DataHz.Core.Abstractions;
using DataHz.Core.Execution;
using DataHz.Infrastructure;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.Extensions.Options;
using Microsoft.IdentityModel.Tokens;
using Microsoft.OpenApi.Models;
using System.Diagnostics;
using System.Reflection;
using System.Security.Claims;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);

var builder = WebApplication.CreateBuilder(args);
const string ApiPrincipalItemKey = "__datahz_api_principal";

builder.Services.Configure<ExecutionJobOptions>(builder.Configuration.GetSection("JobQueue"));
builder.Services.Configure<ApiKeySecurityOptions>(builder.Configuration.GetSection("Security:ApiKey"));
builder.Services.Configure<JwtSecurityOptions>(builder.Configuration.GetSection("Security:Jwt"));
builder.Services.Configure<SecuritySecretSourceOptions>(builder.Configuration.GetSection("Security:Secrets"));
builder.Services.Configure<AuditOptions>(builder.Configuration.GetSection("Audit"));
builder.Services.Configure<MonitoringOptions>(builder.Configuration.GetSection("Monitoring"));

builder.Services
    .AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
    .AddJwtBearer();
builder.Services
    .AddOptions<JwtBearerOptions>(JwtBearerDefaults.AuthenticationScheme)
    .Configure<IOptions<JwtSecurityOptions>, IOptions<SecuritySecretSourceOptions>>(
        (options, jwt, secrets) => ConfigureJwtBearer(options, jwt.Value, secrets.Value));
builder.Services.AddAuthorization();

builder.Services.AddEndpointsApiExplorer();
builder.Services.AddSwaggerGen(options =>
{
    options.SwaggerDoc("v1", new OpenApiInfo
    {
        Title = "DataHz API 文档",
        Version = "v1",
        Description = "DataHz 2.0 服务接口（本地化中文说明）"
    });

    options.AddSecurityDefinition("ApiKey", new OpenApiSecurityScheme
    {
        Type = SecuritySchemeType.ApiKey,
        In = ParameterLocation.Header,
        Name = "X-Api-Key",
        Description = "API Key 鉴权，请在请求头中传入 X-Api-Key。"
    });

    options.AddSecurityDefinition("Bearer", new OpenApiSecurityScheme
    {
        Type = SecuritySchemeType.Http,
        Scheme = "bearer",
        BearerFormat = "JWT",
        In = ParameterLocation.Header,
        Description = "JWT 鉴权，请填写 Bearer Token（无需手工输入 Bearer 前缀）。"
    });
});
builder.Services.AddDataHzInfrastructure();
builder.Services.AddSingleton<IAuditTrail, FileAuditTrail>();
builder.Services.AddSingleton<IAuditLogReader, FileAuditLogReader>();
builder.Services.AddSingleton<ISecurityHardeningInspector, SecurityHardeningInspector>();
builder.Services.AddSingleton<IExecutionJobQueue, PersistentExecutionJobQueue>();
builder.Services.AddHostedService<ExecutionJobWorker>();
builder.Services.ConfigureHttpJsonOptions(options =>
{
    options.SerializerOptions.Converters.Add(new JsonStringEnumConverter());
});

var app = builder.Build();
var appStartedUtc = DateTimeOffset.UtcNow;

var apiKeyOptions = app.Services.GetRequiredService<IOptions<ApiKeySecurityOptions>>().Value;
var jwtOptions = app.Services.GetRequiredService<IOptions<JwtSecurityOptions>>().Value;
var secretSourceOptions = app.Services.GetRequiredService<IOptions<SecuritySecretSourceOptions>>().Value;
var auditTrail = app.Services.GetRequiredService<IAuditTrail>();
var monitoringOptions = app.Services.GetRequiredService<IOptions<MonitoringOptions>>().Value;
var apiKeyMap = BuildApiKeyMap(apiKeyOptions);
var hasPrimaryApiKey = SecuritySecretResolver.ResolveApiKeyCandidates(apiKeyOptions, secretSourceOptions).Count > 0;
var effectiveJwtSigningKey = SecuritySecretResolver.ResolveJwtSigningKey(jwtOptions, secretSourceOptions);

if (apiKeyOptions.Enabled && apiKeyMap.Count == 0 && !hasPrimaryApiKey)
{
    throw new InvalidOperationException(
        "Security:ApiKey enabled but no valid key configured. Set Security:ApiKey:Value or Security:ApiKey:Keys.");
}

if (jwtOptions.Enabled)
{
    var hasAuthority = !string.IsNullOrWhiteSpace(jwtOptions.Authority);
    var hasSigningKey = !string.IsNullOrWhiteSpace(effectiveJwtSigningKey);
    if (!hasAuthority && !hasSigningKey)
    {
        throw new InvalidOperationException(
            $"Security:Jwt enabled but no Authority and no key configured. Set Security:Jwt:Authority or provide key via {SecuritySecretResolver.JwtSigningKeyEnvVar}/Security:Jwt:SigningKey/Security:Secrets:JwtSigningKeyExternalRef.");
    }
}

if (jwtOptions.Enabled)
{
    app.UseAuthentication();
    app.UseAuthorization();
}

app.Use(async (context, next) =>
{
    var securityEnabled = apiKeyOptions.Enabled || jwtOptions.Enabled;
    if (!securityEnabled)
    {
        await next();
        return;
    }

    var path = context.Request.Path.Value ?? string.Empty;
    if (IsPublicPath(path) || !path.StartsWith("/api", StringComparison.OrdinalIgnoreCase))
    {
        await next();
        return;
    }

    ApiKeyPrincipal? principal = null;
    if (apiKeyOptions.Enabled &&
        context.Request.Headers.TryGetValue(apiKeyOptions.HeaderName, out var suppliedApiKey) &&
        !string.IsNullOrWhiteSpace(suppliedApiKey.FirstOrDefault()))
    {
        var key = suppliedApiKey[0] ?? string.Empty;
        if (!TryResolveApiKeyPrincipal(key, apiKeyMap, apiKeyOptions, secretSourceOptions, out principal))
        {
            context.Response.StatusCode = StatusCodes.Status401Unauthorized;
            await context.Response.WriteAsJsonAsync(new { message = "Invalid API key." });

            auditTrail.Write(new AuditEntry(
                DateTimeOffset.UtcNow,
                "security",
                "security.api_key_invalid",
                Message: context.Request.Path.Value,
                Path: context.Request.Path.Value,
                Method: context.Request.Method,
                StatusCode: context.Response.StatusCode,
                RemoteIp: GetRemoteIp(context)));
            return;
        }
    }

    if (principal is null && jwtOptions.Enabled)
    {
        principal = TryBuildJwtPrincipal(context.User);
    }

    if (principal is null)
    {
        var message = apiKeyOptions.Enabled && jwtOptions.Enabled
            ? $"Missing credentials. Use '{apiKeyOptions.HeaderName}' or a Bearer JWT token."
            : apiKeyOptions.Enabled
                ? $"Missing API key header: {apiKeyOptions.HeaderName}"
                : "Missing or invalid Bearer token.";

        context.Response.StatusCode = StatusCodes.Status401Unauthorized;
        await context.Response.WriteAsJsonAsync(new { message });

        auditTrail.Write(new AuditEntry(
            DateTimeOffset.UtcNow,
            "security",
            "security.credentials_missing",
            Message: context.Request.Path.Value,
            Path: context.Request.Path.Value,
            Method: context.Request.Method,
            StatusCode: context.Response.StatusCode,
            RemoteIp: GetRemoteIp(context)));
        return;
    }

    context.Items[ApiPrincipalItemKey] = principal;

    var requiredRole = ResolveRequiredRole(path, context.Request.Method);
    if (requiredRole is not null && principal.Role < requiredRole.Value)
    {
        context.Response.StatusCode = StatusCodes.Status403Forbidden;
        await context.Response.WriteAsJsonAsync(new
        {
            message = $"Role '{requiredRole.Value}' required for this endpoint.",
            principal = principal.Name,
            currentRole = principal.Role.ToString(),
            source = principal.Source
        });

        auditTrail.Write(new AuditEntry(
            DateTimeOffset.UtcNow,
            "security",
            "security.role_forbidden",
            Message: $"Required={requiredRole.Value}; Current={principal.Role}; Principal={principal.Name}; Source={principal.Source}",
            Path: context.Request.Path.Value,
            Method: context.Request.Method,
            StatusCode: context.Response.StatusCode,
            RemoteIp: GetRemoteIp(context)));
        return;
    }

    await next();
});

app.Use(async (context, next) =>
{
    var path = context.Request.Path.Value ?? string.Empty;
    if (!path.StartsWith("/api", StringComparison.OrdinalIgnoreCase))
    {
        await next();
        return;
    }

    var started = DateTimeOffset.UtcNow;
    var sw = Stopwatch.StartNew();
    try
    {
        await next();
    }
    finally
    {
        sw.Stop();
        auditTrail.Write(new AuditEntry(
            started,
            "api",
            "api.request",
            Message: $"Elapsed={sw.ElapsedMilliseconds}ms",
            Path: context.Request.Path.Value,
            Method: context.Request.Method,
            StatusCode: context.Response.StatusCode,
            RemoteIp: GetRemoteIp(context)));
    }
});

app.UseSwagger();
app.UseSwaggerUI(options =>
{
    options.DocumentTitle = "DataHz API 文档";
    options.SwaggerEndpoint("/swagger/v1/swagger.json", "DataHz API v1（中文）");
    options.InjectJavascript("/swagger-zh.js");
    options.DisplayRequestDuration();
});

app.Use(async (context, next) =>
{
    if (context.Request.Path.Equals("/dashboard", StringComparison.OrdinalIgnoreCase))
    {
        context.Response.Redirect("/dashboard/");
        return;
    }

    if (context.Request.Path.Equals("/workbench", StringComparison.OrdinalIgnoreCase))
    {
        context.Response.Redirect("/workbench/");
        return;
    }

    await next();
});

app.UseDefaultFiles();
app.UseStaticFiles();

app.MapGet("/health", () => Results.Ok(new
{
    status = "ok",
    service = "DataHz.Api",
    utc = DateTimeOffset.UtcNow
}))
    .WithTags("系统")
    .WithSummary("健康检查")
    .WithDescription("返回服务健康状态、服务名和当前 UTC 时间。");

app.MapGet("/api/security/whoami", (HttpContext context) =>
{
    var principal = TryGetPrincipal(context, ApiPrincipalItemKey);
    var securityEnabled = apiKeyOptions.Enabled || jwtOptions.Enabled;
    return Results.Ok(new
    {
        securityEnabled,
        apiKeyEnabled = apiKeyOptions.Enabled,
        jwtEnabled = jwtOptions.Enabled,
        headerName = apiKeyOptions.HeaderName,
        principal = principal?.Name ?? "anonymous",
        role = principal?.Role.ToString() ?? (securityEnabled ? "none" : AccessRole.Admin.ToString()),
        source = principal?.Source ?? (securityEnabled ? "none" : "local")
    });
})
    .WithTags("安全")
    .WithSummary("当前身份信息")
    .WithDescription("返回当前请求的鉴权状态、身份来源与角色信息。");

app.MapGet("/api/security/hardening", (ISecurityHardeningInspector inspector) =>
{
    return Results.Ok(inspector.Inspect());
})
    .WithTags("安全")
    .WithSummary("安全加固检查")
    .WithDescription("返回当前配置下的安全加固检查结果。");

app.MapGet("/api/security/secrets/runtime", (HttpContext context) =>
{
    var apiCandidates = SecuritySecretResolver.ResolveApiKeyCandidates(apiKeyOptions, secretSourceOptions);
    var jwtCandidates = SecuritySecretResolver.ResolveJwtSigningKeyCandidates(jwtOptions, secretSourceOptions);
    var principal = TryGetPrincipal(context, ApiPrincipalItemKey);

    auditTrail.Write(new AuditEntry(
        DateTimeOffset.UtcNow,
        "security",
        "security.secrets_runtime_read",
        Message: $"Principal={principal?.Name ?? "anonymous"}; ApiCandidates={apiCandidates.Count}; JwtCandidates={jwtCandidates.Count}",
        Path: context.Request.Path.Value,
        Method: context.Request.Method,
        StatusCode: StatusCodes.Status200OK,
        RemoteIp: GetRemoteIp(context)));

    return Results.Ok(new
    {
        utc = DateTimeOffset.UtcNow,
        settings = new
        {
            secretSourceOptions.CacheTtlSeconds,
            secretSourceOptions.CacheMaxStaleSeconds,
            secretSourceOptions.RotationGraceSeconds,
            secretSourceOptions.EnableExternalProvider,
            ExternalProvider = secretSourceOptions.ExternalProvider,
            secretSourceOptions.AllowCommandExecution
        },
        apiKey = new
        {
            enabled = apiKeyOptions.Enabled,
            source = SecuritySecretResolver.DescribeApiKeySource(apiKeyOptions, secretSourceOptions),
            candidateCount = apiCandidates.Count,
            staticKeyCount = apiKeyMap.Count
        },
        jwt = new
        {
            enabled = jwtOptions.Enabled,
            source = SecuritySecretResolver.DescribeJwtSigningKeySource(jwtOptions, secretSourceOptions),
            candidateCount = jwtCandidates.Count,
            authority = string.IsNullOrWhiteSpace(jwtOptions.Authority) ? "none" : jwtOptions.Authority
        },
        cache = SecuritySecretResolver.GetRuntimeCacheState(),
        providers = SecuritySecretResolver.GetExternalProviderRuntimeState()
    });
})
    .WithTags("安全")
    .WithSummary("密钥运行态")
    .WithDescription("返回密钥来源、缓存状态和外部密钥提供方运行态（不包含明文密钥）。");

app.MapPost("/api/security/secrets/refresh", (HttpContext context) =>
{
    var apiCandidates = SecuritySecretResolver.ResolveApiKeyCandidates(
        apiKeyOptions,
        secretSourceOptions,
        forceRefresh: true);
    var jwtCandidates = SecuritySecretResolver.ResolveJwtSigningKeyCandidates(
        jwtOptions,
        secretSourceOptions,
        forceRefresh: true);
    var principal = TryGetPrincipal(context, ApiPrincipalItemKey);

    auditTrail.Write(new AuditEntry(
        DateTimeOffset.UtcNow,
        "security",
        "security.secrets_refresh",
        Message: $"Principal={principal?.Name ?? "anonymous"}; ApiCandidates={apiCandidates.Count}; JwtCandidates={jwtCandidates.Count}",
        Path: context.Request.Path.Value,
        Method: context.Request.Method,
        StatusCode: StatusCodes.Status200OK,
        RemoteIp: GetRemoteIp(context)));

    return Results.Ok(new
    {
        refreshedAtUtc = DateTimeOffset.UtcNow,
        apiKey = new
        {
            source = SecuritySecretResolver.DescribeApiKeySource(apiKeyOptions, secretSourceOptions),
            candidateCount = apiCandidates.Count
        },
        jwt = new
        {
            source = SecuritySecretResolver.DescribeJwtSigningKeySource(jwtOptions, secretSourceOptions),
            candidateCount = jwtCandidates.Count
        },
        cache = SecuritySecretResolver.GetRuntimeCacheState(),
        providers = SecuritySecretResolver.GetExternalProviderRuntimeState()
    });
})
    .WithTags("安全")
    .WithSummary("刷新密钥缓存")
    .WithDescription("强制刷新 API Key/JWT 密钥来源和运行态缓存。");

app.MapGet("/api/security/secrets/events", (int? take, IAuditLogReader auditReader) =>
{
    var outputTake = ClampTake(take, monitoringOptions.DefaultAuditTake, monitoringOptions.MaxAuditTake);
    var scanTake = Math.Min(monitoringOptions.MaxAuditTake, Math.Max(outputTake * 4, outputTake));

    var rows = auditReader.Query(new AuditQuery(Take: scanTake))
        .Where(x =>
            string.Equals(x.Action, "security.secrets_runtime_read", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(x.Action, "security.secrets_refresh", StringComparison.OrdinalIgnoreCase))
        .OrderByDescending(x => x.Utc)
        .Take(outputTake)
        .ToList();

    return Results.Ok(rows);
})
    .WithTags("安全")
    .WithSummary("密钥操作事件")
    .WithDescription("查询最近的密钥运行态读取和刷新审计事件。");

app.MapGet("/api/runtime/dotnet", () =>
{
    var dotnetPath = Environment.GetEnvironmentVariable("DOTNET_ROOT") ?? "not-set";
    return Results.Ok(new
    {
        dotnetRoot = dotnetPath,
        framework = Environment.Version.ToString(),
        os = Environment.OSVersion.ToString(),
        is64Bit = Environment.Is64BitProcess
    });
})
    .WithTags("系统")
    .WithSummary(".NET 运行时信息")
    .WithDescription("返回当前进程的 .NET、操作系统与位数信息。");

app.MapGet("/api/monitor/overview", (int? jobs, int? audit, IExecutionJobQueue queue, IAuditLogReader auditReader) =>
{
    var jobTake = ClampTake(jobs, monitoringOptions.DefaultJobTake, monitoringOptions.MaxJobTake);
    var auditTake = ClampTake(audit, monitoringOptions.DefaultAuditTake, monitoringOptions.MaxAuditTake);

    var process = Process.GetCurrentProcess();
    var now = DateTimeOffset.UtcNow;
    var recentJobs = queue.List(jobTake)
        .Select(x => new
        {
            x.Id,
            Status = x.Status.ToString(),
            IdempotencyKey = string.IsNullOrWhiteSpace(x.Request.IdempotencyKey) ? null : x.Request.IdempotencyKey,
            x.CreatedAt,
            x.StartedAt,
            x.CompletedAt,
            x.CancellationRequested,
            x.CancellationReason,
            Error = x.Error,
            Summary = x.Result is null
                ? null
                : new
                {
                    x.Result.Success,
                    x.Result.TotalCounties,
                    x.Result.ProcessedCounties,
                    x.Result.CachedCounties,
                    x.Result.MissingDatabases
                }
        })
        .ToList();

    var providerStates = SecuritySecretResolver.GetExternalProviderRuntimeState();
    var lastAttemptUtc = providerStates
        .Where(x => x.LastAttemptUtc is not null)
        .Select(x => x.LastAttemptUtc!.Value)
        .DefaultIfEmpty()
        .Max();
    var averageDurationMs = providerStates
        .Where(x => x.LastDurationMs is not null)
        .Select(x => x.LastDurationMs!.Value)
        .DefaultIfEmpty()
        .Average();
    var configuredProvider = string.IsNullOrWhiteSpace(secretSourceOptions.ExternalProvider)
        ? "none"
        : secretSourceOptions.ExternalProvider.Trim();

    return Results.Ok(new
    {
        service = "DataHz.Api",
        utc = now,
        startedAt = appStartedUtc,
        uptimeSeconds = Convert.ToInt64((now - appStartedUtc).TotalSeconds),
        version = Assembly.GetExecutingAssembly().GetName().Version?.ToString() ?? "unknown",
        runtime = new
        {
            framework = Environment.Version.ToString(),
            os = Environment.OSVersion.ToString(),
            machineName = Environment.MachineName,
            is64Bit = Environment.Is64BitProcess,
            processorCount = Environment.ProcessorCount,
            workingSetMb = Math.Round(process.WorkingSet64 / 1024D / 1024D, 2)
        },
        queue = queue.GetStats(),
        recentJobs,
        recentAudit = auditReader.ReadRecent(auditTake),
        externalSecrets = new
        {
            enabled = secretSourceOptions.EnableExternalProvider,
            configuredProvider,
            totalAttempts = providerStates.Count,
            success = providerStates.Count(x => string.Equals(x.LastStatus, "success", StringComparison.OrdinalIgnoreCase)),
            empty = providerStates.Count(x => string.Equals(x.LastStatus, "empty", StringComparison.OrdinalIgnoreCase)),
            error = providerStates.Count(x => string.Equals(x.LastStatus, "error", StringComparison.OrdinalIgnoreCase)),
            lastAttemptUtc = lastAttemptUtc == default ? (DateTimeOffset?)null : lastAttemptUtc,
            averageDurationMs = providerStates.Count == 0 ? (double?)null : Math.Round(averageDurationMs, 2),
            snapshot = providerStates
                .OrderByDescending(x => x.LastAttemptUtc)
                .Take(8)
                .Select(x => new
                {
                    x.Provider,
                    x.Purpose,
                    x.LastStatus,
                    x.LastAttemptHadValue,
                    x.LastAttemptUtc,
                    x.LastDurationMs
                })
                .ToList()
        }
    });
})
    .WithTags("监控")
    .WithSummary("监控总览")
    .WithDescription("返回服务运行态、队列状态、最近作业、审计与外部密钥提供方概览。");

app.MapGet("/api/monitor/external-secrets",
    (int? take, string? provider, string? purpose, string? status, int? windowMinutes, DateTimeOffset? fromUtc, DateTimeOffset? toUtc) =>
{
    var now = DateTimeOffset.UtcNow;
    var outputTake = ClampTake(take, monitoringOptions.DefaultAuditTake, monitoringOptions.MaxAuditTake);
    var providerFilter = NormalizeExternalProviderAlias(provider);
    var purposeFilter = NormalizeQueryFilter(purpose);
    var statusFilter = NormalizeQueryFilter(status);
    var effectiveFromUtc = ResolveWindowFromUtc(now, fromUtc, windowMinutes);
    var filtered = QueryExternalSecretStates(providerFilter, purposeFilter, statusFilter, effectiveFromUtc, toUtc);
    var summaryLastAttemptUtc = filtered
        .Where(x => x.LastAttemptUtc is not null)
        .Select(x => x.LastAttemptUtc!.Value)
        .DefaultIfEmpty()
        .Max();

    var rows = filtered.Take(outputTake).ToList();
    return Results.Ok(new
    {
        utc = now,
        filter = new
        {
            take = outputTake,
            provider = providerFilter ?? string.Empty,
            purpose = purposeFilter ?? string.Empty,
            status = statusFilter ?? string.Empty,
            windowMinutes = NormalizeWindowMinutes(windowMinutes),
            fromUtc = effectiveFromUtc,
            toUtc
        },
        summary = new
        {
            matched = filtered.Count,
            returned = rows.Count,
            success = filtered.Count(x => string.Equals(x.LastStatus, "success", StringComparison.OrdinalIgnoreCase)),
            empty = filtered.Count(x => string.Equals(x.LastStatus, "empty", StringComparison.OrdinalIgnoreCase)),
            error = filtered.Count(x => string.Equals(x.LastStatus, "error", StringComparison.OrdinalIgnoreCase)),
            lastAttemptUtc = summaryLastAttemptUtc == default ? (DateTimeOffset?)null : summaryLastAttemptUtc
        },
        rows
    });
})
    .WithTags("监控")
    .WithSummary("外部密钥提供方状态")
    .WithDescription("按条件筛选外部密钥提供方的最近调用状态与统计信息。");

app.MapGet("/api/monitor/external-secrets/export",
    (string? format, int? take, string? provider, string? purpose, string? status, int? windowMinutes, DateTimeOffset? fromUtc, DateTimeOffset? toUtc) =>
{
    var now = DateTimeOffset.UtcNow;
    var outputTake = ClampTake(take, monitoringOptions.DefaultAuditTake, monitoringOptions.MaxAuditTake);
    var providerFilter = NormalizeExternalProviderAlias(provider);
    var purposeFilter = NormalizeQueryFilter(purpose);
    var statusFilter = NormalizeQueryFilter(status);
    var effectiveFromUtc = ResolveWindowFromUtc(now, fromUtc, windowMinutes);
    var rows = QueryExternalSecretStates(providerFilter, purposeFilter, statusFilter, effectiveFromUtc, toUtc)
        .Take(outputTake)
        .ToList();

    var stamp = now.ToString("yyyyMMddHHmmss");
    var normalized = string.IsNullOrWhiteSpace(format) ? "csv" : format.Trim().ToLowerInvariant();
    if (normalized == "jsonl")
    {
        var jsonLines = BuildExternalSecretsJsonLines(rows);
        var name = $"external-secrets-{stamp}.jsonl";
        return Results.File(
            fileContents: Encoding.UTF8.GetBytes(jsonLines),
            contentType: "application/x-ndjson; charset=utf-8",
            fileDownloadName: name);
    }

    if (normalized != "csv")
    {
        return Results.BadRequest(new { message = "Unsupported format. Use 'csv' or 'jsonl'." });
    }

    var csv = BuildExternalSecretsCsv(rows);
    var csvName = $"external-secrets-{stamp}.csv";
    return Results.File(
        fileContents: Encoding.UTF8.GetBytes(csv),
        contentType: "text/csv; charset=utf-8",
        fileDownloadName: csvName);
})
    .WithTags("监控")
    .WithSummary("导出外部密钥状态")
    .WithDescription("导出外部密钥提供方状态为 CSV 或 JSONL。");

app.MapPost("/api/monitor/external-secrets/reset",
    (HttpContext context, string? provider, string? purpose, string? status, int? windowMinutes, DateTimeOffset? fromUtc, DateTimeOffset? toUtc) =>
{
    var now = DateTimeOffset.UtcNow;
    var principal = TryGetPrincipal(context, ApiPrincipalItemKey);
    var providerFilter = NormalizeExternalProviderAlias(provider);
    var purposeFilter = NormalizeQueryFilter(purpose);
    var statusFilter = NormalizeQueryFilter(status);
    var effectiveFromUtc = ResolveWindowFromUtc(now, fromUtc, windowMinutes);
    var clearedCount = SecuritySecretResolver.ResetExternalProviderRuntimeState(
        providerFilter: string.IsNullOrWhiteSpace(providerFilter) ? null : providerFilter,
        purposeFilter: purposeFilter,
        statusFilter: statusFilter,
        fromUtc: effectiveFromUtc,
        toUtc: toUtc);

    auditTrail.Write(new AuditEntry(
        now,
        "monitor",
        "monitor.external_secrets_reset",
        Message: $"Principal={principal?.Name ?? "anonymous"}; Provider={providerFilter}; Purpose={purposeFilter}; Status={statusFilter}; From={effectiveFromUtc:O}; To={toUtc:O}; Cleared={clearedCount}",
        Path: context.Request.Path.Value,
        Method: context.Request.Method,
        StatusCode: StatusCodes.Status200OK,
        RemoteIp: GetRemoteIp(context)));

    return Results.Ok(new
    {
        utc = now,
        filter = new
        {
            provider = providerFilter,
            purpose = purposeFilter ?? string.Empty,
            status = statusFilter ?? string.Empty,
            windowMinutes = NormalizeWindowMinutes(windowMinutes),
            fromUtc = effectiveFromUtc,
            toUtc
        },
        clearedCount
    });
})
    .WithTags("监控")
    .WithSummary("清理外部密钥状态")
    .WithDescription("按过滤条件清理外部密钥提供方运行态记录。");

app.MapGet("/api/monitor/jobs/{id:guid}", (Guid id, int? audit, IExecutionJobQueue queue, IAuditLogReader auditReader) =>
{
    if (!queue.TryGet(id, out var record) || record is null)
    {
        return Results.NotFound(new { message = "Job not found.", jobId = id });
    }

    var auditTake = ClampTake(audit, monitoringOptions.DefaultAuditTake, monitoringOptions.MaxAuditTake);
    return Results.Ok(new
    {
        job = record,
        events = auditReader.ReadByJob(id, auditTake)
    });
})
    .WithTags("监控")
    .WithSummary("作业监控明细")
    .WithDescription("查询单个作业详情及关联审计事件。");

app.MapGet("/api/audit/export",
    (string? format,
        int? take,
        DateTimeOffset? fromUtc,
        DateTimeOffset? toUtc,
        string? category,
        string? action,
        Guid? jobId,
        IAuditLogReader auditReader) =>
{
    var auditTake = ClampTake(take, monitoringOptions.DefaultAuditTake, monitoringOptions.MaxAuditTake);
    var query = new AuditQuery(
        Take: auditTake,
        FromUtc: fromUtc,
        ToUtc: toUtc,
        Category: category,
        Action: action,
        JobId: jobId);

    var rows = auditReader.Query(query);
    var now = DateTimeOffset.UtcNow;
    var stamp = now.ToString("yyyyMMddHHmmss");
    var normalized = string.IsNullOrWhiteSpace(format) ? "csv" : format.Trim().ToLowerInvariant();

    if (normalized == "jsonl")
    {
        var jsonLines = BuildAuditJsonLines(rows);
        var name = $"audit-{stamp}.jsonl";
        return Results.File(
            fileContents: Encoding.UTF8.GetBytes(jsonLines),
            contentType: "application/x-ndjson; charset=utf-8",
            fileDownloadName: name);
    }

    var csv = BuildAuditCsv(rows);
    var csvName = $"audit-{stamp}.csv";
    return Results.File(
        fileContents: Encoding.UTF8.GetBytes(csv),
        contentType: "text/csv; charset=utf-8",
        fileDownloadName: csvName);
})
    .WithTags("审计")
    .WithSummary("导出审计日志")
    .WithDescription("按过滤条件导出审计日志（CSV/JSONL）。");

app.MapPost("/api/templates/parse", (ParseTemplateRequest request, ITemplateParser parser) =>
{
    try
    {
        var template = parser.Parse(request.TemplatePath);
        return Results.Ok(new
        {
            template.TemplateName,
            template.TemplatePath,
            NameType = template.NameType.ToString(),
            template.DatabaseName,
            template.TableName,
            template.ColumnCount,
            template.ViewCount,
            template.CheckCount,
            IsFlowTemplate = template.IsFlowTemplate,
            FlowSheets = template.FlowConfig?.Sheets.Count ?? 0,
            Columns = template.Columns.Select(c => new { c.Index, c.Caption, c.Sql }).ToArray(),
            Views = template.Views.Select(v => new { v.Index, v.ViewName, v.TemplateFile, v.TargetFile, v.Range }).ToArray()
        });
    }
    catch (Exception ex)
    {
        return Results.BadRequest(new { message = ex.Message });
    }
})
    .WithTags("模板")
    .WithSummary("解析模板")
    .WithDescription("解析 INI/XLSX 模板并返回模板结构摘要。");

app.MapPost("/api/tasks/plan", (PlanTasksRequest request, ITaskPlanner planner) =>
{
    try
    {
        var plan = planner.BuildPlan(new PlanningRequest(
            request.TemplatePath,
            request.SourceDirectory,
            request.TargetDirectory,
            request.AreaCodePath,
            request.StartIndex,
            request.EndIndex));

        return Results.Ok(new
        {
            Template = new
            {
                plan.Template.TemplateName,
                plan.Template.TemplatePath,
                NameType = plan.Template.NameType.ToString(),
                plan.Template.DatabaseName,
                plan.Template.TableName,
                plan.Template.IsFlowTemplate
            },
            plan.SourceDirectory,
            plan.TargetDirectory,
            plan.Counties,
            plan.Issues
        });
    }
    catch (Exception ex)
    {
        return Results.BadRequest(new { message = ex.Message });
    }
})
    .WithTags("任务")
    .WithSummary("生成执行计划")
    .WithDescription("根据模板和行政区代码生成可执行任务计划。");

app.MapPost("/api/tasks/execute", (ExecuteRequestContract request, ITaskPlanner planner, IExecutionEngine engine) =>
{
    try
    {
        var plan = planner.BuildPlan(new PlanningRequest(
            request.Plan.TemplatePath,
            request.Plan.SourceDirectory,
            request.Plan.TargetDirectory,
            request.Plan.AreaCodePath,
            request.Plan.StartIndex,
            request.Plan.EndIndex));

        var result = engine.Execute(new ExecuteRequest(plan, request.DryRun, request.Incremental));
        return Results.Ok(new { plan.Issues, result });
    }
    catch (Exception ex)
    {
        return Results.BadRequest(new { message = ex.Message });
    }
})
    .WithTags("任务")
    .WithSummary("同步执行任务")
    .WithDescription("按请求计划立即执行任务，支持 dryRun 与 incremental。");

app.MapPost("/api/jobs/submit", (SubmitJobRequest request, IExecutionJobQueue queue, HttpContext http) =>
{
    var enqueueResult = queue.Enqueue(request);
    var id = enqueueResult.JobId;
    var baseUrl = $"{http.Request.Scheme}://{http.Request.Host}";
    return Results.Accepted($"/api/jobs/{id}", new
    {
        jobId = id,
        status = enqueueResult.JobStatus.ToString(),
        deduplicated = enqueueResult.Deduplicated,
        idempotencyKey = enqueueResult.IdempotencyKey ?? string.Empty,
        statusUrl = $"{baseUrl}/api/jobs/{id}",
        message = enqueueResult.Deduplicated
            ? "Reused existing active job by idempotency key."
            : "Job accepted."
    });
})
    .WithTags("作业队列")
    .WithSummary("提交异步作业")
    .WithDescription("提交后台异步执行作业，支持幂等键去重。");

app.MapPost("/api/jobs/{id:guid}/cancel", (Guid id, CancelJobRequest? request, IExecutionJobQueue queue) =>
{
    var result = queue.Cancel(id, request?.Reason);
    return result.Status switch
    {
        ExecutionJobCancelStatus.NotFound => Results.NotFound(new { jobId = id, result.Status, result.Message }),
        ExecutionJobCancelStatus.AlreadyCompleted => Results.Conflict(new { jobId = id, result.Status, result.Message, result.JobStatus }),
        ExecutionJobCancelStatus.CancellationRequested => Results.Accepted($"/api/jobs/{id}", new { jobId = id, result.Status, result.Message, result.JobStatus }),
        _ => Results.Ok(new { jobId = id, result.Status, result.Message, result.JobStatus })
    };
})
    .WithTags("作业队列")
    .WithSummary("取消异步作业")
    .WithDescription("取消指定作业；队列中作业立即取消，运行中作业会请求中止。");

app.MapGet("/api/jobs", (int? take, IExecutionJobQueue queue) =>
{
    var max = take.GetValueOrDefault(50);
    return Results.Ok(queue.List(max));
})
    .WithTags("作业队列")
    .WithSummary("查询作业列表")
    .WithDescription("分页查询最近作业记录。");

app.MapGet("/api/jobs/stats", (IExecutionJobQueue queue) =>
{
    return Results.Ok(queue.GetStats());
})
    .WithTags("作业队列")
    .WithSummary("查询作业统计")
    .WithDescription("返回队列中各状态作业统计信息。");

app.MapGet("/api/jobs/{id:guid}", (Guid id, IExecutionJobQueue queue) =>
{
    return queue.TryGet(id, out var record)
        ? Results.Ok(record)
        : Results.NotFound(new { message = "Job not found.", jobId = id });
})
    .WithTags("作业队列")
    .WithSummary("查询作业详情")
    .WithDescription("按作业 ID 查询作业完整详情。");

app.Run();

static bool IsPublicPath(string path)
{
    return path.Equals("/health", StringComparison.OrdinalIgnoreCase) ||
           path.StartsWith("/swagger", StringComparison.OrdinalIgnoreCase);
}

static int ClampTake(int? take, int defaultTake, int maxTake)
{
    var raw = take.GetValueOrDefault(defaultTake);
    return Math.Min(Math.Max(raw, 1), Math.Max(1, maxTake));
}

static string? GetRemoteIp(HttpContext context)
{
    return context.Connection.RemoteIpAddress?.ToString();
}

static Dictionary<string, ApiKeyPrincipal> BuildApiKeyMap(ApiKeySecurityOptions options)
{
    var result = new Dictionary<string, ApiKeyPrincipal>(StringComparer.Ordinal);
    var defaultRole = ParseRole(options.DefaultRole, AccessRole.Operator);

    if (options.Keys is null)
    {
        return result;
    }

    foreach (var item in options.Keys)
    {
        if (string.IsNullOrWhiteSpace(item.Key))
        {
            continue;
        }

        var role = ParseRole(item.Role, defaultRole);
        var name = string.IsNullOrWhiteSpace(item.Name) ? "key" : item.Name.Trim();
        result[item.Key] = new ApiKeyPrincipal(name, role, "apiKey");
    }

    return result;
}

static bool TryResolveApiKeyPrincipal(
    string suppliedKey,
    IReadOnlyDictionary<string, ApiKeyPrincipal> apiKeyMap,
    ApiKeySecurityOptions options,
    SecuritySecretSourceOptions? secretSourceOptions,
    out ApiKeyPrincipal? principal)
{
    principal = null;
    if (string.IsNullOrWhiteSpace(suppliedKey))
    {
        return false;
    }

    if (apiKeyMap.TryGetValue(suppliedKey, out var staticPrincipal))
    {
        principal = staticPrincipal;
        return true;
    }

    var candidates = SecuritySecretResolver.ResolveApiKeyCandidates(options, secretSourceOptions);
    if (!candidates.Any(x => string.Equals(x, suppliedKey, StringComparison.Ordinal)))
    {
        return false;
    }

    var defaultRole = ParseRole(options.DefaultRole, AccessRole.Operator);
    principal = new ApiKeyPrincipal("default", defaultRole, "apiKey");
    return true;
}

static AccessRole ParseRole(string? raw, AccessRole fallback)
{
    return Enum.TryParse<AccessRole>(raw, ignoreCase: true, out var role) ? role : fallback;
}

static ApiKeyPrincipal? TryGetPrincipal(HttpContext context, string itemKey)
{
    return context.Items.TryGetValue(itemKey, out var raw) && raw is ApiKeyPrincipal principal
        ? principal
        : null;
}

static ApiKeyPrincipal? TryBuildJwtPrincipal(ClaimsPrincipal user)
{
    if (!(user.Identity?.IsAuthenticated ?? false))
    {
        return null;
    }

    var role = ResolveRoleFromClaims(user.Claims, AccessRole.Viewer);
    var name = user.Identity?.Name
        ?? user.Claims.FirstOrDefault(c => c.Type.Equals("preferred_username", StringComparison.OrdinalIgnoreCase))?.Value
        ?? user.Claims.FirstOrDefault(c => c.Type.Equals("name", StringComparison.OrdinalIgnoreCase))?.Value
        ?? user.Claims.FirstOrDefault(c => c.Type.Equals("sub", StringComparison.OrdinalIgnoreCase))?.Value
        ?? user.Claims.FirstOrDefault(c => c.Type == ClaimTypes.NameIdentifier)?.Value
        ?? "jwt-user";

    return new ApiKeyPrincipal(name, role, "jwt");
}

static AccessRole ResolveRoleFromClaims(IEnumerable<Claim> claims, AccessRole fallback)
{
    var roles = new List<AccessRole>();
    foreach (var claim in claims)
    {
        var isRoleClaim = claim.Type.Equals("role", StringComparison.OrdinalIgnoreCase) ||
                          claim.Type.Equals("roles", StringComparison.OrdinalIgnoreCase) ||
                          claim.Type == ClaimTypes.Role;

        if (!isRoleClaim || string.IsNullOrWhiteSpace(claim.Value))
        {
            continue;
        }

        var tokens = claim.Value.Split([',', ';', ' '], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        foreach (var token in tokens)
        {
            if (Enum.TryParse<AccessRole>(token, ignoreCase: true, out var role))
            {
                roles.Add(role);
            }
        }
    }

    return roles.Count == 0 ? fallback : roles.Max();
}

static AccessRole? ResolveRequiredRole(string path, string method)
{
    if (!path.StartsWith("/api", StringComparison.OrdinalIgnoreCase))
    {
        return null;
    }

    if (path.StartsWith("/api/security/whoami", StringComparison.OrdinalIgnoreCase))
    {
        return AccessRole.Viewer;
    }

    if (path.StartsWith("/api/security/secrets", StringComparison.OrdinalIgnoreCase))
    {
        return AccessRole.Admin;
    }

    if (path.StartsWith("/api/security/hardening", StringComparison.OrdinalIgnoreCase))
    {
        return AccessRole.Admin;
    }

    if (path.StartsWith("/api/monitor/external-secrets/reset", StringComparison.OrdinalIgnoreCase))
    {
        return AccessRole.Admin;
    }

    if (path.StartsWith("/api/runtime", StringComparison.OrdinalIgnoreCase) ||
        path.StartsWith("/api/monitor", StringComparison.OrdinalIgnoreCase))
    {
        return AccessRole.Viewer;
    }

    if (path.StartsWith("/api/audit", StringComparison.OrdinalIgnoreCase))
    {
        return AccessRole.Admin;
    }

    if (path.StartsWith("/api/jobs", StringComparison.OrdinalIgnoreCase))
    {
        if (HttpMethods.IsGet(method))
        {
            return AccessRole.Viewer;
        }

        if (HttpMethods.IsPost(method))
        {
            return AccessRole.Operator;
        }
    }

    if (path.StartsWith("/api/tasks", StringComparison.OrdinalIgnoreCase) ||
        path.StartsWith("/api/templates", StringComparison.OrdinalIgnoreCase))
    {
        return AccessRole.Operator;
    }

    return AccessRole.Operator;
}

static string? NormalizeQueryFilter(string? value)
{
    if (string.IsNullOrWhiteSpace(value))
    {
        return null;
    }

    return value.Trim();
}

static string NormalizeExternalProviderAlias(string? provider)
{
    var normalized = string.IsNullOrWhiteSpace(provider)
        ? string.Empty
        : provider.Trim().ToLowerInvariant();

    return normalized switch
    {
        "azure-keyvault" or "keyvault" => "azurekv",
        "aws-secretsmanager" or "awssecretsmanager" => "awssm",
        "gcp-secretmanager" or "gcpsecretmanager" => "gcpsm",
        "aliyun-kms" or "alicloud-kms" or "alicloudkms" => "aliyunkms",
        _ => normalized
    };
}

static int? NormalizeWindowMinutes(int? windowMinutes)
{
    if (windowMinutes is null || windowMinutes <= 0)
    {
        return null;
    }

    return Math.Clamp(windowMinutes.Value, 1, 7 * 24 * 60);
}

static DateTimeOffset? ResolveWindowFromUtc(DateTimeOffset now, DateTimeOffset? fromUtc, int? windowMinutes)
{
    if (fromUtc is not null)
    {
        return fromUtc;
    }

    var normalizedWindow = NormalizeWindowMinutes(windowMinutes);
    return normalizedWindow is null ? null : now.AddMinutes(-normalizedWindow.Value);
}

static List<SecuritySecretResolver.ExternalProviderRuntimeState> QueryExternalSecretStates(
    string? providerFilter,
    string? purposeFilter,
    string? statusFilter,
    DateTimeOffset? fromUtc,
    DateTimeOffset? toUtc)
{
    return SecuritySecretResolver.GetExternalProviderRuntimeState()
        .Where(x => string.IsNullOrWhiteSpace(providerFilter) || string.Equals(NormalizeExternalProviderAlias(x.Provider), providerFilter, StringComparison.Ordinal))
        .Where(x => string.IsNullOrWhiteSpace(purposeFilter) || string.Equals(x.Purpose, purposeFilter, StringComparison.OrdinalIgnoreCase))
        .Where(x => string.IsNullOrWhiteSpace(statusFilter) || string.Equals(x.LastStatus, statusFilter, StringComparison.OrdinalIgnoreCase))
        .Where(x => fromUtc is null || (x.LastAttemptUtc is not null && x.LastAttemptUtc.Value >= fromUtc.Value))
        .Where(x => toUtc is null || (x.LastAttemptUtc is not null && x.LastAttemptUtc.Value <= toUtc.Value))
        .OrderByDescending(x => x.LastAttemptUtc)
        .ThenBy(x => x.Provider, StringComparer.Ordinal)
        .ThenBy(x => x.Purpose, StringComparer.OrdinalIgnoreCase)
        .ToList();
}

static string BuildAuditCsv(IReadOnlyList<AuditEntry> rows)
{
    var sb = new StringBuilder();
    sb.AppendLine("utc,category,action,jobId,message,path,method,statusCode,remoteIp");

    foreach (var row in rows.OrderByDescending(x => x.Utc))
    {
        sb
            .Append(EscapeCsv(row.Utc.ToString("O"))).Append(',')
            .Append(EscapeCsv(row.Category)).Append(',')
            .Append(EscapeCsv(row.Action)).Append(',')
            .Append(EscapeCsv(row.JobId?.ToString() ?? string.Empty)).Append(',')
            .Append(EscapeCsv(row.Message ?? string.Empty)).Append(',')
            .Append(EscapeCsv(row.Path ?? string.Empty)).Append(',')
            .Append(EscapeCsv(row.Method ?? string.Empty)).Append(',')
            .Append(EscapeCsv(row.StatusCode?.ToString() ?? string.Empty)).Append(',')
            .Append(EscapeCsv(row.RemoteIp ?? string.Empty))
            .AppendLine();
    }

    return sb.ToString();
}

static string BuildAuditJsonLines(IReadOnlyList<AuditEntry> rows)
{
    var sb = new StringBuilder();
    foreach (var row in rows.OrderByDescending(x => x.Utc))
    {
        sb.AppendLine(JsonSerializer.Serialize(row));
    }

    return sb.ToString();
}

static string BuildExternalSecretsCsv(IReadOnlyList<SecuritySecretResolver.ExternalProviderRuntimeState> rows)
{
    var sb = new StringBuilder();
    sb.AppendLine("provider,purpose,secretRefHint,lastAttemptUtc,lastSuccessUtc,lastFailureUtc,lastStatus,lastAttemptHadValue,lastDurationMs,lastError");
    foreach (var row in rows.OrderByDescending(x => x.LastAttemptUtc))
    {
        sb
            .Append(EscapeCsv(row.Provider)).Append(',')
            .Append(EscapeCsv(row.Purpose)).Append(',')
            .Append(EscapeCsv(row.SecretRefHint)).Append(',')
            .Append(EscapeCsv(row.LastAttemptUtc?.ToString("O") ?? string.Empty)).Append(',')
            .Append(EscapeCsv(row.LastSuccessUtc?.ToString("O") ?? string.Empty)).Append(',')
            .Append(EscapeCsv(row.LastFailureUtc?.ToString("O") ?? string.Empty)).Append(',')
            .Append(EscapeCsv(row.LastStatus)).Append(',')
            .Append(EscapeCsv(row.LastAttemptHadValue ? "true" : "false")).Append(',')
            .Append(EscapeCsv(row.LastDurationMs?.ToString() ?? string.Empty)).Append(',')
            .Append(EscapeCsv(row.LastError ?? string.Empty))
            .AppendLine();
    }

    return sb.ToString();
}

static string BuildExternalSecretsJsonLines(IReadOnlyList<SecuritySecretResolver.ExternalProviderRuntimeState> rows)
{
    var sb = new StringBuilder();
    foreach (var row in rows.OrderByDescending(x => x.LastAttemptUtc))
    {
        sb.AppendLine(JsonSerializer.Serialize(row));
    }

    return sb.ToString();
}

static string EscapeCsv(string? value)
{
    value ??= string.Empty;

    if (value.Contains('"') || value.Contains(',') || value.Contains('\n') || value.Contains('\r'))
    {
        return "\"" + value.Replace("\"", "\"\"") + "\"";
    }

    return value;
}

static void ConfigureJwtBearer(
    JwtBearerOptions options,
    JwtSecurityOptions settings,
    SecuritySecretSourceOptions? secretSourceOptions)
{
    options.RequireHttpsMetadata = settings.RequireHttpsMetadata;
    options.MapInboundClaims = false;

    if (!string.IsNullOrWhiteSpace(settings.Authority))
    {
        options.Authority = settings.Authority;
    }

    if (!string.IsNullOrWhiteSpace(settings.Audience))
    {
        options.Audience = settings.Audience;
    }

    var signingKey = SecuritySecretResolver.ResolveJwtSigningKey(settings, secretSourceOptions);
    var signingKeyCandidates = SecuritySecretResolver.ResolveJwtSigningKeyCandidates(settings, secretSourceOptions);
    var hasSigningKey = signingKeyCandidates.Count > 0;
    var initialSigningKey = string.IsNullOrWhiteSpace(signingKey)
        ? signingKeyCandidates.FirstOrDefault()
        : signingKey;

    IEnumerable<SecurityKey> ResolveDynamicSigningKeys()
    {
        var candidates = SecuritySecretResolver.ResolveJwtSigningKeyCandidates(settings, secretSourceOptions);
        if (candidates.Count == 0)
        {
            return [];
        }

        return candidates.Select(x => new SymmetricSecurityKey(Encoding.UTF8.GetBytes(x)));
    }

    options.TokenValidationParameters = new TokenValidationParameters
    {
        ValidateLifetime = true,
        ClockSkew = TimeSpan.FromMinutes(2),
        ValidateIssuerSigningKey = hasSigningKey,
        IssuerSigningKeyResolver = hasSigningKey ? (_, _, _, _) => ResolveDynamicSigningKeys() : null,
        IssuerSigningKey = hasSigningKey && !string.IsNullOrWhiteSpace(initialSigningKey)
            ? new SymmetricSecurityKey(Encoding.UTF8.GetBytes(initialSigningKey))
            : null,
        ValidateIssuer = !string.IsNullOrWhiteSpace(settings.ValidIssuer) || !string.IsNullOrWhiteSpace(settings.Authority),
        ValidIssuer = string.IsNullOrWhiteSpace(settings.ValidIssuer) ? null : settings.ValidIssuer,
        ValidateAudience = !string.IsNullOrWhiteSpace(settings.ValidAudience) || !string.IsNullOrWhiteSpace(settings.Audience),
        ValidAudience = string.IsNullOrWhiteSpace(settings.ValidAudience) ? null : settings.ValidAudience,
        RoleClaimType = string.IsNullOrWhiteSpace(settings.RoleClaimType) ? "role" : settings.RoleClaimType,
        NameClaimType = string.IsNullOrWhiteSpace(settings.NameClaimType) ? "name" : settings.NameClaimType
    };
}

public partial class Program;
