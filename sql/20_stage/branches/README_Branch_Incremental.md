# Branch (Stage) — Incremental

File:
- `Branch_Incremental.sql`

Procedure:
- `dbo.usp_Sync_Branch_Incremental`

Targets:
- `dbo.tbl_Branch`
- `dbo.CT_Watermark` (shared watermark table)

Source:
- `dbo.GLOB_SITE` (Change Tracking enabled)
- `dbo.tbl_EarlyPayInitialRatesTable` (lookup)

## What it does

`usp_Sync_Branch_Incremental` is a **CT-driven daily upsert** into `dbo.tbl_Branch`.

It:
1. Optionally takes an **exclusive AppLock** (default on).
2. Validates Change Tracking prerequisites (DB + `GLOB_SITE`).
3. Detects whether an initial load is required:
   - `tbl_Branch` missing
   - `CT_Watermark` missing
   - watermark row missing for process `Branch`
   - watermark is stale vs CT retention (`LastSyncVersion < CHANGE_TRACKING_MIN_VALID_VERSION`)
4. If initial is required, it auto-runs:
   - `EXEC dbo.usp_Sync_Branch_Initial`
5. Reads the last sync version from watermark and fences the run with:
   - `@ToVersion = CHANGE_TRACKING_CURRENT_VERSION()`
6. Builds `#Changed` keys from `CHANGETABLE(CHANGES dbo.GLOB_SITE, @LastSyncVersion)`:
   - Converts `GS_REF` to int safely
7. If no changed keys:
   - Advances watermark to `@ToVersion`
   - Returns a summary
8. If there are changes:
   - Processes keys in chunks (`@ChunkSize`)
   - For each chunk, re-materializes current source values and MERGEs into `dbo.tbl_Branch`
   - Applies the same special logic as initial:
     - Southampton / Old_Southampton renames
     - Early pay rate lookup
     - Portsmouth synthetic row expansion
9. Applies deletes:
   - Deletes target rows where source `GLOB_SITE` row was deleted since last sync (CT operation 'D')
10. Advances watermark to `@ToVersion`
11. Returns a one-line summary with inserted/updated/deleted and watermark

## Why it’s structured this way

### 1) Auto-initial is there to prevent silent “stuck” pipelines
Branch is foundational. If the table or watermark disappears (dev rebuild, restore, deploy), the incremental:
- does not limp on
- does not “half work”
- does not produce empty deltas forever

Instead, it forces the baseline back into existence automatically so the pipeline can self-heal.

### 2) CT retention safety matters
Change Tracking is retention-based. If the watermark falls behind the minimum valid version, you can’t compute a correct delta.
The procedure detects this and forces an initial rebuild rather than silently missing history.

### 3) Chunking is used even for dimensions for two reasons
- avoids large single transactions during unusual spikes
- reduces blocking and log pressure
- keeps the procedure stable even if `GLOB_SITE` becomes unexpectedly large

Branches aren’t huge today, but this repo assumes growth and prefers predictable patterns.

### 4) “Portsmouth” makes upserts non-trivial
A single source row (`GS_REF = 1970000043`) produces:
- a Southampton row
- a Portsmouth row

This is why the MERGE match condition includes:
- `Old_Branch_UUID`
- `Branch_Name`

Without that, Portsmouth would overwrite Southampton or vice-versa.

### 5) Delete handling is explicit
The procedure separately deletes target rows whose source key was deleted (CT operation 'D').
This keeps the stage table consistent with the current source universe.

Because the target can contain multiple rows per source key (Portsmouth), deletes are done by matching `Old_Branch_UUID`.

## Known sharp edges / things to be aware of

- The “Active” field is sourced from `NHS_DEPT` and treated as a string. That might not be what the name suggests; document semantics for BI.
- If `TRY_CONVERT(int, GS_REF)` fails, the row is ignored by incremental change detection. If GS_REF is guaranteed numeric, this is fine; if not, you might want a quarantine table/log.
- `$action` in `MERGE ... OUTPUT $action` is valid in SQL Server, but some editors (VS Code mssql extension) show a false IntelliSense error. SQL Server execution is the real source of truth.

## Operational notes

- Default AppLock prevents overlap with initial and other incrementals.
- Advancing watermark only at the end ensures reruns reprocess the same CT window deterministically.
- If the incremental is executed right after initial, it should typically process 0 rows (unless source changed during baseline).
