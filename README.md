# DataHz 项目文档入口

本仓库包含两个部分：

- `DataHz2/`：正在维护的 .NET 10 重构版本（主开发目录）。
- `多数据库表格汇总程序/`：历史 VB6 版本与样例资产（只读归档目录）。

## 快速开始

```powershell
cd .\DataHz2
.\scripts\check-dotnet.ps1
.\scripts\run-api.ps1
```

默认启动后可访问：

- `http://localhost:5080/swagger`
- `http://localhost:5080/dashboard/`

## 文档导航

- 项目总览：[DataHz2/README.md](/d:/fzhlian/Code/DataHz/DataHz2/README.md)
- 架构设计：[DataHz2/docs/ARCHITECTURE.md](/d:/fzhlian/Code/DataHz/DataHz2/docs/ARCHITECTURE.md)
- API 清单：[DataHz2/docs/API.md](/d:/fzhlian/Code/DataHz/DataHz2/docs/API.md)
- 配置说明：[DataHz2/docs/CONFIGURATION.md](/d:/fzhlian/Code/DataHz/DataHz2/docs/CONFIGURATION.md)
- 运维与发布：[DataHz2/docs/OPERATIONS.md](/d:/fzhlian/Code/DataHz/DataHz2/docs/OPERATIONS.md)
- 文档索引：[DataHz2/docs/README.md](/d:/fzhlian/Code/DataHz/DataHz2/docs/README.md)
- 贡献规范：[CONTRIBUTING.md](/d:/fzhlian/Code/DataHz/CONTRIBUTING.md)
- 安全策略：[SECURITY.md](/d:/fzhlian/Code/DataHz/SECURITY.md)
- 文档协作规则（代理/自动化）：[AGENTS.md](/d:/fzhlian/Code/DataHz/AGENTS.md)

## 维护约定

- 自 2026-03-03 起，仓库启用文档同步校验脚本：`DataHz2/scripts/check-docs-sync.ps1`。
- 当 `src/`、`tests/`、`scripts/`、CI 工作流发生变更时，PR 必须同时更新相关 `md` 文档，否则 CI 会失败。
