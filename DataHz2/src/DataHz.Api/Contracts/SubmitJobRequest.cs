namespace DataHz.Api.Contracts;

public sealed class SubmitJobRequest
{
    public required PlanTasksRequest Plan { get; init; }
    public bool DryRun { get; init; } = true;
    public bool Incremental { get; init; } = true;
    public string IdempotencyKey { get; init; } = string.Empty;
}
