# API 接口说明

最后更新：2026-03-03

## 基础信息

- 基础地址：`http://<host>:<port>`
- 公共接口（无需鉴权）：`/health`、`/swagger/*`
- 文档调试入口：`/swagger`
- Swagger 本地化：接口摘要、分组、文档标题已中文化，并注入 `swagger-zh.js` 做常用 UI 文案中文显示。

## 鉴权与角色

当启用 `Security.ApiKey.Enabled=true` 或 `Security.Jwt.Enabled=true` 后，`/api/*` 需要凭据。

- `Viewer`：读权限（运行态/监控/查询类接口）。
- `Operator`：`Viewer` + 模板解析/执行/任务提交与取消。
- `Admin`：`Operator` + 安全与审计管理接口。

## 角色与路径映射

- `GET /api/security/whoami`：`Viewer`
- `/api/security/secrets/*`：`Admin`
- `/api/security/hardening`：`Admin`
- `/api/monitor/external-secrets/reset`：`Admin`
- `/api/runtime/*`、`/api/monitor/*`：`Viewer`
- `/api/audit/*`：`Admin`
- `/api/jobs`：`GET` 为 `Viewer`，`POST` 为 `Operator`
- `/api/tasks/*`、`/api/templates/*`：`Operator`

## 接口清单

## 健康与运行态

- `GET /health`
- `GET /api/runtime/dotnet`
- `GET /api/security/whoami`
- `GET /api/security/hardening`

## 密钥与安全运行态

- `GET /api/security/secrets/runtime`
- `POST /api/security/secrets/refresh`
- `GET /api/security/secrets/events?take=`

## 监控

- `GET /api/monitor/overview?jobs=&audit=`
- `GET /api/monitor/external-secrets?...`
- `GET /api/monitor/external-secrets/export?format=csv|jsonl&...`
- `POST /api/monitor/external-secrets/reset`
- `GET /api/monitor/jobs/{id}?audit=`

## 审计导出

- `GET /api/audit/export?format=csv|jsonl&take=&fromUtc=&toUtc=&category=&action=&jobId=`

## 模板与任务

- `POST /api/templates/parse`
- `POST /api/tasks/plan`
- `POST /api/tasks/execute`

## 异步作业

- `POST /api/jobs/submit`
- `POST /api/jobs/{id}/cancel`
- `GET /api/jobs?take=`
- `GET /api/jobs/stats`
- `GET /api/jobs/{id}`

## 请求示例

## 提交异步任务

```json
{
  "plan": {
    "templatePath": "D:\\DataHz2\\temp\\sd_test.ini",
    "sourceDirectory": "D:\\DataHz2\\temp",
    "targetDirectory": "D:\\DataHz2\\temp",
    "areaCodePath": "D:\\DataHz2\\temp\\codes.txt",
    "startIndex": 0,
    "endIndex": 10
  },
  "dryRun": false,
  "incremental": true,
  "idempotencyKey": "job-20260303-001"
}
```

## 常见状态码

- `200`：成功。
- `202`：任务已接受（如作业提交/取消请求）。
- `400`：请求参数或业务校验失败。
- `401`：缺失或无效凭据。
- `403`：角色权限不足。
- `404`：资源不存在（如作业 ID 不存在）。
- `409`：状态冲突（如已完成作业再次取消）。
