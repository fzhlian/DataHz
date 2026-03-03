# 贡献指南

最后更新：2026-03-03

## 开发环境

- Windows 10/11（推荐）
- .NET SDK 10.x
- PowerShell 7+
- Access 驱动：`Microsoft ACE OLEDB 12.0+`

## 本地开发流程

```powershell
cd .\DataHz2
.\scripts\check-dotnet.ps1
dotnet restore .\DataHz2.sln
dotnet build .\DataHz2.sln -c Release
dotnet test .\DataHz2.sln -c Release
.\scripts\check-docs-sync.ps1
```

## 提交流程

1. 从最新主分支创建功能分支。
2. 完成功能开发并补齐测试。
3. 更新相关文档（参见 `AGENTS.md` 与 `DataHz2/docs/DOCUMENTATION_POLICY.md`）。
4. 本地执行脚本与测试通过后提交 PR。

## PR 最低要求

- 代码改动说明清晰。
- 风险与回滚方案明确（涉及发布脚本/安全逻辑时）。
- 文档同步更新完成（CI 会强制检查）。

## 推荐提交信息格式

```text
type(scope): summary
```

示例：

- `feat(api): 支持 external-secrets export jsonl`
- `fix(deploy): 修复 fallback 包清理逻辑`
- `docs(ops): 补充生产回滚步骤`
