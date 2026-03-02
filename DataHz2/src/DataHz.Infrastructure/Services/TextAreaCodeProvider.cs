using DataHz.Core.Abstractions;
using DataHz.Core.Domain;
using DataHz.Infrastructure.Parsing;

namespace DataHz.Infrastructure.Services;

public sealed class TextAreaCodeProvider : IAreaCodeProvider
{
    public IReadOnlyList<AreaCodeItem> Load(string areaCodePath)
    {
        if (!File.Exists(areaCodePath))
        {
            throw new FileNotFoundException("Area code file not found.", areaCodePath);
        }

        var result = new List<AreaCodeItem>();
        foreach (var raw in FileEncodingReader.ReadAllLines(areaCodePath))
        {
            if (string.IsNullOrWhiteSpace(raw))
            {
                continue;
            }

            var parts = raw.Split('\t');
            if (parts.Length < 2)
            {
                continue;
            }

            var code = parts[0].Trim();
            var name = parts[1].Trim();
            if (code.Length == 0)
            {
                continue;
            }

            result.Add(new AreaCodeItem(code, name));
        }

        return result;
    }
}
