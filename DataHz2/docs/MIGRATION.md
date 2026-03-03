# Migration Map (VB6 -> DataHz 2.0)

## Core Correspondence

- `GetTableInfo` / `GetTableInfo_xlsx` / `GetTableInfo_LL_xlsx`
  -> `ITemplateParser` (`LegacyIniTemplateParser` in phase-1)
- `GetXZCode`
  -> `IAreaCodeProvider` (`TextAreaCodeProvider`)
- `FormatText`
  -> `PlaceholderResolver`
- `SumTable` / `SumTable_LL` / `SumTable_To_Mdb`
  -> `ITaskPlanner` + `IExecutionEngine` (dry-run now, SQL engine in phase-2)
- `OpenDB`
  -> planned connector layer (phase-2)
- `DoExpor` / `ExporToExcel`
  -> planned export service (phase-2)

## Phase Plan

1. Phase-1 (done): architecture baseline + legacy INI compatibility + task planning API.
2. Phase-2 (done): Access connector + SQL execution engine + column summary pipeline.
3. Phase-3 (done in current baseline):
   - xlsx parser (standard + FX flow template),
   - template-based Excel export,
   - county-level incremental cache (source file timestamp + template hash),
   - flow rollup file generation.
4. Phase-4 (in progress): production hardening
   - done: async job queue + file-backed persistence + queue stats + cancel API + configurable worker concurrency + API key auth switch + role-based key permissions + JWT bearer integration (OIDC/symmetric mode) + env/command secret overrides + external secret provider abstraction (file/vault/azure key vault/aws secrets manager/gcp secret manager/aliyun kms) + online key rotation support (API key/JWT symmetric key without restart) + rotation grace window + secret cache/stale fallback + admin secret runtime/refresh/events API + external provider runtime telemetry (attempt/success/latency/error) + security hardening report API + monitor external-secrets API + monitor external-secrets export/reset API + audit trail + monitor overview API + monitor job drill-down API + audit export API + built-in dashboard UI + API integration tests + SSO hardening runbook.

## Risk Controls

- Keep old template semantics unchanged where possible.
- Build regression packs from representative historical templates.
- Compare county-level outputs against VB6 output baselines.
