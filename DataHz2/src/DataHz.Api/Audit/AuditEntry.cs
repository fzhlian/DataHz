namespace DataHz.Api.Audit;

public sealed record AuditEntry(
    DateTimeOffset Utc,
    string Category,
    string Action,
    Guid? JobId = null,
    string? Message = null,
    string? Path = null,
    string? Method = null,
    int? StatusCode = null,
    string? RemoteIp = null
);
