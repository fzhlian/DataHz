# DataHz 2.0

DataHz 2.0 is a full rewrite of the legacy VB6 multi-database aggregation tool.

## Goals

- High efficiency: concurrent county-level execution with incremental cache.
- High flexibility: template-driven rule engine with legacy compatibility.
- Fast deployment: one API service, suitable for single-file publish.

## Solution Structure

- `src/DataHz.Core`: domain models and abstraction contracts.
- `src/DataHz.Infrastructure`: template parsing, Access execution, incremental state store.
- `src/DataHz.Api`: HTTP API for parse/plan/execute and async job queue.

## Current Capability

- Legacy INI template parsing (`TableInfo`, `Col`, `View`, `Check`, `LogicCheck`).
- Legacy XLSX template parsing:
  - Standard xlsx config template.
  - Flow template (`FX_*.xlsx`) with matrix SQL and multi-sheet writes.
- Access execution pipeline (`mdb/accdb` via OLEDB):
  - Column summary execution.
  - `LIST_` query support.
  - View creation and template-based export.
- Incremental cache:
  - County-level cache by source DB last-write-time + template hash.
  - Flow rollup output generation for city/province prefixes.
- Async job queue API:
  - Submit long-running jobs without blocking HTTP requests.
  - Cancel queued jobs immediately.
  - Best-effort cancel request for running jobs.
  - File-backed persistence (`jobs.json`) with restart recovery.
  - Configurable worker concurrency.
  - Automatic retention cleanup for completed jobs.
  - Poll job status/results.
- Optional API key auth for all `/api/*` endpoints.
- File-based audit trail for API and job lifecycle events.

## API Endpoints

- `GET /health`
- `GET /api/runtime/dotnet`
- `GET /api/security/whoami`
- `GET /api/security/hardening`
- `GET /api/security/secrets/runtime`
- `POST /api/security/secrets/refresh`
- `GET /api/security/secrets/events`
- `GET /api/monitor/overview`
- `GET /api/monitor/external-secrets`
- `GET /api/monitor/external-secrets/export`
- `POST /api/monitor/external-secrets/reset`
- `GET /api/monitor/jobs/{jobId}`
- `GET /api/audit/export`
- `POST /api/templates/parse`
- `POST /api/tasks/plan`
- `POST /api/tasks/execute`
- `POST /api/jobs/submit`
- `POST /api/jobs/{jobId}/cancel`
- `GET /api/jobs`
- `GET /api/jobs/stats`
- `GET /api/jobs/{jobId}`
- `GET /dashboard/`

## Quick Start (Windows)

```powershell
cd .\DataHz2
.\scripts\check-dotnet.ps1
.\scripts\run-api.ps1
```

## Publish & Service Deploy (Windows)

1. Publish single-file package:

```powershell
cd .\DataHz2
.\scripts\publish-api.ps1 -Configuration Release -Runtime win-x64
```

Optional: add `-FrameworkDependent -MultiFile` for smaller framework-dependent publish output.

Create distributable zip + SHA256:

```powershell
.\scripts\package-release.ps1 `
  -InputDir .\artifacts\publish\win-x64 `
  -OutputDir .\artifacts\packages `
  -Name datahz2-api-win-x64 `
  -Overwrite
```

The package script outputs three files:
- `datahz2-api-win-x64.zip`
- `datahz2-api-win-x64.sha256`
- `datahz2-api-win-x64.manifest.json` (contains package checksum, size, file list, and CI build metadata)

2. Install/update Windows service (run as Administrator):

```powershell
.\scripts\install-windows-service.ps1 `
  -ServiceName DataHz.Api `
  -PublishDir .\artifacts\publish\win-x64 `
  -Urls "http://0.0.0.0:5080" `
  -StartAfterInstall
```

3. Remove service:

```powershell
.\scripts\uninstall-windows-service.ps1 -ServiceName DataHz.Api
```

