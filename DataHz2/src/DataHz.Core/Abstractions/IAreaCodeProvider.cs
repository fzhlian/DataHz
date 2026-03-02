using DataHz.Core.Domain;

namespace DataHz.Core.Abstractions;

public interface IAreaCodeProvider
{
    IReadOnlyList<AreaCodeItem> Load(string areaCodePath);
}
