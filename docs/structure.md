# Repository Structure Rules

## Naming
- Use lowercase + underscores for new files
- Avoid spaces in filenames
- Use `initial.sql` and `incremental.sql` inside entity folders

## Where new work goes
- New extraction from a linked server → `sql/10_extract/<source>/`
- New entity load scripts → `sql/20_stage/<entity>/`
- New reusable derived tables → `sql/30_core/<topic>/`
- New BI/reporting builds → `sql/40_reporting/<report>/`

## Script header standard (recommended)
Every SQL file should start with:

-- Purpose:
-- Source:
-- Target:
-- Run frequency:
-- Safe to re-run:
-- Notes:
