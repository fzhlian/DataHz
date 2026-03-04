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
- `prod-auto-wrapper-fail-skip-rollback` 为 `true`。
- `prod-auto-wrapper-smoke-success` 为 `true`（仅在 `-IncludeOnlineSmokeCase` 时执行）。
- `prod-from-release-invalid-tag`、`prod-from-release-dryrun-x64`、`prod-from-release-dryrun-arm64`、`prod-from-release-dryrun-env-token` 均为 `true`。
- `prod-from-release-validate-assets-local-success` 与 `prod-from-release-validate-assets-local-failure` 均为 `true`。
- `prod-from-release-validate-assets-summary` 为 `true`。
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

## 2026-03-04 一键部署失败自动回滚与日志归档

做了什么变更：
- 新增 `.\scripts\deploy-prod-with-auto-rollback.ps1`，封装 `deploy-prod.ps1` 与 `rollback-api.ps1`，用于生产发布失败后的自动回滚。
- 新脚本会按次生成运行目录（默认 `.\artifacts\deploy-runs\<runId>\`），落盘以下诊断文件：
  - `deploy.log`、`rollback.log`（执行日志）
  - `status-before.json`、`status-after-deploy.json`、`status-after-rollback.json`（部署状态快照）
  - `run-summary.json`（本次运行汇总；若由 `deploy-prod-from-release.ps1 -ValidateAssetUrls` 调用，会附带 `assetValidation` 校验结果）
- 每次运行会额外生成同名 zip 归档（`.\artifacts\deploy-runs\<runId>.zip`），便于离线传阅与追溯。
- `check-deploy-guards.ps1` 新增自动回滚包装脚本守卫用例：
  - `prod-auto-wrapper-fail-skip-rollback`（失败路径 + `-SkipRollback` + 日志/状态快照校验）
  - `prod-auto-wrapper-smoke-success`（在线冒烟成功路径 + smoke 报告校验）

如何使用/验证：
- 直接发布（失败自动回滚）：

```powershell
$tag = "datahz2-v1.0.7"
$base = "https://github.com/fzhlian/DataHz/releases/download/$tag"

.\scripts\deploy-prod-with-auto-rollback.ps1 `
  -ServiceName "DataHz.Api" `
  -PackageUrl "$base/datahz2-api-win-arm64-$tag.zip" `
  -PackageSha256Url "$base/datahz2-api-win-arm64-$tag.sha256" `
  -PackageManifestUrl "$base/datahz2-api-win-arm64-$tag.manifest.json" `
  -PackageIndexUrl "$base/datahz2-release-$tag.index.json" `
  -PackageIndexSha256Url "$base/datahz2-release-$tag.sha256" `
  -PackageBearerToken $env:GITHUB_TOKEN `
  -SmokeRequireAuthenticatedApi `
  -SmokeApiKey $env:DATAHZ_API_KEY
```

- 指定回滚目标版本（可选）：

```powershell
.\scripts\deploy-prod-with-auto-rollback.ps1 `
  -ServiceName "DataHz.Api" `
  -PackageUrl "$base/datahz2-api-win-arm64-$tag.zip" `
  -PackageManifestUrl "$base/datahz2-api-win-arm64-$tag.manifest.json" `
  -RollbackTargetReleaseId "20260304-085901"
```

- 若“部署失败但自动回滚成功”仍需返回成功退出码（某些编排场景）：

```powershell
.\scripts\deploy-prod-with-auto-rollback.ps1 `
  -ServiceName "DataHz.Api" `
  -PackageUrl "$base/datahz2-api-win-arm64-$tag.zip" `
  -PackageManifestUrl "$base/datahz2-api-win-arm64-$tag.manifest.json" `
  -TreatRollbackSuccessAsSuccess
```

预期结果：
- 发布成功：脚本退出码 `0`，`run-summary.json` 中 `deploy.succeeded=true`。
- 发布失败 + 回滚成功：默认退出码 `1`（若启用 `-TreatRollbackSuccessAsSuccess` 则为 `0`）。
- 发布失败 + 回滚失败：退出码 `2`，并可在 `run-summary.json` + `*.log` + `*.zip` 中定位原因。

## 2026-03-04 按 Tag/Runtime 自动部署

