# DataHz 2.0

DataHz 2.0 is a full rewrite of the legacy VB6 multi-database aggregation tool.

## Goals

- High efficiency: concurrent county-level execution with incremental cache.
- High flexibility: template-driven rule engine with legacy compatibility.
- Fast deployment: one API service, suitable for single-file publish.

## Solution Structure

- `src/DataHz.Core`: domain models and abstraction contracts.
- `src/DataHz.Infrastructure`: template parsing, Access execution, incremental state store.
- `src/DataHz.Api`: HTTP API for parse/plan/execute.

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

## API Endpoints

- `GET /health`
- `GET /api/runtime/dotnet`
- `POST /api/templates/parse`
- `POST /api/tasks/plan`
- `POST /api/tasks/execute`

## Quick Start (Windows)

```powershell
cd .\DataHz2
.\scripts\check-dotnet.ps1
.\scripts\run-api.ps1
```

## Manual Build

```bash
dotnet restore DataHz2.sln
dotnet build DataHz2.sln -c Release
dotnet run --project src/DataHz.Api/DataHz.Api.csproj
```

## Execute Request Example

```json
{
  "plan": {
    "templatePath": "D:\\fzhlian\\Code\\DataHz\\多数据库表格汇总程序\\模板\\sd_三调_建设用地.ini",
    "sourceDirectory": "E:\\新建文件夹\\",
    "targetDirectory": "E:\\新建文件夹\\",
    "areaCodePath": "D:\\fzhlian\\Code\\DataHz\\多数据库表格汇总程序\\行政代码\\行政代码-三调.txt",
    "startIndex": 23,
    "endIndex": 148
  },
  "dryRun": false,
  "incremental": true
}
```

## Notes

- `.xls` templates are not supported in this build; convert to `.xlsx` first.
- Access provider required: `Microsoft ACE OLEDB 12.0+`.
