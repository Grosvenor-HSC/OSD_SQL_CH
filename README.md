# NewCHSQL

This repository contains SQL Server scripts used to load, transform, enrich, and build reporting outputs
for CH/OSD reporting.

## Folder layout
- `sql/10_extract/`   External pulls (e.g. Linked Server / OPENQUERY)
- `sql/20_stage/`     Entity loads (initial + incremental)
- `sql/30_core/`      Derived/enrichment tables (e.g. visit distance)
- `sql/40_reporting/` Reporting builds (tables/views used by BI)
- `orchestration/`    Run order scripts (SQL Agent / manual execution)
- `tests/`            Sanity checks

## How to run
### One-time initial build
Run: `orchestration/sql_agent/run_initial.sql`

### Daily refresh
Run: `orchestration/sql_agent/run_daily.sql`

## Important safety notes
- “Initial” scripts are one-time backfills. Do not run casually on production.
- Incrementals should not be run in parallel unless you are certain they are isolated.
- Reporting builds should run only after upstream loads complete.
