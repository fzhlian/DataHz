using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.Hosting;
using Microsoft.Extensions.Configuration;

namespace DataHz.Api.Tests;

internal sealed class ApiTestFactory : WebApplicationFactory<Program>
{
    private readonly Dictionary<string, string?> _settings = new(StringComparer.OrdinalIgnoreCase);
    private readonly string _tempRoot;

    public ApiTestFactory(Action<Dictionary<string, string?>>? configure = null)
    {
        _tempRoot = Path.Combine(Path.GetTempPath(), "datahz-tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_tempRoot);

        _settings["JobQueue:StoreDirectory"] = Path.Combine(_tempRoot, "jobs");
        _settings["JobQueue:WorkerCount"] = "0";
        _settings["Audit:Enabled"] = "false";
        _settings["Security:ApiKey:Enabled"] = "false";
        _settings["Security:ApiKey:HeaderName"] = "X-Api-Key";
        _settings["Security:ApiKey:Value"] = string.Empty;
        _settings["Security:Jwt:Enabled"] = "false";
        _settings["Security:Jwt:SigningKey"] = string.Empty;
        _settings["Security:Jwt:ValidIssuer"] = string.Empty;
        _settings["Security:Jwt:ValidAudience"] = string.Empty;
        _settings["Security:Jwt:RoleClaimType"] = "role";
        _settings["Security:Jwt:NameClaimType"] = "name";

        configure?.Invoke(_settings);
    }

    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        builder.UseEnvironment("Testing");
        builder.ConfigureAppConfiguration((_, configBuilder) =>
        {
            configBuilder.AddInMemoryCollection(_settings);
        });
    }

    protected override void Dispose(bool disposing)
    {
        base.Dispose(disposing);
        TryCleanup();
    }

    public override async ValueTask DisposeAsync()
    {
        await base.DisposeAsync();
        TryCleanup();
    }

    private void TryCleanup()
    {
        try
        {
            if (Directory.Exists(_tempRoot))
            {
                Directory.Delete(_tempRoot, recursive: true);
            }
        }
        catch
        {
            // Ignore cleanup failures in test tear-down.
        }
    }
}