4. Zero-downtime style deploy with health check + auto rollback (run as Administrator):

```powershell
.\scripts\deploy-api.ps1 `
  -ServiceName DataHz.Api `
  -Configuration Release `
  -Runtime win-x64 `
  -Urls "http://0.0.0.0:5080"
```

Deploy directly from CI package zip (no local build on target machine):

```powershell
.\scripts\deploy-api.ps1 `
  -ServiceName DataHz.Api `
  -PackageZip .\artifacts\packages\datahz2-api-win-x64.zip `
  -Urls "http://0.0.0.0:5080"
```

If `datahz2-api-win-x64.sha256` exists next to the zip, deploy script verifies hash before extraction.
If `datahz2-api-win-x64.manifest.json` exists next to the zip, deploy script also validates manifest checksum/size/file list before extraction.
If `datahz2-api-win-x64.index.json` (or exactly one `datahz2-release-*.index.json`) exists next to the zip, deploy script validates runtime mapping and release asset metadata before extraction.
If matching `*.sha256` for index exists (or exactly one `datahz2-release-*.sha256`), deploy script also verifies index file hash before index JSON validation.
Add `-RequireManifest` to block deployment when manifest is missing.

Deploy from remote URL (optional bearer token + checksum/manifest URL):

```powershell
.\scripts\deploy-api.ps1 `
  -ServiceName DataHz.Api `
  -PackageUrl "https://example.com/datahz2-api-win-x64.zip" `
  -PackageSha256Url "https://example.com/datahz2-api-win-x64.sha256" `
  -PackageManifestUrl "https://example.com/datahz2-api-win-x64.manifest.json" `
  -PackageIndexUrl "https://example.com/datahz2-release-datahz2-v1.0.0.index.json" `
  -PackageIndexSha256Url "https://example.com/datahz2-release-datahz2-v1.0.0.sha256" `
  -RequireManifest `
  -PackageBearerToken "<token>" `
  -Urls "http://0.0.0.0:5080"
```

Use `-PackageIndexFile` (local) or `-PackageIndexUrl` (remote) to bind deployment to a specific release index file.
`PackageIndexFile` and `PackageIndexUrl` are mutually exclusive; `PackageIndexUrl` requires `PackageUrl`.
Use `-PackageIndexSha256File` (local) or `-PackageIndexSha256Url` (remote) for detached index hash verification.
`PackageIndexSha256File` and `PackageIndexSha256Url` are mutually exclusive; `PackageIndexSha256Url` requires `PackageIndexUrl`.
For URL-based deploy, downloaded filenames keep the source URL basename so manifest/index file-name checks stay consistent.

Production profile wrapper (forces `RequireManifest` + smoke test):

```powershell
.\scripts\deploy-prod.ps1 `
  -ServiceName DataHz.Api `
  -PackageZip .\artifacts\packages\datahz2-api-win-x64.zip `
  -PackageSha256File .\artifacts\packages\datahz2-api-win-x64.sha256 `
  -PackageManifestFile .\artifacts\packages\datahz2-api-win-x64.manifest.json `
  -PackageIndexFile .\artifacts\packages\datahz2-release-datahz2-v1.0.0.index.json `
  -PackageIndexSha256File .\artifacts\packages\datahz2-release-datahz2-v1.0.0.sha256 `
  -Urls "http://0.0.0.0:5080"
```

For remote package in production profile, `-PackageManifestUrl` is required and `-PackageIndexUrl` + `-PackageIndexSha256Url` are recommended.
`deploy-prod.ps1` blocks `-SkipServiceInstall` and `-SkipHealthCheck` by default. Use `-AllowUnsafeBypass` only for local/CI test scenarios.

5. One-click rollback to previous successful release:

```powershell
.\scripts\rollback-api.ps1 -ServiceName DataHz.Api -Urls "http://0.0.0.0:5080"
```

6. Run smoke checks after deployment:

```powershell
.\scripts\smoke-test-api.ps1 -BaseUrl "http://127.0.0.1:5080"
```

If API auth is enabled, pass key/token and require authenticated API checks:

```powershell
.\scripts\deploy-api.ps1 `
  -ServiceName DataHz.Api `
  -Urls "http://0.0.0.0:5080" `
  -RunSmokeTest `
  -SmokeApiKey "<viewer-or-admin-key>" `
  -SmokeRequireAuthenticatedApi
```

