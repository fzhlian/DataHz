namespace DataHz.Api.Jobs;

public sealed class ExecutionJobOptions
{
    public string StoreDirectory { get; set; } = ".datahz-jobs";
    public int RetentionDays { get; set; } = 7;
    public int MaxListTake { get; set; } = 200;
    public int WorkerCount { get; set; } = 1;
}
