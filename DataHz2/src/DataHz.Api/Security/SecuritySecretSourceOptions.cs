namespace DataHz.Api.Security;

public sealed class SecuritySecretSourceOptions
{
    public int CacheTtlSeconds { get; set; } = 15;
    public int CacheMaxStaleSeconds { get; set; } = 300;
    public int RotationGraceSeconds { get; set; } = 0;
    public bool AllowCommandExecution { get; set; }
    public int CommandTimeoutSeconds { get; set; } = 10;
    public string ApiKeyCommand { get; set; } = string.Empty;
    public string JwtSigningKeyCommand { get; set; } = string.Empty;
    public bool EnableExternalProvider { get; set; }
    public string ExternalProvider { get; set; } = "none";
    public int ExternalTimeoutSeconds { get; set; } = 10;
    public string ApiKeyExternalRef { get; set; } = string.Empty;
    public string JwtSigningKeyExternalRef { get; set; } = string.Empty;
    public FileSecretProviderOptions File { get; set; } = new();
    public VaultSecretProviderOptions Vault { get; set; } = new();
    public AzureKeyVaultSecretProviderOptions AzureKeyVault { get; set; } = new();
    public AwsSecretsManagerProviderOptions AwsSecretsManager { get; set; } = new();
    public GcpSecretManagerProviderOptions GcpSecretManager { get; set; } = new();
    public AliyunKmsProviderOptions AliyunKms { get; set; } = new();
}

public sealed class FileSecretProviderOptions
{
    public string RootDirectory { get; set; } = string.Empty;
}

public sealed class VaultSecretProviderOptions
{
    public string Address { get; set; } = string.Empty;
    public string Mount { get; set; } = "secret";
    public int KvVersion { get; set; } = 2;
    public string Token { get; set; } = string.Empty;
    public string TokenEnvVar { get; set; } = "DATAHZ_VAULT_TOKEN";
    public string Namespace { get; set; } = string.Empty;
    public string TokenHeaderName { get; set; } = "X-Vault-Token";
}

public sealed class AzureKeyVaultSecretProviderOptions
{
    public string VaultUri { get; set; } = string.Empty;
    public string TenantId { get; set; } = string.Empty;
    public string ClientId { get; set; } = string.Empty;
    public string ClientSecret { get; set; } = string.Empty;
    public string ManagedIdentityClientId { get; set; } = string.Empty;
}

public sealed class AwsSecretsManagerProviderOptions
{
    public string Region { get; set; } = string.Empty;
    public string AccessKeyId { get; set; } = string.Empty;
    public string SecretAccessKey { get; set; } = string.Empty;
    public string SessionToken { get; set; } = string.Empty;
}

public sealed class GcpSecretManagerProviderOptions
{
    public string ProjectId { get; set; } = string.Empty;
    public string CredentialsPath { get; set; } = string.Empty;
}

public sealed class AliyunKmsProviderOptions
{
    public string RegionId { get; set; } = string.Empty;
    public string Endpoint { get; set; } = string.Empty;
    public string AccessKeyId { get; set; } = string.Empty;
    public string AccessKeySecret { get; set; } = string.Empty;
    public string SecurityToken { get; set; } = string.Empty;
    public string VersionStage { get; set; } = "ACSCurrent";
    public string VersionId { get; set; } = string.Empty;
}
