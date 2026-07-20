# Employee Branch (Initial + Incremental)

## Overview
These procedures maintain `dbo.tbl_EmployeeBranch`, a staging table representing employee-to-branch relationships.

Key rules:
- `Branch_UUID` is the **INT identity** from `dbo.tbl_Branch.UUID`.
- `Old_Branch_UUID` is the **source/native INT** used only for mapping to `Branch_UUID`.
- The row key `UUID` is a **computed SHA2_256 hash string** of `Employee_UUID|Branch_UUID` (not an INT).

---

## Employee_Branch_Initial.sql

### What it does
- Acquires applock `DOM_LIVE:Sync:EmployeeBranch`
- Ensures Change Tracking exists and is enabled on `dbo.DISTKEY`
- Captures CT snapshot at start (`@BaselineFrom = CHANGE_TRACKING_CURRENT_VERSION()`)
- Seeds watermark in `dbo.CT_Watermark` for process `EmployeeBranch` to `@BaselineFrom`
- Drops/recreates `dbo.tbl_EmployeeBranch` defensively (synonym/view/table)
- Loads baseline relationships from `dbo.DISTKEY` + enriches from:
  - `dbo.EMPLOYEE`
  - `dbo.CHSYSDEC` (descriptions)
  - optional `dbo.tbl_Visits` (visit min/max)
  - `dbo.tbl_Branch` (Old_Branch_UUID -> Branch_UUID mapping)
- Builds indexes and enables CT on the target (optional)

### Target schema contract
`dbo.tbl_EmployeeBranch` contains:
- `Employee_UUID int not null`
- `Branch_UUID int not null`
- `Start_Date datetime null`
- `End_Date datetime null`
- `Status nvarchar(255) null`
- `Group nvarchar(255) null`
- `Left_Reason nvarchar(255) null`
- `Location nvarchar(255) null`
- `Main_Branch char(1) null`
- `Branch_Name nvarchar(255) null`
- `UUID` computed persisted hash (PK)
- `CreatedAtUTC`, `UpdatedAtUTC`

---

## Employee_Branch_Incremental.sql

### What it does
- Acquires applock `DOM_LIVE:Sync:EmployeeBranch` (optional)
- Reads watermark from `dbo.CT_Watermark`
- Fences CT window: `From = LastSyncVersion` to `To = CHANGE_TRACKING_CURRENT_VERSION()`
- Validates CT retention using `CHANGE_TRACKING_MIN_VALID_VERSION`
- Builds a set of changed pairs `(Employee_UUID, Old_Branch_UUID)` from `dbo.DISTKEY`
- Optionally adds pairs impacted by changes in:
  - `dbo.EMPLOYEE` (e.g., location affecting branch mapping)
  - `dbo.CHSYSDEC` (text changes)
- Handles deletes from `dbo.DISTKEY` by removing mapped rows from the staging table
- For each changed pair:
  - recomputes the correct `Branch_UUID`
  - rebuilds the row(s) deterministically (delete existing then insert fresh)
- Advances watermark only after a successful sync

### Determinism
The incremental procedure does not “patch” rows blindly. It recomputes the desired rows using the same shaping logic as Initial and replaces what exists for those keys.

---

## Operational notes
- If Change Tracking retention causes `LastSyncVersion < MIN_VALID_VERSION`, you must re-run Initial.
- If `dbo.DISTKEY` Change Tracking does not expose `INPRIKEY/OUTPRIKEY` on deletes, delete handling must be switched to an employee-level rebuild strategy.
