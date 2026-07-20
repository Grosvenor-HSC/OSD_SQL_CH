# Employees Diary (Initial + Incremental)

## What these scripts do

### Employees_Diary_Initial.sql
Creates the baseline employee diary staging table and loads the full history.

- **Source:** `dbo.EMPLOYEE_DY` plus decode text from `dbo.CHSYSDEC`
- **Target:** `dbo.tbl_EmployeesDiary`
- **Keys:**  
  - `Employee_UUID` = `EMPLOYEE_DY.EMP_REF` (INT)  
  - `UUID`         = `EMPLOYEE_DY.EMP_DY_REF` (INT)
- **Behavior:**
  - Acquires an application lock `DOM_LIVE:Sync:EmployeesDiary` to prevent concurrency.
  - Captures a Change Tracking snapshot at the start (`@BaselineFrom = CHANGE_TRACKING_CURRENT_VERSION()`).
  - Seeds/updates `dbo.CT_Watermark` for process `EmployeesDiary` to `@BaselineFrom`.
  - Drops and recreates `dbo.tbl_EmployeesDiary` with a stable schema and PK.
  - Performs a full insert baseline (no varchar casts).
  - Creates supporting indexes after load.
  - Optionally runs incremental quietly as a “top-off”.

This procedure is **destructive** and is intended for non-prod / controlled runs.

---

### Employees_Diary_Incremental.sql
Keeps `dbo.tbl_EmployeesDiary` up to date using SQL Server Change Tracking.

- **Source:** `dbo.EMPLOYEE_DY` (required), `dbo.CHSYSDEC` (optional)
- **Target:** `dbo.tbl_EmployeesDiary`
- **Behavior:**
  - Acquires the same applock as initial (optional via `@UseAppLock`).
  - Reads `LastSyncVersion` from `dbo.CT_Watermark` for process `EmployeesDiary`.
  - Fences the CT window: `From = @LastSyncVersion` to `To = CHANGE_TRACKING_CURRENT_VERSION()`.
  - Validates CT retention: if watermark is older than `CHANGE_TRACKING_MIN_VALID_VERSION`, it fails with “re-baseline required”.
  - Builds a changed set of `EMP_DY_REF` values from `CHANGETABLE(CHANGES dbo.EMPLOYEE_DY, From)`.
  - Optionally adds diary rows impacted by decode text changes when CT is enabled on `dbo.CHSYSDEC`.
  - Performs chunked `MERGE` into `dbo.tbl_EmployeesDiary`:
    - UPDATE existing rows
    - INSERT new rows
  - Applies deletes from source using `CHANGETABLE` delete rows (`SYS_CHANGE_OPERATION = 'D'`) and deletes matching `UUID` rows.
  - Advances `dbo.CT_Watermark.LastSyncVersion` to `To` only after successful sync.
  - Returns a compact Stage/Summary row when `@ReturnSummaryRow = 1`.

Incremental is designed to be **safe to re-run**: it is deterministic for the fenced CT window and advances the watermark only on success.

---

## Why the scripts are structured this way

### 1) Deterministic CT window fencing
Both procedures use a CT version snapshot:
- Initial captures a snapshot at start and seeds the watermark to that version.
- Incremental uses `LastSyncVersion -> CurrentVersion` to ensure it processes a stable window of changes.

This prevents “moving target” issues during long runs.

### 2) Watermark centralization
All processes share `dbo.CT_Watermark` with:
- `ProcessName`
- `LastSyncVersion`
- `LastSyncTime`

This gives a single source of truth for incremental progress, supports consistent monitoring, and makes failures restartable.

### 3) Chunked merge
Large change sets are processed in chunks to:
- reduce transaction/log pressure
- reduce lock duration
- improve operational safety for daily schedules

### 4) CT retention safety
If CT cleanup has removed changes older than the watermark, incremental cannot be trusted.
The procedure fails clearly and requires an initial re-baseline.

### 5) Hard schema contract between Initial and Incremental
Initial owns the table definition.
Incremental assumes the exact schema and verifies it before proceeding.
This avoids “it runs but silently maps to the wrong columns” failures.
