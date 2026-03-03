namespace DataHz.Api.Security;

public sealed class ApiKeySecurityOptions
{
    public bool Enabled { get; set; }
    public string HeaderName { get; set; } = "X-Api-Key";
    public string Value { get; set; } = string.Empty;
    public string DefaultRole { get; set; } = nameof(AccessRole.Operator);
    public List<ApiKeyDefinitionOptions> Keys { get; set; } = [];
}

public sealed class ApiKeyDefinitionOptions
{
    public string Name { get; set; } = string.Empty;
    public string Key { get; set; } = string.Empty;
    public string Role { get; set; } = nameof(AccessRole.Operator);
}
