# Employees Absences (Stage) — Initial + Incremental

Folder: `sql/20_stage/absences`  
Objects:
- `dbo.usp_Sync_EmployeesAbsences_Initial`
- `dbo.usp_Sync_EmployeesAbsences_Incremental`
- Target table: `dbo.tbl_EmployeesAbsences`
- Watermark table: `dbo.CT_Watermark` (shared pattern across sync processes)

## What this loads

This stage loads **employee absence events** from the source table(s):

- Source fact table: `dbo.INACTIVE_DY`
  - Key: `INACT_REF` (INT)
  - Employee key: `EMP_REF` (INT)
  - Record type discriminator: `rectype` = 'E' indicates employee absence
  - Reason decode: `REASON` → `dbo.CHSYSDEC.DECODE_REF`

It writes to the staging table:

- `dbo.tbl_EmployeesAbsences`
  - `UUID` (INT) = `INACTIVE_DY.INACT_REF` (employee absence identifier)
  - `Employee_UUID` (INT) = `INACTIVE_DY.EMP_REF`
  - `Reason`, `Start_Date`, `End_Date`, `Status`, `Comment`
  - `CreatedAtUTC`, `UpdatedAtUTC`

Downstream reporting uses this for workforce/compliance metrics, so the process prioritizes correctness and repeatability.

---

## Initial (`usp_Sync_EmployeesAbsences_Initial`) — what it does

The Initial procedure is a **baseline backfill** that:
1. Acquires an AppLock to prevent concurrent runs.
2. Validates Change Tracking is enabled (DB + `INACTIVE_DY`).
3. Captures a CT version snapshot at the start (`CHANGE_TRACKING_CURRENT_VERSION()`).
4. Seeds/updates the watermark row for this process to the start snapshot.
5. Drops and recreates the target staging table.
6. Inserts all qualifying employee absence rows:
   - `IDY.EMP_REF <> 0`
   - `IDY.rectype = 'E'`
   - Excludes known junk reasons (configurable list)
7. Builds indexes post-load.
8. Optionally runs incremental silently to top off changes that occurred during the baseline window.

### Why it’s structured this way

- **Baseline consistency**: A full rebuild guarantees staging matches the source at a known point in time.
- **CT snapshot at start**: Allows incrementals to reliably capture changes that happen while the baseline is running.
- **Drop/recreate**: Simplifies the one-time backfill and avoids complex “reconcile history” logic.
- **AppLock**: Protects both the staging rebuild and the watermark update from overlapping runs.

---

## Incremental (`usp_Sync_EmployeesAbsences_Incremental`) — what it does

The Incremental procedure is a **daily CT-driven upsert**:

1. Optionally acquires an AppLock (configurable).
2. Validates prerequisites:
   - Change Tracking enabled (DB + `INACTIVE_DY`)
   - Target table exists (baseline must have run)
3. Reads the last watermark and fences a stable upper bound (`@ToVersion`) at start.
4. Validates watermark versus CT retention (min valid version check).
5. Builds a set of changed absence keys (`INACT_REF`) using `CHANGETABLE(CHANGES ...)`:
   - Includes all changes to `INACTIVE_DY` since watermark
   - Optionally includes changes that originate from decode table (`CHSYSDEC`) if CT is enabled there
6. Applies changes in chunks:
   - For each chunk, it materializes the current “Base” rows from `INACTIVE_DY` and `CHSYSDEC`
   - MERGE applies inserts/updates, and removes rows for keys that no longer exist / no longer qualify
7. Advances watermark only after successful completion.
8. Outputs a one-line summary (start/end/row counts/new watermark).

### Why it’s structured this way

- **Idempotent**: A rerun of the same CT window should converge to the same table state.
- **Chunking**: Prevents long-running transactions and reduces blocking/log pressure.
- **Upper bound fencing**: Prevents “moving target” windows and makes job runs explainable.
- **Min-valid check**: Prevents silent data drift if CT retention purges required versions.
- **Qualification filters in Base**: Keeps staging aligned with business expectations (rectype='E', excluded reasons, EMP_REF<>0).

---

## Operational notes

- Must run after Employees baseline/incremental because `EMP_REF` is only meaningful when employee dimension rows exist.
- If the “excluded reasons” list changes, incremental runs will reconcile those rows as part of changed-key processing (or next baseline).
- If CT is not enabled on `CHSYSDEC`, reason text updates won’t be detected automatically. If that matters, either enable CT on `CHSYSDEC` or accept that reason text is “eventually corrected” only when the underlying INACTIVE_DY row changes.
