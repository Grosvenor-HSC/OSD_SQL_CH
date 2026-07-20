# Employee Start/Leave Dates (Staging) — Initial + Incremental

## Objects
- **Driver table:** `dbo.tbl_EmployeeBranch` (Change Tracking enabled)
- **Target table:** `dbo.tbl_EmployeeStartLeaveDates`
- **Initial proc:** `dbo.usp_Sync_EmployeeStartLeaveDates_Initial`
- **Incremental proc:** `dbo.usp_Sync_EmployeeStartLeaveDates_Incremental`
- **Watermark table:** `dbo.CT_Watermark`

## Dependencies / Run Order
1. `tbl_EmployeeBranch` initial + incremental
2. `usp_Sync_EmployeeStartLeaveDates_Initial` once (creates target + seeds watermark)
3. Daily: `usp_Sync_EmployeeStartLeaveDates_Incremental`

## Target Schema (`dbo.tbl_EmployeeStartLeaveDates`)
| Column | Type | Notes |
|---|---|---|
| Start_Date | date NULL | Derived minimum over branch history (fallback 1998-01-01) |
| End_Date | date NULL | NULL if any open rows exist, else max end date |
| Status | varchar(50) NULL | Derived from open rows + ranked status |
| Employee_UUID | varchar(50) NOT NULL | Primary key |
| CreatedAtUTC | datetime2(3) | ETL timestamp |
| UpdatedAtUTC | datetime2(3) | ETL timestamp |

Indexes (created by initial):
- `IX_EmpSLD_Status` on `Status`
- `IX_EmpSLD_StartDate` on `Start_Date`
- `IX_EmpSLD_EndDate` on `End_Date`

## Derivation Rules (Initial + Incremental)
Aggregate over `dbo.tbl_EmployeeBranch` grouped by `Employee_UUID`:

- `Start_Date` = MIN(Start_Date) else `1998-01-01`
- `End_Date` = NULL if any branch rows have `End_Date IS NULL` else MAX(End_Date)
- `Status`:
  - if any open rows:
    - `Active` if any row has Status='Active'
    - else `Temporarily Inactive` if any row has Status='Temporarily Inactive'
    - else `Unknown`
  - else `Permanently Inactive`

## Incremental Strategy
- Uses Change Tracking on `dbo.tbl_EmployeeBranch` as the driver.
- Watermark stored in `dbo.CT_Watermark` under process name `EmployeeStartLeaveDates`.
- Builds a changed employee set from:
  - I/U: CT joined to current `tbl_EmployeeBranch` to obtain `Employee_UUID`
  - D: CT joined to `dbo.tbl_EmployeeBranch_KeyMap` (PK→Employee_UUID) to resolve deletions
- Re-aggregates each changed employee and MERGEs into `dbo.tbl_EmployeeStartLeaveDates`.
- If an employee ends up with **zero** branch rows, deletes the target row.

## Operational Notes
- Concurrency guarded with applock resource: `DOM_LIVE:Sync:EmployeeStartLeaveDates`.
- If watermark < CT min valid version, incremental refuses to run (re-baseline required).