Deployment metadata is stored under `artifacts\releases`:
- `deploy-history.json`: deployment and rollback history.
- `active-release.txt`: current active release id.

`deploy-history.json` key fields:
- `releaseId`, `releaseDir`, `serviceName`, `startedAtUtc`, `completedAtUtc`, `status`, `healthUrl`
- package source fields: `packageZip`, `packageSha256File`, `packageManifestFile`, `packageIndexFile`, `packageIndexSha256File`
- package URL fields: `packageUrl`, `packageSha256Url`, `packageManifestUrl`, `packageIndexUrl`, `packageIndexSha256Url`
- failure/rollback fields: `error`, `rollbackTo`, `rollbackError`

Release management helpers:

```powershell
.\scripts\list-releases.ps1
.\scripts\prune-releases.ps1 -KeepReleases 5
.\scripts\deployment-status.ps1 -BaseUrl "http://127.0.0.1:5080"
.\scripts\audit-deploy-history.ps1 -Take 20
.\scripts\audit-deploy-history.ps1 -Take 20 -FailOnIssues
.\scripts\check-history-audits.ps1
.\scripts\check-ci-contracts.ps1
.\scripts\verify-release.ps1 -PackageZip .\artifacts\packages\datahz2-api-win-x64.zip
.\scripts\verify-release-assets.ps1 `
  -AssetsDir .\artifacts\packages `
  -Tag datahz2-v1.0.0 `
  -Runtimes @("win-x64", "win-arm64")
.\scripts\check-deploy-guards.ps1
.\scripts\check-deploy-guards.ps1 `
  -PackageZip .\artifacts\packages\datahz2-api-win-x64.zip `
  -IncludeOnlineSmokeCase `
  -OnlineSmokePublishDir .\artifacts\publish\win-x64
```

`prune-releases.ps1` also cleans matching `_downloads\<releaseId>` cache directories.
`audit-deploy-history.ps1` validates recent deploy-history records and can fail CI (`-FailOnIssues`) when required metadata is missing.
`check-history-audits.ps1` is a lightweight self-test for `audit-deploy-history.ps1` and `deployment-status.ps1` audit fields/exit codes.
`check-ci-contracts.ps1` enforces required CI workflow guardrail steps and fallback-cleanup contracts.
It also checks workflow triggers/concurrency/runtime matrix, fallback step arguments (`-IncludeOnlineSmokeCase`, no explicit `-OnlineSmokePublishDir`), ensures fallback/cleanup step base names match, enforces `if: matrix.runtime == 'win-x64'` gate, and validates key build/fallback step ordering in CI workflows.
`verify-release.ps1` validates package hash, manifest, and archive file list consistency.
`verify-release-assets.ps1` validates downloaded multi-runtime release assets (`zip/sha256/manifest`) before final publishing and emits:
- `datahz2-release-<tag>.index.json` (runtime assets + sha values + GitHub run/commit provenance when available)
- `datahz2-release-<tag>.sha256`
`check-deploy-guards.ps1` validates deployment guardrails (`RequireManifest`, package-index/index-sha validation, local/URL package source checks, env default parsing, production wrapper parameter checks).
When `-PackageZip` is omitted and the default package is missing, `check-deploy-guards.ps1` auto-generates a test package from `artifacts\publish` (prefers `verify-fd` or the most recent valid publish directory).
Auto-generated fallback package files are temporary and are removed automatically when the self-test completes.
Use `-IncludeOnlineSmokeCase` to additionally validate production wrapper success path with a temporary local API process.
When `-OnlineSmokePublishDir` is omitted, the script auto-selects a valid directory from `artifacts\publish` (prefer auto-package source, then `verify-fd`, then latest valid publish folder).
`list-releases.ps1` includes `RequireManifest`, `Manifest`, `Index`, and `IndexSha` columns for quick audit.
`deployment-status.ps1` includes recent-history audit summary (`auditedEntries/issueEntries`) and per-entry columns (`hasManifest/hasIndex/hasIndexSha/issueCount`).

