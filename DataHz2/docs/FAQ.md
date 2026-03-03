# 常见问题（FAQ）

最后更新：2026-03-03

## 1. 为什么 `.xls` 模板不能直接用？

当前实现仅支持 `INI` 与 `XLSX`。旧版 `.xls` 请先转换为 `.xlsx` 后再执行。

## 2. 启用 JWT 后请求全部 `401` 怎么办？

优先检查：

- `Security.Jwt.Enabled=true`
- `Authority` 或 `SigningKey` 至少配置其一
- `ValidIssuer` / `ValidAudience` 与令牌一致
- 请求头是否为标准 `Authorization: Bearer <token>`

## 3. 作业提交成功但一直不执行？

检查 `JobQueue.WorkerCount` 是否大于 `0`，并查看：

- `GET /api/jobs/stats`
- `GET /api/monitor/overview`

## 4. 如何确认文档是否同步更新？

执行：

```powershell
.\scripts\check-docs-sync.ps1
```

若代码改动未伴随文档变更，该脚本与 CI 都会失败。

## 5. 生产发布最小流程是什么？

1. `publish-api.ps1`
2. `package-release.ps1`
3. `verify-release.ps1`
4. `deploy-prod.ps1`
5. `smoke-test-api.ps1`
