# SSO/JWT 生产加固手册（DataHz.Api）

最后更新：2026-03-03

适用范围：`Security.Jwt.Enabled=true` 的部署环境。

## 基线控制

1. 固定可信签发方
   - 设置 `Security.Jwt.ValidIssuer`
   - 若使用 OIDC，`Authority` 与 `ValidIssuer` 应保持同一信任域
2. 固定受众
   - 设置 `Security.Jwt.ValidAudience`（或 `Audience`）
3. 强制 HTTPS 元数据
   - 生产设置 `Security.Jwt.RequireHttpsMetadata=true`
4. 保持严格时钟偏移
   - 默认偏移 2 分钟，除非事故处置不得放宽
5. 角色 Claim 对齐
   - `RoleClaimType` 与 IdP 保持一致（如 `role`/`roles`）
   - 仅映射 `Viewer`、`Operator`、`Admin`
6. 密钥保护
   - 优先使用外部密钥服务，不在配置文件中存明文
   - 对称签名模式建议每 90 天轮换一次

## 发布前检查

1. 配置一致性
   - `Security.Jwt.Enabled=true`
   - `Security.ApiKey.Enabled` 是否按预期（纯 SSO 或混合应急）
2. 信任链路
   - `Authority` 从部署机可达
   - TLS 证书链合法
3. 身份映射
   - 使用真实令牌调用 `/api/security/whoami`
4. 鉴权边界
   - `Viewer` 仅可读
   - `Operator` 可提交/取消任务
   - `Admin` 可访问安全与审计管理接口
5. 审计有效
   - `Audit.Enabled=true`
   - 鉴权失败写入 `security.*` 事件

## 事件响应

1. 疑似令牌滥用
   - 轮换签名密钥或在 IdP 侧吊销会话/密钥
2. 疑似密钥泄露
   - 立即更新外部密钥，排查配置与日志中是否残留明文
3. 应急兜底
   - 可临时启用混合模式，用短时效管理员 API Key 做故障处置
   - 同步收缩入口网络范围

## 验证命令

```powershell
dotnet build .\DataHz2.sln -c Release
dotnet test .\DataHz2.sln -c Release
```