## Async Job Request Example

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

`idempotencyKey` is optional. When set, duplicate submits with the same key will reuse an existing active job (`Queued`/`Running`) instead of creating a new one.

## Configuration

`src/DataHz.Api/appsettings.json` includes:

- `JobQueue.StoreDirectory`: queue store directory (`.datahz-jobs` by default).
- `JobQueue.RetentionDays`: retention window for completed jobs.
- `JobQueue.MaxListTake`: upper bound for `GET /api/jobs?take=`.
- `JobQueue.WorkerCount`: parallel worker count (`0` disables background execution).
- `Security.ApiKey.Enabled`: `true` to enable API key auth.
- `Security.ApiKey.HeaderName`: request header name, default `X-Api-Key`.
- `Security.ApiKey.Value`: legacy single key value.
- `Security.ApiKey.DefaultRole`: role for legacy single key (`Viewer`/`Operator`/`Admin`).
- `Security.ApiKey.Keys`: multi-key list with `Name` + `Key` + `Role`.
- `Security.Jwt.Enabled`: enable JWT bearer auth.
- `Security.Jwt.Authority`: OIDC authority/JWKS provider (optional).
- `Security.Jwt.Audience`: JWT audience (optional).
- `Security.Jwt.ValidIssuer`: static issuer for local/closed deployments.
- `Security.Jwt.ValidAudience`: static audience for local/closed deployments.
- `Security.Jwt.SigningKey`: symmetric signing key (HMAC mode).
- `Security.Jwt.RoleClaimType`: role claim name (default `role`).
- `Security.Jwt.NameClaimType`: principal name claim (default `name`).
- `Security.Secrets.CacheTtlSeconds`: in-memory secret cache TTL in seconds.
- `Security.Secrets.CacheMaxStaleSeconds`: stale fallback window when secret source is unavailable.
- `Security.Secrets.RotationGraceSeconds`: allow previous key for this many seconds after rotation.
- `Security.Secrets.AllowCommandExecution`: allow reading secrets by shell command.
- `Security.Secrets.CommandTimeoutSeconds`: timeout for secret commands (1-60 seconds).
- `Security.Secrets.ApiKeyCommand`: command used to resolve API key when enabled.
- `Security.Secrets.JwtSigningKeyCommand`: command used to resolve JWT signing key when enabled.
- `Security.Secrets.EnableExternalProvider`: enable external secret provider.
- `Security.Secrets.ExternalProvider`: provider type (`none`/`file`/`vault`/`azurekv`/`awssm`/`gcpsm`/`aliyunkms`).
- `Security.Secrets.ExternalTimeoutSeconds`: timeout for external secret fetch (1-60 seconds).
- `Security.Secrets.ApiKeyExternalRef`: secret reference for API key.
- `Security.Secrets.JwtSigningKeyExternalRef`: secret reference for JWT signing key.
- `Security.Secrets.File.RootDirectory`: root path when using file provider with relative refs.
- `Security.Secrets.Vault.Address`: Vault server address (for example `https://vault.example.com`).
- `Security.Secrets.Vault.Mount`: Vault mount (default `secret`).
- `Security.Secrets.Vault.KvVersion`: KV version (`1` or `2`, default `2`).
- `Security.Secrets.Vault.Token`: optional static Vault token.
- `Security.Secrets.Vault.TokenEnvVar`: env var used for Vault token when `Token` is empty.
- `Security.Secrets.Vault.Namespace`: optional Vault enterprise namespace.
- `Security.Secrets.Vault.TokenHeaderName`: token header name (default `X-Vault-Token`).
- `Security.Secrets.AzureKeyVault.VaultUri`: Azure Key Vault URI.
- `Security.Secrets.AzureKeyVault.TenantId`: service principal tenant ID (optional).
- `Security.Secrets.AzureKeyVault.ClientId`: service principal client ID (optional).
- `Security.Secrets.AzureKeyVault.ClientSecret`: service principal client secret (optional).
- `Security.Secrets.AzureKeyVault.ManagedIdentityClientId`: user-assigned managed identity client ID (optional).
- `Security.Secrets.AwsSecretsManager.Region`: AWS region (for example `ap-southeast-1`).
- `Security.Secrets.AwsSecretsManager.AccessKeyId`: optional static AWS access key ID.
- `Security.Secrets.AwsSecretsManager.SecretAccessKey`: optional static AWS secret access key.
- `Security.Secrets.AwsSecretsManager.SessionToken`: optional AWS session token.
- `Security.Secrets.GcpSecretManager.ProjectId`: GCP project ID used for short secret refs.
- `Security.Secrets.GcpSecretManager.CredentialsPath`: optional service account JSON path.
- `Security.Secrets.AliyunKms.RegionId`: AliCloud region ID (for example `cn-hangzhou`).
- `Security.Secrets.AliyunKms.Endpoint`: optional KMS endpoint host (for example `kms.cn-hangzhou.aliyuncs.com`).
- `Security.Secrets.AliyunKms.AccessKeyId`: optional static AliCloud access key ID.
- `Security.Secrets.AliyunKms.AccessKeySecret`: optional static AliCloud access key secret.
- `Security.Secrets.AliyunKms.SecurityToken`: optional AliCloud STS token.
- `Security.Secrets.AliyunKms.VersionStage`: secret version stage (default `ACSCurrent`).
- `Security.Secrets.AliyunKms.VersionId`: optional explicit secret version ID (overrides `VersionStage` when set).
- `Audit.Enabled`: enable/disable audit trail.
- `Audit.FilePath`: audit log file path.
- `Monitoring.DefaultJobTake`: default recent-job count for monitor API.
- `Monitoring.MaxJobTake`: max recent-job count for monitor API.
- `Monitoring.DefaultAuditTake`: default recent-audit count for monitor API.
- `Monitoring.MaxAuditTake`: max recent-audit count for monitor API.

