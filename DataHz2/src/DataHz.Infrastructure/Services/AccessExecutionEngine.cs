using ClosedXML.Excel;
using DataHz.Core.Abstractions;
using DataHz.Core.Domain;
using DataHz.Core.Execution;
using System.Data.OleDb;
using System.Globalization;

namespace DataHz.Infrastructure.Services;

public sealed class AccessExecutionEngine : IExecutionEngine
{
    public ExecuteResult Execute(ExecuteRequest request)
    {
        var plan = request.Plan;
        var logs = new List<string>();
        var errors = new List<string>();
        var outputFiles = new List<string>();

        var existing = plan.Counties.Count(c => c.Exists);
        var missing = plan.Counties.Count - existing;
        var processed = 0;
        var cached = 0;

        logs.Add($"Template: {plan.Template.TemplateName}");
        logs.Add($"Mode: {(request.DryRun ? "dry-run" : "execute")}");
        logs.Add($"Incremental: {request.Incremental}");
        logs.Add($"Counties: {plan.Counties.Count}");

        if (request.DryRun)
        {
            return new ExecuteResult(
                Success: true,
                TotalCounties: plan.Counties.Count,
                ExistingDatabases: existing,
                MissingDatabases: missing,
                ProcessedCounties: processed,
                CachedCounties: cached,
                OutputFiles: outputFiles,
                Logs: logs,
                Errors: errors);
        }

        try
        {
            Directory.CreateDirectory(plan.TargetDirectory);
            var stateStore = new ExecutionStateStore(plan.TargetDirectory, plan.Template.TemplateName);
            var templateHash = ExecutionStateStore.ComputeTemplateHash(plan.Template.TemplatePath);

            if (plan.Template.IsFlowTemplate && plan.Template.FlowConfig is not null)
            {
                ExecuteFlowTemplate(plan, request, stateStore, templateHash, logs, errors, outputFiles, ref processed, ref cached);
            }
            else
            {
                ExecuteTabularTemplate(plan, request, stateStore, templateHash, logs, errors, outputFiles, ref processed, ref cached);
            }
        }
        catch (Exception ex)
        {
            errors.Add(ex.Message);
        }

        return new ExecuteResult(
            Success: errors.Count == 0,
            TotalCounties: plan.Counties.Count,
            ExistingDatabases: existing,
            MissingDatabases: missing,
            ProcessedCounties: processed,
            CachedCounties: cached,
            OutputFiles: outputFiles,
            Logs: logs,
            Errors: errors);
    }

