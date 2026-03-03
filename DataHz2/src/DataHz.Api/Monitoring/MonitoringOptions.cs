namespace DataHz.Api.Monitoring;

public sealed class MonitoringOptions
{
    public int DefaultJobTake { get; set; } = 20;
    public int MaxJobTake { get; set; } = 200;
    public int DefaultAuditTake { get; set; } = 60;
    public int MaxAuditTake { get; set; } = 500;
}