做了什么变更：
- 新增 `.\scripts\deploy-prod-from-release.ps1`，通过 `-Tag` + `-Runtime` 自动拼装 GitHub Release 资产 URL，并调用 `deploy-prod-with-auto-rollback.ps1` 执行生产部署。
- 默认支持 `win-x64`、`win-arm64` 两个运行时；若未显式传 `-PackageBearerToken`，会自动读取当前进程 `GITHUB_TOKEN` 环境变量。
- 新增 `-DryRun`，用于输出最终透传参数（JSON）并提前验证命令，不实际部署。
- 新增 `-ValidateAssetUrls`，可在部署前校验 5 个 release 资产 URL 的可达性（支持 `-ValidateAssetTimeoutSeconds`、`-ValidateAssetRetryCount`）。
- 新增 `-ReleaseDownloadBaseUrl`，用于覆盖默认 GitHub 下载前缀（例如内网镜像或本地守卫测试）。
- `check-deploy-guards.ps1` 新增 `deploy-prod-from-release.ps1` 守卫用例，覆盖 `invalid-tag`、`dryrun-x64/arm64`、`env token 透传`。
- `check-deploy-guards.ps1` 进一步覆盖 `ValidateAssetUrls` 的本地成功/失败路径。
- `deploy-prod-with-auto-rollback.ps1` 的 `run-summary.json` 现支持记录 `assetValidation`（URL、状态码、尝试次数、方法、详情），便于集中排障。

如何使用/验证：
- `win-x64` 实际部署：

```powershell
.\scripts\deploy-prod-from-release.ps1 `
  -Tag "datahz2-v1.0.8" `
  -Runtime "win-x64" `
  -ServiceName "DataHz.Api" `
  -SmokeRequireAuthenticatedApi `
  -SmokeApiKey $env:DATAHZ_API_KEY `
  -ValidateAssetUrls
```

- `win-arm64` 实际部署：

```powershell
.\scripts\deploy-prod-from-release.ps1 `
  -Tag "datahz2-v1.0.8" `
  -Runtime "win-arm64" `
  -ServiceName "DataHz.Api" `
  -SmokeRequireAuthenticatedApi `
  -SmokeApiKey $env:DATAHZ_API_KEY
```

- 仅检查参数拼装（不部署）：

```powershell
.\scripts\deploy-prod-from-release.ps1 `
  -Tag "datahz2-v1.0.8" `
  -Runtime "win-arm64" `
  -ValidateAssetUrls `
  -DryRun
