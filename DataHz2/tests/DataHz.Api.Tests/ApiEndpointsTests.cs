using System.Net;
using System.Net.Http.Json;
using System.IdentityModel.Tokens.Jwt;
using System.Security.Claims;
using System.Text;
using System.Text.Json;
using Microsoft.IdentityModel.Tokens;

namespace DataHz.Api.Tests;

public sealed class ApiEndpointsTests
{
    [Fact]
    public async Task Health_Should_Return_Ok()
    {
        using var factory = new ApiTestFactory();
        using var client = factory.CreateClient();

        var response = await client.GetAsync("/health");
        response.EnsureSuccessStatusCode();

        var json = await ReadJsonAsync(response);
        Assert.Equal("ok", json.GetProperty("status").GetString());
    }

    [Fact]
    public async Task FsEntries_Should_Normalize_File_Path_To_Parent_Directory()
    {
        var tempRoot = Path.Combine(Path.GetTempPath(), "datahz-tests-fs", Guid.NewGuid().ToString("N"));
        var templateDir = Path.Combine(tempRoot, "templates");
        Directory.CreateDirectory(templateDir);
        var templatePath = Path.Combine(templateDir, "Monthly.XLSX");
        await File.WriteAllTextAsync(templatePath, "stub");

        try
        {
            using var factory = new ApiTestFactory();
            using var client = factory.CreateClient();

            var response = await client.GetAsync($"/api/fs/entries?path={Uri.EscapeDataString(templatePath)}&selection=template");
            response.EnsureSuccessStatusCode();

            var json = await ReadJsonAsync(response);
            Assert.Equal(templateDir, json.GetProperty("currentPath").GetString());
            Assert.Contains(json.GetProperty("files").EnumerateArray(), x =>
                string.Equals(x.GetProperty("path").GetString(), templatePath, StringComparison.OrdinalIgnoreCase));
        }
        finally
        {
            TryDeleteDirectory(tempRoot);
        }
    }

