namespace DataHz.Infrastructure.Parsing;

internal sealed class IniDocument
{
    private readonly Dictionary<string, Dictionary<string, string>> _sections =
        new(StringComparer.OrdinalIgnoreCase);

    public static IniDocument Parse(string path)
    {
        var document = new IniDocument();
        var currentSection = string.Empty;

        foreach (var raw in FileEncodingReader.ReadAllLines(path))
        {
            var line = raw.Trim();
            if (line.Length == 0 || line.StartsWith(";", StringComparison.Ordinal))
            {
                continue;
            }

            if (line.StartsWith("[", StringComparison.Ordinal) && line.EndsWith("]", StringComparison.Ordinal))
            {
                currentSection = line[1..^1].Trim();
                document.EnsureSection(currentSection);
                continue;
            }

            var pos = line.IndexOf('=');
            if (pos <= 0)
            {
                continue;
            }

            var key = line[..pos].Trim();
            var value = line[(pos + 1)..].Trim();

            document.EnsureSection(currentSection);
            document._sections[currentSection][key] = value;
        }

        return document;
    }

    public string GetValue(string section, string key, string defaultValue = "")
    {
        if (_sections.TryGetValue(section, out var values) && values.TryGetValue(key, out var value))
        {
            return value;
        }

        return defaultValue;
    }

    private void EnsureSection(string section)
    {
        if (!_sections.ContainsKey(section))
        {
            _sections[section] = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        }
    }
}
