using Azure.Core;
using Azure.Identity;
using Azure.Security.KeyVault.Secrets;
using Amazon;
using Amazon.Runtime;
using Amazon.SecretsManager;
using Amazon.SecretsManager.Model;
using Google.Api.Gax;
using Google.Api.Gax.Grpc;
using Google.Cloud.SecretManager.V1;
using System.Diagnostics;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace DataHz.Api.Security;

public static class SecuritySecretResolver
{
    public const string ApiKeyEnvVar = "DATAHZ_APIKEY";
    public const string JwtSigningKeyEnvVar = "DATAHZ_JWT_SIGNING_KEY";
    public const string AzureKeyVaultUriEnvVar = "DATAHZ_AZURE_KEYVAULT_URI";
    public const string AwsRegionEnvVar = "AWS_REGION";
    public const string AwsDefaultRegionEnvVar = "AWS_DEFAULT_REGION";
    public const string GcpProjectEnvVar = "GOOGLE_CLOUD_PROJECT";
    public const string GcpLegacyProjectEnvVar = "GCP_PROJECT";
    public const string GcpCredentialsPathEnvVar = "GOOGLE_APPLICATION_CREDENTIALS";
    public const string AliyunRegionEnvVar = "ALIBABA_CLOUD_REGION_ID";
    public const string AliyunLegacyRegionEnvVar = "ALICLOUD_REGION_ID";
    public const string AliyunAccessKeyIdEnvVar = "ALIBABA_CLOUD_ACCESS_KEY_ID";
    public const string AliyunLegacyAccessKeyIdEnvVar = "ALICLOUD_ACCESS_KEY";
    public const string AliyunAccessKeySecretEnvVar = "ALIBABA_CLOUD_ACCESS_KEY_SECRET";
    public const string AliyunLegacyAccessKeySecretEnvVar = "ALICLOUD_ACCESS_KEY_SECRET";
    public const string AliyunSecurityTokenEnvVar = "ALIBABA_CLOUD_SECURITY_TOKEN";
    public const string AliyunEndpointEnvVar = "ALIBABA_CLOUD_KMS_ENDPOINT";
    private static readonly object AzureClientSync = new();
    private static readonly Dictionary<string, SecretClient> AzureClients = new(StringComparer.OrdinalIgnoreCase);
    private static readonly object AwsClientSync = new();
    private static readonly Dictionary<string, IAmazonSecretsManager> AwsSecretsClients = new(StringComparer.OrdinalIgnoreCase);
    private static readonly object GcpClientSync = new();
    private static readonly Dictionary<string, SecretManagerServiceClient> GcpSecretsClients = new(StringComparer.OrdinalIgnoreCase);
    private static readonly object SecretCacheSync = new();
    private static readonly Dictionary<string, SecretCacheEntry> SecretCache = new(StringComparer.Ordinal);
    private static readonly object ExternalStateSync = new();
    private static readonly Dictionary<string, ExternalProviderStateEntry> ExternalProviderStates = new(StringComparer.Ordinal);
    
    public sealed record SecretRuntimeCacheState(
        string Purpose,
        bool HasCurrentValue,
        bool HasPreviousValue,
        DateTimeOffset? PreviousUntilUtc,
        DateTimeOffset? LastSuccessUtc,
        DateTimeOffset? CacheExpiresUtc);

    public sealed record ExternalProviderRuntimeState(
        string Provider,
        string Purpose,
        string SecretRefHint,
        DateTimeOffset? LastAttemptUtc,
        DateTimeOffset? LastSuccessUtc,
        DateTimeOffset? LastFailureUtc,
        bool LastAttemptHadValue,
        long? LastDurationMs,
        string LastStatus,
        string? LastError);

    public static string ResolveApiKeyValue(
        ApiKeySecurityOptions options,
        SecuritySecretSourceOptions? sourceOptions = null,
        Func<string, string?>? envProvider = null,
        bool forceRefresh = false)
    {
        return ResolveApiKeyCandidates(options, sourceOptions, envProvider, forceRefresh).FirstOrDefault() ?? string.Empty;
    }

    public static string ResolveJwtSigningKey(
        JwtSecurityOptions options,
        SecuritySecretSourceOptions? sourceOptions = null,
        Func<string, string?>? envProvider = null,
        bool forceRefresh = false)
    {
        return ResolveJwtSigningKeyCandidates(options, sourceOptions, envProvider, forceRefresh).FirstOrDefault() ?? string.Empty;
    }

    public static IReadOnlyList<string> ResolveApiKeyCandidates(
        ApiKeySecurityOptions options,
        SecuritySecretSourceOptions? sourceOptions = null,
        Func<string, string?>? envProvider = null,
        bool forceRefresh = false)
    {
        envProvider ??= Environment.GetEnvironmentVariable;
        var cacheKey = BuildSecretCacheKey(
            "apiKey",
            options.Value,
            sourceOptions,
            sourceOptions?.ApiKeyExternalRef,
            sourceOptions?.ApiKeyCommand);
        var current = ResolveWithRuntimeCache(
            cacheKey: cacheKey,
            sourceOptions: sourceOptions,
            resolveRaw: () => ResolveApiKeyRaw(options, sourceOptions, envProvider),
            forceRefresh: forceRefresh);
        var previous = TryGetPreviousFromCache(cacheKey, sourceOptions);
        return BuildCandidates(current, previous);
    }

    public static IReadOnlyList<string> ResolveJwtSigningKeyCandidates(
        JwtSecurityOptions options,
        SecuritySecretSourceOptions? sourceOptions = null,
        Func<string, string?>? envProvider = null,
        bool forceRefresh = false)
    {
        envProvider ??= Environment.GetEnvironmentVariable;
        var cacheKey = BuildSecretCacheKey(
            "jwtSigningKey",
            options.SigningKey,
            sourceOptions,
            sourceOptions?.JwtSigningKeyExternalRef,
            sourceOptions?.JwtSigningKeyCommand);
        var current = ResolveWithRuntimeCache(
            cacheKey: cacheKey,
            sourceOptions: sourceOptions,
            resolveRaw: () => ResolveJwtSigningKeyRaw(options, sourceOptions, envProvider),
            forceRefresh: forceRefresh);
        var previous = TryGetPreviousFromCache(cacheKey, sourceOptions);
        return BuildCandidates(current, previous);
    }

    public static IReadOnlyList<SecretRuntimeCacheState> GetRuntimeCacheState()
    {
        lock (SecretCacheSync)
        {
            return SecretCache
                .Select(x =>
                {
                    var entry = x.Value;
                    return new SecretRuntimeCacheState(
                        Purpose: ExtractPurposeFromCacheKey(x.Key),
                        HasCurrentValue: !string.IsNullOrWhiteSpace(entry.CurrentValue),
                        HasPreviousValue: !string.IsNullOrWhiteSpace(entry.PreviousValue) && entry.PreviousUntilUtc >= DateTimeOffset.UtcNow,
                        PreviousUntilUtc: entry.PreviousUntilUtc == DateTimeOffset.MinValue ? null : entry.PreviousUntilUtc,
                        LastSuccessUtc: entry.LastSuccessUtc == DateTimeOffset.MinValue ? null : entry.LastSuccessUtc,
                        CacheExpiresUtc: entry.CacheExpiresUtc == DateTimeOffset.MinValue ? null : entry.CacheExpiresUtc);
                })
                .OrderBy(x => x.Purpose, StringComparer.Ordinal)
                .ToArray();
        }
    }

