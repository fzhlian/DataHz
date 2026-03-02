using DataHz.Core.Domain;

namespace DataHz.Infrastructure.Services;

internal static class AccessSqlComposer
{
    public static string BuildColumnSql(TemplateDefinition template, ColumnRule rule, string code, string name)
    {
        if (string.IsNullOrWhiteSpace(rule.Sql))
        {
            return string.Empty;
        }

        return template.NameType switch
        {
            NameType.SingleDatabaseWithTablePerCode => BuildNameType3(rule, code),
            NameType.SingleDatabaseWithCodeField => BuildNameType4(template, rule, code),
            _ => PlaceholderResolver.Resolve(rule.Sql, code, name)
        };
    }

    public static string Resolve(string sql, string code, string name)
    {
        return PlaceholderResolver.Resolve(sql, code, name);
    }

    private static string BuildNameType3(ColumnRule rule, string code)
    {
        var sql = $"{rule.Sql} [{code}]";
        if (!string.IsNullOrWhiteSpace(rule.Sql2))
        {
            sql += $" WHERE {rule.Sql2}";
        }

        return sql;
    }

    private static string BuildNameType4(TemplateDefinition template, ColumnRule rule, string code)
    {
        var field = string.IsNullOrWhiteSpace(template.FieldName) ? "LEFT(BGHZLDWDM,6)" : template.FieldName;
        var where = string.IsNullOrWhiteSpace(rule.Sql2) ? "1=1" : rule.Sql2;
        return $"{rule.Sql} WHERE ({where}) AND {field}=\"{code}\"";
    }
}