    private static void ExecuteTabularTemplate(
        AggregationPlan plan,
        ExecuteRequest request,
        ExecutionStateStore stateStore,
        string templateHash,
        List<string> logs,
        List<string> errors,
        List<string> outputFiles,
        ref int processed,
        ref int cached)
    {
        var columns = plan.Template.Columns
            .Where(c => c.Index > 0)
            .OrderBy(c => c.Index)
            .ToList();

        if (columns.Count == 0)
        {
            columns = plan.Template.Columns.OrderBy(c => c.Index).ToList();
        }

        var rowValues = new Dictionary<string, Dictionary<int, string>>();

        foreach (var county in plan.Counties)
        {
            var values = new Dictionary<int, string>();
            rowValues[county.Area.Code] = values;

            if (!county.Exists)
            {
                continue;
            }

            var sourceTicks = File.GetLastWriteTimeUtc(county.DatabasePath).Ticks;

            if (request.Incremental
                && stateStore.TryLoad(county.Area.Code, out var cachedState)
                && cachedState is not null
                && cachedState.TemplateHash == templateHash
                && cachedState.SourceLastWriteUtcTicks == sourceTicks
                && cachedState.ColumnValues.Count > 0)
            {
                foreach (var item in cachedState.ColumnValues)
                {
                    values[item.Key] = item.Value;
                }

                cached++;
                logs.Add($"{county.Area.Code}{county.Area.Name}: cached");
                continue;
            }

            using var connection = OpenConnection(county.DatabasePath, plan.Template.DatabasePassword);

            try
            {
                PrepareIntermediateTable(connection, plan.Template.CheckSql, county.Area);
                CreateViews(connection, plan.Template, county.Area);

                foreach (var column in columns)
                {
                    var sql = AccessSqlComposer.BuildColumnSql(plan.Template, column, county.Area.Code, county.Area.Name);
                    values[column.Index] = ExecuteColumn(connection, sql, errors, county.Area.Code);
                }

                ExportConfiguredViews(connection, plan, county.Area, outputFiles, errors);

                stateStore.Save(new CountyExecutionState
                {
                    Code = county.Area.Code,
                    Name = county.Area.Name,
                    DatabasePath = county.DatabasePath,
                    SourceLastWriteUtcTicks = sourceTicks,
                    TemplateHash = templateHash,
                    ColumnValues = values,
                    UpdatedUtc = DateTimeOffset.UtcNow
                });

                processed++;
                logs.Add($"{county.Area.Code}{county.Area.Name}: processed");
            }
            catch (Exception ex)
            {
                errors.Add($"{county.Area.Code}{county.Area.Name}: {ex.Message}");
            }
        }

        var tableName = string.IsNullOrWhiteSpace(plan.Template.TableName)
            ? Path.GetFileNameWithoutExtension(plan.Template.TemplateName)
            : plan.Template.TableName;

        var outputPath = Path.Combine(plan.TargetDirectory, $"{tableName}.txt");
        WriteSummaryFile(outputPath, plan.Counties, columns, rowValues);
        outputFiles.Add(outputPath);
    }

    private static void ExecuteFlowTemplate(
        AggregationPlan plan,
        ExecuteRequest request,
        ExecutionStateStore stateStore,
        string templateHash,
        List<string> logs,
        List<string> errors,
        List<string> outputFiles,
        ref int processed,
        ref int cached)
    {
        var flow = plan.Template.FlowConfig!;
        var extension = Path.GetExtension(plan.Template.TemplatePath);

        foreach (var county in plan.Counties)
        {
            if (!county.Exists)
            {
                continue;
            }

            var sourceTicks = File.GetLastWriteTimeUtc(county.DatabasePath).Ticks;
            var countyOutput = Path.Combine(plan.TargetDirectory, $"{county.Area.Code}{county.Area.Name}{extension}");

            if (request.Incremental
                && stateStore.TryLoad(county.Area.Code, out var cachedState)
                && cachedState is not null
                && cachedState.TemplateHash == templateHash
                && cachedState.SourceLastWriteUtcTicks == sourceTicks
                && File.Exists(countyOutput)
                && cachedState.FlowCells.Count > 0)
            {
                cached++;
                outputFiles.Add(countyOutput);
                logs.Add($"{county.Area.Code}{county.Area.Name}: flow cached");
                continue;
            }

            File.Copy(plan.Template.TemplatePath, countyOutput, true);

            using var connection = OpenConnection(county.DatabasePath, plan.Template.DatabasePassword);
            using var workbook = new XLWorkbook(countyOutput);

            var flowCells = new Dictionary<string, double>();

            foreach (var sheet in flow.Sheets)
            {
                if (!string.IsNullOrWhiteSpace(sheet.ViewSql))
                {
                    PrepareIntermediateTable(connection, AccessSqlComposer.Resolve(sheet.ViewSql, county.Area.Code, county.Area.Name), county.Area);
                }

                var ws = workbook.Worksheet(sheet.WriteSheet);

                for (var c = 0; c < sheet.ColSql.Count; c++)
                {
                    for (var r = 0; r < sheet.RowSql.Count; r++)
                    {
                        var rowSql = sheet.RowSql[r];
                        var colSql = sheet.ColSql[c];
                        if (string.IsNullOrWhiteSpace(rowSql) && string.IsNullOrWhiteSpace(colSql))
                        {
                            continue;
                        }

                        var sql = AccessSqlComposer.Resolve($"{rowSql} AND {colSql}", county.Area.Code, county.Area.Name);
                        var value = ExecuteScalarDouble(connection, sql, errors, county.Area.Code);
                        var row = sheet.WriteRow + c;
                        var col = sheet.WriteCol + r;
                        ws.Cell(row, col).Value = value;
                        flowCells[$"{sheet.WriteSheet}:{row}:{col}"] = value;
                    }
                }
            }

            foreach (var idx in flow.DeleteSheets.Distinct().Where(i => i > 0).OrderByDescending(i => i))
            {
                if (idx <= workbook.Worksheets.Count)
                {
                    workbook.Worksheet(idx).Delete();
                }
            }

            workbook.Save();
            outputFiles.Add(countyOutput);

            stateStore.Save(new CountyExecutionState
            {
                Code = county.Area.Code,
                Name = county.Area.Name,
                DatabasePath = county.DatabasePath,
                SourceLastWriteUtcTicks = sourceTicks,
                TemplateHash = templateHash,
                FlowCells = flowCells,
                UpdatedUtc = DateTimeOffset.UtcNow
            });

            processed++;
            logs.Add($"{county.Area.Code}{county.Area.Name}: flow processed");
        }

        BuildFlowRollupFiles(plan, flow, stateStore, outputFiles, errors);
    }

