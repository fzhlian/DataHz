using DataHz.Core.Abstractions;
using DataHz.Core.Execution;

namespace DataHz.Infrastructure.Services;

public sealed class DryRunExecutionEngine : IExecutionEngine
{
    public ExecuteResult Execute(ExecuteRequest request)
    {
        var logs = new List<string>();
        var errors = new List<string>();

        var existing = request.Plan.Counties.Count(c => c.Exists);
        var missing = request.Plan.Counties.Count - existing;

        logs.Add($"Template: {request.Plan.Template.TemplateName}");
        logs.Add($"Mode: {(request.DryRun ? "dry-run" : "execute")}");
        logs.Add($"Counties: {request.Plan.Counties.Count}");
        logs.Add($"Existing DB: {existing}");
        logs.Add($"Missing DB: {missing}");

        if (!request.DryRun)
        {
            errors.Add("Execution mode is reserved for phase-2. Current build supports planning and validation only.");
        }

        return new ExecuteResult(
            Success: request.DryRun && errors.Count == 0,
            TotalCounties: request.Plan.Counties.Count,
            ExistingDatabases: existing,
            MissingDatabases: missing,
            ProcessedCounties: 0,
            CachedCounties: 0,
            OutputFiles: Array.Empty<string>(),
            Logs: logs,
            Errors: errors);
    }
}
