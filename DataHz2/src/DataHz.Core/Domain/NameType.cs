namespace DataHz.Core.Domain;

public enum NameType
{
    CodeNameFile = 1,
    PatternWithCode = 2,
    SingleDatabaseWithTablePerCode = 3,
    SingleDatabaseWithCodeField = 4,
    SingleDatabaseTemplateDriven = 11,
    MultiDatabaseTemplateDriven = 12,
    MultiDatabaseDetailSummary = 13,
    MultiDatabaseDetailCountyOnly = 14
}
