using Microsoft.Extensions.Options;

namespace DataHz.Api.Security;

public sealed record SecurityHardeningCheck(
    string Id,
    string Status,
    string Message
);

public sealed record SecurityHardeningReport(
    bool ApiKeyEnabled,
    bool JwtEnabled,
    string Mode,
    int PassCount,
    int WarnCount,
    int FailCount,
    IReadOnlyList<SecurityHardeningCheck> Checks
);

public interface ISecurityHardeningInspector
{
    SecurityHardeningReport Inspect();
}

public sealed class SecurityHardeningInspector(
    IOptions<ApiKeySecurityOptions> apiKeyOptions,
    IOptions<JwtSecurityOptions> jwtOptions,
    IOptions<SecuritySecretSourceOptions> secretSourceOptions) : ISecurityHardeningInspector
{
    public SecurityHardeningReport Inspect()
    {
        var api = apiKeyOptions.Value;
        var jwt = jwtOptions.Value;
        var secrets = secretSourceOptions.Value;

        var checks = new List<SecurityHardeningCheck>();
        var mode = ResolveMode(api.Enabled, jwt.Enabled);

        var effectiveApiValue = SecuritySecretResolver.ResolveApiKeyValue(api, secrets);
        var apiKeySource = SecuritySecretResolver.DescribeApiKeySource(api, secrets);
        var effectiveJwtSigningKey = SecuritySecretResolver.ResolveJwtSigningKey(jwt, secrets);
        var jwtKeySource = SecuritySecretResolver.DescribeJwtSigningKeySource(jwt, secrets);
        var externalProvider = (secrets.ExternalProvider ?? string.Empty).Trim().ToLowerInvariant();
        var externalRuntime = SecuritySecretResolver.GetExternalProviderRuntimeState();

        if (!api.Enabled && !jwt.Enabled)
        {
            checks.Add(new SecurityHardeningCheck(
                "auth-mode",
                "warn",
                "No auth enabled. API endpoints are open."));
        }
        else
        {
            checks.Add(new SecurityHardeningCheck(
                "auth-mode",
                "pass",
                $"Auth mode is {mode}."));
        }

        checks.Add(secrets.CacheTtlSeconds > 0
            ? new SecurityHardeningCheck("secret.cache.ttl", "pass", $"Secret cache TTL: {secrets.CacheTtlSeconds}s.")
            : new SecurityHardeningCheck("secret.cache.ttl", "warn", "Secret cache TTL is disabled (0). External providers will be called on every request."));

        checks.Add(secrets.CacheMaxStaleSeconds > 0
            ? new SecurityHardeningCheck("secret.cache.stale", "pass", $"Stale fallback window: {secrets.CacheMaxStaleSeconds}s.")
            : new SecurityHardeningCheck("secret.cache.stale", "warn", "Stale fallback window is disabled (0). Secret source outages may cause auth failures."));

        checks.Add(secrets.RotationGraceSeconds > 0
            ? new SecurityHardeningCheck("secret.rotation.grace", "pass", $"Rotation grace window: {secrets.RotationGraceSeconds}s.")
            : new SecurityHardeningCheck("secret.rotation.grace", "warn", "Rotation grace window is disabled (0). Key cutovers are immediate."));

        if (secrets.EnableExternalProvider)
        {
            checks.Add(string.IsNullOrWhiteSpace(externalProvider) || externalProvider == "none"
                ? new SecurityHardeningCheck("secret.external.provider", "warn", "External provider enabled but provider type is none.")
                : new SecurityHardeningCheck("secret.external.provider", "pass", $"External provider: {externalProvider}."));

            if (externalProvider == "vault")
            {
                if (string.IsNullOrWhiteSpace(secrets.Vault.Address))
                {
                    checks.Add(new SecurityHardeningCheck("secret.external.vault.address", "fail", "Vault provider selected but address is empty."));
                }
                else
                {
                    checks.Add(secrets.Vault.Address.StartsWith("https://", StringComparison.OrdinalIgnoreCase)
                        ? new SecurityHardeningCheck("secret.external.vault.https", "pass", "Vault address uses HTTPS.")
                        : new SecurityHardeningCheck("secret.external.vault.https", "warn", "Vault address does not use HTTPS."));
                }
            }

            if (externalProvider == "azurekv" || externalProvider == "azure-keyvault" || externalProvider == "keyvault")
            {
                if (string.IsNullOrWhiteSpace(secrets.AzureKeyVault.VaultUri))
                {
                    checks.Add(new SecurityHardeningCheck(
                        "secret.external.azurekv.uri",
                        "warn",
                        $"Azure Key Vault URI is empty in config. Provide Security:Secrets:AzureKeyVault:VaultUri or env {SecuritySecretResolver.AzureKeyVaultUriEnvVar}."));
                }
                else
                {
                    checks.Add(secrets.AzureKeyVault.VaultUri.StartsWith("https://", StringComparison.OrdinalIgnoreCase)
                        ? new SecurityHardeningCheck("secret.external.azurekv.https", "pass", "Azure Key Vault URI uses HTTPS.")
                        : new SecurityHardeningCheck("secret.external.azurekv.https", "warn", "Azure Key Vault URI does not use HTTPS."));
                }
            }

            if (externalProvider == "awssm" || externalProvider == "aws-secretsmanager" || externalProvider == "awssecretsmanager")
            {
                var region = secrets.AwsSecretsManager.Region;
                if (string.IsNullOrWhiteSpace(region))
                {
                    checks.Add(new SecurityHardeningCheck(
                        "secret.external.awssm.region",
                        "warn",
                        $"AWS region is empty in config. Provide Security:Secrets:AwsSecretsManager:Region or env {SecuritySecretResolver.AwsRegionEnvVar}/{SecuritySecretResolver.AwsDefaultRegionEnvVar}."));
                }
                else
                {
                    checks.Add(new SecurityHardeningCheck(
                        "secret.external.awssm.region",
                        "pass",
                        $"AWS Secrets Manager region: {region.Trim()}."));
                }

                if (!string.IsNullOrWhiteSpace(secrets.AwsSecretsManager.AccessKeyId) &&
                    !string.IsNullOrWhiteSpace(secrets.AwsSecretsManager.SecretAccessKey))
                {
                    checks.Add(new SecurityHardeningCheck(
                        "secret.external.awssm.static-credentials",
                        "warn",
                        "AWS static credentials configured. Prefer instance/profile-based short-lived credentials."));
                }
            }

            if (externalProvider == "gcpsm" || externalProvider == "gcp-secretmanager" || externalProvider == "gcpsecretmanager")
            {
                var projectId = secrets.GcpSecretManager.ProjectId;
                if (string.IsNullOrWhiteSpace(projectId))
                {
                    checks.Add(new SecurityHardeningCheck(
                        "secret.external.gcpsm.project",
                        "warn",
                        $"GCP project ID is empty in config. Provide Security:Secrets:GcpSecretManager:ProjectId or env {SecuritySecretResolver.GcpProjectEnvVar}/{SecuritySecretResolver.GcpLegacyProjectEnvVar}."));
                }
                else
                {
                    checks.Add(new SecurityHardeningCheck(
                        "secret.external.gcpsm.project",
                        "pass",
                        $"GCP Secret Manager project: {projectId.Trim()}."));
                }

                if (!string.IsNullOrWhiteSpace(secrets.GcpSecretManager.CredentialsPath))
                {
                    checks.Add(new SecurityHardeningCheck(
                        "secret.external.gcpsm.credentials-path",
                        "warn",
                        $"GCP credential file path is configured. Ensure strict file ACLs or prefer workload identity/ADC via env {SecuritySecretResolver.GcpCredentialsPathEnvVar}."));
                }
            }

            if (externalProvider == "aliyunkms" || externalProvider == "aliyun-kms" || externalProvider == "alicloud-kms" || externalProvider == "alicloudkms")
            {
                var regionId = secrets.AliyunKms.RegionId;
                if (string.IsNullOrWhiteSpace(regionId))
                {
                    checks.Add(new SecurityHardeningCheck(
                        "secret.external.aliyunkms.region",
                        "warn",
                        $"Aliyun KMS region is empty in config. Provide Security:Secrets:AliyunKms:RegionId or env {SecuritySecretResolver.AliyunRegionEnvVar}/{SecuritySecretResolver.AliyunLegacyRegionEnvVar}."));
                }
                else
                {
                    checks.Add(new SecurityHardeningCheck(
                        "secret.external.aliyunkms.region",
                        "pass",
                        $"Aliyun KMS region: {regionId.Trim()}."));
                }

                var hasConfiguredAccessKeyId = !string.IsNullOrWhiteSpace(secrets.AliyunKms.AccessKeyId);
                var hasConfiguredAccessKeySecret = !string.IsNullOrWhiteSpace(secrets.AliyunKms.AccessKeySecret);
                if (hasConfiguredAccessKeyId != hasConfiguredAccessKeySecret)
                {
                    checks.Add(new SecurityHardeningCheck(
                        "secret.external.aliyunkms.credentials",
                        "warn",
                        $"Aliyun KMS static credentials are partially configured. Set both AccessKeyId and AccessKeySecret, or use env {SecuritySecretResolver.AliyunAccessKeyIdEnvVar}/{SecuritySecretResolver.AliyunAccessKeySecretEnvVar}."));
                }
                else if (hasConfiguredAccessKeyId && hasConfiguredAccessKeySecret)
                {
                    checks.Add(new SecurityHardeningCheck(
                        "secret.external.aliyunkms.credentials",
                        "warn",
                        "Aliyun KMS static credentials configured. Prefer RAM role / STS short-lived credentials."));
                }

                if (!string.IsNullOrWhiteSpace(secrets.AliyunKms.Endpoint) &&
                    secrets.AliyunKms.Endpoint.StartsWith("http://", StringComparison.OrdinalIgnoreCase))
                {
                    checks.Add(new SecurityHardeningCheck(
                        "secret.external.aliyunkms.endpoint.https",
                        "warn",
                        "Aliyun KMS endpoint uses HTTP. Prefer HTTPS endpoint."));
                }
            }

            if (externalProvider != "none")
            {
                var providerRuntime = externalRuntime
                    .Where(x => IsProviderMatch(x.Provider, externalProvider))
                    .OrderByDescending(x => x.LastAttemptUtc)
                    .ToList();
                if (providerRuntime.Count == 0)
                {
                    checks.Add(new SecurityHardeningCheck(
                        "secret.external.runtime.no-attempt",
                        "warn",
                        $"No runtime attempt recorded yet for provider '{externalProvider}'."));
                }
                else
                {
                    checks.Add(providerRuntime.Any(x => x.LastAttemptHadValue)
                        ? new SecurityHardeningCheck(
                            "secret.external.runtime.success",
                            "pass",
                            $"Recent runtime secret fetch succeeded for provider '{externalProvider}'.")
                        : new SecurityHardeningCheck(
                            "secret.external.runtime.success",
                            "warn",
                            $"Recent runtime secret fetch did not return a value for provider '{externalProvider}'."));

                    var latestError = providerRuntime
                        .Where(x => !string.IsNullOrWhiteSpace(x.LastError))
                        .OrderByDescending(x => x.LastAttemptUtc)
                        .FirstOrDefault();
                    if (latestError is not null)
                    {
                        checks.Add(new SecurityHardeningCheck(
                            "secret.external.runtime.error",
                            "warn",
                            $"Latest provider error ({latestError.Purpose}): {latestError.LastError}."));
                    }
                }
            }
        }

        if (api.Enabled)
        {
            var keyCount = (string.IsNullOrWhiteSpace(effectiveApiValue) ? 0 : 1) +
                           (api.Keys?.Count(x => !string.IsNullOrWhiteSpace(x.Key)) ?? 0);

            checks.Add(keyCount == 0
                ? new SecurityHardeningCheck("api-key.present", "fail", "API key auth enabled but no valid key configured.")
                : new SecurityHardeningCheck("api-key.present", "pass", $"API key count: {keyCount}."));

            if (!string.IsNullOrWhiteSpace(effectiveApiValue) && effectiveApiValue.Length < 16)
            {
                checks.Add(new SecurityHardeningCheck("api-key.length", "warn", "Primary API key length < 16."));
            }
            else if (!string.IsNullOrWhiteSpace(effectiveApiValue))
            {
                checks.Add(new SecurityHardeningCheck("api-key.length", "pass", "Primary API key length looks acceptable."));
            }

            checks.Add(apiKeySource.StartsWith("env:", StringComparison.OrdinalIgnoreCase) ||
                       apiKeySource.StartsWith("external:", StringComparison.OrdinalIgnoreCase) ||
                       apiKeySource.Equals("command", StringComparison.OrdinalIgnoreCase)
                ? new SecurityHardeningCheck("api-key.source", "pass", $"Primary API key source: {apiKeySource}.")
                : new SecurityHardeningCheck("api-key.source", "warn", $"Primary API key source: {apiKeySource}."));
        }

        if (jwt.Enabled)
        {
            var hasAuthority = !string.IsNullOrWhiteSpace(jwt.Authority);
            var hasSigningKey = !string.IsNullOrWhiteSpace(effectiveJwtSigningKey);
            if (!hasAuthority && !hasSigningKey)
            {
                checks.Add(new SecurityHardeningCheck(
                    "jwt.material",
                    "fail",
                    "JWT enabled but no Authority and no SigningKey configured."));
            }
            else
            {
                checks.Add(new SecurityHardeningCheck(
                    "jwt.material",
                    "pass",
                    hasAuthority ? "JWT authority mode enabled." : "JWT symmetric-signing mode enabled."));
            }

            if (hasAuthority)
            {
                var https = jwt.Authority.StartsWith("https://", StringComparison.OrdinalIgnoreCase);
                checks.Add(https
                    ? new SecurityHardeningCheck("jwt.authority.https", "pass", "JWT authority uses HTTPS.")
                    : new SecurityHardeningCheck("jwt.authority.https", "warn", "JWT authority does not use HTTPS."));
            }

            if (hasSigningKey)
            {
                checks.Add(effectiveJwtSigningKey.Length >= 32
                    ? new SecurityHardeningCheck("jwt.signing-key.length", "pass", "JWT signing key length >= 32.")
                    : new SecurityHardeningCheck("jwt.signing-key.length", "warn", "JWT signing key length < 32."));
            }

            checks.Add(jwtKeySource.StartsWith("env:", StringComparison.OrdinalIgnoreCase) ||
                       jwtKeySource.StartsWith("external:", StringComparison.OrdinalIgnoreCase) ||
                       jwtKeySource.Equals("command", StringComparison.OrdinalIgnoreCase)
                ? new SecurityHardeningCheck("jwt.signing-key.source", "pass", $"JWT signing key source: {jwtKeySource}.")
                : new SecurityHardeningCheck("jwt.signing-key.source", "warn", $"JWT signing key source: {jwtKeySource}."));
        }

        var pass = checks.Count(x => x.Status == "pass");
        var warn = checks.Count(x => x.Status == "warn");
        var fail = checks.Count(x => x.Status == "fail");

        return new SecurityHardeningReport(
            ApiKeyEnabled: api.Enabled,
            JwtEnabled: jwt.Enabled,
            Mode: mode,
            PassCount: pass,
            WarnCount: warn,
            FailCount: fail,
            Checks: checks);
    }

    private static string ResolveMode(bool apiKeyEnabled, bool jwtEnabled)
    {
        if (apiKeyEnabled && jwtEnabled)
        {
            return "hybrid";
        }

        if (apiKeyEnabled)
        {
            return "apiKey";
        }

        if (jwtEnabled)
        {
            return "jwt";
        }

        return "none";
    }

    private static bool IsProviderMatch(string actualProvider, string configuredProvider)
    {
        var actual = NormalizeProvider(actualProvider);
        var configured = NormalizeProvider(configuredProvider);

        if (actual == configured)
        {
            return true;
        }

        return configured switch
        {
            "azure-keyvault" or "keyvault" => actual == "azurekv",
            "aws-secretsmanager" or "awssecretsmanager" => actual == "awssm",
            "gcp-secretmanager" or "gcpsecretmanager" => actual == "gcpsm",
            "aliyun-kms" or "alicloud-kms" or "alicloudkms" => actual == "aliyunkms",
            _ => false
        };
    }

    private static string NormalizeProvider(string value)
    {
        return string.IsNullOrWhiteSpace(value)
            ? "none"
            : value.Trim().ToLowerInvariant();
    }
}