When security is enabled (`ApiKey` or `Jwt`), `/api/*` requires credentials and enforces role-based access:
- `Viewer`: read-only APIs (`/api/runtime/*`, `/api/monitor/*`, `/api/jobs` GET).
- `Operator`: includes viewer permissions + parse/plan/execute + submit/cancel jobs.
- `Admin`: includes operator permissions + `/api/audit/export` + `/api/security/hardening` + `/api/security/secrets/*`.

You can run API key only, JWT only, or hybrid mode (both enabled).

Environment variable overrides:
- `DATAHZ_APIKEY`: overrides `Security.ApiKey.Value`.
- `DATAHZ_JWT_SIGNING_KEY`: overrides `Security.Jwt.SigningKey`.
- `DATAHZ_DEPLOY_REQUIRE_MANIFEST`: deploy-script default for `RequireManifest` when `deploy-api.ps1` parameter is not provided (`true/false`, `1/0`, `yes/no`, `on/off`).
- `deploy-api.ps1 -RequireManifest` takes precedence over `DATAHZ_DEPLOY_REQUIRE_MANIFEST`.
- `DATAHZ_VAULT_TOKEN`: default env token used by Vault provider.
- `DATAHZ_AZURE_KEYVAULT_URI`: default Key Vault URI when `Security.Secrets.AzureKeyVault.VaultUri` is empty.
- `AWS_REGION` / `AWS_DEFAULT_REGION`: default AWS region when `Security.Secrets.AwsSecretsManager.Region` is empty.
- `GOOGLE_CLOUD_PROJECT` / `GCP_PROJECT`: default GCP project when `Security.Secrets.GcpSecretManager.ProjectId` is empty.
- `GOOGLE_APPLICATION_CREDENTIALS`: default GCP credential JSON path when `Security.Secrets.GcpSecretManager.CredentialsPath` is empty.
- `ALIBABA_CLOUD_REGION_ID` / `ALICLOUD_REGION_ID`: default AliCloud region when `Security.Secrets.AliyunKms.RegionId` is empty.
- `ALIBABA_CLOUD_ACCESS_KEY_ID` / `ALICLOUD_ACCESS_KEY`: default AliCloud access key ID when `Security.Secrets.AliyunKms.AccessKeyId` is empty.
- `ALIBABA_CLOUD_ACCESS_KEY_SECRET` / `ALICLOUD_ACCESS_KEY_SECRET`: default AliCloud access key secret when `Security.Secrets.AliyunKms.AccessKeySecret` is empty.
- `ALIBABA_CLOUD_SECURITY_TOKEN`: default AliCloud STS token when `Security.Secrets.AliyunKms.SecurityToken` is empty.
- `ALIBABA_CLOUD_KMS_ENDPOINT`: default KMS endpoint host when `Security.Secrets.AliyunKms.Endpoint` is empty.

