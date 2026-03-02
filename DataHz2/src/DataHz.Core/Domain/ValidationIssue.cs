namespace DataHz.Core.Domain;

public sealed record ValidationIssue(string Scope, string Message);
