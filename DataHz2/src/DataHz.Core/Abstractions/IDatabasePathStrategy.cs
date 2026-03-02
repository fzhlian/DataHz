using DataHz.Core.Domain;

namespace DataHz.Core.Abstractions;

public interface IDatabasePathStrategy
{
    string ResolveDatabaseFileName(TemplateDefinition template, AreaCodeItem area);
}
