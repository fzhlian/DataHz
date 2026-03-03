using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading.Channels;
using DataHz.Api.Audit;
using DataHz.Api.Contracts;
using DataHz.Core.Domain;
using DataHz.Core.Execution;
using Microsoft.Extensions.Options;

namespace DataHz.Api.Jobs;

public interface IExecutionJobQueue
{
    ExecutionJobEnqueueResult Enqueue(SubmitJobRequest request);
    bool TryGet(Guid id, out ExecutionJobRecord? record);
    IReadOnlyList<ExecutionJobRecord> List(int take = 50);
    ExecutionJobStats GetStats();
    ExecutionJobCancelResult Cancel(Guid id, string? reason);
    bool IsCancellationRequested(Guid id);
    ValueTask<Guid> DequeueAsync(CancellationToken cancellationToken);
    bool TryMarkRunning(Guid id, out SubmitJobRequest? request);
    bool TryMarkCanceled(Guid id, string? reason);
    bool TryMarkSucceeded(Guid id, ExecuteResult result, IReadOnlyList<ValidationIssue> issues);
    bool TryMarkFailed(Guid id, string error, IReadOnlyList<ValidationIssue> issues);
}

public enum ExecutionJobCancelStatus
{
    Canceled,
    CancellationRequested,
    NotFound,
    AlreadyCompleted
}

public sealed record ExecutionJobCancelResult(
    ExecutionJobCancelStatus Status,
    string Message,
    ExecutionJobStatus? JobStatus
);

public sealed record ExecutionJobEnqueueResult(
    Guid JobId,
    ExecutionJobStatus JobStatus,
    bool Deduplicated,
    string? IdempotencyKey
);

public sealed record ExecutionJobStats(
    int Total,
    int Queued,
    int Running,
    int Succeeded,
    int Failed,
    int Canceled,
    int CancellationRequested,
    DateTimeOffset? OldestCreatedAt,
    DateTimeOffset? NewestCreatedAt
);

