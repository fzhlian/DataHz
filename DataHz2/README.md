# DataHz 2.0（中文项目总览）

最后更新：2026-03-03

`DataHz 2.0` 是对旧版 VB6 多数据库汇总工具的重构版本，核心目标是：

- 并发执行与增量缓存，提升县级批量汇总效率。
- 兼容历史模板（INI/XLSX），平滑迁移既有业务规则。
- 提供 API 与异步任务队列，便于服务化部署与自动化运维。

## 目录结构

- `src/DataHz.Core`：领域模型与抽象接口。
- `src/DataHz.Infrastructure`：模板解析、Access 执行、增量状态管理。
- `src/DataHz.Api`：HTTP API、鉴权、审计、监控、异步任务队列、Dashboard。
- `tests/DataHz.Api.Tests`：API 集成测试。
- `scripts`：构建、打包、部署、回滚、校验脚本。
- `docs`：中文设计与运维文档。

## 快速启动（Windows）

```powershell
cd .\DataHz2
.\scripts\check-dotnet.ps1
.\scripts\run-api.ps1
```

启动后默认入口：

- Swagger：`http://localhost:5080/swagger`
- Dashboard：`http://localhost:5080/dashboard/`
- 健康检查：`http://localhost:5080/health`

## 关键能力

- 历史模板解析：`INI`、标准 `XLSX`、流向模板 `FX_*.xlsx`。
- Access 执行流水线：列汇总、`LIST_` 查询、模板导出。
- 增量缓存：按县级源库时间戳 + 模板哈希复用结果。
- 异步任务：提交、轮询、取消、幂等键复用、文件持久化恢复。
- 安全能力：API Key、JWT、角色权限、外部密钥服务、审计日志。
- 运维能力：发布打包、部署校验、健康探测、回滚、发布历史审计。

## 常用命令

```powershell
# 测试
dotnet test .\DataHz2.sln -c Release

# 发布
.\scripts\publish-api.ps1 -Configuration Release -Runtime win-x64

# 打包
.\scripts\package-release.ps1 -InputDir .\artifacts\publish\win-x64 -OutputDir .\artifacts\packages -Name datahz2-api-win-x64 -Overwrite

# 部署
.\scripts\deploy-api.ps1 -ServiceName DataHz.Api -PackageZip .\artifacts\packages\datahz2-api-win-x64.zip -Urls "http://0.0.0.0:5080"

# 回滚
.\scripts\rollback-api.ps1 -ServiceName DataHz.Api -Urls "http://0.0.0.0:5080"
```

## 文档导航

- 文档索引：[docs/README.md](/d:/fzhlian/Code/DataHz/DataHz2/docs/README.md)
- 架构设计：[docs/ARCHITECTURE.md](/d:/fzhlian/Code/DataHz/DataHz2/docs/ARCHITECTURE.md)
- API 说明：[docs/API.md](/d:/fzhlian/Code/DataHz/DataHz2/docs/API.md)
- 配置说明：[docs/CONFIGURATION.md](/d:/fzhlian/Code/DataHz/DataHz2/docs/CONFIGURATION.md)
- 开发规范：[docs/DEVELOPMENT.md](/d:/fzhlian/Code/DataHz/DataHz2/docs/DEVELOPMENT.md)
- 测试与发布：[docs/TESTING_AND_RELEASE.md](/d:/fzhlian/Code/DataHz/DataHz2/docs/TESTING_AND_RELEASE.md)
- 运维手册：[docs/OPERATIONS.md](/d:/fzhlian/Code/DataHz/DataHz2/docs/OPERATIONS.md)
- 文档维护策略：[docs/DOCUMENTATION_POLICY.md](/d:/fzhlian/Code/DataHz/DataHz2/docs/DOCUMENTATION_POLICY.md)
- 迁移映射：[docs/MIGRATION.md](/d:/fzhlian/Code/DataHz/DataHz2/docs/MIGRATION.md)
- SSO 加固：[docs/SSO_HARDENING_RUNBOOK.md](/d:/fzhlian/Code/DataHz/DataHz2/docs/SSO_HARDENING_RUNBOOK.md)

## 文档自动同步机制

自 2026-03-03 起，仓库启用文档同步约束：

- 本地/CI 可执行：`.\scripts\check-docs-sync.ps1`
- 当 `src/`、`tests/`、`scripts/`、CI 工作流发生变更，必须同步更新相关 Markdown 文档。
- CI 工作流 `datahz2-ci.yml` 与 `datahz2-release.yml` 已接入该检查。
