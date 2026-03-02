using DataHz.Core.Abstractions;

namespace DataHz.Infrastructure.Services;

public sealed class SystemFileSystem : IFileSystem
{
    public bool FileExists(string path) => File.Exists(path);

    public bool DirectoryExists(string path) => Directory.Exists(path);
}
