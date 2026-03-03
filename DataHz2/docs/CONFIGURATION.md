# 配置说明

最后更新：2026-03-03

## 配置文件位置

- 主配置：`DataHz2/src/DataHz.Api/appsettings.json`

## 核心配置块

## `JobQueue`

- `StoreDirectory`：队列持久化目录（默认 `.datahz-jobs`）。
- `RetentionDays`：已完成任务保留天数。
- `MaxListTake`：`GET /api/jobs?take=` 上限。
- `WorkerCount`：后台执行并发数，`0` 表示禁用后台执行。

## `Security.ApiKey`

- `Enabled`：启用 API Key 鉴权。
- `HeaderName`：请求头名，默认 `X-Api-Key`。
- `Value`：单密钥模式值（可被环境变量覆盖）。
- `DefaultRole`：默认角色（`Viewer/Operator/Admin`）。
- `Keys`：多密钥配置列表（`Name/Key/Role`）。

## `Security.Jwt`

- `Enabled`：启用 JWT 鉴权。
- `Authority/Audience`：OIDC 模式设置。
- `ValidIssuer/ValidAudience`：静态签发方/受众校验。
- `SigningKey`：对称签名密钥（本地模式）。
- `RequireHttpsMetadata`：生产建议 `true`。
- `RoleClaimType/NameClaimType`：Claim 映射名称。

## `Security.Secrets`

- 缓存与轮换：
  - `CacheTtlSeconds`
  - `CacheMaxStaleSeconds`
  - `RotationGraceSeconds`
- 命令源：
  - `AllowCommandExecution`
  - `CommandTimeoutSeconds`
  - `ApiKeyCommand`
  - `JwtSigningKeyCommand`
- 外部密钥源：
  - `EnableExternalProvider`
  - `ExternalProvider`：`none/file/vault/azurekv/awssm/gcpsm/aliyunkms`
  - `ApiKeyExternalRef`
  - `JwtSigningKeyExternalRef`

## `Audit`

- `Enabled`：启用审计。
- `FilePath`：审计日志输出路径。

## `Monitoring`

- `DefaultJobTake/MaxJobTake`
- `DefaultAuditTake/MaxAuditTake`

## 环境变量覆盖

- `DATAHZ_APIKEY`：覆盖 `Security.ApiKey.Value`
- `DATAHZ_JWT_SIGNING_KEY`：覆盖 `Security.Jwt.SigningKey`
- `DATAHZ_DEPLOY_REQUIRE_MANIFEST`：部署脚本默认值
- `DATAHZ_VAULT_TOKEN`：Vault 令牌
- `DATAHZ_AZURE_KEYVAULT_URI`：Azure Key Vault URI
- `AWS_REGION` / `AWS_DEFAULT_REGION`：AWS 区域
- `GOOGLE_CLOUD_PROJECT` / `GCP_PROJECT`：GCP 项目
- `GOOGLE_APPLICATION_CREDENTIALS`：GCP 凭据路径
- `ALIBABA_CLOUD_REGION_ID` / `ALICLOUD_REGION_ID`：阿里云地域
- `ALIBABA_CLOUD_ACCESS_KEY_ID` / `ALICLOUD_ACCESS_KEY`
- `ALIBABA_CLOUD_ACCESS_KEY_SECRET` / `ALICLOUD_ACCESS_KEY_SECRET`
- `ALIBABA_CLOUD_SECURITY_TOKEN`
- `ALIBABA_CLOUD_KMS_ENDPOINT`

## 密钥解析优先级

- API Key：`DATAHZ_APIKEY` -> 外部密钥 -> 命令 -> `Security.ApiKey.Value`
- JWT Key：`DATAHZ_JWT_SIGNING_KEY` -> 外部密钥 -> 命令 -> `Security.Jwt.SigningKey`

## 推荐配置实践

1. 生产环境禁用明文 `Value/SigningKey`，优先外部密钥服务。
2. 启用 `Audit.Enabled=true`，保留审计链路。
3. 启用 JWT 时设置 `RequireHttpsMetadata=true`。
4. 根据任务量设置 `WorkerCount`，避免单机过载。
