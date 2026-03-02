# DataHz 2.0

DataHz 2.0 is a full rewrite of the legacy VB6 "multi-database table aggregation" tool.

## Goals

- High efficiency: task planning and validation for county-level batch jobs.
- High flexibility: template-driven rule engine (phase-1 supports legacy INI templates).
- Fast deployment: single service API, ready for `dotnet publish` single-file deployment.

## Solution Structure

- `src/DataHz.Core`: domain models and abstraction contracts.
- `src/DataHz.Infrastructure`: legacy INI parser, area-code provider, task planner, dry-run engine.
- `src/DataHz.Api`: minimal HTTP API for parse/plan/execute.

## Current Capability (Phase-1)

- Parse legacy INI templates (`[TableInfo]`, `[ColX]`, `[ViewX]`, `[Check]`, `[LogicCheckX]`).
- Resolve VB6 placeholders (`\\` for code, `::` for name).
- Generate county task plans with NameType-compatible database file resolution.
- Dry-run execution for large-batch validation before full SQL execution is implemented.

## API Endpoints

- `GET /health`
- `POST /api/templates/parse`
- `POST /api/tasks/plan`
- `POST /api/tasks/execute`

## Example Request (`/api/tasks/plan`)

```json
{
  "templatePath": "D:\\fzhlian\\Code\\DataHz\\多数据库表格汇总程序\\模板\\sd_三调_建设用地.ini",
  "sourceDirectory": "E:\\新建文件夹\\",
  "targetDirectory": "E:\\新建文件夹\\",
  "areaCodePath": "D:\\fzhlian\\Code\\DataHz\\多数据库表格汇总程序\\行政代码\\行政代码-三调.txt",
  "startIndex": 23,
  "endIndex": 148
}
```

## Build & Run

```bash
dotnet restore DataHz2.sln
dotnet build DataHz2.sln -c Release
dotnet run --project src/DataHz.Api/DataHz.Api.csproj
```

## Notes

- Target framework is `net10.0`.
- Excel template parser (`.xls/.xlsx`) and real SQL execution pipeline are phase-2 items.
