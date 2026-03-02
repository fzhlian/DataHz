using System.Text;

namespace DataHz.Infrastructure.Parsing;

internal static class FileEncodingReader
{
    public static string[] ReadAllLines(string path)
    {
        // Prefer UTF-8 with BOM, then UTF-8, then GB18030 for legacy Chinese text files.
        foreach (var encoding in GetCandidates())
        {
            try
            {
                return File.ReadAllLines(path, encoding);
            }
            catch
            {
                // Try next encoding.
            }
        }

        return File.ReadAllLines(path);
    }

    private static IEnumerable<Encoding> GetCandidates()
    {
        yield return new UTF8Encoding(encoderShouldEmitUTF8Identifier: true);
        yield return new UTF8Encoding(encoderShouldEmitUTF8Identifier: false);

        try
        {
            Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
            yield return Encoding.GetEncoding("GB18030");
        }
        catch
        {
            // Ignore when code page is unavailable.
        }
    }
}