public sealed class PersistentExecutionJobQueue : IExecutionJobQueue
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter() }
    };

    private readonly Channel<Guid> _channel = Channel.CreateUnbounded<Guid>();
    private readonly Dictionary<Guid, ExecutionJobRecord> _jobs = new();
    private readonly object _sync = new();
    private readonly ILogger<PersistentExecutionJobQueue> _logger;
    private readonly IAuditTrail _auditTrail;
    private readonly TimeSpan _retention;
    private readonly int _maxListTake;
    private readonly string _storeFilePath;
    private DateTimeOffset _lastPrunedAt = DateTimeOffset.MinValue;

    public PersistentExecutionJobQueue(
        IOptions<ExecutionJobOptions> options,
        IHostEnvironment hostEnvironment,
        IAuditTrail auditTrail,
        ILogger<PersistentExecutionJobQueue> logger)
    {
        var value = options.Value;
        _logger = logger;
        _auditTrail = auditTrail;
        _retention = TimeSpan.FromDays(Math.Clamp(value.RetentionDays, 1, 3650));
        _maxListTake = Math.Max(1, value.MaxListTake);

        var root = hostEnvironment.ContentRootPath;
        var storeDirectory = ResolveStoreDirectory(value.StoreDirectory, root);
        Directory.CreateDirectory(storeDirectory);
        _storeFilePath = Path.Combine(storeDirectory, "jobs.json");

        LoadFromDisk();
    }

    public ExecutionJobEnqueueResult Enqueue(SubmitJobRequest request)
    {
        var idempotencyKey = NormalizeIdempotencyKey(request.IdempotencyKey);
        var normalizedRequest = new SubmitJobRequest
        {
            Plan = request.Plan,
            DryRun = request.DryRun,
            Incremental = request.Incremental,
            IdempotencyKey = idempotencyKey ?? string.Empty
        };
        var utc = DateTimeOffset.UtcNow;
        var id = Guid.NewGuid();
        ExecutionJobRecord? deduplicatedExisting = null;

        lock (_sync)
        {
            PruneExpiredJobsLocked();

            if (idempotencyKey is not null)
            {
                deduplicatedExisting = _jobs.Values
                    .Where(x => x.Status is ExecutionJobStatus.Queued or ExecutionJobStatus.Running)
                    .Where(x => string.Equals(NormalizeIdempotencyKey(x.Request.IdempotencyKey), idempotencyKey, StringComparison.Ordinal))
                    .OrderByDescending(x => x.CreatedAt)
                    .FirstOrDefault();

                if (deduplicatedExisting is not null)
                {
                    return new ExecutionJobEnqueueResult(
                        JobId: deduplicatedExisting.Id,
                        JobStatus: deduplicatedExisting.Status,
                        Deduplicated: true,
                        IdempotencyKey: idempotencyKey);
                }
            }

            var record = new ExecutionJobRecord
            {
                Id = id,
                Request = normalizedRequest,
                Status = ExecutionJobStatus.Queued,
                CreatedAt = utc
            };

            _jobs[id] = record;
            PersistLocked(changed: true);
        }

        _channel.Writer.TryWrite(id);
        _auditTrail.Write(new AuditEntry(
            Utc: utc,
            Category: "job",
            Action: "job.submitted",
            JobId: id,
            Message: idempotencyKey is null ? null : $"IdempotencyKey={idempotencyKey}"));

        return new ExecutionJobEnqueueResult(
            JobId: id,
            JobStatus: ExecutionJobStatus.Queued,
            Deduplicated: false,
            IdempotencyKey: idempotencyKey);
    }

    public bool TryGet(Guid id, out ExecutionJobRecord? record)
    {
        lock (_sync)
        {
            if (_jobs.TryGetValue(id, out var inner))
            {
                record = Clone(inner);
                return true;
            }
        }

        record = null;
        return false;
    }

    public IReadOnlyList<ExecutionJobRecord> List(int take = 50)
    {
        lock (_sync)
        {
            var limitedTake = Math.Min(_maxListTake, Math.Max(1, take));
            return _jobs.Values
                .OrderByDescending(x => x.CreatedAt)
                .Take(limitedTake)
                .Select(Clone)
                .ToList();
        }
    }

    public ExecutionJobStats GetStats()
    {
        lock (_sync)
        {
            var values = _jobs.Values.ToList();
            return new ExecutionJobStats(
                Total: values.Count,
                Queued: values.Count(x => x.Status == ExecutionJobStatus.Queued),
                Running: values.Count(x => x.Status == ExecutionJobStatus.Running),
                Succeeded: values.Count(x => x.Status == ExecutionJobStatus.Succeeded),
                Failed: values.Count(x => x.Status == ExecutionJobStatus.Failed),
                Canceled: values.Count(x => x.Status == ExecutionJobStatus.Canceled),
                CancellationRequested: values.Count(x => x.CancellationRequested),
                OldestCreatedAt: values.Count == 0 ? null : values.Min(x => x.CreatedAt),
                NewestCreatedAt: values.Count == 0 ? null : values.Max(x => x.CreatedAt)
            );
        }
    }

    public ExecutionJobCancelResult Cancel(Guid id, string? reason)
    {
        var utc = DateTimeOffset.UtcNow;
        var normalizedReason = NormalizeReason(reason);
        ExecutionJobCancelResult result;
        AuditEntry? audit = null;

        lock (_sync)
        {
            if (!_jobs.TryGetValue(id, out var record))
            {
                return new ExecutionJobCancelResult(
                    ExecutionJobCancelStatus.NotFound,
                    "Job not found.",
                    null);
            }

            switch (record.Status)
            {
                case ExecutionJobStatus.Queued:
                    ApplyCanceledLocked(record, utc, normalizedReason ?? "Canceled before execution started.");
                    PersistLocked(changed: true);
                    result = new ExecutionJobCancelResult(
                        ExecutionJobCancelStatus.Canceled,
                        "Queued job canceled.",
                        record.Status);
                    audit = new AuditEntry(utc, "job", "job.canceled", id, result.Message);
                    break;

                case ExecutionJobStatus.Running:
                    if (!record.CancellationRequested)
                    {
                        record.CancellationRequested = true;
                        record.CancellationRequestedAt = utc;
                        record.CancellationReason = normalizedReason ?? "Cancellation requested by user.";
                        PersistLocked(changed: true);
                    }

                    result = new ExecutionJobCancelResult(
                        ExecutionJobCancelStatus.CancellationRequested,
                        "Cancellation requested for running job. Stop is best-effort.",
                        record.Status);
                    audit = new AuditEntry(utc, "job", "job.cancel_requested", id, result.Message);
                    break;

                case ExecutionJobStatus.Succeeded:
                case ExecutionJobStatus.Failed:
                case ExecutionJobStatus.Canceled:
                    result = new ExecutionJobCancelResult(
                        ExecutionJobCancelStatus.AlreadyCompleted,
                        "Job already completed.",
                        record.Status);
                    break;

                default:
                    result = new ExecutionJobCancelResult(
                        ExecutionJobCancelStatus.AlreadyCompleted,
                        "Job already completed.",
                        record.Status);
                    break;
            }
        }

        if (audit is not null)
        {
            _auditTrail.Write(audit);
        }

        return result;
    }

    public bool IsCancellationRequested(Guid id)
    {
        lock (_sync)
        {
            return _jobs.TryGetValue(id, out var record) && record.CancellationRequested;
        }
    }

    public ValueTask<Guid> DequeueAsync(CancellationToken cancellationToken)
    {
        return _channel.Reader.ReadAsync(cancellationToken);
    }

    public bool TryMarkRunning(Guid id, out SubmitJobRequest? request)
    {
        request = null;
        AuditEntry? audit = null;

        lock (_sync)
        {
            if (!_jobs.TryGetValue(id, out var record))
            {
                return false;
            }

            if (record.Status != ExecutionJobStatus.Queued)
            {
                return false;
            }

            record.Status = ExecutionJobStatus.Running;
            record.StartedAt = DateTimeOffset.UtcNow;
            request = record.Request;
            PersistLocked(changed: true);
            audit = new AuditEntry(record.StartedAt.Value, "job", "job.running", id);
        }

        if (audit is not null)
        {
            _auditTrail.Write(audit);
        }

        return true;
    }

    public bool TryMarkCanceled(Guid id, string? reason)
    {
        AuditEntry? audit = null;
        var utc = DateTimeOffset.UtcNow;

        lock (_sync)
        {
            if (!_jobs.TryGetValue(id, out var record))
            {
                return false;
            }

            if (record.Status is ExecutionJobStatus.Succeeded or ExecutionJobStatus.Failed or ExecutionJobStatus.Canceled)
            {
                return false;
            }

            ApplyCanceledLocked(record, utc, NormalizeReason(reason) ?? "Canceled.");
            PersistLocked(changed: true);
            audit = new AuditEntry(utc, "job", "job.canceled", id, record.CancellationReason);
        }

        if (audit is not null)
        {
            _auditTrail.Write(audit);
        }

        return true;
    }

    public bool TryMarkSucceeded(Guid id, ExecuteResult result, IReadOnlyList<ValidationIssue> issues)
    {
        AuditEntry? audit = null;

        lock (_sync)
        {
            if (!_jobs.TryGetValue(id, out var record))
            {
                return false;
            }

            if (record.Status == ExecutionJobStatus.Canceled)
            {
                return false;
            }

            record.Status = ExecutionJobStatus.Succeeded;
            record.Result = result;
            record.PlanIssues = issues.ToArray();
            record.Error = null;
            record.CompletedAt = DateTimeOffset.UtcNow;
            PersistLocked(changed: true);
            audit = new AuditEntry(
                record.CompletedAt.Value,
                "job",
                "job.succeeded",
                id,
                record.CancellationRequested
                    ? "Completed after cancellation was requested."
                    : null);
        }

        if (audit is not null)
        {
            _auditTrail.Write(audit);
        }

        return true;
    }

    public bool TryMarkFailed(Guid id, string error, IReadOnlyList<ValidationIssue> issues)
    {
        AuditEntry? audit = null;

        lock (_sync)
        {
            if (!_jobs.TryGetValue(id, out var record))
            {
                return false;
            }

            if (record.Status == ExecutionJobStatus.Canceled)
            {
                return false;
            }

            record.Status = ExecutionJobStatus.Failed;
            record.Error = error;
            record.PlanIssues = issues.ToArray();
            record.CompletedAt = DateTimeOffset.UtcNow;
            PersistLocked(changed: true);
            audit = new AuditEntry(record.CompletedAt.Value, "job", "job.failed", id, error);
        }

        if (audit is not null)
        {
            _auditTrail.Write(audit);
        }

        return true;
    }

    private static string ResolveStoreDirectory(string configuredPath, string contentRootPath)
    {
        if (string.IsNullOrWhiteSpace(configuredPath))
        {
            configuredPath = ".datahz-jobs";
        }

        return Path.IsPathRooted(configuredPath)
            ? configuredPath
            : Path.GetFullPath(Path.Combine(contentRootPath, configuredPath));
    }

    private void LoadFromDisk()
    {
        if (!File.Exists(_storeFilePath))
        {
            return;
        }

        ExecutionJobSnapshot? snapshot;
        try
        {
            var text = File.ReadAllText(_storeFilePath);
            snapshot = JsonSerializer.Deserialize<ExecutionJobSnapshot>(text, JsonOptions);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Failed to load job store file {Path}.", _storeFilePath);
            return;
        }

        if (snapshot?.Jobs is null || snapshot.Jobs.Count == 0)
        {
            return;
        }

        var pending = new List<Guid>();
        lock (_sync)
        {
            var changed = false;
            foreach (var raw in snapshot.Jobs.OrderBy(x => x.CreatedAt))
            {
                if (raw.Request is null)
                {
                    changed = true;
                    continue;
                }

                var normalized = Clone(raw);
                if (normalized.Status == ExecutionJobStatus.Running)
                {
                    normalized.Status = ExecutionJobStatus.Queued;
                    normalized.StartedAt = null;
                    normalized.CompletedAt = null;
                    normalized.Error = "Recovered after service restart; re-queued.";
                    changed = true;
                }

                _jobs[normalized.Id] = normalized;
            }

            changed |= PruneExpiredJobsLocked(force: true);
            PersistLocked(changed);

            foreach (var item in _jobs.Values
                         .Where(x => x.Status == ExecutionJobStatus.Queued)
                         .OrderBy(x => x.CreatedAt))
            {
                pending.Add(item.Id);
            }
        }

        foreach (var id in pending)
        {
            _channel.Writer.TryWrite(id);
        }
    }

    private bool PruneExpiredJobsLocked(bool force = false)
    {
        var now = DateTimeOffset.UtcNow;
        if (!force && now - _lastPrunedAt < TimeSpan.FromMinutes(1))
        {
            return false;
        }

        _lastPrunedAt = now;
        var cutoff = now - _retention;
        var expired = _jobs
            .Where(pair => pair.Value.CompletedAt is DateTimeOffset completed && completed < cutoff)
            .Select(pair => pair.Key)
            .ToList();

        if (expired.Count == 0)
        {
            return false;
        }

        foreach (var id in expired)
        {
            _jobs.Remove(id);
        }

        _logger.LogInformation("Removed {Count} expired job records.", expired.Count);
        return true;
    }

    private void PersistLocked(bool changed)
    {
        if (!changed)
        {
            return;
        }

        var snapshot = new ExecutionJobSnapshot
        {
            SavedAt = DateTimeOffset.UtcNow,
            Jobs = _jobs.Values
                .OrderBy(x => x.CreatedAt)
                .Select(Clone)
                .ToList()
        };

        var temp = _storeFilePath + ".tmp";
        var text = JsonSerializer.Serialize(snapshot, JsonOptions);
        File.WriteAllText(temp, text);
        File.Move(temp, _storeFilePath, overwrite: true);
    }

    private static void ApplyCanceledLocked(ExecutionJobRecord record, DateTimeOffset utc, string reason)
    {
        record.Status = ExecutionJobStatus.Canceled;
        record.CancellationRequested = true;
        record.CancellationRequestedAt ??= utc;
        record.CancellationReason = reason;
        record.CompletedAt = utc;
        record.Error = reason;
    }

    private static string? NormalizeReason(string? reason)
    {
        if (string.IsNullOrWhiteSpace(reason))
        {
            return null;
        }

        return reason.Trim();
    }

    private static string? NormalizeIdempotencyKey(string? key)
    {
        if (string.IsNullOrWhiteSpace(key))
        {
            return null;
        }

        var normalized = key.Trim();
        if (normalized.Length > 128)
        {
            normalized = normalized[..128];
        }

        return normalized;
    }

    private static ExecutionJobRecord Clone(ExecutionJobRecord source)
    {
        return new ExecutionJobRecord
        {
            Id = source.Id,
            Request = source.Request,
            Status = source.Status,
            CreatedAt = source.CreatedAt,
            StartedAt = source.StartedAt,
            CompletedAt = source.CompletedAt,
            CancellationRequested = source.CancellationRequested,
            CancellationRequestedAt = source.CancellationRequestedAt,
            CancellationReason = source.CancellationReason,
            PlanIssues = source.PlanIssues?.ToArray(),
            Result = source.Result,
            Error = source.Error
        };
    }
}

internal sealed class ExecutionJobSnapshot
{
    public DateTimeOffset SavedAt { get; set; }
    public List<ExecutionJobRecord> Jobs { get; set; } = [];
}
