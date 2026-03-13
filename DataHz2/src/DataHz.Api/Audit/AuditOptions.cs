namespace DataHz.Api.Audit;

public sealed class AuditOptions
{
    public bool Enabled { get; set; } = true;
    public string FilePath { get; set; } = ".datahz-jobs/audit.log";
}
