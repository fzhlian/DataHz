namespace DataHz.Api.Contracts;

public sealed class ExecuteRequestContract
{
    public required PlanTasksRequest Plan { get; init; }
    public bool DryRun { get; init; } = true;
}
