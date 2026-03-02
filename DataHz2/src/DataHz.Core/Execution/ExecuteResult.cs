namespace DataHz.Core.Execution;

public sealed record ExecuteRequest(
    AggregationPlan Plan,
    bool DryRun = true,
    bool Incremental = true
);

public sealed record ExecuteResult(
    bool Success,
    int TotalCounties,
    int ExistingDatabases,
    int MissingDatabases,
    int ProcessedCounties,
    int CachedCounties,
    IReadOnlyList<string> OutputFiles,
    IReadOnlyList<string> Logs,
    IReadOnlyList<string> Errors
);
