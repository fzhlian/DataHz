using DataHz.Core.Abstractions;
using DataHz.Core.Domain;
using DataHz.Core.Execution;
using Microsoft.Extensions.Options;

namespace DataHz.Api.Jobs;

public sealed class ExecutionJobWorker(
    IExecutionJobQueue queue,
    ITaskPlanner planner,
    IExecutionEngine engine,
    IOptions<ExecutionJobOptions> options,
    ILogger<ExecutionJobWorker> logger) : BackgroundService
{
    protected override Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var configuredCount = options.Value.WorkerCount;
        if (configuredCount <= 0)
        {
            logger.LogWarning("Job worker is disabled because JobQueue.WorkerCount={Count}.", configuredCount);
            return Task.CompletedTask;
        }

        var workerCount = Math.Clamp(configuredCount, 1, 32);
        var loops = Enumerable.Range(1, workerCount)
            .Select(index => RunLoopAsync(index, stoppingToken))
            .ToArray();

        logger.LogInformation("Started {Count} execution worker loops.", workerCount);
        return Task.WhenAll(loops);
    }

    private async Task RunLoopAsync(int workerIndex, CancellationToken stoppingToken)
    {
        while (!stoppingToken.IsCancellationRequested)
        {
            Guid id;
            try
            {
                id = await queue.DequeueAsync(stoppingToken);
            }
            catch (OperationCanceledException)
            {
                break;
            }

            if (!queue.TryMarkRunning(id, out var request) || request is null)
            {
                continue;
            }

            try
            {
                if (queue.IsCancellationRequested(id))
                {
                    queue.TryMarkCanceled(id, "Cancellation requested before planning started.");
                    logger.LogInformation("Worker {WorkerIndex} canceled job {JobId} before planning.", workerIndex, id);
                    continue;
                }

                var plan = planner.BuildPlan(new PlanningRequest(
                    request.Plan.TemplatePath,
                    request.Plan.SourceDirectory,
                    request.Plan.TargetDirectory,
                    request.Plan.AreaCodePath,
                    request.Plan.StartIndex,
                    request.Plan.EndIndex));

                if (queue.IsCancellationRequested(id))
                {
                    queue.TryMarkCanceled(id, "Cancellation requested before execution started.");
                    logger.LogInformation("Worker {WorkerIndex} canceled job {JobId} before execution.", workerIndex, id);
                    continue;
                }

                var result = engine.Execute(new ExecuteRequest(plan, request.DryRun, request.Incremental));
                queue.TryMarkSucceeded(id, result, plan.Issues);

                if (queue.IsCancellationRequested(id))
                {
                    logger.LogWarning(
                        "Worker {WorkerIndex} finished job {JobId} after cancellation request. Engine does not support interruption.",
                        workerIndex,
                        id);
                }
                else
                {
                    logger.LogInformation(
                        "Worker {WorkerIndex} completed job {JobId}. Success={Success}",
                        workerIndex,
                        id,
                        result.Success);
                }
            }
            catch (Exception ex)
            {
                queue.TryMarkFailed(id, ex.Message, Array.Empty<ValidationIssue>());
                logger.LogError(ex, "Worker {WorkerIndex} failed job {JobId}.", workerIndex, id);
            }
        }
    }
}
