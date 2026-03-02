namespace DataHz.Core.Domain;

public sealed record ColumnRule(
    int Index,
    string Caption,
    string Sql,
    string Sql2
);