Secret resolution precedence:
- API key: `DATAHZ_APIKEY` -> external provider (`ApiKeyExternalRef`) -> command (`ApiKeyCommand`) -> `Security.ApiKey.Value`.
- JWT signing key: `DATAHZ_JWT_SIGNING_KEY` -> external provider (`JwtSigningKeyExternalRef`) -> command (`JwtSigningKeyCommand`) -> `Security.Jwt.SigningKey`.

Rotation behavior:
- Primary API key (resolved by env/external/command) is checked dynamically per request, so secret updates can take effect without restarting the service.
- Symmetric JWT signing key in local mode is resolved dynamically during token validation, so key rotation can also take effect without restart.
- `RotationGraceSeconds > 0` enables smooth cutover (current + previous key accepted during grace window).
- `CacheMaxStaleSeconds > 0` enables temporary stale-secret fallback during provider outages.

Admin secret operations:
- `GET /api/security/secrets/runtime`: shows non-sensitive runtime cache/status info (no secret values), including external provider runtime attempts/latency/error summary.
- `POST /api/security/secrets/refresh`: forces immediate refresh from configured secret sources.
- `GET /api/security/secrets/events`: shows recent secret-operation audit entries (`security.secrets_*`).

External provider monitor endpoint:
- `GET /api/monitor/external-secrets`: viewer-level telemetry list for provider attempts.
- Query params: `take`, `provider`, `purpose`, `status`, `windowMinutes`, `fromUtc`, `toUtc`.
- `GET /api/monitor/external-secrets/export`: export filtered telemetry as `csv`/`jsonl`.
- `POST /api/monitor/external-secrets/reset`: admin-only telemetry cleanup, supports optional filters `provider`, `purpose`, `status`, `windowMinutes`, `fromUtc`, `toUtc` (no filters = clear all).

External reference format:
- `file`: absolute file path, or relative path under `Security.Secrets.File.RootDirectory`.
- `vault`: `path#field` (for example `datahz/security#api_key`).
- `azurekv`: `secretName` or `secretName/version` (also supports full secret URL).
- `awssm`: `secretId` or `secretId#jsonField` (for example `prod/datahz/api#apiKey`).
- `gcpsm`: `secretId`, `secretId/version`, or full `projects/<p>/secrets/<s>/versions/<v>`, with optional `#jsonField`.
- `aliyunkms`: `secretName` or `secretName#jsonField` (secret value can be JSON and projected by field).

