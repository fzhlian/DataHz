# 文档维护策略

最后更新：2026-03-03

## 目标

- 确保代码、接口、配置、运维流程与文档一致。
- 将“文档更新”纳入研发流水线，不依赖人工记忆。

## 覆盖矩阵

| 变更区域 | 必须更新的文档 |
| --- | --- |
| `src/DataHz.Api/**` | `docs/API.md`、`docs/ARCHITECTURE.md` |
| `src/DataHz.Infrastructure/**` | `docs/ARCHITECTURE.md`、`docs/CONFIGURATION.md` |
| `src/DataHz.Core/**` | `docs/ARCHITECTURE.md` |
| `src/**` 鉴权/密钥逻辑 | `SECURITY.md`、`docs/SSO_HARDENING_RUNBOOK.md`、`docs/CONFIGURATION.md` |
| `scripts/**` | `docs/TESTING_AND_RELEASE.md`、`docs/OPERATIONS.md` |
| `.github/workflows/**` | `docs/TESTING_AND_RELEASE.md` |
| `tests/**` | `docs/DEVELOPMENT.md`（测试说明） |

## 自动检查机制

- 脚本：`DataHz2/scripts/check-docs-sync.ps1`
- CI：`datahz2-ci.yml` 与 `datahz2-release.yml` 构建阶段强制执行
- 规则：当代码/脚本/工作流有变更时，若无文档变更，CI 失败

## 质量要求

1. 每个文档保留“最后更新”日期。
2. 配置项需说明默认值与覆盖关系。
3. API 文档需体现权限与状态码。
4. 运维文档需包含回滚与排障步骤。

## 推荐更新流程

1. 先改代码。
2. 再改对应文档。
3. 本地运行 `.\scripts\check-docs-sync.ps1`。
4. 提交 PR 并通过 CI。
