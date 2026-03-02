using System.Security.Cryptography;
using System.Text.Json;

namespace DataHz.Infrastructure.Services;

internal sealed class ExecutionStateStore
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true
    };

    private readonly string _storeDirectory;

    public ExecutionStateStore(string targetDirectory, string templateName)
    {
        var safeName = SanitizeFileName(Path.GetFileNameWithoutExtension(templateName));
        _storeDirectory = Path.Combine(targetDirectory, ".datahz-state", safeName);
        Directory.CreateDirectory(_storeDirectory);
    }

    public bool TryLoad(string code, out CountyExecutionState? state)
    {
        var path = GetPath(code);
        state = null;

        if (!File.Exists(path))
        {
            return false;
        }

        var text = File.ReadAllText(path);
        state = JsonSerializer.Deserialize<CountyExecutionState>(text, JsonOptions);
        return state is not null;
    }

    public IReadOnlyList<CountyExecutionState> LoadAll()
    {
        var result = new List<CountyExecutionState>();
        foreach (var file in Directory.EnumerateFiles(_storeDirectory, "*.json"))
        {
            var text = File.ReadAllText(file);
            var state = JsonSerializer.Deserialize<CountyExecutionState>(text, JsonOptions);
            if (state is not null)
            {
                result.Add(state);
            }
        }

        return result;
    }

    public void Save(CountyExecutionState state)
    {
        var path = GetPath(state.Code);
        var text = JsonSerializer.Serialize(state, JsonOptions);
        File.WriteAllText(path, text);
    }

    public static string ComputeTemplateHash(string templatePath)
    {
        using var stream = File.OpenRead(templatePath);
        using var sha = SHA256.Create();
        var hash = sha.ComputeHash(stream);
        return Convert.ToHexString(hash);
    }

    private string GetPath(string code) => Path.Combine(_storeDirectory, $"{SanitizeFileName(code)}.json");

    private static string SanitizeFileName(string name)
    {
        foreach (var c in Path.GetInvalidFileNameChars())
        {
            name = name.Replace(c, '_');
        }

        return name;
    }
}

internal sealed class CountyExecutionState
{
    public string Code { get; init; } = string.Empty;
    public string Name { get; init; } = string.Empty;
    public string DatabasePath { get; init; } = string.Empty;
    public long SourceLastWriteUtcTicks { get; init; }
    public string TemplateHash { get; init; } = string.Empty;
    public Dictionary<int, string> ColumnValues { get; init; } = new();
    public Dictionary<string, double> FlowCells { get; init; } = new();
    public DateTimeOffset UpdatedUtc { get; init; }
}
