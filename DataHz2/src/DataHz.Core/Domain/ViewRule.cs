namespace DataHz.Core.Domain;

public sealed record ViewRule(
    int Index,
    string ViewName,
    string ViewSql,
    string TemplateFile,
    string TargetFile,
    string Range
);
