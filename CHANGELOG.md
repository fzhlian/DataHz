# Changelog

所有显著变更都会记录在此文件。

## [2026-03-03]

### Added

- 新增中文文档体系：
  - `DataHz2/docs/README.md`
  - `DataHz2/docs/ARCHITECTURE.md`
  - `DataHz2/docs/API.md`
  - `DataHz2/docs/CONFIGURATION.md`
  - `DataHz2/docs/DEVELOPMENT.md`
  - `DataHz2/docs/TESTING_AND_RELEASE.md`
  - `DataHz2/docs/OPERATIONS.md`
  - `DataHz2/docs/DOCUMENTATION_POLICY.md`
  - `DataHz2/docs/FAQ.md`
- 新增仓库级规范文档：
  - `AGENTS.md`
  - `CONTRIBUTING.md`
  - `SECURITY.md`
  - `.github/PULL_REQUEST_TEMPLATE.md`
- 新增文档同步校验脚本：`DataHz2/scripts/check-docs-sync.ps1`

### Changed

- 将 `README.md`、`DataHz2/README.md` 改为中文导向文档。
- 将 `DataHz2/docs/MIGRATION.md`、`DataHz2/docs/SSO_HARDENING_RUNBOOK.md` 改为中文。
- CI 与 Release 工作流接入文档同步检查步骤。
- `DataHz2/scripts/check-ci-contracts.ps1` 增加文档同步步骤合同校验。
