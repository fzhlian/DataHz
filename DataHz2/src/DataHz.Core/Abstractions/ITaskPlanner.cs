using DataHz.Core.Execution;

namespace DataHz.Core.Abstractions;

public interface ITaskPlanner
{
    AggregationPlan BuildPlan(PlanningRequest request);
}