    private static void BuildFlowRollupFiles(
        AggregationPlan plan,
        FlowTemplateConfig flow,
        ExecutionStateStore stateStore,
        List<string> outputFiles,
        List<string> errors)
    {
        try
        {
            var all = stateStore.LoadAll().Where(s => s.FlowCells.Count > 0).ToList();
            if (all.Count == 0)
            {
                return;
            }

            var ext = Path.GetExtension(plan.Template.TemplatePath);
            BuildGroupFile(all.Where(s => s.Code.Length >= 4).GroupBy(s => s.Code[..4]), flow, plan, ext, outputFiles);
            BuildGroupFile(all.Where(s => s.Code.Length >= 2).GroupBy(s => s.Code[..2]), flow, plan, ext, outputFiles);
        }
        catch (Exception ex)
        {
            errors.Add($"Flow rollup failed: {ex.Message}");
        }
    }

    private static void BuildGroupFile(
        IEnumerable<IGrouping<string, CountyExecutionState>> groups,
        FlowTemplateConfig flow,
        AggregationPlan plan,
        string ext,
        List<string> outputFiles)
    {
        foreach (var group in groups)
        {
            var sums = new Dictionary<string, double>();
            foreach (var state in group)
            {
                foreach (var item in state.FlowCells)
                {
                    sums[item.Key] = sums.TryGetValue(item.Key, out var old) ? old + item.Value : item.Value;
                }
            }

            if (sums.Count == 0)
            {
                continue;
            }

            var output = Path.Combine(plan.TargetDirectory, $"{group.Key}{ext}");
            File.Copy(plan.Template.TemplatePath, output, true);

            using var wb = new XLWorkbook(output);
            foreach (var item in sums)
            {
                var parts = item.Key.Split(':');
                if (parts.Length != 3)
                {
                    continue;
                }

                var sheetIndex = int.Parse(parts[0], CultureInfo.InvariantCulture);
                var row = int.Parse(parts[1], CultureInfo.InvariantCulture);
                var col = int.Parse(parts[2], CultureInfo.InvariantCulture);

                if (sheetIndex <= wb.Worksheets.Count)
                {
                    wb.Worksheet(sheetIndex).Cell(row, col).Value = item.Value;
                }
            }

            foreach (var idx in flow.DeleteSheets.Distinct().Where(i => i > 0).OrderByDescending(i => i))
            {
                if (idx <= wb.Worksheets.Count)
                {
                    wb.Worksheet(idx).Delete();
                }
            }

            wb.Save();
            outputFiles.Add(output);
        }
    }

