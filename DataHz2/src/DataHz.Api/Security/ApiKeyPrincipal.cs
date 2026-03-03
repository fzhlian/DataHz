namespace DataHz.Api.Security;

public sealed record ApiKeyPrincipal(string Name, AccessRole Role, string Source = "apiKey");
