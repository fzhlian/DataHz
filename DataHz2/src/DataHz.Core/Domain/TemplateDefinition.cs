namespace DataHz.Core.Domain;

public sealed class TemplateDefinition
{
    public required string TemplateName { get; init; }
    public required string TemplatePath { get; init; }
    public string DatabaseName { get; init; } = string.Empty;
    public NameType NameType { get; init; } = NameType.MultiDatabaseTemplateDriven;
    public string DatabasePassword { get; init; } = string.Empty;
    public int XzCodeStart { get; init; }
    public int CreatJcb { get; init; }
    public string FieldName { get; init; } = string.Empty;
    public string TableName { get; init; } = string.Empty;
    public int ColumnCount { get; init; }
    public int ViewCount { get; init; }
    public int CheckCount { get; init; }
    public string CheckSql { get; init; } = string.Empty;
    public string CheckErrorInfo { get; init; } = string.Empty;
    public bool CheckStop { get; init; }

    public IReadOnlyList<ColumnRule> Columns { get; init; } = Array.Empty<ColumnRule>();
    public IReadOnlyList<ViewRule> Views { get; init; } = Array.Empty<ViewRule>();
    public IReadOnlyList<LogicCheckRule> LogicChecks { get; init; } = Array.Empty<LogicCheckRule>();
    public FlowTemplateConfig? FlowConfig { get; init; }

    public bool IsFlowTemplate =>
        TemplateName.StartsWith("FX_", StringComparison.OrdinalIgnoreCase)
        || FlowConfig is not null;

    public string TemplateDirectory => Path.GetDirectoryName(TemplatePath) ?? string.Empty;
}
