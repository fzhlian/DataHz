using DataHz.Core.Abstractions;
using DataHz.Infrastructure.Parsing;
using DataHz.Infrastructure.Services;
using Microsoft.Extensions.DependencyInjection;

namespace DataHz.Infrastructure;

public static class ServiceCollectionExtensions
{
    public static IServiceCollection AddDataHzInfrastructure(this IServiceCollection services)
    {
        services.AddSingleton<LegacyIniTemplateParser>();
        services.AddSingleton<LegacyXlsxTemplateParser>();
        services.AddSingleton<ITemplateParser, CompositeTemplateParser>();

        services.AddSingleton<IAreaCodeProvider, TextAreaCodeProvider>();
        services.AddSingleton<IDatabasePathStrategy, DefaultDatabasePathStrategy>();
        services.AddSingleton<IFileSystem, SystemFileSystem>();
        services.AddSingleton<ITaskPlanner, DefaultTaskPlanner>();
        services.AddSingleton<IExecutionEngine, AccessExecutionEngine>();

        return services;
    }
}
