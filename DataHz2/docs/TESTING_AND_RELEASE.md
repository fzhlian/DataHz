# 测试与发布

最后更新：2026-03-04

## 测试命令

```powershell
dotnet test .\DataHz2.sln -c Release
```

## 脚本校验

```powershell
.\scripts\validate-scripts.ps1
.\scripts\check-history-audits.ps1
.\scripts\check-ci-contracts.ps1
.\scripts\check-docs-sync.ps1
```

`smoke-test-api.ps1` 的静态页面探测规则说明：
- `swagger` 使用 `/swagger/index.html`，必须返回 `200` 且包含 `swagger-ui` 关键字（兼容本地化标题页面）。
- `dashboard` 使用 `/dashboard/`，允许 `200` 或标准重定向（`301/302/307/308`）。
- `health` 通过 `Wait-ForHealthReady` 轮询判定就绪后直接记为通过，不再额外执行第二次确认请求。

### 2026-03-04 冒烟稳定性增强

做了什么变更：
- `smoke-test-api.ps1` 新增 `CheckRetryCount`（默认 `3`）与 `CheckRetryDelayMilliseconds`（默认 `500`）参数。
- `smoke-test-api.ps1` 新增 `HealthPollDelayMilliseconds`（默认 `500`）参数，用于控制健康检查轮询间隔。
- `smoke-test-api.ps1` 新增 `WarnCheckDurationMilliseconds`（默认 `0`）与 `FailCheckDurationMilliseconds`（默认 `0`）参数，用于慢检查阈值告警/失败控制（`0` 表示关闭）。
- `smoke-test-api.ps1` 新增 `FailureContentSnippetLength`（默认 `240`）参数，用于控制失败时响应体摘要长度。
- `swagger` / `dashboard` 与 API 端点检查改为带重试执行，降低冷启动瞬时抖动导致的误报失败。
- CI 与 Release 工作流的 smoke 步骤固定使用 `-CheckRetryCount 5 -CheckRetryDelayMilliseconds 800`，并由 `check-ci-contracts.ps1` 强制校验。
- CI 与 Release 工作流的 smoke 步骤固定使用 `-HealthPollDelayMilliseconds 500`，并由 `check-ci-contracts.ps1` 强制校验。
- CI 与 Release 工作流的 smoke 步骤固定使用 `-WarnCheckDurationMilliseconds 3000 -FailCheckDurationMilliseconds 0`，并由 `check-ci-contracts.ps1` 强制校验。
- `health` 检查改为“就绪轮询结果直接判定”，避免通过后再次请求造成偶发失败。
- `smoke-test-api.ps1` 新增 `OutputJsonPath` 参数，可输出结构化 JSON 报告（包含上下文、耗时、每个检查项的尝试次数与结果）。
- 失败项明细新增 `bodySnippet` 输出，可快速看到错误响应的关键片段。
- 每个检查项新增 `DurationMs` 指标（终端表格与 JSON 报告均包含），可快速定位慢检查。
- `bodySnippet` 与失败明细会对 `ApiKey/BearerToken` 等敏感值做脱敏处理，降低日志泄露风险。
- 运行上下文中的 `BaseUrl` 与结构化报告中的 `baseUrl` 也会做脱敏处理。
- CI 与 Release smoke 步骤在失败时会额外打印结构化 smoke 报告，提升排障效率。
- CI 与 Release 工作流新增 `Upload smoke diagnostics` 步骤（`always()`），会上传 `stdout/stderr/report` 三类日志产物用于离线排查。
- CI 与 Release 工作流新增 `Publish smoke summary` 步骤（`always()`），会将结构化报告摘要写入 `GITHUB_STEP_SUMMARY`。
- `Publish smoke summary` 现包含平均检查耗时、最大耗时检查以及 Top3 慢检查表，便于快速识别性能瓶颈。
- `Publish smoke summary` 现额外包含 health 轮询间隔（`healthPollDelayMilliseconds`）。
- `Publish smoke summary` 现额外包含慢检查阈值与命中计数（`warn/fail`）。
- 当 `failSlowCheckCount > 0` 时，`Publish smoke summary` 还会输出 `failSlowChecks` 明细表用于定位超阈值检查项。
- `deploy-api.ps1` 新增 `SmokeCheckRetryCount`、`SmokeCheckRetryDelayMilliseconds`、`SmokeHealthPollDelayMilliseconds`、`SmokeWarnCheckDurationMilliseconds`、`SmokeFailCheckDurationMilliseconds`、`SmokeFailureContentSnippetLength`、`SmokeOutputJsonPath` 参数，并透传给 `smoke-test-api.ps1`。
- `deploy-api.ps1` 的主部署 smoke 与失败后自动回滚 smoke 现在使用同一组透传参数，减少两条路径的行为偏差。
- `deploy-prod.ps1` 与 `rollback-api.ps1` 新增同名 `Smoke*` 参数，并继续向 `deploy-api.ps1` / `smoke-test-api.ps1` 透传，支持在生产发布与手工回滚时统一调参。
- 修复 `check-ci-contracts.ps1` 对 `GITHUB_STEP_SUMMARY` 的匹配方式：改为匹配字面量 `'$env:GITHUB_STEP_SUMMARY'`，避免 CI 环境变量展开后出现误报失败（本地可能通过、CI 失败）。
- 修复 `smoke-test-api.ps1` 构建结构化报告时的集合转换方式：将 `results` 从 `@($results)` 改为 `$results.ToArray()`，避免在 `check-deploy-guards.ps1` 在线冒烟路径触发 `Argument types do not match`。
- 修复 `smoke-test-api.ps1` 的 swagger 页面标记匹配：从固定 `Swagger UI` 调整为 `swagger-ui`，兼容本地化 Swagger 页面文本差异。