    private static OleDbConnection OpenConnection(string databasePath, string password)
    {
        var connectionString = string.IsNullOrWhiteSpace(password)
            ? $"Provider=Microsoft.ACE.OLEDB.12.0;Data Source={databasePath};Persist Security Info=False"
            : $"Provider=Microsoft.ACE.OLEDB.12.0;Data Source={databasePath};Persist Security Info=False;Jet OLEDB:Database Password={password}";

        var connection = new OleDbConnection(connectionString);
        connection.Open();
        return connection;
    }

    private static void PrepareIntermediateTable(OleDbConnection connection, string sql, AreaCodeItem area)
    {
        if (string.IsNullOrWhiteSpace(sql))
        {
            return;
        }

        sql = AccessSqlComposer.Resolve(sql, area.Code, area.Name);
        if (!sql.Contains(" INTO ", StringComparison.OrdinalIgnoreCase))
        {
            return;
        }

        var tableName = ExtractIntoTable(sql);
        if (!string.IsNullOrWhiteSpace(tableName))
        {
            TryExecuteNonQuery(connection, $"DROP TABLE {tableName}");
        }

        using var cmd = new OleDbCommand(sql, connection);
        cmd.ExecuteNonQuery();
    }

    private static void CreateViews(OleDbConnection connection, TemplateDefinition template, AreaCodeItem area)
    {
        foreach (var view in template.Views)
        {
            if (string.IsNullOrWhiteSpace(view.ViewSql) || string.IsNullOrWhiteSpace(view.ViewName))
            {
                continue;
            }

            var name = AccessSqlComposer.Resolve(view.ViewName, area.Code, area.Name);
            var sql = AccessSqlComposer.Resolve(view.ViewSql, area.Code, area.Name);

            TryExecuteNonQuery(connection, $"DROP VIEW [{name}]");

            using var cmd = new OleDbCommand(sql, connection);
            cmd.ExecuteNonQuery();
        }
    }

    private static string ExecuteColumn(OleDbConnection connection, string sql, List<string> errors, string code)
    {
        if (string.IsNullOrWhiteSpace(sql))
        {
            return string.Empty;
        }

        try
        {
            if (sql.StartsWith("LIST_", StringComparison.OrdinalIgnoreCase))
            {
                var listSql = sql[5..];
                var list = new List<string>();
                using var cmd = new OleDbCommand(listSql, connection);
                using var reader = cmd.ExecuteReader();
                while (reader is not null && reader.Read())
                {
                    if (reader.IsDBNull(0))
                    {
                        continue;
                    }

                    var listValue = NormalizeListValue(reader.GetValue(0).ToString() ?? string.Empty);
                    if (!string.IsNullOrWhiteSpace(listValue))
                    {
                        list.Add(listValue);
                    }
                }

                return string.Join('|', list.Distinct(StringComparer.Ordinal));
            }

            using var scalarCmd = new OleDbCommand(sql, connection);
            var value = scalarCmd.ExecuteScalar();
            if (value is null || value == DBNull.Value)
            {
                return string.Empty;
            }

            return Convert.ToString(value, CultureInfo.InvariantCulture) ?? string.Empty;
        }
        catch (Exception ex)
        {
            errors.Add($"{code}: {ex.Message}");
            return string.Empty;
        }
    }

    private static double ExecuteScalarDouble(OleDbConnection connection, string sql, List<string> errors, string code)
    {
        try
        {
            using var cmd = new OleDbCommand(sql, connection);
            var value = cmd.ExecuteScalar();
            if (value is null || value == DBNull.Value)
            {
                return 0D;
            }

            return Convert.ToDouble(value, CultureInfo.InvariantCulture);
        }
        catch (Exception ex)
        {
            errors.Add($"{code}: {ex.Message}");
            return 0D;
        }
    }

