# AGENTS 协作规则（DataHz）

最后更新：2026-03-03

本文件用于约束人类开发者与代理在本仓库内的文档协作行为。

## 目标

- 代码、配置、接口、部署流程与文档始终保持同步。
- 不允许“代码已变更但文档滞后”的状态进入主分支。

## 强制规则

1. 变更 `DataHz2/src/**` 时，必须更新下列至少一个文件：
   - `DataHz2/README.md`
   - `DataHz2/docs/ARCHITECTURE.md`
   - `DataHz2/docs/API.md`
   - `DataHz2/docs/CONFIGURATION.md`
   - `DataHz2/docs/OPERATIONS.md`
2. 变更 `DataHz2/scripts/**` 或 `.github/workflows/**` 时，必须更新下列至少一个文件：
   - `DataHz2/docs/TESTING_AND_RELEASE.md`
   - `DataHz2/docs/DEVELOPMENT.md`
   - `DataHz2/docs/DOCUMENTATION_POLICY.md`
3. 变更安全鉴权逻辑时，必须更新：
   - `SECURITY.md`
   - `DataHz2/docs/SSO_HARDENING_RUNBOOK.md`
4. 每次功能合并前，需执行：
   - `.\DataHz2\scripts\check-docs-sync.ps1`

## 文档更新最小标准

- 必须包含“做了什么变更”和“如何使用/验证”。
- 配置项变更必须写清默认值、环境变量覆盖方式、风险提示。
- 对外 API 变更必须更新 `DataHz2/docs/API.md`。
- 发布/部署变更必须更新 `DataHz2/docs/TESTING_AND_RELEASE.md` 或 `DataHz2/docs/OPERATIONS.md`。

## 自动化

- CI 工作流（`datahz2-ci.yml`、`datahz2-release.yml`）已接入 `check-docs-sync.ps1`。
- 若代码改动未同步文档，CI 直接失败并阻止合并。