    [Fact]
    public async Task FsEntries_Should_Filter_Files_By_Extension_Case_Insensitively()
    {
        var tempRoot = Path.Combine(Path.GetTempPath(), "datahz-tests-fs", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(tempRoot);
        var iniPath = Path.Combine(tempRoot, "alpha.INI");
        var xlsxPath = Path.Combine(tempRoot, "beta.xlsx");
        var txtPath = Path.Combine(tempRoot, "notes.txt");
        await File.WriteAllTextAsync(iniPath, "stub");
        await File.WriteAllTextAsync(xlsxPath, "stub");
        await File.WriteAllTextAsync(txtPath, "stub");

        try
        {
            using var factory = new ApiTestFactory();
            using var client = factory.CreateClient();

            var response = await client.GetAsync($"/api/fs/entries?path={Uri.EscapeDataString(tempRoot)}&selection=template");
            response.EnsureSuccessStatusCode();

            var json = await ReadJsonAsync(response);
            var files = json.GetProperty("files").EnumerateArray()
                .Select(x => x.GetProperty("name").GetString())
                .OfType<string>()
                .ToArray();

            Assert.Contains("alpha.INI", files);
            Assert.Contains("beta.xlsx", files);
            Assert.DoesNotContain("notes.txt", files);
        }
        finally
        {
            TryDeleteDirectory(tempRoot);
        }
    }

    [Fact]
    public async Task ApiKey_Should_Block_Api_When_Header_Missing()
    {
        using var factory = new ApiTestFactory(settings =>
        {
            settings["Security:ApiKey:Enabled"] = "true";
            settings["Security:ApiKey:Value"] = "test-key";
        });
        using var client = factory.CreateClient();

        var unauthorized = await client.GetAsync("/api/runtime/dotnet");
        Assert.Equal(HttpStatusCode.Unauthorized, unauthorized.StatusCode);

        client.DefaultRequestHeaders.Add("X-Api-Key", "test-key");
        var authorized = await client.GetAsync("/api/runtime/dotnet");
        Assert.Equal(HttpStatusCode.OK, authorized.StatusCode);
    }

    [Fact]
    public async Task ApiKey_Command_Source_Should_Work_When_Enabled()
    {
        using var factory = new ApiTestFactory(settings =>
        {
            settings["Security:ApiKey:Enabled"] = "true";
            settings["Security:ApiKey:Value"] = "";
            settings["Security:Secrets:AllowCommandExecution"] = "true";
            settings["Security:Secrets:ApiKeyCommand"] = "echo cmd-source-key";
        });
        using var client = factory.CreateClient();

        var unauthorized = await client.GetAsync("/api/runtime/dotnet");
        Assert.Equal(HttpStatusCode.Unauthorized, unauthorized.StatusCode);

        client.DefaultRequestHeaders.Add("X-Api-Key", "cmd-source-key");
        var authorized = await client.GetAsync("/api/runtime/dotnet");
        Assert.Equal(HttpStatusCode.OK, authorized.StatusCode);
    }

    [Fact]
    public async Task ApiKey_External_File_Source_Should_Work_When_Enabled()
    {
        var tempRoot = Path.Combine(Path.GetTempPath(), "datahz-tests-secrets", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(tempRoot);
        var secretFile = Path.Combine(tempRoot, "apikey.txt");
        await File.WriteAllTextAsync(secretFile, "file-secret-key");

        try
        {
            using var factory = new ApiTestFactory(settings =>
            {
                settings["Security:ApiKey:Enabled"] = "true";
                settings["Security:ApiKey:Value"] = "";
                settings["Security:Secrets:EnableExternalProvider"] = "true";
                settings["Security:Secrets:ExternalProvider"] = "file";
                settings["Security:Secrets:ApiKeyExternalRef"] = secretFile;
                settings["Security:Secrets:CacheTtlSeconds"] = "0";
                settings["Security:Secrets:CacheMaxStaleSeconds"] = "0";
            });
            using var client = factory.CreateClient();

            var unauthorized = await client.GetAsync("/api/runtime/dotnet");
            Assert.Equal(HttpStatusCode.Unauthorized, unauthorized.StatusCode);

            client.DefaultRequestHeaders.Add("X-Api-Key", "file-secret-key");
            var authorized = await client.GetAsync("/api/runtime/dotnet");
            Assert.Equal(HttpStatusCode.OK, authorized.StatusCode);
        }
        finally
        {
            TryDeleteDirectory(tempRoot);
        }
    }

    [Fact]
    public async Task ApiKey_External_File_Source_Should_Support_Rotation_Without_Restart()
    {
        var tempRoot = Path.Combine(Path.GetTempPath(), "datahz-tests-secrets", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(tempRoot);
        var secretFile = Path.Combine(tempRoot, "apikey-rotate.txt");
        await File.WriteAllTextAsync(secretFile, "api-key-v1");

        try
        {
            using var factory = new ApiTestFactory(settings =>
            {
                settings["Security:ApiKey:Enabled"] = "true";
                settings["Security:ApiKey:Value"] = "";
                settings["Security:Secrets:EnableExternalProvider"] = "true";
                settings["Security:Secrets:ExternalProvider"] = "file";
                settings["Security:Secrets:ApiKeyExternalRef"] = secretFile;
                settings["Security:Secrets:CacheTtlSeconds"] = "0";
                settings["Security:Secrets:CacheMaxStaleSeconds"] = "0";
            });
            using var client = factory.CreateClient();

            client.DefaultRequestHeaders.Add("X-Api-Key", "api-key-v1");
            var first = await client.GetAsync("/api/runtime/dotnet");
            Assert.Equal(HttpStatusCode.OK, first.StatusCode);

            await File.WriteAllTextAsync(secretFile, "api-key-v2");

            client.DefaultRequestHeaders.Remove("X-Api-Key");
            client.DefaultRequestHeaders.Add("X-Api-Key", "api-key-v1");
            var oldKeyResponse = await client.GetAsync("/api/runtime/dotnet");
            Assert.Equal(HttpStatusCode.Unauthorized, oldKeyResponse.StatusCode);

            client.DefaultRequestHeaders.Remove("X-Api-Key");
            client.DefaultRequestHeaders.Add("X-Api-Key", "api-key-v2");
            var newKeyResponse = await client.GetAsync("/api/runtime/dotnet");
            Assert.Equal(HttpStatusCode.OK, newKeyResponse.StatusCode);
        }
        finally
        {
            TryDeleteDirectory(tempRoot);
        }
    }

    [Fact]
    public async Task ApiKey_Rotation_Grace_Window_Should_Allow_Previous_Key_Temporarily()
    {
        var tempRoot = Path.Combine(Path.GetTempPath(), "datahz-tests-secrets", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(tempRoot);
        var secretFile = Path.Combine(tempRoot, "apikey-grace.txt");
        await File.WriteAllTextAsync(secretFile, "api-key-v1");

        try
        {
            using var factory = new ApiTestFactory(settings =>
            {
                settings["Security:ApiKey:Enabled"] = "true";
                settings["Security:ApiKey:Value"] = "";
                settings["Security:Secrets:EnableExternalProvider"] = "true";
                settings["Security:Secrets:ExternalProvider"] = "file";
                settings["Security:Secrets:ApiKeyExternalRef"] = secretFile;
                settings["Security:Secrets:CacheTtlSeconds"] = "1";
                settings["Security:Secrets:RotationGraceSeconds"] = "2";
            });
            using var client = factory.CreateClient();

            client.DefaultRequestHeaders.Add("X-Api-Key", "api-key-v1");
            (await client.GetAsync("/api/runtime/dotnet")).EnsureSuccessStatusCode();

            await File.WriteAllTextAsync(secretFile, "api-key-v2");
            await Task.Delay(1200);

            client.DefaultRequestHeaders.Remove("X-Api-Key");
            client.DefaultRequestHeaders.Add("X-Api-Key", "api-key-v2");
            (await client.GetAsync("/api/runtime/dotnet")).EnsureSuccessStatusCode();

            client.DefaultRequestHeaders.Remove("X-Api-Key");
            client.DefaultRequestHeaders.Add("X-Api-Key", "api-key-v1");
            var withinGrace = await client.GetAsync("/api/runtime/dotnet");
            Assert.Equal(HttpStatusCode.OK, withinGrace.StatusCode);

            await Task.Delay(2500);
            var afterGrace = await client.GetAsync("/api/runtime/dotnet");
            Assert.Equal(HttpStatusCode.Unauthorized, afterGrace.StatusCode);
        }
        finally
        {
            TryDeleteDirectory(tempRoot);
        }
    }

    [Fact]
    public async Task ApiKey_External_File_Source_Should_Use_Stale_Cache_On_Source_Outage()
    {
        var tempRoot = Path.Combine(Path.GetTempPath(), "datahz-tests-secrets", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(tempRoot);
        var secretFile = Path.Combine(tempRoot, "apikey-stale.txt");
        await File.WriteAllTextAsync(secretFile, "api-key-stale");

        try
        {
            using var factory = new ApiTestFactory(settings =>
            {
                settings["Security:ApiKey:Enabled"] = "true";
                settings["Security:ApiKey:Value"] = "";
                settings["Security:Secrets:EnableExternalProvider"] = "true";
                settings["Security:Secrets:ExternalProvider"] = "file";
                settings["Security:Secrets:ApiKeyExternalRef"] = secretFile;
                settings["Security:Secrets:CacheTtlSeconds"] = "1";
                settings["Security:Secrets:CacheMaxStaleSeconds"] = "3";
            });
            using var client = factory.CreateClient();

            client.DefaultRequestHeaders.Add("X-Api-Key", "api-key-stale");
            (await client.GetAsync("/api/runtime/dotnet")).EnsureSuccessStatusCode();

            File.Delete(secretFile);
            await Task.Delay(1200);

            var staleSuccess = await client.GetAsync("/api/runtime/dotnet");
            Assert.Equal(HttpStatusCode.OK, staleSuccess.StatusCode);

            await Task.Delay(3200);
            var staleExpired = await client.GetAsync("/api/runtime/dotnet");
            Assert.Equal(HttpStatusCode.Unauthorized, staleExpired.StatusCode);
        }
        finally
        {
            TryDeleteDirectory(tempRoot);
        }
    }

    [Fact]
    public async Task ApiKey_AzureKeyVault_Should_Fallback_To_Command_When_Unavailable()
    {
        using var factory = new ApiTestFactory(settings =>
        {
            settings["Security:ApiKey:Enabled"] = "true";
            settings["Security:ApiKey:Value"] = "";
            settings["Security:Secrets:EnableExternalProvider"] = "true";
            settings["Security:Secrets:ExternalProvider"] = "azurekv";
            settings["Security:Secrets:ApiKeyExternalRef"] = "api-key-secret";
            settings["Security:Secrets:AzureKeyVault:VaultUri"] = "not-a-uri";
            settings["Security:Secrets:AllowCommandExecution"] = "true";
            settings["Security:Secrets:ApiKeyCommand"] = "echo azurekv-fallback-key";
        });
        using var client = factory.CreateClient();

        var unauthorized = await client.GetAsync("/api/runtime/dotnet");
        Assert.Equal(HttpStatusCode.Unauthorized, unauthorized.StatusCode);

        client.DefaultRequestHeaders.Add("X-Api-Key", "azurekv-fallback-key");
        var authorized = await client.GetAsync("/api/runtime/dotnet");
        Assert.Equal(HttpStatusCode.OK, authorized.StatusCode);
    }

    [Fact]
    public async Task ApiKey_AwsSecretsManager_Should_Fallback_To_Command_When_Unavailable()
    {
        using var factory = new ApiTestFactory(settings =>
        {
            settings["Security:ApiKey:Enabled"] = "true";
            settings["Security:ApiKey:Value"] = "";
            settings["Security:Secrets:EnableExternalProvider"] = "true";
            settings["Security:Secrets:ExternalProvider"] = "awssm";
            settings["Security:Secrets:ApiKeyExternalRef"] = "datahz/api-key";
            settings["Security:Secrets:AwsSecretsManager:Region"] = "";
            settings["Security:Secrets:AllowCommandExecution"] = "true";
            settings["Security:Secrets:ApiKeyCommand"] = "echo awssm-fallback-key";
        });
        using var client = factory.CreateClient();

        var unauthorized = await client.GetAsync("/api/runtime/dotnet");
        Assert.Equal(HttpStatusCode.Unauthorized, unauthorized.StatusCode);

        client.DefaultRequestHeaders.Add("X-Api-Key", "awssm-fallback-key");
        var authorized = await client.GetAsync("/api/runtime/dotnet");
        Assert.Equal(HttpStatusCode.OK, authorized.StatusCode);
    }

    [Fact]
    public async Task ApiKey_GcpSecretManager_Should_Fallback_To_Command_When_Unavailable()
    {
        using var factory = new ApiTestFactory(settings =>
        {
            settings["Security:ApiKey:Enabled"] = "true";
            settings["Security:ApiKey:Value"] = "";
            settings["Security:Secrets:EnableExternalProvider"] = "true";
            settings["Security:Secrets:ExternalProvider"] = "gcpsm";
            settings["Security:Secrets:ApiKeyExternalRef"] = "datahz-api-key";
            settings["Security:Secrets:GcpSecretManager:ProjectId"] = "";
            settings["Security:Secrets:AllowCommandExecution"] = "true";
            settings["Security:Secrets:ApiKeyCommand"] = "echo gcpsm-fallback-key";
        });
        using var client = factory.CreateClient();

        var unauthorized = await client.GetAsync("/api/runtime/dotnet");
        Assert.Equal(HttpStatusCode.Unauthorized, unauthorized.StatusCode);

        client.DefaultRequestHeaders.Add("X-Api-Key", "gcpsm-fallback-key");
        var authorized = await client.GetAsync("/api/runtime/dotnet");
        Assert.Equal(HttpStatusCode.OK, authorized.StatusCode);
    }

    [Fact]
    public async Task ApiKey_AliyunKms_Should_Fallback_To_Command_When_Unavailable()
    {
        using var factory = new ApiTestFactory(settings =>
        {
            settings["Security:ApiKey:Enabled"] = "true";
            settings["Security:ApiKey:Value"] = "";
            settings["Security:Secrets:EnableExternalProvider"] = "true";
            settings["Security:Secrets:ExternalProvider"] = "aliyunkms";
            settings["Security:Secrets:ApiKeyExternalRef"] = "datahz-api-key";
            settings["Security:Secrets:AliyunKms:RegionId"] = "";
            settings["Security:Secrets:AllowCommandExecution"] = "true";
            settings["Security:Secrets:ApiKeyCommand"] = "echo aliyunkms-fallback-key";
        });
        using var client = factory.CreateClient();

        var unauthorized = await client.GetAsync("/api/runtime/dotnet");
        Assert.Equal(HttpStatusCode.Unauthorized, unauthorized.StatusCode);

        client.DefaultRequestHeaders.Add("X-Api-Key", "aliyunkms-fallback-key");
        var authorized = await client.GetAsync("/api/runtime/dotnet");
        Assert.Equal(HttpStatusCode.OK, authorized.StatusCode);
    }

    [Fact]
    public async Task Submit_Then_Cancel_Should_Set_Canceled_Status()
    {
        using var factory = new ApiTestFactory();
        using var client = factory.CreateClient();

        var submitBody = new
        {
            plan = new
            {
                templatePath = @"D:\missing\template.ini",
                sourceDirectory = @"D:\missing",
                targetDirectory = @"D:\missing",
                areaCodePath = @"D:\missing\codes.txt",
                startIndex = 0,
                endIndex = 1
            },
            dryRun = true,
            incremental = true
        };

        var submitResponse = await client.PostAsJsonAsync("/api/jobs/submit", submitBody);
        Assert.Equal(HttpStatusCode.Accepted, submitResponse.StatusCode);

        var submitJson = await ReadJsonAsync(submitResponse);
        var jobId = submitJson.GetProperty("jobId").GetGuid();

        var cancelResponse = await client.PostAsJsonAsync($"/api/jobs/{jobId}/cancel", new { reason = "test cancel" });
        Assert.Equal(HttpStatusCode.OK, cancelResponse.StatusCode);

        var cancelJson = await ReadJsonAsync(cancelResponse);
        Assert.Equal("Canceled", cancelJson.GetProperty("status").GetString());

        var jobResponse = await client.GetAsync($"/api/jobs/{jobId}");
        jobResponse.EnsureSuccessStatusCode();
        var jobJson = await ReadJsonAsync(jobResponse);
        Assert.Equal("Canceled", jobJson.GetProperty("status").GetString());
        Assert.True(jobJson.GetProperty("cancellationRequested").GetBoolean());

        var statsResponse = await client.GetAsync("/api/jobs/stats");
        statsResponse.EnsureSuccessStatusCode();
        var statsJson = await ReadJsonAsync(statsResponse);
        Assert.True(statsJson.GetProperty("total").GetInt32() >= 1);
        Assert.True(statsJson.GetProperty("canceled").GetInt32() >= 1);
    }

    [Fact]
    public async Task Submit_With_IdempotencyKey_Should_Deduplicate_Active_Job()
    {
        using var factory = new ApiTestFactory(settings =>
        {
            settings["JobQueue:WorkerCount"] = "0";
        });
        using var client = factory.CreateClient();

        var submitBody = CreateSubmitBody("idem-job-001");
        var first = await client.PostAsJsonAsync("/api/jobs/submit", submitBody);
        Assert.Equal(HttpStatusCode.Accepted, first.StatusCode);
        var firstPayload = await ReadJsonAsync(first);
        var firstJobId = firstPayload.GetProperty("jobId").GetGuid();
        Assert.False(firstPayload.GetProperty("deduplicated").GetBoolean());

        var second = await client.PostAsJsonAsync("/api/jobs/submit", submitBody);
        Assert.Equal(HttpStatusCode.Accepted, second.StatusCode);
        var secondPayload = await ReadJsonAsync(second);
        var secondJobId = secondPayload.GetProperty("jobId").GetGuid();
        Assert.True(secondPayload.GetProperty("deduplicated").GetBoolean());
        Assert.Equal(firstJobId, secondJobId);

        var jobsResponse = await client.GetAsync("/api/jobs?take=20");
        jobsResponse.EnsureSuccessStatusCode();
        var jobs = await ReadJsonAsync(jobsResponse);
        Assert.Equal(JsonValueKind.Array, jobs.ValueKind);
        Assert.Single(jobs.EnumerateArray().ToList());
    }

    [Fact]
    public async Task Monitor_Overview_Should_Return_Runtime_Queue_And_Recent_Collections()
    {
        using var factory = new ApiTestFactory();
        using var client = factory.CreateClient();

        var response = await client.GetAsync("/api/monitor/overview?jobs=5&audit=5");
        response.EnsureSuccessStatusCode();

        var json = await ReadJsonAsync(response);
        Assert.Equal("DataHz.Api", json.GetProperty("service").GetString());
        Assert.True(json.GetProperty("uptimeSeconds").GetInt64() >= 0);

        var queue = json.GetProperty("queue");
        Assert.True(queue.GetProperty("total").GetInt32() >= 0);
        Assert.True(queue.GetProperty("queued").GetInt32() >= 0);

        var recentJobs = json.GetProperty("recentJobs");
        Assert.Equal(JsonValueKind.Array, recentJobs.ValueKind);

        var recentAudit = json.GetProperty("recentAudit");
        Assert.Equal(JsonValueKind.Array, recentAudit.ValueKind);

        var externalSecrets = json.GetProperty("externalSecrets");
        Assert.Equal(JsonValueKind.Object, externalSecrets.ValueKind);
        Assert.True(externalSecrets.TryGetProperty("configuredProvider", out _));
        Assert.Equal(JsonValueKind.Array, externalSecrets.GetProperty("snapshot").ValueKind);
    }

    [Fact]
    public async Task Monitor_Overview_Should_Include_External_Secret_Runtime_Snapshot()
    {
        var tempRoot = Path.Combine(Path.GetTempPath(), "datahz-tests-secrets", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(tempRoot);
        var secretFile = Path.Combine(tempRoot, "overview-apikey.txt");
        await File.WriteAllTextAsync(secretFile, "overview-key");

        try
        {
            using var factory = new ApiTestFactory(settings =>
            {
                settings["Security:ApiKey:Enabled"] = "true";
                settings["Security:ApiKey:Value"] = "";
                settings["Security:Secrets:EnableExternalProvider"] = "true";
                settings["Security:Secrets:ExternalProvider"] = "file";
                settings["Security:Secrets:ApiKeyExternalRef"] = secretFile;
                settings["Security:Secrets:CacheTtlSeconds"] = "0";
                settings["Security:Secrets:CacheMaxStaleSeconds"] = "0";
            });
            using var client = factory.CreateClient();
            client.DefaultRequestHeaders.Add("X-Api-Key", "overview-key");

            var response = await client.GetAsync("/api/monitor/overview?jobs=5&audit=5");
            response.EnsureSuccessStatusCode();

            var payload = await ReadJsonAsync(response);
            var externalSecrets = payload.GetProperty("externalSecrets");

            Assert.Equal("file", externalSecrets.GetProperty("configuredProvider").GetString());
            Assert.True(externalSecrets.GetProperty("totalAttempts").GetInt32() >= 1);
            Assert.True(externalSecrets.GetProperty("success").GetInt32() >= 1);

            var snapshot = externalSecrets.GetProperty("snapshot");
            Assert.Equal(JsonValueKind.Array, snapshot.ValueKind);
            Assert.Contains(snapshot.EnumerateArray(), x =>
                x.GetProperty("provider").GetString() == "file" &&
                x.GetProperty("purpose").GetString() == "apiKey");
        }
        finally
        {
            TryDeleteDirectory(tempRoot);
        }
    }

    [Fact]
    public async Task Monitor_ExternalSecrets_Should_Require_Viewer_And_Support_Filters()
    {
        var tempRoot = Path.Combine(Path.GetTempPath(), "datahz-tests-secrets", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(tempRoot);
        var secretFile = Path.Combine(tempRoot, "monitor-external-apikey.txt");
        await File.WriteAllTextAsync(secretFile, "external-monitor-key");

        try
        {
            using var factory = new ApiTestFactory(settings =>
            {
                settings["Security:ApiKey:Enabled"] = "true";
                settings["Security:ApiKey:Value"] = "";
                settings["Security:ApiKey:Keys:0:Name"] = "viewer";
                settings["Security:ApiKey:Keys:0:Key"] = "viewer-key";
                settings["Security:ApiKey:Keys:0:Role"] = "Viewer";
                settings["Security:Secrets:EnableExternalProvider"] = "true";
                settings["Security:Secrets:ExternalProvider"] = "file";
                settings["Security:Secrets:ApiKeyExternalRef"] = secretFile;
                settings["Security:Secrets:CacheTtlSeconds"] = "0";
                settings["Security:Secrets:CacheMaxStaleSeconds"] = "0";
            });
            using var client = factory.CreateClient();
            var fromUtc = DateTimeOffset.UtcNow.AddSeconds(-1);
            var fromUtcQuery = Uri.EscapeDataString(fromUtc.ToString("O"));

            var unauthorized = await client.GetAsync("/api/monitor/external-secrets?take=5");
            Assert.Equal(HttpStatusCode.Unauthorized, unauthorized.StatusCode);

            client.DefaultRequestHeaders.Add("X-Api-Key", "external-monitor-key");
            (await client.GetAsync("/api/runtime/dotnet")).EnsureSuccessStatusCode();
            client.DefaultRequestHeaders.Remove("X-Api-Key");

            client.DefaultRequestHeaders.Add("X-Api-Key", "viewer-key");

            var filtered = await client.GetAsync("/api/monitor/external-secrets?take=5&provider=file&purpose=apiKey&status=success&fromUtc=" + fromUtcQuery);
            filtered.EnsureSuccessStatusCode();
            var filteredPayload = await ReadJsonAsync(filtered);
            Assert.Equal(5, filteredPayload.GetProperty("filter").GetProperty("take").GetInt32());
            Assert.True(filteredPayload.GetProperty("summary").GetProperty("matched").GetInt32() >= 1);
            var rows = filteredPayload.GetProperty("rows");
            Assert.Equal(JsonValueKind.Array, rows.ValueKind);
            Assert.Contains(rows.EnumerateArray(), x =>
                x.GetProperty("provider").GetString() == "file" &&
                x.GetProperty("purpose").GetString() == "apiKey" &&
                x.GetProperty("lastStatus").GetString() == "success");

            var windowed = await client.GetAsync("/api/monitor/external-secrets?take=5&provider=file&purpose=apiKey&status=success&windowMinutes=1");
            windowed.EnsureSuccessStatusCode();
            var windowedPayload = await ReadJsonAsync(windowed);
            Assert.Equal(1, windowedPayload.GetProperty("filter").GetProperty("windowMinutes").GetInt32());
            Assert.True(windowedPayload.GetProperty("filter").GetProperty("fromUtc").ValueKind != JsonValueKind.Null);

            var none = await client.GetAsync("/api/monitor/external-secrets?provider=awssm&purpose=__none__&take=5&fromUtc=" + fromUtcQuery);
            none.EnsureSuccessStatusCode();
            var nonePayload = await ReadJsonAsync(none);
            Assert.Equal(0, nonePayload.GetProperty("summary").GetProperty("matched").GetInt32());
        }
        finally
        {
            TryDeleteDirectory(tempRoot);
        }
    }

    [Fact]
    public async Task Monitor_ExternalSecrets_Export_Should_Require_Viewer_And_Return_File()
    {
        var tempRoot = Path.Combine(Path.GetTempPath(), "datahz-tests-secrets", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(tempRoot);
        var secretFile = Path.Combine(tempRoot, "monitor-export-apikey.txt");
        await File.WriteAllTextAsync(secretFile, "external-export-key");

        try
        {
            using var factory = new ApiTestFactory(settings =>
            {
                settings["Security:ApiKey:Enabled"] = "true";
                settings["Security:ApiKey:Value"] = "";
                settings["Security:ApiKey:Keys:0:Name"] = "viewer";
                settings["Security:ApiKey:Keys:0:Key"] = "viewer-key";
                settings["Security:ApiKey:Keys:0:Role"] = "Viewer";
                settings["Security:Secrets:EnableExternalProvider"] = "true";
                settings["Security:Secrets:ExternalProvider"] = "file";
                settings["Security:Secrets:ApiKeyExternalRef"] = secretFile;
                settings["Security:Secrets:CacheTtlSeconds"] = "0";
                settings["Security:Secrets:CacheMaxStaleSeconds"] = "0";
            });
            using var client = factory.CreateClient();

            var unauthorized = await client.GetAsync("/api/monitor/external-secrets/export?format=csv&take=20");
            Assert.Equal(HttpStatusCode.Unauthorized, unauthorized.StatusCode);

            client.DefaultRequestHeaders.Add("X-Api-Key", "external-export-key");
            (await client.GetAsync("/api/runtime/dotnet")).EnsureSuccessStatusCode();
            client.DefaultRequestHeaders.Remove("X-Api-Key");

            client.DefaultRequestHeaders.Add("X-Api-Key", "viewer-key");

            var csv = await client.GetAsync("/api/monitor/external-secrets/export?format=csv&provider=file&purpose=apiKey&status=success&windowMinutes=10&take=20");
            csv.EnsureSuccessStatusCode();
            Assert.Equal("text/csv; charset=utf-8", csv.Content.Headers.ContentType?.ToString());
            var csvBody = await csv.Content.ReadAsStringAsync();
            Assert.Contains("provider,purpose,secretRefHint,lastAttemptUtc,lastSuccessUtc,lastFailureUtc,lastStatus,lastAttemptHadValue,lastDurationMs,lastError", csvBody);

            var jsonl = await client.GetAsync("/api/monitor/external-secrets/export?format=jsonl&provider=file&purpose=apiKey&status=success&windowMinutes=10&take=20");
            jsonl.EnsureSuccessStatusCode();
            Assert.Equal("application/x-ndjson; charset=utf-8", jsonl.Content.Headers.ContentType?.ToString());
            var jsonLines = await jsonl.Content.ReadAsStringAsync();
            Assert.Contains("\"Provider\":\"file\"", jsonLines);

            var badFormat = await client.GetAsync("/api/monitor/external-secrets/export?format=xml");
            Assert.Equal(HttpStatusCode.BadRequest, badFormat.StatusCode);
        }
        finally
        {
            TryDeleteDirectory(tempRoot);
        }
    }

    [Fact]
    public async Task Monitor_ExternalSecrets_Reset_Should_Require_Admin_And_Clear_State()
    {
        var tempRoot = Path.Combine(Path.GetTempPath(), "datahz-tests-secrets", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(tempRoot);
        var secretFile = Path.Combine(tempRoot, "monitor-reset-apikey.txt");
        await File.WriteAllTextAsync(secretFile, "external-reset-key");

        try
        {
            using var factory = new ApiTestFactory(settings =>
            {
                settings["Security:ApiKey:Enabled"] = "true";
                settings["Security:ApiKey:Value"] = "";
                settings["Security:ApiKey:Keys:0:Name"] = "viewer";
                settings["Security:ApiKey:Keys:0:Key"] = "viewer-key";
                settings["Security:ApiKey:Keys:0:Role"] = "Viewer";
                settings["Security:ApiKey:Keys:1:Name"] = "admin";
                settings["Security:ApiKey:Keys:1:Key"] = "admin-key";
                settings["Security:ApiKey:Keys:1:Role"] = "Admin";
                settings["Security:Secrets:EnableExternalProvider"] = "true";
                settings["Security:Secrets:ExternalProvider"] = "file";
                settings["Security:Secrets:ApiKeyExternalRef"] = secretFile;
                settings["Security:Secrets:CacheTtlSeconds"] = "0";
                settings["Security:Secrets:CacheMaxStaleSeconds"] = "0";
            });
            using var client = factory.CreateClient();

            client.DefaultRequestHeaders.Add("X-Api-Key", "external-reset-key");
            (await client.GetAsync("/api/runtime/dotnet")).EnsureSuccessStatusCode();
            client.DefaultRequestHeaders.Remove("X-Api-Key");

            client.DefaultRequestHeaders.Add("X-Api-Key", "viewer-key");
            var viewerReset = await client.PostAsync("/api/monitor/external-secrets/reset", null);
            Assert.Equal(HttpStatusCode.Forbidden, viewerReset.StatusCode);

            var before = await client.GetAsync("/api/monitor/external-secrets?provider=file&purpose=apiKey&take=20");
            before.EnsureSuccessStatusCode();
            var beforePayload = await ReadJsonAsync(before);
            Assert.True(beforePayload.GetProperty("summary").GetProperty("matched").GetInt32() >= 1);

            client.DefaultRequestHeaders.Remove("X-Api-Key");
            client.DefaultRequestHeaders.Add("X-Api-Key", "admin-key");
            var adminReset = await client.PostAsync("/api/monitor/external-secrets/reset", null);
            adminReset.EnsureSuccessStatusCode();
            var resetPayload = await ReadJsonAsync(adminReset);
            Assert.True(resetPayload.GetProperty("clearedCount").GetInt32() >= 1);

            var after = await client.GetAsync("/api/monitor/external-secrets?provider=file&purpose=apiKey&take=20");
            after.EnsureSuccessStatusCode();
            var afterPayload = await ReadJsonAsync(after);
            Assert.Equal(0, afterPayload.GetProperty("summary").GetProperty("matched").GetInt32());
        }
        finally
        {
            TryDeleteDirectory(tempRoot);
        }
    }

    [Fact]
    public async Task Monitor_ExternalSecrets_Reset_Should_Support_Filtered_Clear()
    {
        var tempRoot = Path.Combine(Path.GetTempPath(), "datahz-tests-secrets", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(tempRoot);
        var apiKeySecretFile = Path.Combine(tempRoot, "monitor-reset-filtered-apikey.txt");
        var jwtSecretFile = Path.Combine(tempRoot, "monitor-reset-filtered-jwt.txt");
        await File.WriteAllTextAsync(apiKeySecretFile, "filtered-reset-api-key");
        await File.WriteAllTextAsync(jwtSecretFile, "filtered-reset-jwt-key");

        try
        {
            using var factory = new ApiTestFactory(settings =>
            {
                settings["Security:ApiKey:Enabled"] = "true";
                settings["Security:ApiKey:Value"] = "";
                settings["Security:ApiKey:Keys:0:Name"] = "viewer";
                settings["Security:ApiKey:Keys:0:Key"] = "viewer-key";
                settings["Security:ApiKey:Keys:0:Role"] = "Viewer";
                settings["Security:ApiKey:Keys:1:Name"] = "admin";
                settings["Security:ApiKey:Keys:1:Key"] = "admin-key";
                settings["Security:ApiKey:Keys:1:Role"] = "Admin";
                settings["Security:Secrets:EnableExternalProvider"] = "true";
                settings["Security:Secrets:ExternalProvider"] = "file";
                settings["Security:Secrets:ApiKeyExternalRef"] = apiKeySecretFile;
                settings["Security:Secrets:JwtSigningKeyExternalRef"] = jwtSecretFile;
                settings["Security:Secrets:CacheTtlSeconds"] = "0";
                settings["Security:Secrets:CacheMaxStaleSeconds"] = "0";
            });
            using var client = factory.CreateClient();

            client.DefaultRequestHeaders.Add("X-Api-Key", "admin-key");
            (await client.GetAsync("/api/security/secrets/runtime")).EnsureSuccessStatusCode();

            var beforeApiKey = await client.GetAsync("/api/monitor/external-secrets?provider=file&purpose=apiKey&take=20");
            beforeApiKey.EnsureSuccessStatusCode();
            var beforeApiPayload = await ReadJsonAsync(beforeApiKey);
            Assert.True(beforeApiPayload.GetProperty("summary").GetProperty("matched").GetInt32() >= 1);

            var beforeJwt = await client.GetAsync("/api/monitor/external-secrets?provider=file&purpose=jwtSigningKey&take=20");
            beforeJwt.EnsureSuccessStatusCode();
            var beforeJwtPayload = await ReadJsonAsync(beforeJwt);
            Assert.True(beforeJwtPayload.GetProperty("summary").GetProperty("matched").GetInt32() >= 1);

            var filteredReset = await client.PostAsync("/api/monitor/external-secrets/reset?provider=file&purpose=apiKey", null);
            filteredReset.EnsureSuccessStatusCode();
            var filteredResetPayload = await ReadJsonAsync(filteredReset);
            Assert.True(filteredResetPayload.GetProperty("clearedCount").GetInt32() >= 1);
            Assert.Equal("file", filteredResetPayload.GetProperty("filter").GetProperty("provider").GetString());
            Assert.Equal("apiKey", filteredResetPayload.GetProperty("filter").GetProperty("purpose").GetString());

            var afterApiKey = await client.GetAsync("/api/monitor/external-secrets?provider=file&purpose=apiKey&take=20");
            afterApiKey.EnsureSuccessStatusCode();
            var afterApiPayload = await ReadJsonAsync(afterApiKey);
            Assert.Equal(0, afterApiPayload.GetProperty("summary").GetProperty("matched").GetInt32());

            var afterJwt = await client.GetAsync("/api/monitor/external-secrets?provider=file&purpose=jwtSigningKey&take=20");
            afterJwt.EnsureSuccessStatusCode();
            var afterJwtPayload = await ReadJsonAsync(afterJwt);
            Assert.True(afterJwtPayload.GetProperty("summary").GetProperty("matched").GetInt32() >= 1);
        }
        finally
        {
            TryDeleteDirectory(tempRoot);
        }
    }

    [Fact]
    public async Task Dashboard_Page_Should_Be_Served()
    {
        using var factory = new ApiTestFactory();
        using var client = factory.CreateClient();

        var response = await client.GetAsync("/dashboard/index.html");
        response.EnsureSuccessStatusCode();

        var html = await response.Content.ReadAsStringAsync();
        Assert.Contains("DataHz Monitor Board", html);
    }

    [Fact]
    public async Task Rbac_Viewer_Can_Read_But_Cannot_Submit()
    {
        using var factory = new ApiTestFactory(settings =>
        {
            settings["Security:ApiKey:Enabled"] = "true";
            settings["Security:ApiKey:Keys:0:Name"] = "viewer";
            settings["Security:ApiKey:Keys:0:Key"] = "viewer-key";
            settings["Security:ApiKey:Keys:0:Role"] = "Viewer";
            settings["Security:ApiKey:Keys:1:Name"] = "operator";
            settings["Security:ApiKey:Keys:1:Key"] = "operator-key";
            settings["Security:ApiKey:Keys:1:Role"] = "Operator";
        });
        using var client = factory.CreateClient();

        client.DefaultRequestHeaders.Add("X-Api-Key", "viewer-key");
        var whoAmIResponse = await client.GetAsync("/api/security/whoami");
        whoAmIResponse.EnsureSuccessStatusCode();
        var whoAmI = await ReadJsonAsync(whoAmIResponse);
        Assert.Equal("Viewer", whoAmI.GetProperty("role").GetString());

        var statsResponse = await client.GetAsync("/api/jobs/stats");
        statsResponse.EnsureSuccessStatusCode();

        var submitWithViewer = await client.PostAsJsonAsync("/api/jobs/submit", CreateSubmitBody());
        Assert.Equal(HttpStatusCode.Forbidden, submitWithViewer.StatusCode);

        client.DefaultRequestHeaders.Remove("X-Api-Key");
        client.DefaultRequestHeaders.Add("X-Api-Key", "operator-key");
        var submitWithOperator = await client.PostAsJsonAsync("/api/jobs/submit", CreateSubmitBody());
        Assert.Equal(HttpStatusCode.Accepted, submitWithOperator.StatusCode);
    }

    [Fact]
    public async Task Monitor_Job_Detail_Should_Return_Job_And_Events()
    {
        using var factory = new ApiTestFactory();
        using var client = factory.CreateClient();

        var submitResponse = await client.PostAsJsonAsync("/api/jobs/submit", CreateSubmitBody());
        Assert.Equal(HttpStatusCode.Accepted, submitResponse.StatusCode);

        var submitJson = await ReadJsonAsync(submitResponse);
        var jobId = submitJson.GetProperty("jobId").GetGuid();

        var detailResponse = await client.GetAsync($"/api/monitor/jobs/{jobId}?audit=20");
        detailResponse.EnsureSuccessStatusCode();

        var detailJson = await ReadJsonAsync(detailResponse);
        var job = detailJson.GetProperty("job");
        Assert.Equal(jobId, job.GetProperty("id").GetGuid());

        var events = detailJson.GetProperty("events");
        Assert.Equal(JsonValueKind.Array, events.ValueKind);
    }

    [Fact]
    public async Task Audit_Export_Should_Require_Admin_And_Return_File()
    {
        using var factory = new ApiTestFactory(settings =>
        {
            settings["Security:ApiKey:Enabled"] = "true";
            settings["Security:ApiKey:Keys:0:Name"] = "viewer";
            settings["Security:ApiKey:Keys:0:Key"] = "viewer-key";
            settings["Security:ApiKey:Keys:0:Role"] = "Viewer";
            settings["Security:ApiKey:Keys:1:Name"] = "admin";
            settings["Security:ApiKey:Keys:1:Key"] = "admin-key";
            settings["Security:ApiKey:Keys:1:Role"] = "Admin";
        });
        using var client = factory.CreateClient();

        client.DefaultRequestHeaders.Add("X-Api-Key", "viewer-key");
        var forbidden = await client.GetAsync("/api/audit/export?format=csv&take=10");
        Assert.Equal(HttpStatusCode.Forbidden, forbidden.StatusCode);

        client.DefaultRequestHeaders.Remove("X-Api-Key");
        client.DefaultRequestHeaders.Add("X-Api-Key", "admin-key");

        var csvResponse = await client.GetAsync("/api/audit/export?format=csv&take=10");
        csvResponse.EnsureSuccessStatusCode();
        Assert.Equal("text/csv; charset=utf-8", csvResponse.Content.Headers.ContentType?.ToString());
        var csv = await csvResponse.Content.ReadAsStringAsync();
        Assert.Contains("utc,category,action,jobId,message,path,method,statusCode,remoteIp", csv);

        var jsonlResponse = await client.GetAsync("/api/audit/export?format=jsonl&take=10");
        jsonlResponse.EnsureSuccessStatusCode();
        Assert.Equal("application/x-ndjson; charset=utf-8", jsonlResponse.Content.Headers.ContentType?.ToString());
    }

    [Fact]
    public async Task Jwt_Mode_Should_Authenticate_And_Enforce_Role()
    {
        const string issuer = "datahz-tests";
        const string audience = "datahz-api";
        const string signingKey = "datahz-tests-signing-key-2026-very-secure";

        using var factory = new ApiTestFactory(settings =>
        {
            settings["Security:ApiKey:Enabled"] = "false";
            settings["Security:Jwt:Enabled"] = "true";
            settings["Security:Jwt:SigningKey"] = signingKey;
            settings["Security:Jwt:ValidIssuer"] = issuer;
            settings["Security:Jwt:ValidAudience"] = audience;
        });
        using var client = factory.CreateClient();

        var unauthorized = await client.GetAsync("/api/security/whoami");
        Assert.Equal(HttpStatusCode.Unauthorized, unauthorized.StatusCode);

        var viewerToken = CreateJwtToken("viewer-user", "Viewer", signingKey, issuer, audience);
        client.DefaultRequestHeaders.Authorization =
            new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", viewerToken);

        var whoAmIResponse = await client.GetAsync("/api/security/whoami");
        whoAmIResponse.EnsureSuccessStatusCode();
        var whoAmI = await ReadJsonAsync(whoAmIResponse);
        Assert.Equal("Viewer", whoAmI.GetProperty("role").GetString());
        Assert.Equal("jwt", whoAmI.GetProperty("source").GetString());

        var submitWithViewer = await client.PostAsJsonAsync("/api/jobs/submit", CreateSubmitBody());
        Assert.Equal(HttpStatusCode.Forbidden, submitWithViewer.StatusCode);

        var operatorToken = CreateJwtToken("operator-user", "Operator", signingKey, issuer, audience);
        client.DefaultRequestHeaders.Authorization =
            new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", operatorToken);

        var submitWithOperator = await client.PostAsJsonAsync("/api/jobs/submit", CreateSubmitBody());
        Assert.Equal(HttpStatusCode.Accepted, submitWithOperator.StatusCode);
    }

    [Fact]
    public async Task Jwt_Command_Source_Should_Work_When_Enabled()
    {
        const string issuer = "datahz-tests";
        const string audience = "datahz-api";
        const string signingKey = "datahz-tests-signing-key-2026-very-secure";

        using var factory = new ApiTestFactory(settings =>
        {
            settings["Security:ApiKey:Enabled"] = "false";
            settings["Security:Jwt:Enabled"] = "true";
            settings["Security:Jwt:SigningKey"] = "";
            settings["Security:Jwt:ValidIssuer"] = issuer;
            settings["Security:Jwt:ValidAudience"] = audience;
            settings["Security:Secrets:AllowCommandExecution"] = "true";
            settings["Security:Secrets:JwtSigningKeyCommand"] = $"echo {signingKey}";
        });
        using var client = factory.CreateClient();

        var unauthorized = await client.GetAsync("/api/security/whoami");
        Assert.Equal(HttpStatusCode.Unauthorized, unauthorized.StatusCode);

        var token = CreateJwtToken("viewer-user", "Viewer", signingKey, issuer, audience);
        client.DefaultRequestHeaders.Authorization =
            new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", token);

        var whoAmIResponse = await client.GetAsync("/api/security/whoami");
        whoAmIResponse.EnsureSuccessStatusCode();
        var whoAmI = await ReadJsonAsync(whoAmIResponse);
        Assert.Equal("jwt", whoAmI.GetProperty("source").GetString());
        Assert.Equal("Viewer", whoAmI.GetProperty("role").GetString());
    }

    [Fact]
    public async Task Jwt_External_File_Source_Should_Work_When_Enabled()
    {
        const string issuer = "datahz-tests";
        const string audience = "datahz-api";
        const string signingKey = "datahz-tests-signing-key-2026-very-secure";

        var tempRoot = Path.Combine(Path.GetTempPath(), "datahz-tests-secrets", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(tempRoot);
        var secretFile = Path.Combine(tempRoot, "jwt.key");
        await File.WriteAllTextAsync(secretFile, signingKey);

        try
        {
            using var factory = new ApiTestFactory(settings =>
            {
                settings["Security:ApiKey:Enabled"] = "false";
                settings["Security:Jwt:Enabled"] = "true";
                settings["Security:Jwt:SigningKey"] = "";
                settings["Security:Jwt:ValidIssuer"] = issuer;
                settings["Security:Jwt:ValidAudience"] = audience;
                settings["Security:Secrets:EnableExternalProvider"] = "true";
                settings["Security:Secrets:ExternalProvider"] = "file";
                settings["Security:Secrets:JwtSigningKeyExternalRef"] = secretFile;
                settings["Security:Secrets:CacheTtlSeconds"] = "0";
                settings["Security:Secrets:CacheMaxStaleSeconds"] = "0";
            });
            using var client = factory.CreateClient();

            var token = CreateJwtToken("viewer-user", "Viewer", signingKey, issuer, audience);
            client.DefaultRequestHeaders.Authorization =
                new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", token);

            var whoAmIResponse = await client.GetAsync("/api/security/whoami");
            whoAmIResponse.EnsureSuccessStatusCode();
            var whoAmI = await ReadJsonAsync(whoAmIResponse);
            Assert.Equal("jwt", whoAmI.GetProperty("source").GetString());
            Assert.Equal("Viewer", whoAmI.GetProperty("role").GetString());
        }
        finally
        {
            TryDeleteDirectory(tempRoot);
        }
    }

    [Fact]
    public async Task Jwt_External_File_Source_Should_Support_Rotation_Without_Restart()
    {
        const string issuer = "datahz-tests";
        const string audience = "datahz-api";
        const string signingKeyV1 = "datahz-tests-signing-key-2026-version-one";
        const string signingKeyV2 = "datahz-tests-signing-key-2026-version-two";

        var tempRoot = Path.Combine(Path.GetTempPath(), "datahz-tests-secrets", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(tempRoot);
        var secretFile = Path.Combine(tempRoot, "jwt-rotate.key");
        await File.WriteAllTextAsync(secretFile, signingKeyV1);

        try
        {
            using var factory = new ApiTestFactory(settings =>
            {
                settings["Security:ApiKey:Enabled"] = "false";
                settings["Security:Jwt:Enabled"] = "true";
                settings["Security:Jwt:SigningKey"] = "";
                settings["Security:Jwt:ValidIssuer"] = issuer;
                settings["Security:Jwt:ValidAudience"] = audience;
                settings["Security:Secrets:EnableExternalProvider"] = "true";
                settings["Security:Secrets:ExternalProvider"] = "file";
                settings["Security:Secrets:JwtSigningKeyExternalRef"] = secretFile;
                settings["Security:Secrets:CacheTtlSeconds"] = "0";
                settings["Security:Secrets:CacheMaxStaleSeconds"] = "0";
            });
            using var client = factory.CreateClient();

            var tokenV1 = CreateJwtToken("viewer-user", "Viewer", signingKeyV1, issuer, audience);
            client.DefaultRequestHeaders.Authorization =
                new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", tokenV1);
            var first = await client.GetAsync("/api/security/whoami");
            first.EnsureSuccessStatusCode();

            await File.WriteAllTextAsync(secretFile, signingKeyV2);

            var oldKeyResponse = await client.GetAsync("/api/security/whoami");
            Assert.Equal(HttpStatusCode.Unauthorized, oldKeyResponse.StatusCode);

            var tokenV2 = CreateJwtToken("viewer-user", "Viewer", signingKeyV2, issuer, audience);
            client.DefaultRequestHeaders.Authorization =
                new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", tokenV2);
            var second = await client.GetAsync("/api/security/whoami");
            second.EnsureSuccessStatusCode();
            var whoAmI = await ReadJsonAsync(second);
            Assert.Equal("Viewer", whoAmI.GetProperty("role").GetString());
        }
        finally
        {
            TryDeleteDirectory(tempRoot);
        }
    }

    [Fact]
    public async Task Jwt_Rotation_Grace_Window_Should_Allow_Previous_Key_Temporarily()
    {
        const string issuer = "datahz-tests";
        const string audience = "datahz-api";
        const string signingKeyV1 = "datahz-tests-signing-key-2026-grace-v1";
        const string signingKeyV2 = "datahz-tests-signing-key-2026-grace-v2";

        var tempRoot = Path.Combine(Path.GetTempPath(), "datahz-tests-secrets", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(tempRoot);
        var secretFile = Path.Combine(tempRoot, "jwt-grace.key");
        await File.WriteAllTextAsync(secretFile, signingKeyV1);

        try
        {
            using var factory = new ApiTestFactory(settings =>
            {
                settings["Security:ApiKey:Enabled"] = "false";
                settings["Security:Jwt:Enabled"] = "true";
                settings["Security:Jwt:SigningKey"] = "";
                settings["Security:Jwt:ValidIssuer"] = issuer;
                settings["Security:Jwt:ValidAudience"] = audience;
                settings["Security:Secrets:EnableExternalProvider"] = "true";
                settings["Security:Secrets:ExternalProvider"] = "file";
                settings["Security:Secrets:JwtSigningKeyExternalRef"] = secretFile;
                settings["Security:Secrets:CacheTtlSeconds"] = "1";
                settings["Security:Secrets:RotationGraceSeconds"] = "2";
            });
            using var client = factory.CreateClient();

            var tokenV1 = CreateJwtToken("viewer-user", "Viewer", signingKeyV1, issuer, audience);
            client.DefaultRequestHeaders.Authorization =
                new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", tokenV1);
            (await client.GetAsync("/api/security/whoami")).EnsureSuccessStatusCode();

            await File.WriteAllTextAsync(secretFile, signingKeyV2);
            await Task.Delay(1200);

            var tokenV2 = CreateJwtToken("viewer-user", "Viewer", signingKeyV2, issuer, audience);
            client.DefaultRequestHeaders.Authorization =
                new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", tokenV2);
            (await client.GetAsync("/api/security/whoami")).EnsureSuccessStatusCode();

            client.DefaultRequestHeaders.Authorization =
                new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", tokenV1);
            var withinGrace = await client.GetAsync("/api/security/whoami");
            Assert.Equal(HttpStatusCode.OK, withinGrace.StatusCode);

            await Task.Delay(2500);
            var afterGrace = await client.GetAsync("/api/security/whoami");
            Assert.Equal(HttpStatusCode.Unauthorized, afterGrace.StatusCode);
        }
        finally
        {
            TryDeleteDirectory(tempRoot);
        }
    }

    [Fact]
    public async Task Jwt_AzureKeyVault_Should_Fallback_To_Command_When_Unavailable()
    {
        const string issuer = "datahz-tests";
        const string audience = "datahz-api";
        const string signingKey = "datahz-tests-signing-key-2026-very-secure";

        using var factory = new ApiTestFactory(settings =>
        {
            settings["Security:ApiKey:Enabled"] = "false";
            settings["Security:Jwt:Enabled"] = "true";
            settings["Security:Jwt:SigningKey"] = "";
            settings["Security:Jwt:ValidIssuer"] = issuer;
            settings["Security:Jwt:ValidAudience"] = audience;
            settings["Security:Secrets:EnableExternalProvider"] = "true";
            settings["Security:Secrets:ExternalProvider"] = "azurekv";
            settings["Security:Secrets:JwtSigningKeyExternalRef"] = "jwt-signing-key";
            settings["Security:Secrets:AzureKeyVault:VaultUri"] = "not-a-uri";
            settings["Security:Secrets:AllowCommandExecution"] = "true";
            settings["Security:Secrets:JwtSigningKeyCommand"] = $"echo {signingKey}";
        });
        using var client = factory.CreateClient();

        var token = CreateJwtToken("viewer-user", "Viewer", signingKey, issuer, audience);
        client.DefaultRequestHeaders.Authorization =
            new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", token);

        var whoAmIResponse = await client.GetAsync("/api/security/whoami");
        whoAmIResponse.EnsureSuccessStatusCode();
        var whoAmI = await ReadJsonAsync(whoAmIResponse);
        Assert.Equal("jwt", whoAmI.GetProperty("source").GetString());
        Assert.Equal("Viewer", whoAmI.GetProperty("role").GetString());
    }

    [Fact]
    public async Task Hybrid_Mode_Should_Accept_ApiKey_And_Jwt()
    {
        const string issuer = "datahz-tests";
        const string audience = "datahz-api";
        const string signingKey = "datahz-tests-signing-key-2026-very-secure";

        using var factory = new ApiTestFactory(settings =>
        {
            settings["Security:ApiKey:Enabled"] = "true";
            settings["Security:ApiKey:Keys:0:Name"] = "operator";
            settings["Security:ApiKey:Keys:0:Key"] = "operator-key";
            settings["Security:ApiKey:Keys:0:Role"] = "Operator";
            settings["Security:Jwt:Enabled"] = "true";
            settings["Security:Jwt:SigningKey"] = signingKey;
            settings["Security:Jwt:ValidIssuer"] = issuer;
            settings["Security:Jwt:ValidAudience"] = audience;
        });
        using var client = factory.CreateClient();

        client.DefaultRequestHeaders.Add("X-Api-Key", "operator-key");
        var submitByApiKey = await client.PostAsJsonAsync("/api/jobs/submit", CreateSubmitBody());
        Assert.Equal(HttpStatusCode.Accepted, submitByApiKey.StatusCode);

        client.DefaultRequestHeaders.Remove("X-Api-Key");
        var viewerToken = CreateJwtToken("viewer-user", "Viewer", signingKey, issuer, audience);
        client.DefaultRequestHeaders.Authorization =
            new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", viewerToken);

        var statsByJwtViewer = await client.GetAsync("/api/jobs/stats");
        statsByJwtViewer.EnsureSuccessStatusCode();

        var submitByJwtViewer = await client.PostAsJsonAsync("/api/jobs/submit", CreateSubmitBody());
        Assert.Equal(HttpStatusCode.Forbidden, submitByJwtViewer.StatusCode);
    }

    [Fact]
    public async Task Security_Hardening_Should_Require_Admin_And_Return_Report()
    {
        using var factory = new ApiTestFactory(settings =>
        {
            settings["Security:ApiKey:Enabled"] = "true";
            settings["Security:ApiKey:Keys:0:Name"] = "viewer";
            settings["Security:ApiKey:Keys:0:Key"] = "viewer-key";
            settings["Security:ApiKey:Keys:0:Role"] = "Viewer";
            settings["Security:ApiKey:Keys:1:Name"] = "admin";
            settings["Security:ApiKey:Keys:1:Key"] = "admin-key";
            settings["Security:ApiKey:Keys:1:Role"] = "Admin";
        });
        using var client = factory.CreateClient();

        client.DefaultRequestHeaders.Add("X-Api-Key", "viewer-key");
        var forbidden = await client.GetAsync("/api/security/hardening");
        Assert.Equal(HttpStatusCode.Forbidden, forbidden.StatusCode);

        client.DefaultRequestHeaders.Remove("X-Api-Key");
        client.DefaultRequestHeaders.Add("X-Api-Key", "admin-key");
        var ok = await client.GetAsync("/api/security/hardening");
        ok.EnsureSuccessStatusCode();

        var payload = await ReadJsonAsync(ok);
        Assert.Equal("apiKey", payload.GetProperty("mode").GetString());
        Assert.True(payload.GetProperty("passCount").GetInt32() >= 0);
        Assert.True(payload.GetProperty("warnCount").GetInt32() >= 0);
        Assert.Equal(JsonValueKind.Array, payload.GetProperty("checks").ValueKind);
    }

    [Fact]
    public async Task Security_Hardening_Should_Report_AzureKeyVault_Warning_When_Uri_Missing()
    {
        using var factory = new ApiTestFactory(settings =>
        {
            settings["Security:ApiKey:Enabled"] = "true";
            settings["Security:ApiKey:Keys:0:Name"] = "admin";
            settings["Security:ApiKey:Keys:0:Key"] = "admin-key";
            settings["Security:ApiKey:Keys:0:Role"] = "Admin";
            settings["Security:Secrets:EnableExternalProvider"] = "true";
            settings["Security:Secrets:ExternalProvider"] = "azurekv";
            settings["Security:Secrets:ApiKeyExternalRef"] = "api-key";
            settings["Security:Secrets:JwtSigningKeyExternalRef"] = "jwt-key";
            settings["Security:Secrets:AzureKeyVault:VaultUri"] = "";
        });
        using var client = factory.CreateClient();
        client.DefaultRequestHeaders.Add("X-Api-Key", "admin-key");

        var response = await client.GetAsync("/api/security/hardening");
        response.EnsureSuccessStatusCode();
        var payload = await ReadJsonAsync(response);

        var checks = payload.GetProperty("checks");
        Assert.Equal(JsonValueKind.Array, checks.ValueKind);
        Assert.Contains(checks.EnumerateArray(), check =>
            check.GetProperty("id").GetString() == "secret.external.azurekv.uri");
    }

    [Fact]
    public async Task Security_Hardening_Should_Report_AwsSecretsManager_Warning_When_Region_Missing()
    {
        using var factory = new ApiTestFactory(settings =>
        {
            settings["Security:ApiKey:Enabled"] = "true";
            settings["Security:ApiKey:Keys:0:Name"] = "admin";
            settings["Security:ApiKey:Keys:0:Key"] = "admin-key";
            settings["Security:ApiKey:Keys:0:Role"] = "Admin";
            settings["Security:Secrets:EnableExternalProvider"] = "true";
            settings["Security:Secrets:ExternalProvider"] = "awssm";
            settings["Security:Secrets:ApiKeyExternalRef"] = "datahz/api-key";
            settings["Security:Secrets:AwsSecretsManager:Region"] = "";
        });
        using var client = factory.CreateClient();
        client.DefaultRequestHeaders.Add("X-Api-Key", "admin-key");

        var response = await client.GetAsync("/api/security/hardening");
        response.EnsureSuccessStatusCode();
        var payload = await ReadJsonAsync(response);

        var checks = payload.GetProperty("checks");
        Assert.Equal(JsonValueKind.Array, checks.ValueKind);
        Assert.Contains(checks.EnumerateArray(), check =>
            check.GetProperty("id").GetString() == "secret.external.awssm.region");
        Assert.Contains(checks.EnumerateArray(), check =>
            check.GetProperty("id").GetString() == "secret.external.runtime.success" &&
            check.GetProperty("status").GetString() == "warn");
    }

    [Fact]
    public async Task Security_Hardening_Should_Report_GcpSecretManager_Warning_When_Project_Missing()
    {
        using var factory = new ApiTestFactory(settings =>
        {
            settings["Security:ApiKey:Enabled"] = "true";
            settings["Security:ApiKey:Keys:0:Name"] = "admin";
            settings["Security:ApiKey:Keys:0:Key"] = "admin-key";
            settings["Security:ApiKey:Keys:0:Role"] = "Admin";
            settings["Security:Secrets:EnableExternalProvider"] = "true";
            settings["Security:Secrets:ExternalProvider"] = "gcpsm";
            settings["Security:Secrets:ApiKeyExternalRef"] = "datahz/api-key";
            settings["Security:Secrets:GcpSecretManager:ProjectId"] = "";
        });
        using var client = factory.CreateClient();
        client.DefaultRequestHeaders.Add("X-Api-Key", "admin-key");

        var response = await client.GetAsync("/api/security/hardening");
        response.EnsureSuccessStatusCode();
        var payload = await ReadJsonAsync(response);

        var checks = payload.GetProperty("checks");
        Assert.Equal(JsonValueKind.Array, checks.ValueKind);
        Assert.Contains(checks.EnumerateArray(), check =>
            check.GetProperty("id").GetString() == "secret.external.gcpsm.project");
    }

    [Fact]
    public async Task Security_Hardening_Should_Report_AliyunKms_Warning_When_Region_Missing()
    {
        using var factory = new ApiTestFactory(settings =>
        {
            settings["Security:ApiKey:Enabled"] = "true";
            settings["Security:ApiKey:Keys:0:Name"] = "admin";
            settings["Security:ApiKey:Keys:0:Key"] = "admin-key";
            settings["Security:ApiKey:Keys:0:Role"] = "Admin";
            settings["Security:Secrets:EnableExternalProvider"] = "true";
            settings["Security:Secrets:ExternalProvider"] = "aliyunkms";
            settings["Security:Secrets:ApiKeyExternalRef"] = "datahz/api-key";
            settings["Security:Secrets:AliyunKms:RegionId"] = "";
        });
        using var client = factory.CreateClient();
        client.DefaultRequestHeaders.Add("X-Api-Key", "admin-key");

        var response = await client.GetAsync("/api/security/hardening");
        response.EnsureSuccessStatusCode();
        var payload = await ReadJsonAsync(response);

        var checks = payload.GetProperty("checks");
        Assert.Equal(JsonValueKind.Array, checks.ValueKind);
        Assert.Contains(checks.EnumerateArray(), check =>
            check.GetProperty("id").GetString() == "secret.external.aliyunkms.region");
    }

    [Fact]
    public async Task Security_Secrets_Runtime_And_Refresh_Should_Require_Admin()
    {
        using var factory = new ApiTestFactory(settings =>
        {
            settings["Security:ApiKey:Enabled"] = "true";
            settings["Security:ApiKey:Value"] = "primary-observed-key";
            settings["Security:ApiKey:Keys:0:Name"] = "viewer";
            settings["Security:ApiKey:Keys:0:Key"] = "viewer-key";
            settings["Security:ApiKey:Keys:0:Role"] = "Viewer";
            settings["Security:ApiKey:Keys:1:Name"] = "admin";
            settings["Security:ApiKey:Keys:1:Key"] = "admin-key";
            settings["Security:ApiKey:Keys:1:Role"] = "Admin";
        });
        using var client = factory.CreateClient();

        client.DefaultRequestHeaders.Add("X-Api-Key", "viewer-key");
        var viewerRuntime = await client.GetAsync("/api/security/secrets/runtime");
        Assert.Equal(HttpStatusCode.Forbidden, viewerRuntime.StatusCode);
        var viewerRefresh = await client.PostAsync("/api/security/secrets/refresh", null);
        Assert.Equal(HttpStatusCode.Forbidden, viewerRefresh.StatusCode);

        client.DefaultRequestHeaders.Remove("X-Api-Key");
        client.DefaultRequestHeaders.Add("X-Api-Key", "admin-key");

        var runtime = await client.GetAsync("/api/security/secrets/runtime");
        runtime.EnsureSuccessStatusCode();
        var runtimePayload = await ReadJsonAsync(runtime);
        Assert.Equal(JsonValueKind.Object, runtimePayload.GetProperty("settings").ValueKind);
        Assert.Equal(JsonValueKind.Object, runtimePayload.GetProperty("apiKey").ValueKind);
        Assert.Equal(JsonValueKind.Object, runtimePayload.GetProperty("jwt").ValueKind);
        Assert.Equal(JsonValueKind.Array, runtimePayload.GetProperty("cache").ValueKind);
        Assert.Equal(JsonValueKind.Array, runtimePayload.GetProperty("providers").ValueKind);
        Assert.True(runtimePayload.GetProperty("apiKey").GetProperty("candidateCount").GetInt32() >= 1);

        var refresh = await client.PostAsync("/api/security/secrets/refresh", null);
        refresh.EnsureSuccessStatusCode();
        var refreshPayload = await ReadJsonAsync(refresh);
        Assert.True(refreshPayload.TryGetProperty("refreshedAtUtc", out _));
        Assert.True(refreshPayload.GetProperty("apiKey").GetProperty("candidateCount").GetInt32() >= 1);
        Assert.Equal(JsonValueKind.Array, refreshPayload.GetProperty("providers").ValueKind);
    }

    [Fact]
    public async Task Security_Secrets_Refresh_Should_Write_Audit_Action_When_Audit_Enabled()
    {
        var tempRoot = Path.Combine(Path.GetTempPath(), "datahz-tests-audit", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(tempRoot);
        var auditFile = Path.Combine(tempRoot, "audit.log");

        try
        {
            using var factory = new ApiTestFactory(settings =>
            {
                settings["Audit:Enabled"] = "true";
                settings["Audit:FilePath"] = auditFile;
                settings["Security:ApiKey:Enabled"] = "true";
                settings["Security:ApiKey:Keys:0:Name"] = "admin";
                settings["Security:ApiKey:Keys:0:Key"] = "admin-key";
                settings["Security:ApiKey:Keys:0:Role"] = "Admin";
            });
            using var client = factory.CreateClient();
            client.DefaultRequestHeaders.Add("X-Api-Key", "admin-key");

            var refresh = await client.PostAsync("/api/security/secrets/refresh", null);
            refresh.EnsureSuccessStatusCode();

            await Task.Delay(120);
            Assert.True(File.Exists(auditFile));
            var auditRaw = await File.ReadAllTextAsync(auditFile);
            Assert.Contains("security.secrets_refresh", auditRaw);
        }
        finally
        {
            TryDeleteDirectory(tempRoot);
        }
    }

    [Fact]
    public async Task Security_Secrets_Events_Should_Require_Admin_And_Return_Secret_Actions()
    {
        var tempRoot = Path.Combine(Path.GetTempPath(), "datahz-tests-audit", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(tempRoot);
        var auditFile = Path.Combine(tempRoot, "audit.log");

        try
        {
            using var factory = new ApiTestFactory(settings =>
            {
                settings["Audit:Enabled"] = "true";
                settings["Audit:FilePath"] = auditFile;
                settings["Security:ApiKey:Enabled"] = "true";
                settings["Security:ApiKey:Keys:0:Name"] = "viewer";
                settings["Security:ApiKey:Keys:0:Key"] = "viewer-key";
                settings["Security:ApiKey:Keys:0:Role"] = "Viewer";
                settings["Security:ApiKey:Keys:1:Name"] = "admin";
                settings["Security:ApiKey:Keys:1:Key"] = "admin-key";
                settings["Security:ApiKey:Keys:1:Role"] = "Admin";
            });
            using var client = factory.CreateClient();

            client.DefaultRequestHeaders.Add("X-Api-Key", "viewer-key");
            var forbidden = await client.GetAsync("/api/security/secrets/events?take=20");
            Assert.Equal(HttpStatusCode.Forbidden, forbidden.StatusCode);

            client.DefaultRequestHeaders.Remove("X-Api-Key");
            client.DefaultRequestHeaders.Add("X-Api-Key", "admin-key");

            var refresh = await client.PostAsync("/api/security/secrets/refresh", null);
            refresh.EnsureSuccessStatusCode();
            await Task.Delay(180);

            var eventsResponse = await client.GetAsync("/api/security/secrets/events?take=20");
            eventsResponse.EnsureSuccessStatusCode();
            var eventsPayload = await ReadJsonAsync(eventsResponse);

            Assert.Equal(JsonValueKind.Array, eventsPayload.ValueKind);
            Assert.Contains(eventsPayload.EnumerateArray(), x =>
                x.GetProperty("action").GetString() == "security.secrets_refresh");
        }
        finally
        {
            TryDeleteDirectory(tempRoot);
        }
    }

    private static async Task<JsonElement> ReadJsonAsync(HttpResponseMessage response)
    {
        var payload = await response.Content.ReadFromJsonAsync<JsonElement>();
        return payload;
    }

    private static object CreateSubmitBody(string? idempotencyKey = null)
    {
        return new
        {
            plan = new
            {
                templatePath = @"D:\missing\template.ini",
                sourceDirectory = @"D:\missing",
                targetDirectory = @"D:\missing",
                areaCodePath = @"D:\missing\codes.txt",
                startIndex = 0,
                endIndex = 1
            },
            dryRun = true,
            incremental = true,
            idempotencyKey = idempotencyKey ?? string.Empty
        };
    }

    private static string CreateJwtToken(string name, string role, string signingKey, string issuer, string audience)
    {
        var claims = new[]
        {
            new Claim("sub", name),
            new Claim("name", name),
            new Claim("role", role)
        };

        var credentials = new SigningCredentials(
            new SymmetricSecurityKey(Encoding.UTF8.GetBytes(signingKey)),
            SecurityAlgorithms.HmacSha256);

        var token = new JwtSecurityToken(
            issuer: issuer,
            audience: audience,
            claims: claims,
            notBefore: DateTime.UtcNow.AddMinutes(-1),
            expires: DateTime.UtcNow.AddMinutes(30),
            signingCredentials: credentials);

        return new JwtSecurityTokenHandler().WriteToken(token);
    }

    private static void TryDeleteDirectory(string path)
    {
        try
        {
            if (Directory.Exists(path))
            {
                Directory.Delete(path, recursive: true);
            }
        }
        catch
        {
            // Ignore cleanup failures in tests.
        }
    }
}
