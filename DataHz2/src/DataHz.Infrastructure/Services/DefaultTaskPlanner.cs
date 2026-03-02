using DataHz.Core.Abstractions;
using DataHz.Core.Domain;
using DataHz.Core.Execution;

namespace DataHz.Infrastructure.Services;

public sealed class DefaultTaskPlanner(
    ITemplateParser templateParser,
    IAreaCodeProvider areaCodeProvider,
    IDatabasePathStrategy databasePathStrategy,
    IFileSystem fileSystem) : ITaskPlanner
{
    public AggregationPlan BuildPlan(PlanningRequest request)
    {
        var issues = new List<ValidationIssue>();

        var template = templateParser.Parse(request.TemplatePath);
        var areaCodes = areaCodeProvider.Load(request.AreaCodePath);

        if (!fileSystem.DirectoryExists(request.SourceDirectory))
        {
            issues.Add(new ValidationIssue("SourceDirectory", $"Directory not found: {request.SourceDirectory}"));
        }

        if (!fileSystem.DirectoryExists(request.TargetDirectory))
        {
            issues.Add(new ValidationIssue("TargetDirectory", $"Directory not found: {request.TargetDirectory}"));
        }

        if (request.StartIndex < 0)
        {
            issues.Add(new ValidationIssue("StartIndex", "StartIndex must be >= 0."));
        }

        if (request.EndIndex < request.StartIndex)
        {
            issues.Add(new ValidationIssue("EndIndex", "EndIndex must be >= StartIndex."));
        }

        var start = Math.Max(0, request.StartIndex);
        var end = Math.Min(request.EndIndex, areaCodes.Count - 1);
        var plans = new List<CountyTaskPlan>();

        for (var i = start; i <= end; i++)
        {
            var area = areaCodes[i];
            var fileName = databasePathStrategy.ResolveDatabaseFileName(template, area);
            var fullPath = Path.Combine(request.SourceDirectory, fileName);
            var exists = fileSystem.FileExists(fullPath);

            if (!exists)
            {
                issues.Add(new ValidationIssue(area.Code, $"Database missing: {fileName}"));
            }

            plans.Add(new CountyTaskPlan(i, area, fileName, fullPath, exists));
        }

        return new AggregationPlan(
            template,
            request.SourceDirectory,
            request.TargetDirectory,
            request.AreaCodePath,
            plans,
            issues);
    }
}
