namespace DataHz.Core.Domain;

public sealed class FlowTemplateConfig
{
    public IReadOnlyList<FlowSheetRule> Sheets { get; init; } = Array.Empty<FlowSheetRule>();
    public IReadOnlyList<int> DeleteSheets { get; init; } = Array.Empty<int>();
}
