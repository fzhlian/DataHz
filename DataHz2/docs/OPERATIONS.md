# 运维手册

最后更新：2026-03-03

## 部署方式

## 方式一：本地构建后部署

```powershell
.\scripts\publish-api.ps1 -Configuration Release -Runtime win-x64
.\scripts\package-release.ps1 -InputDir .\artifacts\publish\win-x64 -OutputDir .\artifacts\packages -Name datahz2-api-win-x64 -Overwrite
.\scripts\deploy-api.ps1 -ServiceName DataHz.Api -PackageZip .\artifacts\packages\datahz2-api-win-x64.zip -Urls "http://0.0.0.0:5080"
```

## 方式二：从远程包部署

```powershell
.\scripts\deploy-api.ps1 `
  -ServiceName DataHz.Api `
  -PackageUrl "https://example.com/datahz2-api-win-x64.zip" `
  -PackageSha256Url "https://example.com/datahz2-api-win-x64.sha256" `
  -PackageManifestUrl "https://example.com/datahz2-api-win-x64.manifest.json" `
  -RequireManifest `
  -Urls "http://0.0.0.0:5080"
```

## 健康检查

```powershell
.\scripts\smoke-test-api.ps1 -BaseUrl "http://127.0.0.1:5080"
```

关键接口：

- `GET /health`
- `GET /api/monitor/overview`
- `GET /api/jobs/stats`

## 运行状态文件

- `artifacts\releases\deploy-history.json`：部署和回滚历史。
- `artifacts\releases\active-release.txt`：当前活动版本。
- `.datahz-jobs\jobs.json`：任务队列持久化数据。
- `.datahz-jobs\audit.log`：审计日志。

## 常见问题

1. API 启动失败且提示密钥配置错误：
   - 检查 `Security.ApiKey` / `Security.Jwt` 是否开启但未配置密钥。
2. 任务不执行：
   - 检查 `JobQueue.WorkerCount` 是否为 `0`。
3. Access 相关错误：
   - 确认已安装 ACE OLEDB 驱动，位数与运行环境一致。

## 回滚

```powershell
.\scripts\rollback-api.ps1 -ServiceName DataHz.Api -Urls "http://0.0.0.0:5080"
```

回滚后建议立即执行：

```powershell
.\scripts\smoke-test-api.ps1 -BaseUrl "http://127.0.0.1:5080"
```