`/health` and `/swagger` stay public.

## Monitor UI

Open `http://localhost:<port>/dashboard/` to view queue counters, recent jobs, selected-job drill-down, recent audit events, external secret-provider health snapshot, security hardening summary, and one-click audit export.
If API key is enabled, fill it in the page header once; it is saved to browser `localStorage`.

## Test

```powershell
dotnet test .\DataHz2.sln -c Release
```

## CI

GitHub Actions workflow: `.github/workflows/datahz2-ci.yml`
- enable workflow concurrency (`cancel-in-progress`) to avoid duplicate runs on the same ref
- run on `DataHz2/**`, `.github/workflows/datahz2-ci.yml`, and `.github/workflows/datahz2-release.yml` changes
- validate PowerShell deployment scripts
- verify deploy-history/deployment-status audit script behavior (`check-history-audits.ps1`)
- verify CI workflow contracts (`check-ci-contracts.ps1`)
- run `build-test` job first (restore/build/test on Windows)
- run `package-verify` matrix job for `win-x64` and `win-arm64`
- cache NuGet packages (`actions/cache`) in both jobs to reduce restore time
- use runtime-specific restore + `publish --no-restore` in matrix job
- verify package integrity (`verify-release.ps1`)
- verify deployment guardrails (`check-deploy-guards.ps1`)
- verify guardrail auto-package fallback path (missing `-PackageZip` target) and online success case (`-IncludeOnlineSmokeCase`) with auto-selected publish directory on `win-x64`
- assert fallback guard artifacts are auto-cleaned after self-test
- run package smoke test on `win-x64`
- collect smoke stdout/stderr separately on failure for faster troubleshooting
- publish runtime-specific artifacts:
  - `datahz2-win-x64-package`
  - `datahz2-win-arm64-package`

Tag release workflow: `.github/workflows/datahz2-release.yml`
- trigger: push tag `datahz2-v*` (for example `datahz2-v1.0.0`)
- run `build-test` job first (restore/build/test on Windows)
- verify deploy-history/deployment-status audit script behavior (`check-history-audits.ps1`)
- verify CI workflow contracts (`check-ci-contracts.ps1`)
- run `package-verify` matrix job for `win-x64` and `win-arm64`
- cache NuGet packages (`actions/cache`) in both jobs to reduce restore time
- use runtime-specific restore + `publish --no-restore` in matrix job
- verify package integrity (`verify-release.ps1`)
- verify deployment guardrails (`check-deploy-guards.ps1`)
- verify guardrail auto-package fallback path (missing `-PackageZip` target) and online success case (`-IncludeOnlineSmokeCase`) with auto-selected publish directory on `win-x64`
- assert fallback guard artifacts are auto-cleaned after self-test
- run package smoke test on `win-x64`
- collect smoke stdout/stderr separately on failure for faster troubleshooting
- publish assets in a separate `publish-release` job gated by GitHub Environment `datahz2-production`
- verify downloaded release assets again in `publish-release` (`verify-release-assets.ps1`) before uploading to GitHub Release
- create GitHub Release and upload:
  - `datahz2-api-win-x64-<tag>.zip/.sha256/.manifest.json`
  - `datahz2-api-win-arm64-<tag>.zip/.sha256/.manifest.json`
  - `datahz2-release-<tag>.index.json`
  - `datahz2-release-<tag>.sha256`

Set required reviewers in repository settings for environment `datahz2-production` to enable manual approval before publishing release assets.

## Notes

- `.xls` templates are not supported in this build; convert to `.xlsx` first.
- Access provider required: `Microsoft ACE OLEDB 12.0+`.
- SSO/JWT production hardening checklist: `docs/SSO_HARDENING_RUNBOOK.md`.
