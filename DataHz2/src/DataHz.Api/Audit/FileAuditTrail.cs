using System.Text.Json;
using Microsoft.Extensions.Options;

namespace DataHz.Api.Audit;

public interface IAuditTrail
{
    void Write(AuditEntry entry);
}

public sealed class FileAuditTrail : IAuditTrail
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    private readonly object _sync = new();
    private readonly ILogger<FileAuditTrail> _logger;
    private readonly bool _enabled;
    private readonly string _filePath;

    public FileAuditTrail(
        IOptions<AuditOptions> options,
        IHostEnvironment hostEnvironment,
        ILogger<FileAuditTrail> logger)
    {
        _logger = logger;
        var value = options.Value;
        _enabled = value.Enabled;
        _filePath = ResolveFilePath(value.FilePath, hostEnvironment.ContentRootPath);

        if (_enabled)
        {
            var directory = Path.GetDirectoryName(_filePath);
            if (!string.IsNullOrWhiteSpace(directory))
            {
                Directory.CreateDirectory(directory);
            }
        }
    }

    public void Write(AuditEntry entry)
    {
        if (!_enabled)
        {
            return;
        }

        try
        {
            var line = JsonSerializer.Serialize(entry, JsonOptions);
            lock (_sync)
            {
                File.AppendAllText(_filePath, line + Environment.NewLine);
            }
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Failed to append audit entry.");
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
