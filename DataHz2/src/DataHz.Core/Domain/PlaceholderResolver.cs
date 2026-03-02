namespace DataHz.Core.Domain;

public static class PlaceholderResolver
{
    public const string CodeToken = "\\\\";
    public const string NameToken = "::";

    public static string Resolve(string text, string code, string name)
    {
        if (string.IsNullOrEmpty(text))
        {
            return string.Empty;
        }

        return text.Replace(CodeToken, code, StringComparison.Ordinal)
                   .Replace(NameToken, name, StringComparison.Ordinal);
    }
}
