# DataHz 2.0（中文项目总览）

最后更新：2026-03-10

`DataHz 2.0` 是对旧版 VB6 多数据库汇总工具的重构版本，核心目标是：

- 并发执行与增量缓存，提升县级批量汇总效率。
- 兼容历史模板（INI/XLSX），平滑迁移既有业务规则。
- 提供 API 与异步任务队列，便于服务化部署与自动化运维。

## 目录结构

- `src/DataHz.Core`：领域模型与抽象接口。
- `src/DataHz.Infrastructure`：模板解析、Access 执行、增量状态管理。
- `src/DataHz.Api`：HTTP API、鉴权、审计、监控、异步任务队列、Dashboard、Workbench GUI。
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

- 首页：`http://127.0.0.1:5080/`
- Swagger：`http://127.0.0.1:5080/swagger`
- Dashboard：`http://127.0.0.1:5080/dashboard/`
- Workbench：`http://127.0.0.1:5080/workbench/`
- 健康检查：`http://127.0.0.1:5080/health`

`run-api.ps1` 默认会在健康检查就绪后自动打开浏览器到首页，可通过以下参数调整：

- 禁用自动打开：`./scripts/run-api.ps1 -NoBrowser`
- 指定打开地址：`./scripts/run-api.ps1 -BaseUrl "http://127.0.0.1:5080" -LaunchPath "/workbench/"`

## 图形界面（Workbench）

### 做了什么变更

- 新增 `src/DataHz.Api/wwwroot/workbench/index.html`，提供图形化任务操作工作台。
- 新增 `src/DataHz.Api/wwwroot/index.html`，作为 GUI 首页入口（链接 Workbench/Monitor/Swagger/Health）。
- 新增 `/workbench -> /workbench/` 重定向，统一入口体验。
- Workbench 增强：参数校验、示例参数填充、参数导入/导出、一键流程（解析→计划→提交）、计划预设保存/加载/重命名/删除、计划预设默认项设置与启动自动应用、计划预设置顶常用与上移/下移排序、计划预设拖拽排序与 `Alt+↑/Alt+↓` 快捷排序、计划预设多步撤销/重做排序（最多保留最近 30 步，按钮与 `Alt+Z`、`Alt+Shift+Z`、`Alt+Y`）、计划预设排序历史可视化（含时间戳与操作摘要，点击历史项可按步回退/前进，历史会持久化到浏览器本地，且支持 JSON 导出/导入）、计划预设导入/导出/清空、作业自动刷新与队列统计、作业筛选搜索、作业排序、最新失败定位、筛选预设保存/加载/删除、筛选预设导入/导出/清空、批量取消、筛选状态持久化、按状态批量勾选、批量取消并发控制、筛选结果 CSV/JSONL 导出、失败取消一键重试、失败 ID 复制、终态跳过策略、失败原因分组与失败清单下载、失败原因一键筛选、失败历史清理、选中作业参数回填、选中作业克隆提交、选中作业路径复制、选中作业 JSON 导出与复制。

### 如何使用与验证

1. 启动 API 服务后访问 `http://127.0.0.1:5080/`，点击 `Task Workbench`。
2. 在 Workbench 中填写 `TemplatePath/SourceDirectory/TargetDirectory/AreaCodePath` 与索引范围，按顺序执行：
   - `解析模板`（`POST /api/templates/parse`）
   - `生成计划`（`POST /api/tasks/plan`）
   - `同步执行`（`POST /api/tasks/execute`）
