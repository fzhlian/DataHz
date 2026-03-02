using DataHz.Core.Abstractions;
using DataHz.Core.Domain;

namespace DataHz.Infrastructure.Parsing;

public sealed class LegacyIniTemplateParser : ITemplateParser
{
    public TemplateDefinition Parse(string templatePath)
    {
        if (!File.Exists(templatePath))
        {
            throw new FileNotFoundException("Template file not found.", templatePath);
        }

        var extension = Path.GetExtension(templatePath);
        if (!string.Equals(extension, ".ini", StringComparison.OrdinalIgnoreCase))
        {
            throw new NotSupportedException($"Template extension '{extension}' is not supported by INI parser.");
        }

        var ini = IniDocument.Parse(templatePath);

        var columnCount = ParseInt(ini.GetValue("TableInfo", "ColCount"));
        var viewCount = ParseInt(ini.GetValue("TableInfo", "ViewCount"));
        var checkCount = ParseInt(ini.GetValue("TableInfo", "CheckCount"));
        var nameTypeRaw = ParseInt(ini.GetValue("TableInfo", "NameType"), 12);

        var columns = new List<ColumnRule>();
        for (var i = 0; i <= columnCount; i++)
        {
            var section = $"Col{i}";
            var caption = ini.GetValue(section, "Caption");
            var sql = ini.GetValue(section, "SQL");
            var sql2 = ini.GetValue(section, "SQL2");
            if (string.IsNullOrWhiteSpace(caption) && string.IsNullOrWhiteSpace(sql) && string.IsNullOrWhiteSpace(sql2))
            {
                continue;
            }

            columns.Add(new ColumnRule(i, caption, sql, sql2));
        }

        var views = new List<ViewRule>();
        for (var i = 0; i <= viewCount; i++)
        {
            var section = $"View{i}";
            var viewName = ini.GetValue(section, "ViewName");
            var viewSql = ini.GetValue(section, "ViewSQL");
            var templateFile = ini.GetValue(section, "Templet");
            var targetFile = ini.GetValue(section, "TagetName");
            var range = ini.GetValue(section, "Range");
            if (string.IsNullOrWhiteSpace(viewName) && string.IsNullOrWhiteSpace(viewSql))
            {
                continue;
            }

            views.Add(new ViewRule(i, viewName, viewSql, templateFile, targetFile, range));
        }

        var checks = new List<LogicCheckRule>();
        for (var i = 0; i <= checkCount; i++)
        {
            var section = $"LogicCheck{i}";
            var sql = ini.GetValue(section, "CheckSQL");
            var tip = ini.GetValue(section, "CheckTip");
            if (string.IsNullOrWhiteSpace(sql) && string.IsNullOrWhiteSpace(tip))
            {
                continue;
            }

            checks.Add(new LogicCheckRule(i, sql, tip));
        }

        return new TemplateDefinition
        {
            TemplateName = Path.GetFileName(templatePath),
            TemplatePath = templatePath,
            DatabaseName = ini.GetValue("TableInfo", "DatabaseName"),
            NameType = Enum.IsDefined(typeof(NameType), nameTypeRaw)
                ? (NameType)nameTypeRaw
                : NameType.MultiDatabaseTemplateDriven,
            DatabasePassword = ini.GetValue("TableInfo", "DatabasePWD"),
            XzCodeStart = ParseInt(ini.GetValue("TableInfo", "XZCodeStart")),
            CreatJcb = ParseInt(ini.GetValue("TableInfo", "CreatJCB")),
            FieldName = ini.GetValue("TableInfo", "FieldName", "LEFT(BGHZLDWDM,6)"),
            TableName = ini.GetValue("TableInfo", "TableName"),
            ColumnCount = columnCount,
            ViewCount = viewCount,
            CheckCount = checkCount,
            CheckSql = ini.GetValue("Check", "SQL"),
            CheckErrorInfo = ini.GetValue("Check", "ErrInfo"),
            CheckStop = ParseInt(ini.GetValue("Check", "CheckStop")) != 0,
            Columns = columns,
            Views = views,
            LogicChecks = checks
        };
    }

    private static int ParseInt(string? value, int defaultValue = 0)
    {
        return int.TryParse(value, out var number) ? number : defaultValue;
    }
}
