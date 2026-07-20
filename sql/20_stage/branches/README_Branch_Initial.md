# Branch (Stage) — Initial

File:
- `Branch_Initial.sql`

Procedure:
- `dbo.usp_Sync_Branch_Initial`

Targets:
- `dbo.tbl_Branch`
- `dbo.CT_Watermark` (shared watermark table)

Source:
- `dbo.GLOB_SITE` (Change Tracking enabled)
- `dbo.tbl_EarlyPayInitialRatesTable` (lookup for early pay rate)

## What it does

`usp_Sync_Branch_Initial` is a **baseline build** of the branch staging table.

It:
1. Takes an **exclusive AppLock** (`DOM_LIVE:Sync:Branch`) to prevent concurrent Branch runs.
2. Validates Change Tracking is enabled:
   - At the database level
   - On `dbo.GLOB_SITE`
3. Captures the **CT fence version at the start** (`CHANGE_TRACKING_CURRENT_VERSION()`).
4. Writes that version into `dbo.CT_Watermark` for process `Branch`.
5. Drops and recreates `dbo.tbl_Branch`, then bulk loads all branch rows from `dbo.GLOB_SITE`, applying:
   - GS_REF → `Old_Branch_UUID` (TRY_CONVERT to int)
   - Branch name remaps for special IDs:
     - `1970000043` → `Southampton`
     - `1970000069` → `Old_Southampton`
   - Trim/NULLIF cleaning on Brand/Active
   - Early pay rate lookup from `tbl_EarlyPayInitialRatesTable`
   - A deliberate **extra synthetic row**:
     - Adds `Portsmouth` when Southampton exists (same GS_REF 1970000043, different Branch_Name)
6. Adds indexes + uniqueness constraint:
   - PK on identity UUID
   - Unique `(Old_Branch_UUID, Branch_Name)` to allow multiple names per source branch key (required for Portsmouth)
7. Optionally enables Change Tracking on the target table (not required for the staging sync logic, but useful if other downstream processes track it).

Outputs:
- A single summary line (`@Summary` + `SELECT [Summary] = @Summary`)

## Why it’s structured this way

### 1) The AppLock is non-negotiable
Branch is a core dimension and is referenced by other staging loads. Two overlapping runs can:
- race on `CT_Watermark`
- partially build `tbl_Branch`
- break downstream jobs that expect stable branch data

The AppLock makes the procedure safe under SQL Agent retries and accidental manual execution.

### 2) CT fence at start is to avoid drift
The baseline load can take time. Capturing the CT version at the start ensures incrementals can safely process **everything after the baseline snapshot**, including changes that happen while the baseline is running.

This pattern is the only way to prevent the classic “baseline window gap”.

### 3) Dynamic SQL for DROP/CREATE is deliberate
The initial proc uses dynamic SQL to drop objects because this repo is designed to be resilient to “stale objects”:
- someone might have created a view or synonym named `tbl_Branch`
- previous runs might have left behind an object with a different type

Dynamic SQL forces late binding and avoids compilation problems that can happen when DDL changes object types.

### 4) The `(Old_Branch_UUID, Branch_Name)` uniqueness is intentional
You explicitly create a second logical branch row (`Portsmouth`) off the Southampton source row.
That means you *must* allow multiple names per source GS_REF.
The unique constraint matches that reality and prevents accidental duplicates.

### 5) Early pay rate is done in-stage because it’s a stable attribute
This is the point where you want “branch + stable enrichments” before other staging/core logic runs.
Doing it here keeps reporting logic simpler and avoids duplicating the mapping later.

## Operational notes

- This is a baseline: it is safe to rerun in non-prod. In prod, rerun should be deliberate because it rebuilds the table.
- Incremental relies on CT watermark from this initial (or auto-initial logic inside incremental).
- The synthetic Portsmouth row should be documented in BI semantics because it can surprise consumers.
