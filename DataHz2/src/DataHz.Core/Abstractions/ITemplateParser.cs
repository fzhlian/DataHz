using DataHz.Core.Domain;

namespace DataHz.Core.Abstractions;

public interface ITemplateParser
{
    TemplateDefinition Parse(string templatePath);
}