    private static void ExportConfiguredViews(
        OleDbConnection connection,
        AggregationPlan plan,
        AreaCodeItem area,
        List<string> outputFiles,
        List<string> errors)
    {
        foreach (var view in plan.Template.Views)
        {
            if (string.IsNullOrWhiteSpace(view.TemplateFile) || string.IsNullOrWhiteSpace(view.ViewName))
            {
                continue;
            }

            var viewName = AccessSqlComposer.Resolve(view.ViewName, area.Code, area.Name);
            var selectSql = $"SELECT * FROM [{viewName}]";
            var records = new List<object[]>();

            try
            {
                using var cmd = new OleDbCommand(selectSql, connection);
                using var reader = cmd.ExecuteReader();
                if (reader is null)
                {
                    continue;
                }

                while (reader.Read())
                {
                    var row = new object[reader.FieldCount];
                    reader.GetValues(row);
                    records.Add(row);
                }
            }
            catch (Exception ex)
            {
                errors.Add($"{area.Code} export {viewName}: {ex.Message}");
                continue;
            }

            if (records.Count == 0)
            {
                continue;
            }

            var sourceTemplate = Path.Combine(plan.Template.TemplateDirectory, view.TemplateFile);
            if (!File.Exists(sourceTemplate))
            {
                errors.Add($"Template file not found: {sourceTemplate}");
                continue;
            }

            var targetName = string.IsNullOrWhiteSpace(view.TargetFile)
                ? $"{area.Code}_{view.Index}.xlsx"
                : AccessSqlComposer.Resolve(view.TargetFile, area.Code, area.Name);

            var targetPath = Path.Combine(plan.TargetDirectory, targetName);
            Directory.CreateDirectory(Path.GetDirectoryName(targetPath) ?? plan.TargetDirectory);
            File.Copy(sourceTemplate, targetPath, true);

            using var wb = new XLWorkbook(targetPath);
            var ws = wb.Worksheet(1);
            var startCell = string.IsNullOrWhiteSpace(view.Range) ? ws.Cell("A1") : ws.Cell(view.Range);

            for (var r = 0; r < records.Count; r++)
            {
                var row = records[r];
                for (var c = 0; c < row.Length; c++)
                {
                    var cellValue = row[c] == DBNull.Value
                        ? string.Empty
                        : Convert.ToString(row[c], CultureInfo.InvariantCulture) ?? string.Empty;
                    ws.Cell(startCell.Address.RowNumber + r, startCell.Address.ColumnNumber + c).Value = cellValue;
                }
            }

            wb.Save();
            outputFiles.Add(targetPath);
        }
    }

    private static void WriteSummaryFile(
        string outputPath,
        IReadOnlyList<CountyTaskPlan> counties,
        IReadOnlyList<ColumnRule> columns,
        IReadOnlyDictionary<string, Dictionary<int, string>> values)
    {
        using var writer = new StreamWriter(outputPath, false);

        var header = "代码\t单位";
        foreach (var column in columns)
        {
            header += $"\t{column.Caption}";
        }

        writer.WriteLine(header);

        foreach (var county in counties)
        {
            var line = $"{county.Area.Code}\t{county.Area.Name}";
            values.TryGetValue(county.Area.Code, out var row);
            row ??= new Dictionary<int, string>();

            foreach (var column in columns)
            {
                row.TryGetValue(column.Index, out var value);
                line += "\t" + (value ?? string.Empty);
            }

            writer.WriteLine(line);
        }
    }

    private static string NormalizeListValue(string value)
    {
        var chars = value.Where(c => char.IsLetterOrDigit(c) || c == '_' || c == '-').ToArray();
        return new string(chars).ToUpperInvariant();
    }

    private static void TryExecuteNonQuery(OleDbConnection connection, string sql)
    {
        try
        {
            using var cmd = new OleDbCommand(sql, connection);
            cmd.ExecuteNonQuery();
        }
        catch
        {
            // Ignore best-effort DDL.
        }
    }

    private static string ExtractIntoTable(string sql)
    {
        var intoIndex = sql.IndexOf("INTO", StringComparison.OrdinalIgnoreCase);
        if (intoIndex < 0)
        {
            return string.Empty;
        }

        var fromIndex = sql.IndexOf("FROM", intoIndex, StringComparison.OrdinalIgnoreCase);
        if (fromIndex < 0)
        {
            return string.Empty;
        }

        var table = sql[(intoIndex + 4)..fromIndex].Trim();
        return table;
    }
}
