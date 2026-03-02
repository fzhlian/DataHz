namespace DataHz.Core.Abstractions;

public interface IFileSystem
{
    bool FileExists(string path);
    bool DirectoryExists(string path);
}
