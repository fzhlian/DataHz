using DataHz.Core.Abstractions;
using DataHz.Core.Domain;

namespace DataHz.Infrastructure.Parsing;

public sealed class CompositeTemplateParser(
    LegacyIniTemplateParser iniParser,
    LegacyXlsxTemplateParser xlsxParser) : ITemplateParser
{
    public TemplateDefinition Parse(string templatePath)
    {
        var ext = Path.GetExtension(templatePath);
        if (string.Equals(ext, ".ini", StringComparison.OrdinalIgnoreCase))
        {
            return iniParser.Parse(templatePath);
        }

        if (string.Equals(ext, ".xlsx", StringComparison.OrdinalIgnoreCase))
        {
            return xlsxParser.Parse(templatePath);
        }

        if (string.Equals(ext, ".xls", StringComparison.OrdinalIgnoreCase))
        {
            throw new NotSupportedException(".xls templates are not supported in this build. Please convert to .xlsx.");
        }

        throw new NotSupportedException($"Unsupported template extension: {ext}");
    }
}
