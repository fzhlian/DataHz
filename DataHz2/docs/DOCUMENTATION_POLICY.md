# 文档维护策略

最后更新：2026-03-03

## 目标

- 保持代码、配置、接口、部署流程与文档同步。
- 阻止“代码已变更但文档滞后”的改动进入主分支。

## 强制联动规则（与 `AGENTS.md` 一致）

1. 变更 `DataHz2/src/**` 时，必须更新以下至少一个文件：
   - `DataHz2/README.md`
   - `DataHz2/docs/ARCHITECTURE.md`
   - `DataHz2/docs/API.md`
   - `DataHz2/docs/CONFIGURATION.md`
   - `DataHz2/docs/OPERATIONS.md`
2. 变更 `DataHz2/scripts/**` 或 `.github/workflows/**` 时，必须更新以下至少一个文件：
   - `DataHz2/docs/TESTING_AND_RELEASE.md`
   - `DataHz2/docs/DEVELOPMENT.md`
   - `DataHz2/docs/DOCUMENTATION_POLICY.md`
3. 变更安全鉴权逻辑时，必须同时更新：
   - `SECURITY.md`
   - `DataHz2/docs/SSO_HARDENING_RUNBOOK.md`
4. 每次合并前必须执行：
   - `.\DataHz2\scripts\check-docs-sync.ps1`

## 自动化校验

- 本地/CI 统一使用：`DataHz2/scripts/check-docs-sync.ps1`
- CI 工作流 `datahz2-ci.yml`、`datahz2-release.yml` 强制执行该脚本。
- 若触发规则但未满足对应文档条件，CI 直接失败并阻止合并。

## 本次策略增强（2026-03-03）

### 做了什么变更

- 将 `check-docs-sync.ps1` 从“代码改动 + 任意文档改动”升级为“按改动类型匹配指定文档集”。
- 新增三条硬性规则校验：`src/**`、`scripts/workflows/**`、`安全鉴权逻辑`。
- 安全鉴权规则改为强制同时更新 `SECURITY.md` 与 `SSO_HARDENING_RUNBOOK.md`。
- 失败输出中新增规则触发计数与命中文件列表，便于快速定位。

### 如何使用/验证

1. 执行：
   - `powershell -NoProfile -ExecutionPolicy Bypass -File .\DataHz2\scripts\check-docs-sync.ps1`
2. 仅修改 `DataHz2/src/**` 且不改上述指定文档，预期失败。
3. 修改 `DataHz2/scripts/**` 且同步更新 `DataHz2/docs/DOCUMENTATION_POLICY.md`，预期通过。
4. 修改 `DataHz2/src/**` 下安全鉴权相关逻辑，若缺少 `SECURITY.md` 或 `SSO_HARDENING_RUNBOOK.md` 任一更新，预期失败。

## 文档更新最小标准

- 必须包含“做了什么变更”和“如何使用/验证”。
- 配置项变更必须写明默认值、环境变量覆盖方式、风险提示。
- 对外 API 变更必须更新 `DataHz2/docs/API.md`。
- 发布/部署变更必须更新 `DataHz2/docs/TESTING_AND_RELEASE.md` 或 `DataHz2/docs/OPERATIONS.md`。