3. 点击 `提交异步作业`（`POST /api/jobs/submit`），随后在下方 `Async Jobs` 列表查看状态并点击行加载详情。
4. 若需要中止任务，选中作业后点击 `取消选中作业`（`POST /api/jobs/{id}/cancel`）。
5. 可以先用 `校验参数` 检查输入完整性，或使用 `一键流程` 一次完成解析、计划与异步提交。
6. 可通过 `导出参数/导入参数` 复用任务配置；作业区支持自动刷新（5 秒）与实时队列统计。
7. 作业筛选条件（关键词、状态、take、自动刷新开关）会自动保存在浏览器本地，刷新页面后可恢复。
8. 在作业区可按 `status` 与关键词筛选历史任务，可按状态快速勾选，再批量取消。
9. 批量取消支持并发度设置（1-20）；可启用“跳过已终态”以避免无效取消请求。
10. 若有失败项，可点击 `重试失败取消` 执行一键重试，或点击 `复制失败作业ID` 输出失败清单。
11. 上次批量取消失败会显示原因分组摘要，可点击某个原因一键筛选回作业表（并支持清除原因筛选）。
12. 支持下载失败清单（TXT/JSON）与“清空失败历史”。
13. 选中任一作业后，可点击 `回填选中作业参数` 将该作业请求参数写回计划区；也可点击 `克隆提交选中作业` 快速提交副本任务。
14. 选中作业后可点击 `复制模板路径` 或 `复制路径集`，快速复用路径到外部工具或脚本。
15. 选中作业后可点击 `复制选中作业JSON` 或 `下载选中作业JSON`，用于留档与排障。
16. 作业区支持排序字段/方向设置，并可一键定位当前结果中的最新 failed 作业。
17. 计划区参数可保存为“计划预设”，支持一键加载、重命名、删除、导入/导出 JSON 与一键清空。
18. 计划预设支持“设为默认”，页面初始化时会自动应用默认计划预设（若当前未锁定有效活动预设）。
19. 计划预设支持“置顶常用”，并可在常用区/非常用区内执行上移、下移排序。
20. 计划预设可在排序面板中直接拖拽排序，也可用 `Alt+↑/Alt+↓` 快速调整当前选中预设顺序。
21. 若误操作排序，可点击 `撤销排序`/`重做排序`，或使用 `Alt+Z` 撤销、`Alt+Shift+Z`（或 `Alt+Y`）重做；系统最多保留最近 30 步排序历史，历史列表会展示时间戳与操作摘要，并支持按步点击回退或前进，且刷新页面后仍可继续使用这些历史。
22. 排序历史支持 `导出排序历史` 与 `导入排序历史`（JSON），便于跨浏览器备份和迁移；导入后会自动按当前已有计划预设做清洗对齐。
23. 作业筛选条件可保存为“筛选预设”，支持后续一键加载、删除、导入/导出 JSON 与一键清空。
24. 可将当前筛选结果导出为 CSV 或 JSONL，供离线核对与二次处理。
25. 任一步骤失败时，可在右侧 `Response Console` 查看请求与响应内容用于排错。

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

- 文档索引：[docs/README.md](./docs/README.md)
- 架构设计：[docs/ARCHITECTURE.md](./docs/ARCHITECTURE.md)
- API 说明：[docs/API.md](./docs/API.md)
- 配置说明：[docs/CONFIGURATION.md](./docs/CONFIGURATION.md)
- 开发规范：[docs/DEVELOPMENT.md](./docs/DEVELOPMENT.md)
- 测试与发布：[docs/TESTING_AND_RELEASE.md](./docs/TESTING_AND_RELEASE.md)
- 运维手册：[docs/OPERATIONS.md](./docs/OPERATIONS.md)
- 文档维护策略：[docs/DOCUMENTATION_POLICY.md](./docs/DOCUMENTATION_POLICY.md)
- 迁移映射：[docs/MIGRATION.md](./docs/MIGRATION.md)
- SSO 加固：[docs/SSO_HARDENING_RUNBOOK.md](./docs/SSO_HARDENING_RUNBOOK.md)

## 文档自动同步机制

自 2026-03-03 起，仓库启用文档同步约束：

- 本地/CI 可执行：`.\scripts\check-docs-sync.ps1`
- 当 `src/`、`tests/`、`scripts/`、CI 工作流发生变更，必须同步更新相关 Markdown 文档。
- CI 工作流 `datahz2-ci.yml` 与 `datahz2-release.yml` 已接入该检查。
