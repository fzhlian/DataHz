namespace DataHz.Api.Contracts;

public sealed class PlanTasksRequest
{
    public required string TemplatePath { get; init; }
    public required string SourceDirectory { get; init; }
    public required string TargetDirectory { get; init; }
    public required string AreaCodePath { get; init; }
    public int StartIndex { get; init; } = 23;
    public int EndIndex { get; init; } = 148;
}
