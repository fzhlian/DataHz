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
2. Phase-2: Access connector + SQL execution engine + xlsx parser + result writer.
3. Phase-3: DuckDB result store + incremental recomputation + web UI.
4. Phase-4: production hardening (auth, audit, monitoring, job queue).

## Risk Controls

- Keep old template semantics unchanged where possible.
- Build regression packs from representative historical templates.
- Compare county-level outputs against VB6 output baselines.
