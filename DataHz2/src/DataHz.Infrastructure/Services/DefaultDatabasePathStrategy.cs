using DataHz.Core.Abstractions;
using DataHz.Core.Domain;

namespace DataHz.Infrastructure.Services;

public sealed class DefaultDatabasePathStrategy : IDatabasePathStrategy
{
    public string ResolveDatabaseFileName(TemplateDefinition template, AreaCodeItem area)
    {
        return template.NameType switch
        {
            NameType.CodeNameFile => $"{area.Code}{area.Name}.mdb",
            NameType.PatternWithCode => ResolvePatternWithCode(template, area),
            NameType.SingleDatabaseWithTablePerCode => template.DatabaseName,
            NameType.SingleDatabaseWithCodeField => template.DatabaseName,
            NameType.SingleDatabaseTemplateDriven => template.DatabaseName,
            NameType.MultiDatabaseTemplateDriven => PlaceholderResolver.Resolve(template.DatabaseName, area.Code, area.Name),
            NameType.MultiDatabaseDetailSummary => PlaceholderResolver.Resolve(template.DatabaseName, area.Code, area.Name),
            NameType.MultiDatabaseDetailCountyOnly => PlaceholderResolver.Resolve(template.DatabaseName, area.Code, area.Name),
            _ => PlaceholderResolver.Resolve(template.DatabaseName, area.Code, area.Name)
        };
    }

    private static string ResolvePatternWithCode(TemplateDefinition template, AreaCodeItem area)
    {
        if (template.XzCodeStart <= 0 || template.XzCodeStart > template.DatabaseName.Length)
        {
            return template.DatabaseName;
        }

        var prefix = template.DatabaseName[..(template.XzCodeStart - 1)];
        var suffix = template.DatabaseName[(template.XzCodeStart - 1)..];
        return $"{prefix}{area.Code}{suffix}.mdb";
    }
}
