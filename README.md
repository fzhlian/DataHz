# DataHz

最后更新：2026-03-10

本仓库包含 DataHz 的重构版与历史归档资产：

- `DataHz2/`：当前维护中的 .NET 10 版本，包含 API、异步任务队列、Dashboard、Workbench、部署脚本与测试。
- `多数据库表格汇总程序/`：历史 VB6 版本及模板/样例文件，作为迁移参考保留，不作为当前主开发目录。

## 当前项目概览

`DataHz2` 解决的是多数据库模板汇总场景，代码入口可对应到以下能力：

- HTTP 服务：`DataHz2/src/DataHz.Api/Program.cs`
- 领域与抽象：`DataHz2/src/DataHz.Core`
- 模板解析、Access 执行、增量缓存：`DataHz2/src/DataHz.Infrastructure`
- API 集成测试：`DataHz2/tests/DataHz.Api.Tests`
- 本地运行、发布、部署、回滚脚本：`DataHz2/scripts`

当前 API 已实现的主要入口包括：

- 公共入口：`/`、`/health`、`/swagger`、`/dashboard/`、`/workbench/`
- 模板与任务：`/api/templates/parse`、`/api/tasks/plan`、`/api/tasks/execute`
- 异步作业：`/api/jobs/submit`、`/api/jobs`、`/api/jobs/{id}`、`/api/jobs/{id}/cancel`
- 监控与审计：`/api/monitor/*`、`/api/audit/export`
- 安全与密钥运行态：`/api/security/*`

## 快速开始

项目脚本以 PowerShell 为主，默认开发路径是 `DataHz2/`。

```powershell
cd .\DataHz2
.\scripts\check-dotnet.ps1
.\scripts\run-api.ps1
```

`run-api.ps1` 会先执行 `dotnet restore`、`dotnet build -c Release`，然后启动 `src/DataHz.Api`。默认地址来自脚本参数与 API 静态资源配置：

- 首页：`http://127.0.0.1:5080/`
- Swagger：`http://127.0.0.1:5080/swagger`
- Dashboard：`http://127.0.0.1:5080/dashboard/`
- Workbench：`http://127.0.0.1:5080/workbench/`
- 健康检查：`http://127.0.0.1:5080/health`

常用启动参数：

```powershell
.\scripts\run-api.ps1 -NoBrowser
.\scripts\run-api.ps1 -BaseUrl "http://127.0.0.1:5080" -LaunchPath "/workbench/"
```

## 默认配置摘要

基于 `DataHz2/src/DataHz.Api/appsettings.json` 的默认值：

- `JobQueue.StoreDirectory=.datahz-jobs`
- `JobQueue.WorkerCount=1`
- `Security.ApiKey.Enabled=false`
- `Security.Jwt.Enabled=false`
- `Audit.Enabled=true`

这意味着本地默认启动时：

- API 端点默认不强制鉴权
- 异步作业会落盘到 `DataHz2/.datahz-jobs`
- 审计日志默认写入 `DataHz2/.datahz-jobs/audit.log`

## 仓库导航

- 项目总览：[`DataHz2/README.md`](./DataHz2/README.md)
- 文档索引：[`DataHz2/docs/README.md`](./DataHz2/docs/README.md)
- 架构说明：[`DataHz2/docs/ARCHITECTURE.md`](./DataHz2/docs/ARCHITECTURE.md)
- API 说明：[`DataHz2/docs/API.md`](./DataHz2/docs/API.md)
- 配置说明：[`DataHz2/docs/CONFIGURATION.md`](./DataHz2/docs/CONFIGURATION.md)
- 开发规范：[`DataHz2/docs/DEVELOPMENT.md`](./DataHz2/docs/DEVELOPMENT.md)
- 测试与发布：[`DataHz2/docs/TESTING_AND_RELEASE.md`](./DataHz2/docs/TESTING_AND_RELEASE.md)
- 运维手册：[`DataHz2/docs/OPERATIONS.md`](./DataHz2/docs/OPERATIONS.md)
- 迁移说明：[`DataHz2/docs/MIGRATION.md`](./DataHz2/docs/MIGRATION.md)
- 贡献规范：[`CONTRIBUTING.md`](./CONTRIBUTING.md)
- 安全策略：[`SECURITY.md`](./SECURITY.md)
- 变更记录：[`CHANGELOG.md`](./CHANGELOG.md)
- 代理协作规则：[`AGENTS.md`](./AGENTS.md)

## 文档与协作约束

- 当修改 `DataHz2/src/**` 时，必须同步更新 `DataHz2/README.md` 或 `DataHz2/docs/*.md`
- 当修改 `DataHz2/scripts/**` 或 `.github/workflows/**` 时，必须同步更新对应开发/发布文档
- 合并前需执行 `DataHz2/scripts/check-docs-sync.ps1`

这套约束已在仓库规则与 CI 中启用，用于阻止“代码已变更但文档未同步”的状态进入主分支。
