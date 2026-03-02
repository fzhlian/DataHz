using DataHz.Api.Contracts;
using DataHz.Core.Abstractions;
using DataHz.Core.Execution;
using DataHz.Infrastructure;
using System.Text;

Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddEndpointsApiExplorer();
builder.Services.AddSwaggerGen();
builder.Services.AddDataHzInfrastructure();

var app = builder.Build();

app.UseSwagger();
app.UseSwaggerUI();

app.MapGet("/health", () => Results.Ok(new
{
    status = "ok",
    service = "DataHz.Api",
    utc = DateTimeOffset.UtcNow
}));

app.MapPost("/api/templates/parse", (ParseTemplateRequest request, ITemplateParser parser) =>
{
    try
    {
        var template = parser.Parse(request.TemplatePath);
        return Results.Ok(new
        {
            template.TemplateName,
            NameType = template.NameType.ToString(),
            template.DatabaseName,
            template.TableName,
            template.ColumnCount,
            template.ViewCount,
            template.CheckCount,
            Columns = template.Columns.Select(c => new { c.Index, c.Caption, c.Sql }).ToArray(),
            Views = template.Views.Select(v => new { v.Index, v.ViewName, v.TemplateFile, v.TargetFile, v.Range }).ToArray()
        });
    }
    catch (Exception ex)
    {
        return Results.BadRequest(new { message = ex.Message });
    }
});

app.MapPost("/api/tasks/plan", (PlanTasksRequest request, ITaskPlanner planner) =>
{
    try
    {
        var plan = planner.BuildPlan(new PlanningRequest(
            request.TemplatePath,
            request.SourceDirectory,
            request.TargetDirectory,
            request.AreaCodePath,
            request.StartIndex,
            request.EndIndex));

        return Results.Ok(new
        {
            Template = new
            {
                plan.Template.TemplateName,
                NameType = plan.Template.NameType.ToString(),
                plan.Template.DatabaseName,
                plan.Template.TableName
            },
            plan.Counties,
            plan.Issues
        });
    }
    catch (Exception ex)
    {
        return Results.BadRequest(new { message = ex.Message });
    }
});

app.MapPost("/api/tasks/execute", (ExecuteRequestContract request, ITaskPlanner planner, IExecutionEngine engine) =>
{
    try
    {
        var plan = planner.BuildPlan(new PlanningRequest(
            request.Plan.TemplatePath,
            request.Plan.SourceDirectory,
            request.Plan.TargetDirectory,
            request.Plan.AreaCodePath,
            request.Plan.StartIndex,
            request.Plan.EndIndex));

        var result = engine.Execute(new ExecuteRequest(plan, request.DryRun));
        return Results.Ok(new { plan.Issues, result });
    }
    catch (Exception ex)
    {
        return Results.BadRequest(new { message = ex.Message });
    }
});

app.Run();