```

预期结果：
- `DryRun` 输出中应包含 5 个 release URL：`zip`、`sha256`、`manifest`、`index.json`、`index.sha256`。
- 启用 `-ValidateAssetUrls` 时，`DryRun` 输出的 `assetValidation` 应包含 5 条记录；真实可达资源应全部 `Passed=true`。
- 实际部署时会进入 `deploy-prod-with-auto-rollback.ps1` 统一流程，并在 `artifacts\deploy-runs` 生成运行日志与总结。

## 2026-03-04 guard refinement (from-release summary)

What changed:
- `check-deploy-guards.ps1` now builds from-release test assets with a rewritten manifest and regenerated release index (`datahz2-release-<tag>.index.json` + `.sha256`) so metadata matches renamed files.
- Guard case `prod-from-release-validate-assets-summary` is tightened to require wrapper exit code `0`.
- The same guard now asserts `run-summary.json` includes `deploy.succeeded=true` and `rollback.attempted=false` in addition to `assetValidation` entries.

How to validate:
- Run: `./DataHz2/scripts/check-deploy-guards.ps1 -PackageZip ./DataHz2/artifacts/packages/datahz2-api-win-x64.zip`
- Expect case `prod-from-release-validate-assets-summary` to pass with no fallback to exit code `1`.

## 2026-03-04 log encoding hardening (auto-rollback wrapper)

What changed:
- `deploy-prod-with-auto-rollback.ps1` no longer uses `Tee-Object -FilePath` for step logs.
- Wrapper step logs are now appended line-by-line with explicit UTF-8 encoding, avoiding mixed UTF-8/UTF-16 content in `deploy.log` / `rollback.log`.
- `check-deploy-guards.ps1` now asserts wrapper deploy logs contain no NUL bytes in:
  - `prod-auto-wrapper-fail-skip-rollback`
  - `prod-from-release-validate-assets-summary`

How to validate:
- Run: `./DataHz2/scripts/check-deploy-guards.ps1 -PackageZip ./DataHz2/artifacts/packages/datahz2-api-win-x64.zip`
- Expect both wrapper-related guard cases to pass and generated `deploy.log` to be plain UTF-8 text (no embedded NUL bytes).

## 2026-03-04 smoke detail sanitization hardening

What changed:
- `smoke-test-api.ps1` adds text normalization for display/report fields, removing control characters from check `Detail`/`Endpoint`.
- On non-2xx HTTP errors, response-body extraction now distinguishes text vs non-text payloads using content type and byte heuristics.
- For non-text/binary payloads, failure details now use explicit placeholders (for example `binary response body omitted`) instead of raw undecodable bytes.
- `check-deploy-guards.ps1` adds case `smoke-binary-error-detail-sanitized` to verify smoke JSON details contain no control chars and include binary/non-text placeholders when appropriate.

How to validate:
- Run: `./DataHz2/scripts/check-deploy-guards.ps1 -PackageZip ./DataHz2/artifacts/packages/datahz2-api-win-x64.zip`
- Expect case `smoke-binary-error-detail-sanitized` to pass.

## 2026-03-04 smoke body-unavailable fallback (cross-shell)

What changed:
- `smoke-test-api.ps1` now emits a stable placeholder (`response body unavailable`) when HTTP error response bytes cannot be read in the current shell/runtime.
- `check-deploy-guards.ps1` updates case `smoke-binary-error-detail-sanitized` to accept `binary`, `non-text`, or `body unavailable` placeholders while still requiring no control characters in smoke report details.

How to validate:
- Run: `./DataHz2/scripts/check-deploy-guards.ps1 -PackageZip ./DataHz2/artifacts/packages/datahz2-api-win-x64.zip`
- Expect case `smoke-binary-error-detail-sanitized` to pass in both Windows PowerShell and PowerShell 7 environments.

## 2026-03-04 smoke subprocess log encoding guard

What changed:
- `check-deploy-guards.ps1` now asserts `smoke-binary-error-detail-sanitized` subprocess logs are text-safe:
  - `smoke.stdout.log` must not contain NUL bytes.
  - `smoke.stderr.log` must not contain NUL bytes.
- The same case now also asserts `smoke.report.json` `results[*].Endpoint` values contain no control characters (matching the existing `Detail` sanitization guard).
- This prevents regressions where mixed encodings make smoke diagnostics unreadable in CI artifacts.

How to validate:
- Run: `./DataHz2/scripts/check-deploy-guards.ps1 -PackageZip ./DataHz2/artifacts/packages/datahz2-api-win-x64.zip`
- Expect case `smoke-binary-error-detail-sanitized` to pass, generated smoke logs to be plain text without embedded NUL bytes, and report `Endpoint`/`Detail` fields to be control-char free.

## 2026-03-04 smoke secret redaction guard

What changed:
- `check-deploy-guards.ps1` adds `smoke-detail-redacts-secrets`.
- The case starts a local mock server that echoes `Authorization` / `X-Api-Key` values in JSON error bodies, then runs `smoke-test-api.ps1` with both `-ApiKey` and `-BearerToken`.
- `smoke-test-api.ps1` now also redacts URL userinfo fragments (`http://user:pass@host`) to `http://[REDACTED]@host` in display/report text.
- Guard assertions now require:
  - smoke report generation with expected failure path (`exit code 1`);
  - smoke stdout/stderr logs remain text-safe (no NUL bytes);
  - report/log outputs do not contain raw secret values;
  - smoke details include `[REDACTED]` marker and URL userinfo redaction marker.

How to validate:
- Run: `./DataHz2/scripts/check-deploy-guards.ps1 -PackageZip ./DataHz2/artifacts/packages/datahz2-api-win-x64.zip`
- Expect case `smoke-detail-redacts-secrets` to pass.

## 2026-03-04 smoke base URL userinfo redaction guard

What changed:
- `check-deploy-guards.ps1` adds `smoke-baseurl-userinfo-redacted`.
- The case runs `smoke-test-api.ps1` with a base URL containing userinfo (`http://user:pass@host`) against the local smoke mock server.
- Guard assertions require:
  - smoke succeeds (`exit code 0`, `failedChecks=0`);
  - report `baseUrl` equals sanitized host-only URL (no userinfo);
  - stdout/stderr/report content does not contain raw username/password fragments;
  - smoke context output includes sanitized `BaseUrl`.

How to validate:
- Run: `./DataHz2/scripts/check-deploy-guards.ps1 -PackageZip ./DataHz2/artifacts/packages/datahz2-api-win-x64.zip`
- Expect case `smoke-baseurl-userinfo-redacted` to pass.

## 2026-03-04 smoke base URL whitespace-injection guard

What changed:
- `smoke-test-api.ps1` now normalizes display/report `baseUrl` to a single safe token after control-char cleanup.
- `check-deploy-guards.ps1` adds `smoke-baseurl-whitespace-injection-sanitized`.
- The case runs smoke with a CRLF-injected base URL string and asserts:
  - expected failure path (`exit code 1`) with report generated;
  - report `baseUrl` equals sanitized host URL;
  - report/log outputs do not contain injected suffix text;
  - smoke context prints sanitized `BaseUrl`.

How to validate:
- Run: `./DataHz2/scripts/check-deploy-guards.ps1 -PackageZip ./DataHz2/artifacts/packages/datahz2-api-win-x64.zip`
- Expect case `smoke-baseurl-whitespace-injection-sanitized` to pass.
