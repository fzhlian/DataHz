# SSO Hardening Runbook (DataHz.Api)

## Scope

This runbook applies to deployments that enable `Security.Jwt.Enabled=true`.
Target date baseline: 2026-03-03.

## Baseline Controls

1. Enforce trusted issuer:
   - Set `Security.Jwt.ValidIssuer` to your IdP issuer URL.
   - If OIDC discovery is used, set `Security.Jwt.Authority` to the same trust domain.
2. Enforce audience:
   - Set `Security.Jwt.ValidAudience` (or `Security.Jwt.Audience`) to the API resource ID.
3. Enforce HTTPS metadata in production:
   - Set `Security.Jwt.RequireHttpsMetadata=true`.
4. Keep token lifetime strict:
   - Default clock skew is 2 minutes; do not raise without incident justification.
5. Use role claims mapped to platform roles:
   - Keep `Security.Jwt.RoleClaimType` aligned with IdP (`role` or `roles`).
   - Map only `Viewer`, `Operator`, `Admin`.
6. Protect signing material:
   - Prefer env/external secret provider over inline config.
   - If using Azure Key Vault, set `Security.Secrets.ExternalProvider=azurekv` and store signing key as a secret.
   - Rotate symmetric signing keys at least every 90 days for non-OIDC local mode.

## Deployment Checklist

1. Validate config before release:
   - `Security.Jwt.Enabled=true`
   - `Security.ApiKey.Enabled` mode chosen intentionally (`false` for pure SSO, `true` for hybrid break-glass).
2. Verify trust path:
   - `Authority` reachable from app host.
   - TLS certificate chain valid.
3. Verify claim mapping:
   - Use `/api/security/whoami` with a real token.
   - Confirm `role` resolved as expected.
4. Verify authorization boundaries:
   - `Viewer` can read monitor/runtime.
   - `Operator` can submit/cancel jobs.
   - `Admin` can call `/api/audit/export` and `/api/security/hardening`.
5. Verify audit:
   - Ensure `Audit.Enabled=true` in production.
   - Confirm auth failures produce `security.*` audit actions.

## Incident Response

1. Suspected token abuse:
   - Rotate signing key or revoke IdP keys/session.
   - Temporarily disable affected role mapping in IdP.
2. Suspected secret leak:
   - Rotate external secret immediately.
   - Validate no plaintext secret remains in config history.
3. Emergency containment:
   - Enable hybrid mode and use short-lived admin API key for break-glass.
   - Restrict ingress to trusted network segment until IdP trust is restored.

## Validation Commands

```powershell
# Build and run tests
& "C:\Program Files\dotnet\dotnet.exe" build .\DataHz2.sln -c Release
& "C:\Program Files\dotnet\dotnet.exe" test .\DataHz2.sln -c Release
```