    public static IReadOnlyList<ExternalProviderRuntimeState> GetExternalProviderRuntimeState()
    {
        lock (ExternalStateSync)
        {
            return ExternalProviderStates
                .Values
                .Select(x => new ExternalProviderRuntimeState(
                    Provider: x.Provider,
                    Purpose: x.Purpose,
                    SecretRefHint: x.SecretRefHint,
                    LastAttemptUtc: x.LastAttemptUtc == DateTimeOffset.MinValue ? null : x.LastAttemptUtc,
                    LastSuccessUtc: x.LastSuccessUtc == DateTimeOffset.MinValue ? null : x.LastSuccessUtc,
                    LastFailureUtc: x.LastFailureUtc == DateTimeOffset.MinValue ? null : x.LastFailureUtc,
                    LastAttemptHadValue: x.LastAttemptHadValue,
                    LastDurationMs: x.LastDurationMs <= 0 ? null : x.LastDurationMs,
                    LastStatus: x.LastStatus,
                    LastError: string.IsNullOrWhiteSpace(x.LastError) ? null : x.LastError))
                .OrderByDescending(x => x.LastAttemptUtc)
                .ThenBy(x => x.Provider, StringComparer.Ordinal)
                .ThenBy(x => x.Purpose, StringComparer.Ordinal)
                .ToArray();
        }
    }

    public static int ResetExternalProviderRuntimeState()
    {
        return ResetExternalProviderRuntimeState(
            providerFilter: null,
            purposeFilter: null,
            statusFilter: null,
            fromUtc: null,
            toUtc: null);
    }

    public static int ResetExternalProviderRuntimeState(
        string? providerFilter,
        string? purposeFilter,
        string? statusFilter,
        DateTimeOffset? fromUtc,
        DateTimeOffset? toUtc)
    {
        var normalizedProvider = NormalizeProviderFilter(providerFilter);
        var normalizedPurpose = NormalizeFilter(purposeFilter);
        var normalizedStatus = NormalizeFilter(statusFilter);

        lock (ExternalStateSync)
        {
            if (normalizedProvider is null &&
                normalizedPurpose is null &&
                normalizedStatus is null &&
                fromUtc is null &&
                toUtc is null)
            {
                var count = ExternalProviderStates.Count;
                ExternalProviderStates.Clear();
                return count;
            }

            var keys = ExternalProviderStates
                .Where(x => MatchesExternalProviderState(
                    x.Value,
                    normalizedProvider,
                    normalizedPurpose,
                    normalizedStatus,
                    fromUtc,
                    toUtc))
                .Select(x => x.Key)
                .ToList();

            foreach (var key in keys)
            {
                ExternalProviderStates.Remove(key);
            }

            return keys.Count;
        }
    }

    private static string ResolveApiKeyRaw(
        ApiKeySecurityOptions options,
        SecuritySecretSourceOptions? sourceOptions,
        Func<string, string?> envProvider)
    {
        var env = envProvider(ApiKeyEnvVar);
        if (!string.IsNullOrWhiteSpace(env))
        {
            return env.Trim();
        }

        var externalValue = TryResolveFromExternal("apiKey", sourceOptions, sourceOptions?.ApiKeyExternalRef, envProvider);
        if (!string.IsNullOrWhiteSpace(externalValue))
        {
            return externalValue;
        }

        var commandValue = TryResolveFromCommand(sourceOptions, sourceOptions?.ApiKeyCommand);
        if (!string.IsNullOrWhiteSpace(commandValue))
        {
            return commandValue;
        }

        return options.Value;
    }

    private static string ResolveJwtSigningKeyRaw(
        JwtSecurityOptions options,
        SecuritySecretSourceOptions? sourceOptions,
        Func<string, string?> envProvider)
    {
        var env = envProvider(JwtSigningKeyEnvVar);
        if (!string.IsNullOrWhiteSpace(env))
        {
            return env.Trim();
        }

        var externalValue = TryResolveFromExternal("jwtSigningKey", sourceOptions, sourceOptions?.JwtSigningKeyExternalRef, envProvider);
        if (!string.IsNullOrWhiteSpace(externalValue))
        {
            return externalValue;
        }

        var commandValue = TryResolveFromCommand(sourceOptions, sourceOptions?.JwtSigningKeyCommand);
        if (!string.IsNullOrWhiteSpace(commandValue))
        {
            return commandValue;
        }

        return options.SigningKey;
    }

    public static string DescribeApiKeySource(
        ApiKeySecurityOptions options,
        SecuritySecretSourceOptions? sourceOptions = null,
        Func<string, string?>? envProvider = null)
    {
        envProvider ??= Environment.GetEnvironmentVariable;
        if (!string.IsNullOrWhiteSpace(envProvider(ApiKeyEnvVar)))
        {
            return $"env:{ApiKeyEnvVar}";
        }

        if (!string.IsNullOrWhiteSpace(TryResolveFromExternal("apiKey", sourceOptions, sourceOptions?.ApiKeyExternalRef, envProvider)))
        {
            return $"external:{NormalizeProvider(sourceOptions?.ExternalProvider)}";
        }

        if (!string.IsNullOrWhiteSpace(TryResolveFromCommand(sourceOptions, sourceOptions?.ApiKeyCommand)))
        {
            return "command";
        }

        return string.IsNullOrWhiteSpace(options.Value) ? "none" : "config";
    }

    public static string DescribeJwtSigningKeySource(
        JwtSecurityOptions options,
        SecuritySecretSourceOptions? sourceOptions = null,
        Func<string, string?>? envProvider = null)
    {
        envProvider ??= Environment.GetEnvironmentVariable;
        if (!string.IsNullOrWhiteSpace(envProvider(JwtSigningKeyEnvVar)))
        {
            return $"env:{JwtSigningKeyEnvVar}";
        }

        if (!string.IsNullOrWhiteSpace(TryResolveFromExternal("jwtSigningKey", sourceOptions, sourceOptions?.JwtSigningKeyExternalRef, envProvider)))
        {
            return $"external:{NormalizeProvider(sourceOptions?.ExternalProvider)}";
        }

        if (!string.IsNullOrWhiteSpace(TryResolveFromCommand(sourceOptions, sourceOptions?.JwtSigningKeyCommand)))
        {
            return "command";
        }

        return string.IsNullOrWhiteSpace(options.SigningKey) ? "none" : "config";
    }

