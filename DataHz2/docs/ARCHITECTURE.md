# 架构设计说明

最后更新：2026-03-03

## 1. 架构目标

- 兼容历史模板与 Access 数据源，降低迁移成本。
- 支持服务化部署和异步任务，满足批处理场景。
- 提供安全鉴权、审计、监控与可回滚发布能力。

## 2. 模块划分

### `DataHz.Core`

- 领域模型：`TemplateDefinition`、`ColumnRule`、`FlowTemplateConfig` 等。
- 抽象接口：`ITemplateParser`、`ITaskPlanner`、`IExecutionEngine`、`IAreaCodeProvider`。
- 职责：定义业务契约，不依赖具体基础设施实现。

### `DataHz.Infrastructure`

- 模板解析：`LegacyIniTemplateParser`、`LegacyXlsxTemplateParser`、`CompositeTemplateParser`。
- 执行能力：`AccessExecutionEngine`、`AccessSqlComposer`、`DryRunExecutionEngine`。
- 任务规划：`DefaultTaskPlanner`。
- 状态管理：`ExecutionStateStore`（增量缓存基础）。
- 职责：承载与文件、数据库、Excel、编码等相关的具体实现。

### `DataHz.Api`

- 最小 API：`Program.cs` 中 `MapGet/MapPost` 暴露业务接口。
- 异步队列：`PersistentExecutionJobQueue` + `ExecutionJobWorker`。
- 安全：API Key/JWT、角色授权、密钥动态解析。
- 审计：`FileAuditTrail`、`FileAuditLogReader`。
- 监控：运行态总览、外部密钥提供方状态、审计导出、Dashboard。

### `DataHz.Api.Tests`

- 使用 `Microsoft.AspNetCore.Mvc.Testing` + `xUnit` 做 API 集成测试。

## 3. 关键业务流程

## 模板执行流程

1. `POST /api/templates/parse` 解析模板并返回结构摘要。
2. `POST /api/tasks/plan` 根据模板 + 行政区代码生成执行计划。
3. `POST /api/tasks/execute` 执行计划（支持 `dryRun`、`incremental`）。

## 异步任务流程

1. `POST /api/jobs/submit` 提交任务，返回 `jobId`。
2. `GET /api/jobs/{id}` / `GET /api/monitor/jobs/{id}` 轮询进度和事件。
3. `POST /api/jobs/{id}/cancel` 取消队列中或运行中的任务。
4. 队列状态通过 `jobs.json` 持久化，服务重启后可恢复。

## 安全流程

1. 请求进入 API 中间件。
2. 根据配置选择 API Key 或 JWT（或两者）。
3. 生成主体 `ApiKeyPrincipal` 并解析角色。
4. 依据路径与方法映射到 `Viewer/Operator/Admin` 权限。
5. 失败写入审计日志并返回 `401/403`。

## 4. 依赖关系

- `DataHz.Api` 依赖 `DataHz.Core` + `DataHz.Infrastructure`。
- `DataHz.Infrastructure` 依赖 `DataHz.Core`。
- `DataHz.Core` 无项目内反向依赖。

## 5. 当前边界与约束

- 运行环境偏 Windows：目标框架包含 `net10.0-windows`。
- 数据源执行依赖 `System.Data.OleDb` 与 ACE 驱动。
- 旧 `.xls` 模板不直接支持，需转换为 `.xlsx`。
