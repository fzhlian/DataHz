namespace DataHz.Core.Domain;

public sealed record LogicCheckRule(
    int Index,
    string CheckSql,
    string CheckTip
);