    private static string TryResolveFromExternal(
        string purpose,
        SecuritySecretSourceOptions? sourceOptions,
        string? secretRef,
        Func<string, string?> envProvider)
    {
        if (sourceOptions is null ||
            !sourceOptions.EnableExternalProvider ||
            string.IsNullOrWhiteSpace(secretRef))
        {
            return string.Empty;
        }

        var normalizedProvider = NormalizeProvider(sourceOptions.ExternalProvider);
        return normalizedProvider switch
        {
            "file" => ResolveExternalWithTelemetry(normalizedProvider, purpose, secretRef, () => TryResolveFromFile(sourceOptions.File, secretRef)),
            "vault" => ResolveExternalWithTelemetry(normalizedProvider, purpose, secretRef, () => TryResolveFromVault(sourceOptions, secretRef, envProvider)),
            "azurekv" => ResolveExternalWithTelemetry(normalizedProvider, purpose, secretRef, () => TryResolveFromAzureKeyVault(sourceOptions, secretRef, envProvider)),
            "awssm" => ResolveExternalWithTelemetry(normalizedProvider, purpose, secretRef, () => TryResolveFromAwsSecretsManager(sourceOptions, secretRef, envProvider)),
            "gcpsm" => ResolveExternalWithTelemetry(normalizedProvider, purpose, secretRef, () => TryResolveFromGcpSecretManager(sourceOptions, secretRef, envProvider)),
            "aliyunkms" => ResolveExternalWithTelemetry(normalizedProvider, purpose, secretRef, () => TryResolveFromAliyunKms(sourceOptions, secretRef, envProvider)),
            _ => string.Empty
        };
    }

    private static string ResolveExternalWithTelemetry(
        string provider,
        string purpose,
        string secretRef,
        Func<string> resolver)
    {
        var started = DateTimeOffset.UtcNow;
        var sw = Stopwatch.StartNew();
        try
        {
            var value = resolver()?.Trim() ?? string.Empty;
            sw.Stop();

            UpdateExternalProviderState(
                provider: provider,
                purpose: purpose,
                secretRef: secretRef,
                status: string.IsNullOrWhiteSpace(value) ? "empty" : "success",
                hadValue: !string.IsNullOrWhiteSpace(value),
                error: string.Empty,
                attemptedAt: started,
                durationMs: sw.ElapsedMilliseconds);
            return value;
        }
        catch (Exception ex)
        {
            sw.Stop();
            UpdateExternalProviderState(
                provider: provider,
                purpose: purpose,
                secretRef: secretRef,
                status: "error",
                hadValue: false,
                error: $"{ex.GetType().Name}: {CompactError(ex.Message)}",
                attemptedAt: started,
                durationMs: sw.ElapsedMilliseconds);
            return string.Empty;
        }
    }

    private static void UpdateExternalProviderState(
        string provider,
        string purpose,
        string secretRef,
        string status,
        bool hadValue,
        string error,
        DateTimeOffset attemptedAt,
        long durationMs)
    {
        var key = BuildExternalStateKey(provider, purpose, secretRef);
        lock (ExternalStateSync)
        {
            if (!ExternalProviderStates.TryGetValue(key, out var entry))
            {
                entry = new ExternalProviderStateEntry
                {
                    Provider = provider,
                    Purpose = purpose,
                    SecretRefHint = BuildSecretRefHint(secretRef)
                };
            }

            entry.LastAttemptUtc = attemptedAt;
            entry.LastDurationMs = Math.Max(0, durationMs);
            entry.LastAttemptHadValue = hadValue;
            entry.LastStatus = string.IsNullOrWhiteSpace(status) ? "unknown" : status;
            entry.LastError = string.IsNullOrWhiteSpace(error) ? string.Empty : error.Trim();

            if (hadValue)
            {
                entry.LastSuccessUtc = attemptedAt;
            }
            else
            {
                entry.LastFailureUtc = attemptedAt;
            }

            ExternalProviderStates[key] = entry;
        }
    }

    private static string TryResolveFromCommand(SecuritySecretSourceOptions? sourceOptions, string? command)
    {
        if (sourceOptions is null ||
            !sourceOptions.AllowCommandExecution ||
            string.IsNullOrWhiteSpace(command))
        {
            return string.Empty;
        }

        var timeoutSeconds = Math.Clamp(sourceOptions.CommandTimeoutSeconds, 1, 60);
        try
        {
            var info = BuildShellCommand(command.Trim());
            info.RedirectStandardOutput = true;
            info.RedirectStandardError = true;
            info.UseShellExecute = false;
            info.CreateNoWindow = true;

            using var process = Process.Start(info);
            if (process is null)
            {
                return string.Empty;
            }

            if (!process.WaitForExit(timeoutSeconds * 1000))
            {
                try { process.Kill(entireProcessTree: true); } catch { }
                return string.Empty;
            }

            if (process.ExitCode != 0)
            {
                return string.Empty;
            }

            var output = process.StandardOutput.ReadToEnd();
            return output.Trim();
        }
        catch
        {
            return string.Empty;
        }
    }

    private static string TryResolveFromFile(FileSecretProviderOptions options, string secretRef)
    {
        try
        {
            var candidate = secretRef.Trim();
            if (!Path.IsPathRooted(candidate) && !string.IsNullOrWhiteSpace(options.RootDirectory))
            {
                candidate = Path.Combine(options.RootDirectory, candidate);
            }

            if (!File.Exists(candidate))
            {
                return string.Empty;
            }

            var content = File.ReadAllText(candidate);
            return content.Trim();
        }
        catch
        {
            return string.Empty;
        }
    }

    private static string TryResolveFromVault(
        SecuritySecretSourceOptions sourceOptions,
        string secretRef,
        Func<string, string?> envProvider)
    {
        var vault = sourceOptions.Vault;
        if (string.IsNullOrWhiteSpace(vault.Address))
        {
            return string.Empty;
        }

        var (path, field) = ParseVaultReference(secretRef);
        if (string.IsNullOrWhiteSpace(path))
        {
            return string.Empty;
        }

        var token = ResolveVaultToken(vault, envProvider);
        if (string.IsNullOrWhiteSpace(token))
        {
            return string.Empty;
        }

        var mount = string.IsNullOrWhiteSpace(vault.Mount) ? "secret" : vault.Mount.Trim().Trim('/');
        var kvVersion = vault.KvVersion <= 1 ? 1 : 2;
        var endpoint = kvVersion == 1
            ? $"{vault.Address.TrimEnd('/')}/v1/{mount}/{path.TrimStart('/')}"
            : $"{vault.Address.TrimEnd('/')}/v1/{mount}/data/{path.TrimStart('/')}";
        var tokenHeaderName = string.IsNullOrWhiteSpace(vault.TokenHeaderName) ? "X-Vault-Token" : vault.TokenHeaderName;
        var timeoutSeconds = Math.Clamp(sourceOptions.ExternalTimeoutSeconds, 1, 60);

        try
        {
            using var client = new HttpClient
            {
                Timeout = TimeSpan.FromSeconds(timeoutSeconds)
            };
            using var request = new HttpRequestMessage(HttpMethod.Get, endpoint);
            request.Headers.TryAddWithoutValidation(tokenHeaderName, token);

            if (!string.IsNullOrWhiteSpace(vault.Namespace))
            {
                request.Headers.TryAddWithoutValidation("X-Vault-Namespace", vault.Namespace.Trim());
            }

            using var response = client.Send(request);
            if (!response.IsSuccessStatusCode)
            {
                return string.Empty;
            }

            var payload = response.Content.ReadAsStringAsync().GetAwaiter().GetResult();
            return ExtractVaultSecret(payload, field, kvVersion);
        }
        catch
        {
            return string.Empty;
        }
    }

