namespace DataHz.Api.Security;

public sealed class JwtSecurityOptions
{
    public bool Enabled { get; set; }
    public string Authority { get; set; } = string.Empty;
    public string Audience { get; set; } = string.Empty;
    public string ValidIssuer { get; set; } = string.Empty;
    public string ValidAudience { get; set; } = string.Empty;
    public string SigningKey { get; set; } = string.Empty;
    public bool RequireHttpsMetadata { get; set; } = false;
    public string RoleClaimType { get; set; } = "role";
    public string NameClaimType { get; set; } = "name";
}
