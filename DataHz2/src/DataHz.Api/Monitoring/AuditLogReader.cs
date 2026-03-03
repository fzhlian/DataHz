using System.Text.Json;
using DataHz.Api.Audit;
using Microsoft.Extensions.Options;

namespace DataHz.Api.Monitoring;

public sealed record AuditQuery(
    int Take,
    DateTimeOffset? FromUtc = null,
    DateTimeOffset? ToUtc = null,
    string? Category = null,
    string? Action = null,
    Guid? JobId = null
);

public interface IAuditLogReader
{
    IReadOnlyList<AuditEntry> ReadRecent(int take);
    IReadOnlyList<AuditEntry> ReadByJob(Guid jobId, int take);
    IReadOnlyList<AuditEntry> Query(AuditQuery query);
}

public sealed class FileAuditLogReader : IAuditLogReader
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    private readonly ILogger<FileAuditLogReader> _logger;
    private readonly string _filePath;
    private readonly int _maxAuditTake;

    public FileAuditLogReader(
        IOptions<AuditOptions> auditOptions,
        IOptions<MonitoringOptions> monitoringOptions,
        IHostEnvironment hostEnvironment,
        ILogger<FileAuditLogReader> logger)
    {
        _logger = logger;

        var audit = auditOptions.Value;
        _filePath = ResolveFilePath(audit.FilePath, hostEnvironment.ContentRootPath);

        var max = monitoringOptions.Value.MaxAuditTake;
        _maxAuditTake = Math.Max(1, max);
    }

    public IReadOnlyList<AuditEntry> ReadRecent(int take)
    {
        return Query(new AuditQuery(take));
    }

    public IReadOnlyList<AuditEntry> ReadByJob(Guid jobId, int take)
    {
        return Query(new AuditQuery(take, JobId: jobId));
    }

    public IReadOnlyList<AuditEntry> Query(AuditQuery query)
    {
        return ReadEntries(query);
    }

    private AuditEntry? TryParse(string line)
    {
        if (string.IsNullOrWhiteSpace(line))
        {
            return null;
        }

        try
        {
            var entry = JsonSerializer.Deserialize<AuditEntry>(line, JsonOptions);
            if (entry is null ||
                string.IsNullOrWhiteSpace(entry.Category) ||
                string.IsNullOrWhiteSpace(entry.Action))
            {
                return null;
            }

            return entry;
        }
        catch
        {
            return null;
        }
    }

    private IReadOnlyList<AuditEntry> ReadEntries(AuditQuery query)
    {
        if (!File.Exists(_filePath))
        {
            return [];
        }

        var limit = Math.Min(_maxAuditTake, Math.Max(1, query.Take));
        var category = query.Category?.Trim();
        var action = query.Action?.Trim();

        try
        {
            return File.ReadLines(_filePath)
                .Select(TryParse)
                .Where(x => x is not null)
                .Select(x => x!)
                .Where(x => query.FromUtc is null || x.Utc >= query.FromUtc.Value)
                .Where(x => query.ToUtc is null || x.Utc <= query.ToUtc.Value)
                .Where(x => string.IsNullOrWhiteSpace(category) || string.Equals(x.Category, category, StringComparison.OrdinalIgnoreCase))
                .Where(x => string.IsNullOrWhiteSpace(action) || string.Equals(x.Action, action, StringComparison.OrdinalIgnoreCase))
                .Where(x => query.JobId is null || x.JobId == query.JobId)
                .TakeLast(limit)
                .OrderByDescending(x => x.Utc)
                .ToList();
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Failed to read audit log from {Path}.", _filePath);
            return [];
        }
    }

    private static string ResolveFilePath(string configuredPath, string contentRootPath)
    {
        if (string.IsNullOrWhiteSpace(configuredPath))
        {
            configuredPath = ".datahz-jobs\\audit.log";
        }

        return Path.IsPathRooted(configuredPath)
            ? configuredPath
            : Path.GetFullPath(Path.Combine(contentRootPath, configuredPath));
    }
}
