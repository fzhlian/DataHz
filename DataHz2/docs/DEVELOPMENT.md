# 开发规范

最后更新：2026-03-03

## 环境要求

- Windows 10/11
- .NET SDK 10.x
- PowerShell 7+
- ACE OLEDB 驱动（Access 读取）

## 本地运行

```powershell
cd .\DataHz2
.\scripts\check-dotnet.ps1
.\scripts\run-api.ps1
```

## 开发命令

```powershell
dotnet restore .\DataHz2.sln
dotnet build .\DataHz2.sln -c Release
dotnet test .\DataHz2.sln -c Release
.\scripts\validate-scripts.ps1
.\scripts\check-docs-sync.ps1
```

## 代码约定

1. 优先保持 `Core` 纯业务契约，不引入基础设施依赖。
2. API 新增接口时同步补充权限映射和审计记录。
3. 脚本变更需保证非交互可执行，并维持幂等行为。
4. 涉及部署/回滚链路的变更必须补充测试或自检脚本。

## 文档约定

1. 功能变更必须同步更新 `README` 与 `docs` 对应章节。
2. API 变更更新 `docs/API.md`。
3. 配置变更更新 `docs/CONFIGURATION.md`。
4. 发布流程变更更新 `docs/TESTING_AND_RELEASE.md` 或 `docs/OPERATIONS.md`。

## 分支与提交

1. 功能分支命名建议：`feat/*`、`fix/*`、`docs/*`。
2. 建议提交信息：`type(scope): summary`。
3. PR 合并前需通过 CI 与文档同步检查。
