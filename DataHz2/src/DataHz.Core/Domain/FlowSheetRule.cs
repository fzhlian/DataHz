namespace DataHz.Core.Domain;

public sealed class FlowSheetRule
{
    public int ConfigSheet { get; init; }
    public int WriteSheet { get; init; }
    public int WriteRow { get; init; }
    public int WriteCol { get; init; }
    public string ViewSql { get; init; } = string.Empty;
    public IReadOnlyList<string> RowSql { get; init; } = Array.Empty<string>();
    public IReadOnlyList<string> ColSql { get; init; } = Array.Empty<string>();
}
