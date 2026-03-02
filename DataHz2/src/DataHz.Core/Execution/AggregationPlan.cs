using DataHz.Core.Domain;

namespace DataHz.Core.Execution;

public sealed record PlanningRequest(
    string TemplatePath,
    string SourceDirectory,
    string TargetDirectory,
    string AreaCodePath,
    int StartIndex = 23,
    int EndIndex = 148
);

public sealed record CountyTaskPlan(
    int Index,
    AreaCodeItem Area,
    string DatabaseFile,
    string DatabasePath,
    bool Exists
);

public sealed record AggregationPlan(
    TemplateDefinition Template,
    string SourceDirectory,
    string TargetDirectory,
    string AreaCodePath,
    IReadOnlyList<CountyTaskPlan> Counties,
    IReadOnlyList<ValidationIssue> Issues
);
