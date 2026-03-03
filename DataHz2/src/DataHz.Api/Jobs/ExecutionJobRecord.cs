using DataHz.Api.Contracts;
using DataHz.Core.Domain;
using DataHz.Core.Execution;

namespace DataHz.Api.Jobs;

public enum ExecutionJobStatus
{
    Queued,
    Running,
    Succeeded,
    Failed,
    Canceled
}

public sealed class ExecutionJobRecord
{
    public required Guid Id { get; init; }
    public required SubmitJobRequest Request { get; init; }
    public ExecutionJobStatus Status { get; set; } = ExecutionJobStatus.Queued;
    public DateTimeOffset CreatedAt { get; init; } = DateTimeOffset.UtcNow;
    public DateTimeOffset? StartedAt { get; set; }
    public DateTimeOffset? CompletedAt { get; set; }
    public bool CancellationRequested { get; set; }
    public DateTimeOffset? CancellationRequestedAt { get; set; }
    public string? CancellationReason { get; set; }
    public IReadOnlyList<ValidationIssue>? PlanIssues { get; set; }
    public ExecuteResult? Result { get; set; }
    public string? Error { get; set; }
}