    private static string TryResolveFromAzureKeyVault(
        SecuritySecretSourceOptions sourceOptions,
        string secretRef,
        Func<string, string?> envProvider)
    {
        var options = sourceOptions.AzureKeyVault;
        var vaultUri = string.IsNullOrWhiteSpace(options.VaultUri)
            ? envProvider(AzureKeyVaultUriEnvVar)
            : options.VaultUri;

        if (string.IsNullOrWhiteSpace(vaultUri) ||
            !Uri.TryCreate(vaultUri.Trim(), UriKind.Absolute, out var endpoint))
        {
            return string.Empty;
        }

        var (name, version) = ParseAzureKeyVaultReference(secretRef);
        if (string.IsNullOrWhiteSpace(name))
        {
            return string.Empty;
        }

        try
        {
            var credential = BuildAzureCredential(options, envProvider);
            var timeoutSeconds = Math.Clamp(sourceOptions.ExternalTimeoutSeconds, 1, 60);
            var client = GetOrCreateAzureClient(endpoint, options, credential, timeoutSeconds);

            var secret = string.IsNullOrWhiteSpace(version)
                ? client.GetSecret(name).Value
                : client.GetSecret(name, version).Value;

            return secret.Value?.Trim() ?? string.Empty;
        }
        catch
        {
            return string.Empty;
        }
    }