如何使用/验证：
- 本地执行示例：

```powershell
.\scripts\smoke-test-api.ps1 `
  -BaseUrl "http://127.0.0.1:5080" `
  -TimeoutSeconds 120 `
  -CheckRetryCount 5 `
  -CheckRetryDelayMilliseconds 800 `
  -HealthPollDelayMilliseconds 500 `
  -WarnCheckDurationMilliseconds 2000 `
  -FailCheckDurationMilliseconds 5000 `
  -FailureContentSnippetLength 300 `
  -OutputJsonPath ".\artifacts\smoke\smoke-report.json"
```

- 生产发布（通过 `deploy-prod.ps1` 透传 smoke 参数）：

```powershell
.\scripts\deploy-prod.ps1 `
  -ServiceName DataHz.Api `
  -PackageZip .\artifacts\packages\datahz2-api-win-x64.zip `
  -PackageSha256File .\artifacts\packages\datahz2-api-win-x64.sha256 `
  -PackageManifestFile .\artifacts\packages\datahz2-api-win-x64.manifest.json `
  -SmokeCheckRetryCount 5 `
  -SmokeCheckRetryDelayMilliseconds 800 `
  -SmokeHealthPollDelayMilliseconds 500 `
  -SmokeWarnCheckDurationMilliseconds 3000 `
  -SmokeFailCheckDurationMilliseconds 0 `
  -SmokeOutputJsonPath .\artifacts\smoke\deploy-prod-smoke.json
```

- 手工回滚（通过 `rollback-api.ps1` 透传 smoke 参数）：

```powershell
.\scripts\rollback-api.ps1 `
  -ServiceName DataHz.Api `
  -RunSmokeTest `
  -SmokeCheckRetryCount 5 `
  -SmokeCheckRetryDelayMilliseconds 800 `
  -SmokeHealthPollDelayMilliseconds 500 `
  -SmokeWarnCheckDurationMilliseconds 3000 `
  -SmokeFailCheckDurationMilliseconds 0 `
  -SmokeOutputJsonPath .\artifacts\smoke\rollback-smoke.json
```

- CI 合约脚本回归验证（建议在提交前执行）：

```powershell
.\scripts\check-ci-contracts.ps1
```

预期结果：
- `ci-smoke-summary-contract` 与 `release-smoke-summary-contract` 均为 `true`。
- 不再出现“must write into GITHUB_STEP_SUMMARY”误报。

- 部署守卫在线冒烟回归（建议在提交前执行）：

```powershell
.\scripts\check-deploy-guards.ps1 `
  -PackageZip ".\artifacts\packages\datahz2-api-win-x64-fallback.zip" `
  -IncludeOnlineSmokeCase `
  -OnlineSmokeStartupSeconds 6
```

预期结果：
- `prod-wrapper-smoke-success` 为 `true`。
- 不再出现 `Deployment failed. Argument types do not match`。

## CI 工作流

- `/.github/workflows/datahz2-ci.yml`
  - 触发：`push`、`pull_request`、`workflow_dispatch`
  - 构建测试 + 双运行时打包校验（`win-x64`、`win-arm64`）
- `/.github/workflows/datahz2-release.yml`
  - 触发：标签 `datahz2-v*`
  - 构建、测试、打包、资产复验、发布 GitHub Release

## 本地发布与打包

```powershell
.\scripts\publish-api.ps1 -Configuration Release -Runtime win-x64
.\scripts\package-release.ps1 -InputDir .\artifacts\publish\win-x64 -OutputDir .\artifacts\packages -Name datahz2-api-win-x64 -Overwrite
.\scripts\verify-release.ps1 -PackageZip .\artifacts\packages\datahz2-api-win-x64.zip
```

## 生产发布

```powershell
.\scripts\deploy-prod.ps1 `
  -ServiceName DataHz.Api `
  -PackageZip .\artifacts\packages\datahz2-api-win-x64.zip `
  -PackageSha256File .\artifacts\packages\datahz2-api-win-x64.sha256 `
  -PackageManifestFile .\artifacts\packages\datahz2-api-win-x64.manifest.json `
  -Urls "http://0.0.0.0:5080"
```

## 发布资产

每个运行时至少包含：

- `*.zip`
- `*.sha256`
- `*.manifest.json`

多运行时汇总发布包含：

- `datahz2-release-<tag>.index.json`
- `datahz2-release-<tag>.sha256`

## 失败回滚

```powershell
.\scripts\rollback-api.ps1 -ServiceName DataHz.Api -Urls "http://0.0.0.0:5080"
```
