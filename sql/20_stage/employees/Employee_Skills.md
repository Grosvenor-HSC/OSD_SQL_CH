# Employee Skills (Staging) — Initial + Incremental

## Objects
- **Target table:** `dbo.tbl_EmployeeSkills`
- **Initial proc:** `dbo.usp_Sync_EmployeeSkills_Initial`
- **Incremental proc:** `dbo.usp_Sync_EmployeeSkills_Incremental`
- **Watermark table:** `dbo.CT_Watermark` (shared convention)

## Dependencies / Run Order
1. Employee initial/incremental should run before this if downstream expects valid employee refs.
2. Change Tracking must be enabled on:
   - `dbo.SKILL_REQD` (required)
   - `dbo.CHSYSDEC` (optional but improves “skill text changed” detection)
   - `dbo.SKILL_CATS` (optional but improves “category changed” detection)

## Target Schema (`dbo.tbl_EmployeeSkills`)
| Column | Type | Notes |
|---|---|---|
| Employee_UUID | int | Parsed from `SKILL_REQD.[REFERENCE]` |
| Skill_Description | varchar(255) NOT NULL | From `CHSYSDEC` decode row (`GROUP1=2`, `CODE='SKIL'`); blank if missing |
| UUID | int PK | `SKILL_REQD.SKILLREQ_REF` |
| Valid_From_Date | datetime2 NULL | From `VAL_START_DTM` |
| Valid_To_Date | datetime2 NULL | From `VAL_END_DTM` |
| Notes | nvarchar(max) NULL | From `SKILL_REQD.NOTES` |
| Skill_Category | varchar(255) NULL | From `SKILL_CATS.DESC_TXT` via `CHSYSDEC.VALUE1` |
| CreatedAtUTC | datetime2(3) | ETL timestamp |
| UpdatedAtUTC | datetime2(3) | ETL timestamp |

Indexes (created by initial):
- `IX_tbl_EmployeeSkills_Employee_UUID` on `(Employee_UUID)` include description/dates
- `IX_tbl_EmployeeSkills_Skill_Description` on `(Skill_Description)` include employee/dates

## Initial Load Behavior
- Destructive reset: drops synonym/view/table named `dbo.tbl_EmployeeSkills`, then recreates the table.
- Sets watermark to `CHANGE_TRACKING_CURRENT_VERSION()` at start of run.
- Loads qualifying rows from `SKILL_REQD` where:
  - `REF_TYPE = 2` (employee)
  - `TRY_CONVERT(int, [REFERENCE]) IS NOT NULL`
- Uses decode join:
  - `CHSYSDEC` where `GROUP1=2 AND CODE='SKIL'`
  - `SKILL_CATS` join via `CHSYSDEC.VALUE1`

## Incremental Load Behavior
- Uses `dbo.CT_Watermark` to get `LastSyncVersion` and fences the upper bound with `CHANGE_TRACKING_CURRENT_VERSION()`.
- Builds a changed UUID set from:
  - `CHANGETABLE(CHANGES dbo.SKILL_REQD, @LastSyncVersion)` (required)
  - Optional “touch” expansion from CHSYSDEC / SKILL_CATS if CT enabled there.
- Processes UUIDs in chunks via MERGE:
  - Updates existing UUID rows
  - Inserts new UUID rows
  - Deletes target rows for UUIDs in the chunk that no longer qualify or were deleted upstream
- Advances watermark only on success.

## Operational Notes
- Concurrency guarded with `sp_getapplock` resource: `DOM_LIVE:Sync:EmployeeSkills`.
- If watermark < CT min valid version, incremental refuses to run (needs re-baseline / initial).