    private static string TryResolveFromAwsSecretsManager(
        SecuritySecretSourceOptions sourceOptions,
        string secretRef,
        Func<string, string?> envProvider)
    {
        var options = sourceOptions.AwsSecretsManager;
        var region = ResolveAwsRegion(options, envProvider);
        if (string.IsNullOrWhiteSpace(region))
        {
            return string.Empty;
        }

        var (secretId, field) = ParseAwsSecretReference(secretRef);
        if (string.IsNullOrWhiteSpace(secretId))
        {
            return string.Empty;
        }

        var timeoutSeconds = Math.Clamp(sourceOptions.ExternalTimeoutSeconds, 1, 60);

        try
        {
            var client = GetOrCreateAwsSecretsClient(region, options, timeoutSeconds);
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(timeoutSeconds));
            var response = client.GetSecretValueAsync(new GetSecretValueRequest
            {
                SecretId = secretId
            }, cts.Token).GetAwaiter().GetResult();

            var payload = !string.IsNullOrWhiteSpace(response.SecretString)
                ? response.SecretString
                : response.SecretBinary is not null
                    ? Encoding.UTF8.GetString(response.SecretBinary.ToArray())
                    : string.Empty;
            if (string.IsNullOrWhiteSpace(payload))
            {
                return string.Empty;
            }

            return ExtractAwsSecret(payload, field);
        }
        catch
        {
            return string.Empty;
        }
    }

    private static string TryResolveFromGcpSecretManager(
        SecuritySecretSourceOptions sourceOptions,
        string secretRef,
        Func<string, string?> envProvider)
    {
        var options = sourceOptions.GcpSecretManager;
        var projectId = ResolveGcpProjectId(options, envProvider);
        var (resourceName, field) = ParseGcpSecretReference(secretRef, projectId);
        if (string.IsNullOrWhiteSpace(resourceName))
        {
            return string.Empty;
        }

        var timeoutSeconds = Math.Clamp(sourceOptions.ExternalTimeoutSeconds, 1, 60);

        try
        {
            var client = GetOrCreateGcpSecretsClient(options, envProvider);
            var callSettings = CallSettings.FromExpiration(Expiration.FromTimeout(TimeSpan.FromSeconds(timeoutSeconds)));
            var response = client.AccessSecretVersion(new AccessSecretVersionRequest
            {
                Name = resourceName
            }, callSettings);

            var payload = response.Payload?.Data?.ToStringUtf8()?.Trim() ?? string.Empty;
            if (string.IsNullOrWhiteSpace(payload))
            {
                return string.Empty;
            }

            return ExtractGcpSecret(payload, field);
        }
        catch
        {
            return string.Empty;
        }
    }

    private static string TryResolveFromAliyunKms(
        SecuritySecretSourceOptions sourceOptions,
        string secretRef,
        Func<string, string?> envProvider)
    {
        var options = sourceOptions.AliyunKms;
        var regionId = ResolveAliyunRegionId(options, envProvider);
        var endpoint = ResolveAliyunEndpoint(options, envProvider, regionId);
        var accessKeyId = ResolveAliyunAccessKeyId(options, envProvider);
        var accessKeySecret = ResolveAliyunAccessKeySecret(options, envProvider);
        var securityToken = ResolveAliyunSecurityToken(options, envProvider);
        var (secretName, field) = ParseAliyunKmsReference(secretRef);

        if (string.IsNullOrWhiteSpace(regionId) ||
            string.IsNullOrWhiteSpace(endpoint) ||
            string.IsNullOrWhiteSpace(accessKeyId) ||
            string.IsNullOrWhiteSpace(accessKeySecret) ||
            string.IsNullOrWhiteSpace(secretName))
        {
            return string.Empty;
        }

        var timeoutSeconds = Math.Clamp(sourceOptions.ExternalTimeoutSeconds, 1, 60);
        var now = DateTimeOffset.UtcNow;
        var parameters = new SortedDictionary<string, string>(StringComparer.Ordinal)
        {
            ["Action"] = "GetSecretValue",
            ["Format"] = "JSON",
            ["Version"] = "2016-01-20",
            ["AccessKeyId"] = accessKeyId,
            ["SignatureMethod"] = "HMAC-SHA1",
            ["Timestamp"] = now.ToString("yyyy-MM-ddTHH:mm:ssZ"),
            ["SignatureVersion"] = "1.0",
            ["SignatureNonce"] = Guid.NewGuid().ToString("N"),
            ["RegionId"] = regionId,
            ["SecretName"] = secretName
        };

        var versionId = NormalizeFilter(options.VersionId);
        var versionStage = NormalizeFilter(options.VersionStage);
        if (!string.IsNullOrWhiteSpace(versionId))
        {
            parameters["VersionId"] = versionId;
        }
        else
        {
            parameters["VersionStage"] = string.IsNullOrWhiteSpace(versionStage) ? "ACSCurrent" : versionStage;
        }

        if (!string.IsNullOrWhiteSpace(securityToken))
        {
            parameters["SecurityToken"] = securityToken;
        }

        var signature = BuildAliyunRpcSignature(parameters, accessKeySecret);
        parameters["Signature"] = signature;
        var query = BuildAliyunQuery(parameters);
        var requestUri = $"https://{endpoint.TrimEnd('/')}/?{query}";

        try
        {
            using var client = new HttpClient
            {
                Timeout = TimeSpan.FromSeconds(timeoutSeconds)
            };
            using var response = client.GetAsync(requestUri).GetAwaiter().GetResult();
            if (!response.IsSuccessStatusCode)
            {
                return string.Empty;
            }

            var payload = response.Content.ReadAsStringAsync().GetAwaiter().GetResult();
            return ExtractAliyunKmsSecret(payload, field);
        }
        catch
        {
            return string.Empty;
        }
    }

    private static SecretClient GetOrCreateAzureClient(
        Uri endpoint,
        AzureKeyVaultSecretProviderOptions options,
        TokenCredential credential,
        int timeoutSeconds)
    {
        var key = string.Join("|",
            endpoint.AbsoluteUri.ToLowerInvariant(),
            options.TenantId.Trim(),
            options.ClientId.Trim(),
            options.ManagedIdentityClientId.Trim());

        lock (AzureClientSync)
        {
            if (AzureClients.TryGetValue(key, out var existing))
            {
                return existing;
            }

            var clientOptions = new SecretClientOptions();
            clientOptions.Retry.MaxRetries = 2;
            clientOptions.Retry.NetworkTimeout = TimeSpan.FromSeconds(timeoutSeconds);

            var created = new SecretClient(endpoint, credential, clientOptions);
            AzureClients[key] = created;
            return created;
        }
    }

    private static IAmazonSecretsManager GetOrCreateAwsSecretsClient(
        string region,
        AwsSecretsManagerProviderOptions options,
        int timeoutSeconds)
    {
        var credentialsKey = string.Join("|",
            options.AccessKeyId.Trim(),
            options.SecretAccessKey.Trim(),
            options.SessionToken.Trim());
        var key = $"{region.Trim().ToLowerInvariant()}|{HashForCachePart(credentialsKey)}";

        lock (AwsClientSync)
        {
            if (AwsSecretsClients.TryGetValue(key, out var existing))
            {
                return existing;
            }

            var config = new AmazonSecretsManagerConfig
            {
                RegionEndpoint = RegionEndpoint.GetBySystemName(region.Trim()),
                Timeout = TimeSpan.FromSeconds(timeoutSeconds),
                MaxErrorRetry = 2
            };

            var created = BuildAwsCredentials(options) is { } credentials
                ? new AmazonSecretsManagerClient(credentials, config)
                : new AmazonSecretsManagerClient(config);

            AwsSecretsClients[key] = created;
            return created;
        }
    }

    private static SecretManagerServiceClient GetOrCreateGcpSecretsClient(
        GcpSecretManagerProviderOptions options,
        Func<string, string?> envProvider)
    {
        var credentialsPath = ResolveGcpCredentialsPath(options, envProvider);
        var key = HashForCachePart(credentialsPath);

        lock (GcpClientSync)
        {
            if (GcpSecretsClients.TryGetValue(key, out var existing))
            {
                return existing;
            }

            SecretManagerServiceClient created;
            if (string.IsNullOrWhiteSpace(credentialsPath))
            {
                created = SecretManagerServiceClient.Create();
            }
            else
            {
#pragma warning disable CS0618
                var builder = new SecretManagerServiceClientBuilder
                {
                    CredentialsPath = credentialsPath
                };
#pragma warning restore CS0618
                created = builder.Build();
            }

            GcpSecretsClients[key] = created;
            return created;
        }
    }

    private static TokenCredential BuildAzureCredential(
        AzureKeyVaultSecretProviderOptions options,
        Func<string, string?> envProvider)
    {
        if (!string.IsNullOrWhiteSpace(options.TenantId) &&
            !string.IsNullOrWhiteSpace(options.ClientId) &&
            !string.IsNullOrWhiteSpace(options.ClientSecret))
        {
            return new ClientSecretCredential(
                options.TenantId.Trim(),
                options.ClientId.Trim(),
                options.ClientSecret.Trim());
        }

        var managedIdentityClientId = !string.IsNullOrWhiteSpace(options.ManagedIdentityClientId)
            ? options.ManagedIdentityClientId.Trim()
            : envProvider("AZURE_CLIENT_ID");

        if (!string.IsNullOrWhiteSpace(managedIdentityClientId))
        {
            return new ManagedIdentityCredential(managedIdentityClientId);
        }

        return new DefaultAzureCredential(new DefaultAzureCredentialOptions
        {
            ExcludeInteractiveBrowserCredential = true
        });
    }

    private static AWSCredentials? BuildAwsCredentials(AwsSecretsManagerProviderOptions options)
    {
        var accessKeyId = options.AccessKeyId.Trim();
        var secretAccessKey = options.SecretAccessKey.Trim();
        var sessionToken = options.SessionToken.Trim();

        if (string.IsNullOrWhiteSpace(accessKeyId) || string.IsNullOrWhiteSpace(secretAccessKey))
        {
            return null;
        }

        return string.IsNullOrWhiteSpace(sessionToken)
            ? new BasicAWSCredentials(accessKeyId, secretAccessKey)
            : new SessionAWSCredentials(accessKeyId, secretAccessKey, sessionToken);
    }

    private static (string Name, string Version) ParseAzureKeyVaultReference(string secretRef)
    {
        var raw = (secretRef ?? string.Empty).Trim();
        if (string.IsNullOrWhiteSpace(raw))
        {
            return (string.Empty, string.Empty);
        }

        if (Uri.TryCreate(raw, UriKind.Absolute, out var absolute))
        {
            var segments = absolute.AbsolutePath.Split('/', StringSplitOptions.RemoveEmptyEntries);
            if (segments.Length >= 2 && segments[0].Equals("secrets", StringComparison.OrdinalIgnoreCase))
            {
                var name = segments[1];
                var version = segments.Length >= 3 ? segments[2] : string.Empty;
                return (name, version);
            }
        }

        var slash = raw.IndexOf('/');
        if (slash <= 0 || slash == raw.Length - 1)
        {
            return (raw, string.Empty);
        }

        return (raw[..slash], raw[(slash + 1)..]);
    }

    private static (string SecretId, string Field) ParseAwsSecretReference(string secretRef)
    {
        var raw = (secretRef ?? string.Empty).Trim();
        if (string.IsNullOrWhiteSpace(raw))
        {
            return (string.Empty, string.Empty);
        }

        var index = raw.LastIndexOf('#');
        if (index <= 0 || index == raw.Length - 1)
        {
            return (raw, string.Empty);
        }

        return (raw[..index], raw[(index + 1)..]);
    }

    private static string ExtractAwsSecret(string payload, string field)
    {
        if (string.IsNullOrWhiteSpace(payload))
        {
            return string.Empty;
        }

        var normalizedField = field?.Trim() ?? string.Empty;
        if (string.IsNullOrWhiteSpace(normalizedField))
        {
            return payload.Trim();
        }

        try
        {
            using var doc = JsonDocument.Parse(payload);
            if (doc.RootElement.ValueKind != JsonValueKind.Object ||
                !doc.RootElement.TryGetProperty(normalizedField, out var value))
            {
                return string.Empty;
            }

            return value.ValueKind switch
            {
                JsonValueKind.String => value.GetString()?.Trim() ?? string.Empty,
                JsonValueKind.Null => string.Empty,
                _ => value.GetRawText().Trim()
            };
        }
        catch
        {
            return string.Empty;
        }
    }

    private static string ResolveAwsRegion(AwsSecretsManagerProviderOptions options, Func<string, string?> envProvider)
    {
        if (!string.IsNullOrWhiteSpace(options.Region))
        {
            return options.Region.Trim();
        }

        var region = envProvider(AwsRegionEnvVar);
        if (!string.IsNullOrWhiteSpace(region))
        {
            return region.Trim();
        }

        var defaultRegion = envProvider(AwsDefaultRegionEnvVar);
        return string.IsNullOrWhiteSpace(defaultRegion) ? string.Empty : defaultRegion.Trim();
    }

    private static string ResolveGcpProjectId(GcpSecretManagerProviderOptions options, Func<string, string?> envProvider)
    {
        if (!string.IsNullOrWhiteSpace(options.ProjectId))
        {
            return options.ProjectId.Trim();
        }

        var project = envProvider(GcpProjectEnvVar);
        if (!string.IsNullOrWhiteSpace(project))
        {
            return project.Trim();
        }

        var legacyProject = envProvider(GcpLegacyProjectEnvVar);
        return string.IsNullOrWhiteSpace(legacyProject) ? string.Empty : legacyProject.Trim();
    }

    private static string ResolveGcpCredentialsPath(GcpSecretManagerProviderOptions options, Func<string, string?> envProvider)
    {
        if (!string.IsNullOrWhiteSpace(options.CredentialsPath))
        {
            return options.CredentialsPath.Trim();
        }

        var fromEnv = envProvider(GcpCredentialsPathEnvVar);
        return string.IsNullOrWhiteSpace(fromEnv) ? string.Empty : fromEnv.Trim();
    }

    private static string ResolveAliyunRegionId(AliyunKmsProviderOptions options, Func<string, string?> envProvider)
    {
        if (!string.IsNullOrWhiteSpace(options.RegionId))
        {
            return options.RegionId.Trim();
        }

        var region = envProvider(AliyunRegionEnvVar);
        if (!string.IsNullOrWhiteSpace(region))
        {
            return region.Trim();
        }

        var legacyRegion = envProvider(AliyunLegacyRegionEnvVar);
        return string.IsNullOrWhiteSpace(legacyRegion) ? string.Empty : legacyRegion.Trim();
    }

    private static string ResolveAliyunAccessKeyId(AliyunKmsProviderOptions options, Func<string, string?> envProvider)
    {
        if (!string.IsNullOrWhiteSpace(options.AccessKeyId))
        {
            return options.AccessKeyId.Trim();
        }

        var accessKeyId = envProvider(AliyunAccessKeyIdEnvVar);
        if (!string.IsNullOrWhiteSpace(accessKeyId))
        {
            return accessKeyId.Trim();
        }

        var legacyAccessKeyId = envProvider(AliyunLegacyAccessKeyIdEnvVar);
        return string.IsNullOrWhiteSpace(legacyAccessKeyId) ? string.Empty : legacyAccessKeyId.Trim();
    }

    private static string ResolveAliyunAccessKeySecret(AliyunKmsProviderOptions options, Func<string, string?> envProvider)
    {
        if (!string.IsNullOrWhiteSpace(options.AccessKeySecret))
        {
            return options.AccessKeySecret.Trim();
        }

        var accessKeySecret = envProvider(AliyunAccessKeySecretEnvVar);
        if (!string.IsNullOrWhiteSpace(accessKeySecret))
        {
            return accessKeySecret.Trim();
        }

        var legacyAccessKeySecret = envProvider(AliyunLegacyAccessKeySecretEnvVar);
        return string.IsNullOrWhiteSpace(legacyAccessKeySecret) ? string.Empty : legacyAccessKeySecret.Trim();
    }

    private static string ResolveAliyunSecurityToken(AliyunKmsProviderOptions options, Func<string, string?> envProvider)
    {
        if (!string.IsNullOrWhiteSpace(options.SecurityToken))
        {
            return options.SecurityToken.Trim();
        }

        var securityToken = envProvider(AliyunSecurityTokenEnvVar);
        return string.IsNullOrWhiteSpace(securityToken) ? string.Empty : securityToken.Trim();
    }

    private static string ResolveAliyunEndpoint(
        AliyunKmsProviderOptions options,
        Func<string, string?> envProvider,
        string regionId)
    {
        var endpoint = NormalizeAliyunEndpoint(options.Endpoint);
        if (!string.IsNullOrWhiteSpace(endpoint))
        {
            return endpoint;
        }

        var endpointFromEnv = NormalizeAliyunEndpoint(envProvider(AliyunEndpointEnvVar));
        if (!string.IsNullOrWhiteSpace(endpointFromEnv))
        {
            return endpointFromEnv;
        }

        return string.IsNullOrWhiteSpace(regionId)
            ? string.Empty
            : $"kms.{regionId.Trim().ToLowerInvariant()}.aliyuncs.com";
    }

    private static (string ResourceName, string Field) ParseGcpSecretReference(string secretRef, string projectId)
    {
        var raw = (secretRef ?? string.Empty).Trim();
        if (string.IsNullOrWhiteSpace(raw))
        {
            return (string.Empty, string.Empty);
        }

        var index = raw.LastIndexOf('#');
        var reference = index > 0 ? raw[..index].Trim() : raw;
        var field = index > 0 && index < raw.Length - 1
            ? raw[(index + 1)..].Trim()
            : string.Empty;

        if (string.IsNullOrWhiteSpace(reference))
        {
            return (string.Empty, string.Empty);
        }

        if (reference.StartsWith("projects/", StringComparison.OrdinalIgnoreCase))
        {
            var normalized = reference.Trim('/');
            if (!normalized.Contains("/versions/", StringComparison.OrdinalIgnoreCase))
            {
                normalized += "/versions/latest";
            }

            return (normalized, field);
        }

        if (string.IsNullOrWhiteSpace(projectId))
        {
            return (string.Empty, string.Empty);
        }

        var slash = reference.IndexOf('/');
        if (slash > 0 && slash < reference.Length - 1)
        {
            var secret = reference[..slash].Trim();
            var version = reference[(slash + 1)..].Trim();
            if (string.IsNullOrWhiteSpace(secret) || string.IsNullOrWhiteSpace(version))
            {
                return (string.Empty, string.Empty);
            }

            return ($"projects/{projectId}/secrets/{secret}/versions/{version}", field);
        }

        return ($"projects/{projectId}/secrets/{reference}/versions/latest", field);
    }

    private static (string SecretName, string Field) ParseAliyunKmsReference(string secretRef)
    {
        var raw = (secretRef ?? string.Empty).Trim();
        if (string.IsNullOrWhiteSpace(raw))
        {
            return (string.Empty, string.Empty);
        }

        var index = raw.LastIndexOf('#');
        if (index <= 0 || index == raw.Length - 1)
        {
            return (raw, string.Empty);
        }

        return (raw[..index], raw[(index + 1)..]);
    }

    private static string ExtractGcpSecret(string payload, string field)
    {
        if (string.IsNullOrWhiteSpace(payload))
        {
            return string.Empty;
        }

        var normalizedField = field?.Trim() ?? string.Empty;
        if (string.IsNullOrWhiteSpace(normalizedField))
        {
            return payload.Trim();
        }

        try
        {
            using var doc = JsonDocument.Parse(payload);
            if (doc.RootElement.ValueKind != JsonValueKind.Object ||
                !doc.RootElement.TryGetProperty(normalizedField, out var value))
            {
                return string.Empty;
            }

            return value.ValueKind switch
            {
                JsonValueKind.String => value.GetString()?.Trim() ?? string.Empty,
                JsonValueKind.Null => string.Empty,
                _ => value.GetRawText().Trim()
            };
        }
        catch
        {
            return string.Empty;
        }
    }

    private static string ExtractAliyunKmsSecret(string payload, string field)
    {
        if (string.IsNullOrWhiteSpace(payload))
        {
            return string.Empty;
        }

        try
        {
            using var doc = JsonDocument.Parse(payload);
            if (doc.RootElement.ValueKind != JsonValueKind.Object)
            {
                return string.Empty;
            }

            if (!doc.RootElement.TryGetProperty("SecretData", out var secretDataElement) &&
                !doc.RootElement.TryGetProperty("secretData", out secretDataElement))
            {
                return string.Empty;
            }

            var secretData = secretDataElement.ValueKind switch
            {
                JsonValueKind.String => secretDataElement.GetString()?.Trim() ?? string.Empty,
                JsonValueKind.Null => string.Empty,
                _ => secretDataElement.GetRawText().Trim()
            };

            if (string.IsNullOrWhiteSpace(secretData))
            {
                return string.Empty;
            }

            return ExtractAwsSecret(secretData, field);
        }
        catch
        {
            return string.Empty;
        }
    }

    private static string ResolveVaultToken(VaultSecretProviderOptions options, Func<string, string?> envProvider)
    {
        if (!string.IsNullOrWhiteSpace(options.Token))
        {
            return options.Token.Trim();
        }

        var envVar = string.IsNullOrWhiteSpace(options.TokenEnvVar)
            ? "DATAHZ_VAULT_TOKEN"
            : options.TokenEnvVar.Trim();
        var token = envProvider(envVar);
        return string.IsNullOrWhiteSpace(token) ? string.Empty : token.Trim();
    }

    private static (string Path, string Field) ParseVaultReference(string secretRef)
    {
        var raw = secretRef.Trim();
        if (string.IsNullOrWhiteSpace(raw))
        {
            return (string.Empty, string.Empty);
        }

        var index = raw.LastIndexOf('#');
        if (index <= 0 || index == raw.Length - 1)
        {
            return (raw, "value");
        }

        return (raw[..index], raw[(index + 1)..]);
    }

    private static string ExtractVaultSecret(string payload, string field, int kvVersion)
    {
        try
        {
            using var doc = JsonDocument.Parse(payload);
            if (!doc.RootElement.TryGetProperty("data", out var data))
            {
                return string.Empty;
            }

            var source = kvVersion <= 1
                ? data
                : data.TryGetProperty("data", out var nested) ? nested : default;
            if (source.ValueKind != JsonValueKind.Object)
            {
                return string.Empty;
            }

            var key = string.IsNullOrWhiteSpace(field) ? "value" : field.Trim();
            if (!source.TryGetProperty(key, out var value))
            {
                return string.Empty;
            }

            return value.ValueKind switch
            {
                JsonValueKind.String => value.GetString()?.Trim() ?? string.Empty,
                JsonValueKind.Null => string.Empty,
                _ => value.GetRawText().Trim()
            };
        }
        catch
        {
            return string.Empty;
        }
    }

    private static string NormalizeProvider(string? provider)
    {
        if (string.IsNullOrWhiteSpace(provider))
        {
            return "none";
        }

        var normalized = provider.Trim().ToLowerInvariant();
        return NormalizeProviderAliasForFilter(normalized);
    }

    private static string? NormalizeFilter(string? value)
    {
        return string.IsNullOrWhiteSpace(value) ? null : value.Trim();
    }

    private static string? NormalizeProviderFilter(string? provider)
    {
        var normalized = NormalizeFilter(provider);
        return normalized is null ? null : NormalizeProviderAliasForFilter(normalized);
    }

    private static string NormalizeProviderAliasForFilter(string provider)
    {
        var normalized = provider.Trim().ToLowerInvariant();
        return normalized switch
        {
            "azure-keyvault" or "keyvault" => "azurekv",
            "aws-secretsmanager" or "awssecretsmanager" => "awssm",
            "gcp-secretmanager" or "gcpsecretmanager" => "gcpsm",
            "aliyun-kms" or "alicloud-kms" or "alicloudkms" => "aliyunkms",
            _ => normalized
        };
    }

    private static bool MatchesExternalProviderState(
        ExternalProviderStateEntry entry,
        string? providerFilter,
        string? purposeFilter,
        string? statusFilter,
        DateTimeOffset? fromUtc,
        DateTimeOffset? toUtc)
    {
        if (providerFilter is not null &&
            !string.Equals(
                NormalizeProviderAliasForFilter(entry.Provider),
                providerFilter,
                StringComparison.Ordinal))
        {
            return false;
        }

        if (purposeFilter is not null &&
            !string.Equals(entry.Purpose, purposeFilter, StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        if (statusFilter is not null &&
            !string.Equals(entry.LastStatus, statusFilter, StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        var lastAttemptUtc = entry.LastAttemptUtc == DateTimeOffset.MinValue
            ? (DateTimeOffset?)null
            : entry.LastAttemptUtc;

        if (fromUtc is not null && (lastAttemptUtc is null || lastAttemptUtc.Value < fromUtc.Value))
        {
            return false;
        }

        if (toUtc is not null && (lastAttemptUtc is null || lastAttemptUtc.Value > toUtc.Value))
        {
            return false;
        }

        return true;
    }

    private static string BuildSecretCacheKey(
        string purpose,
        string? fallbackValue,
        SecuritySecretSourceOptions? sourceOptions,
        string? externalRef,
        string? command)
    {
        if (sourceOptions is null)
        {
            return $"{purpose}|{HashForCachePart(fallbackValue)}";
        }

        return string.Join("|",
            purpose,
            HashForCachePart(fallbackValue),
            sourceOptions.EnableExternalProvider,
            NormalizeProvider(sourceOptions.ExternalProvider),
            HashForCachePart(externalRef),
            sourceOptions.AllowCommandExecution,
            HashForCachePart(command));
    }

    private static string ResolveWithRuntimeCache(
        string cacheKey,
        SecuritySecretSourceOptions? sourceOptions,
        Func<string> resolveRaw,
        bool forceRefresh)
    {
        var now = DateTimeOffset.UtcNow;
        var ttlSeconds = Math.Clamp(sourceOptions?.CacheTtlSeconds ?? 0, 0, 3600);
        var staleSeconds = Math.Clamp(sourceOptions?.CacheMaxStaleSeconds ?? 0, 0, 86400);
        var graceSeconds = Math.Clamp(sourceOptions?.RotationGraceSeconds ?? 0, 0, 3600);

        if (!forceRefresh && ttlSeconds > 0)
        {
            var snapshot = GetCacheSnapshot(cacheKey);
            if (snapshot is not null &&
                !string.IsNullOrWhiteSpace(snapshot.CurrentValue) &&
                snapshot.CacheExpiresUtc > now)
            {
                return snapshot.CurrentValue;
            }
        }

        var resolved = resolveRaw().Trim();
        if (!string.IsNullOrWhiteSpace(resolved))
        {
            UpdateCacheOnSuccess(cacheKey, resolved, ttlSeconds, graceSeconds, now);
            return resolved;
        }

        if (staleSeconds <= 0)
        {
            return string.Empty;
        }

        var stale = GetCacheSnapshot(cacheKey);
        if (stale is null || string.IsNullOrWhiteSpace(stale.CurrentValue))
        {
            return string.Empty;
        }

        return stale.LastSuccessUtc.AddSeconds(staleSeconds) >= now
            ? stale.CurrentValue
            : string.Empty;
    }

    private static string TryGetPreviousFromCache(string cacheKey, SecuritySecretSourceOptions? sourceOptions)
    {
        var graceSeconds = Math.Clamp(sourceOptions?.RotationGraceSeconds ?? 0, 0, 3600);
        if (graceSeconds <= 0)
        {
            return string.Empty;
        }

        var snapshot = GetCacheSnapshot(cacheKey);
        if (snapshot is null ||
            string.IsNullOrWhiteSpace(snapshot.PreviousValue) ||
            snapshot.PreviousUntilUtc < DateTimeOffset.UtcNow)
        {
            return string.Empty;
        }

        return snapshot.PreviousValue;
    }

    private static IReadOnlyList<string> BuildCandidates(string current, string previous)
    {
        if (string.IsNullOrWhiteSpace(current) && string.IsNullOrWhiteSpace(previous))
        {
            return [];
        }

        if (string.IsNullOrWhiteSpace(previous) || string.Equals(current, previous, StringComparison.Ordinal))
        {
            return string.IsNullOrWhiteSpace(current) ? [] : [current];
        }

        if (string.IsNullOrWhiteSpace(current))
        {
            return [previous];
        }

        return [current, previous];
    }

    private static SecretCacheEntry? GetCacheSnapshot(string cacheKey)
    {
        lock (SecretCacheSync)
        {
            return SecretCache.TryGetValue(cacheKey, out var entry)
                ? entry.Clone()
                : null;
        }
    }

    private static void UpdateCacheOnSuccess(
        string cacheKey,
        string resolvedValue,
        int ttlSeconds,
        int graceSeconds,
        DateTimeOffset now)
    {
        lock (SecretCacheSync)
        {
            SecretCache.TryGetValue(cacheKey, out var existing);
            var next = existing?.Clone() ?? new SecretCacheEntry();

            var changed = !string.Equals(next.CurrentValue, resolvedValue, StringComparison.Ordinal);
            if (changed &&
                !string.IsNullOrWhiteSpace(next.CurrentValue) &&
                graceSeconds > 0)
            {
                next.PreviousValue = next.CurrentValue;
                next.PreviousUntilUtc = now.AddSeconds(graceSeconds);
            }
            else if (next.PreviousUntilUtc < now)
            {
                next.PreviousValue = string.Empty;
                next.PreviousUntilUtc = DateTimeOffset.MinValue;
            }

            next.CurrentValue = resolvedValue;
            next.LastSuccessUtc = now;
            next.CacheExpiresUtc = ttlSeconds > 0 ? now.AddSeconds(ttlSeconds) : now;
            SecretCache[cacheKey] = next;
        }
    }

    private static string HashForCachePart(string? value)
    {
        var normalized = string.IsNullOrEmpty(value) ? string.Empty : value;
        var bytes = SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(normalized));
        return Convert.ToHexString(bytes);
    }

    private static string ExtractPurposeFromCacheKey(string cacheKey)
    {
        var splitIndex = cacheKey.IndexOf('|');
        if (splitIndex <= 0)
        {
            return "unknown";
        }

        return cacheKey[..splitIndex];
    }

    private static string BuildExternalStateKey(string provider, string purpose, string secretRef)
    {
        return string.Join("|",
            NormalizeProvider(provider),
            purpose?.Trim() ?? string.Empty,
            HashForCachePart(secretRef));
    }

    private static string BuildSecretRefHint(string secretRef)
    {
        var hash = HashForCachePart(secretRef);
        return hash.Length <= 12 ? hash : hash[..12];
    }

    private static string CompactError(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return string.Empty;
        }

        var compact = value.Replace('\r', ' ').Replace('\n', ' ').Trim();
        return compact.Length <= 200 ? compact : compact[..200];
    }

    private static string BuildAliyunRpcSignature(
        IReadOnlyDictionary<string, string> parameters,
        string accessKeySecret)
    {
        var canonical = BuildAliyunQuery(parameters);
        var stringToSign = $"GET&{AliyunPercentEncode("/")}&{AliyunPercentEncode(canonical)}";
        using var hmac = new HMACSHA1(Encoding.UTF8.GetBytes($"{accessKeySecret.Trim()}&"));
        var bytes = hmac.ComputeHash(Encoding.UTF8.GetBytes(stringToSign));
        return Convert.ToBase64String(bytes);
    }

    private static string BuildAliyunQuery(IReadOnlyDictionary<string, string> parameters)
    {
        return string.Join("&", parameters
            .OrderBy(x => x.Key, StringComparer.Ordinal)
            .Select(x => $"{AliyunPercentEncode(x.Key)}={AliyunPercentEncode(x.Value)}"));
    }

    private static string AliyunPercentEncode(string value)
    {
        return Uri.EscapeDataString(value ?? string.Empty)
            .Replace("+", "%20", StringComparison.Ordinal)
            .Replace("*", "%2A", StringComparison.Ordinal)
            .Replace("%7E", "~", StringComparison.Ordinal);
    }

    private static string NormalizeAliyunEndpoint(string? endpoint)
    {
        var raw = NormalizeFilter(endpoint);
        if (raw is null)
        {
            return string.Empty;
        }

        if (Uri.TryCreate(raw, UriKind.Absolute, out var absolute))
        {
            if (absolute.Port > 0 && !absolute.IsDefaultPort)
            {
                return $"{absolute.Host}:{absolute.Port}";
            }

            return absolute.Host;
        }

        return raw
            .Replace("https://", string.Empty, StringComparison.OrdinalIgnoreCase)
            .Replace("http://", string.Empty, StringComparison.OrdinalIgnoreCase)
            .Trim('/')
            .Trim();
    }

    private static ProcessStartInfo BuildShellCommand(string command)
    {
        if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
        {
            return new ProcessStartInfo("cmd.exe", $"/c {command}");
        }

        return new ProcessStartInfo("/bin/sh", $"-c \"{command.Replace("\"", "\\\"")}\"");
    }

    private sealed class SecretCacheEntry
    {
        public string CurrentValue { get; set; } = string.Empty;
        public string PreviousValue { get; set; } = string.Empty;
        public DateTimeOffset PreviousUntilUtc { get; set; } = DateTimeOffset.MinValue;
        public DateTimeOffset LastSuccessUtc { get; set; } = DateTimeOffset.MinValue;
        public DateTimeOffset CacheExpiresUtc { get; set; } = DateTimeOffset.MinValue;

        public SecretCacheEntry Clone()
        {
            return new SecretCacheEntry
            {
                CurrentValue = CurrentValue,
                PreviousValue = PreviousValue,
                PreviousUntilUtc = PreviousUntilUtc,
                LastSuccessUtc = LastSuccessUtc,
                CacheExpiresUtc = CacheExpiresUtc
            };
        }
    }

    private sealed class ExternalProviderStateEntry
    {
        public string Provider { get; set; } = string.Empty;
        public string Purpose { get; set; } = string.Empty;
        public string SecretRefHint { get; set; } = string.Empty;
        public DateTimeOffset LastAttemptUtc { get; set; } = DateTimeOffset.MinValue;
        public DateTimeOffset LastSuccessUtc { get; set; } = DateTimeOffset.MinValue;
        public DateTimeOffset LastFailureUtc { get; set; } = DateTimeOffset.MinValue;
        public bool LastAttemptHadValue { get; set; }
        public long LastDurationMs { get; set; }
        public string LastStatus { get; set; } = "unknown";
        public string LastError { get; set; } = string.Empty;
    }
}
