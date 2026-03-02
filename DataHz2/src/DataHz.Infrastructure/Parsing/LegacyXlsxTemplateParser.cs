using ClosedXML.Excel;
using DataHz.Core.Abstractions;
using DataHz.Core.Domain;

namespace DataHz.Infrastructure.Parsing;

public sealed class LegacyXlsxTemplateParser : ITemplateParser
{
    public TemplateDefinition Parse(string templatePath)
    {
        if (string.IsNullOrWhiteSpace(templatePath) || !File.Exists(templatePath))
        {
            throw new FileNotFoundException($"Template file not found: '{templatePath}'.", templatePath);
        }

        var extension = Path.GetExtension(templatePath);
        if (!string.Equals(extension, ".xlsx", StringComparison.OrdinalIgnoreCase))
        {
            throw new NotSupportedException($"Template extension '{extension}' is not supported by XLSX parser.");
        }

        using var wb = new XLWorkbook(templatePath);

        if (Path.GetFileName(templatePath).StartsWith("FX_", StringComparison.OrdinalIgnoreCase))
        {
            return ParseFlowTemplate(templatePath, wb);
        }

        return ParseStandardTemplate(templatePath, wb);
    }

    private static TemplateDefinition ParseStandardTemplate(string templatePath, XLWorkbook workbook)
    {
        var ws = workbook.Worksheets.Count >= 2 ? workbook.Worksheet(2) : workbook.Worksheet(1);

        var columnCount = ReadInt(ws.Cell(2, 13));
        var viewCount = ReadInt(ws.Cell(2, 11));
        var nameTypeRaw = ReadInt(ws.Cell(2, 5), 12);

        var columns = new List<ColumnRule>();
        for (var i = 1; i <= columnCount; i++)
        {
            var caption = ReadText(ws.Cell(6 + i, 1));
            var sql = ReadText(ws.Cell(6 + i, 2));
            columns.Add(new ColumnRule(i, caption, sql, string.Empty));
        }

        return new TemplateDefinition
        {
            TemplateName = Path.GetFileName(templatePath),
            TemplatePath = templatePath,
            DatabaseName = ReadText(ws.Cell(2, 3)),
            NameType = Enum.IsDefined(typeof(NameType), nameTypeRaw)
                ? (NameType)nameTypeRaw
                : NameType.MultiDatabaseTemplateDriven,
            DatabasePassword = ReadText(ws.Cell(2, 7)),
            TableName = ReadText(ws.Cell(2, 9)),
            ViewCount = viewCount,
            ColumnCount = columnCount,
            CheckSql = ReadText(ws.Cell(3, 3)),
            CheckErrorInfo = ReadText(ws.Cell(3, 7)),
            CheckStop = ReadInt(ws.Cell(3, 11)) != 0,
            Columns = columns
        };
    }

    private static TemplateDefinition ParseFlowTemplate(string templatePath, XLWorkbook workbook)
    {
        var ws0 = workbook.Worksheet(1);

        var sheetCount = ReadInt(ws0.Cell(2, 2));
        var deleteCount = ReadInt(ws0.Cell(2, 13));
        var sheets = new List<FlowSheetRule>(sheetCount);

        var deleteSheets = new List<int>(deleteCount);
        for (var i = 1; i <= deleteCount; i++)
        {
            deleteSheets.Add(ReadInt(ws0.Cell(4 + i, 13)));
        }

        for (var i = 1; i <= sheetCount; i++)
        {
            var row = 4 + i;
            var configSheet = ReadInt(ws0.Cell(row, 1));
            var rowSqlRow = ReadInt(ws0.Cell(row, 2));
            var rowSqlCol = ReadInt(ws0.Cell(row, 3));
            var rowSqlCount = ReadInt(ws0.Cell(row, 4));
            var colSqlRow = ReadInt(ws0.Cell(row, 5));
            var colSqlCol = ReadInt(ws0.Cell(row, 6));
            var colSqlCount = ReadInt(ws0.Cell(row, 7));
            var writeSheet = ReadInt(ws0.Cell(row, 8));
            var writeRow = ReadInt(ws0.Cell(row, 9));
            var writeCol = ReadInt(ws0.Cell(row, 10));
            var viewSql = ReadText(ws0.Cell(row, 11));

            var wsCfg = workbook.Worksheet(configSheet);
            var rowSql = new List<string>(rowSqlCount);
            var colSql = new List<string>(colSqlCount);

            for (var c = 0; c < rowSqlCount; c++)
            {
                rowSql.Add(ReadText(wsCfg.Cell(rowSqlRow, rowSqlCol + c)));
            }

            for (var r = 0; r < colSqlCount; r++)
            {
                colSql.Add(ReadText(wsCfg.Cell(colSqlRow + r, colSqlCol)));
            }

            sheets.Add(new FlowSheetRule
            {
                ConfigSheet = configSheet,
                WriteSheet = writeSheet,
                WriteRow = writeRow,
                WriteCol = writeCol,
                ViewSql = viewSql,
                RowSql = rowSql,
                ColSql = colSql
            });
        }

        return new TemplateDefinition
        {
            TemplateName = Path.GetFileName(templatePath),
            TemplatePath = templatePath,
            NameType = NameType.MultiDatabaseTemplateDriven,
            DatabaseName = ReadText(ws0.Cell(2, 4)),
            TableName = Path.GetFileNameWithoutExtension(templatePath),
            FlowConfig = new FlowTemplateConfig
            {
                Sheets = sheets,
                DeleteSheets = deleteSheets
            }
        };
    }

    private static string ReadText(IXLCell cell)
    {
        return cell.GetString().Trim();
    }

    private static int ReadInt(IXLCell cell, int defaultValue = 0)
    {
        if (cell.TryGetValue<double>(out var number))
        {
            return Convert.ToInt32(number);
        }

        return int.TryParse(cell.GetString().Trim(), out var value) ? value : defaultValue;
    }
}
