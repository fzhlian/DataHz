# 安全策略

最后更新：2026-03-03

## 支持范围

当前受支持并持续维护的版本为 `DataHz2` 主分支最新代码。

## 漏洞上报

请不要在公开 Issue 直接披露可利用细节，建议通过私有渠道联系维护者并附上：

- 漏洞类型与影响范围
- 复现步骤
- 影响版本与环境
- 临时缓解建议（如有）

## 安全基线

- API 可启用 `ApiKey`、`JWT` 或混合鉴权模式。
- `Security.Secrets` 支持环境变量、命令、外部密钥服务多来源解析。
- 审计日志默认开启（`Audit.Enabled=true`）。
- SSO 加固基线参见：
  - [DataHz2/docs/SSO_HARDENING_RUNBOOK.md](/d:/fzhlian/Code/DataHz/DataHz2/docs/SSO_HARDENING_RUNBOOK.md)

## 轮换建议

- 非 OIDC 对称签名密钥：至少每 90 天轮换一次。
- API Key：按环境设置轮换窗口，并开启 `RotationGraceSeconds` 平滑切换。
- 生产环境优先使用外部密钥服务，不在仓库中保存明文密钥。
