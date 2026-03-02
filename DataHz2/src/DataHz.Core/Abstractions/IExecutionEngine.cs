using DataHz.Core.Execution;

namespace DataHz.Core.Abstractions;

public interface IExecutionEngine
{
    ExecuteResult Execute(ExecuteRequest request);
}
