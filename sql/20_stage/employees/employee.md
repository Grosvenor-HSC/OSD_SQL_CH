# Employees (Staging) — Initial + Incremental

## Objects
- **Source (driver):** `dbo.EMPLOYEE` (Change Tracking required)
- **Optional CT sources:** `dbo.CONTACT_DT`, `dbo.CONTACT_HD`, `dbo.CHSYSDEC`
- **Target table:** `dbo.tbl_Employees`
- **Initial proc:** `dbo.usp_Sync_Employees_Initial`
- **Incremental proc:** `dbo.usp_Sync_Employees_Incremental`
- **Watermark table:** `dbo.CT_Watermark` (ProcessName = `Employees`)

## Dependencies / Run Order
1. `usp_Sync_Employees_Initial` (creates `dbo.tbl_Employees` and seeds watermark)
2. Daily: `usp_Sync_Employees_Incremental`
3. Employee relationship incrementals (branch, skills, start/leave dates) run after Employees incremental

## Target Schema (`dbo.tbl_Employees`)
| Column | Type | Notes |
|---|---|---|
| UUID | int PK | `EMPLOYEE.EMP_REF` |
| DOB | date NULL | `TRY_CONVERT(date, EMPLOYEE.BIRTH_DATE)` |
| Code | nvarchar(50) NOT NULL | `LTRIM(RTRIM(EMPLOYEE.EMP_CODE))` |
| Gender | nvarchar(20) NULL | SEX -> Male/Female/Not Applicable/Unknown |
| Forenames | nvarchar(100) NULL | from CONTACT_HD |
| Surname | nvarchar(100) NULL | from CONTACT_HD |
| Telephone_Number | nvarchar(20) NULL | from CONTACT_HD |
| Payroll_Number | nvarchar(50) NULL | from EMPLOYEE |
| Email | nvarchar(100) NULL | from CONTACT_HD |
| Ethnicity | nvarchar(100) NULL | CHSYSDEC on EMPLOYEE.ETHNICITY |
| Religion | nvarchar(100) NULL | CHSYSDEC on EMPLOYEE.RELORG_REF; NULL if 'Not Declared' |
| Job_Title | nvarchar(100) NULL | CHSYSDEC on EMPLOYEE.JOBTITLE |
| Salaried | nvarchar(20) NULL | CHSYSDEC on EMPLOYEE.JOB_QUAL; NULL if '<no selection>' |
| Payroll_Schedule | nvarchar(20) NULL | from EMPLOYEE.INTERFACE |
| Driver | nvarchar(20) NULL | from EMPLOYEE.DRIVER |
| First_Line_Address | nvarchar(100) NULL | from CONTACT_HD |
| Second_Line_Address | nvarchar(100) NULL | from CONTACT_HD |
| Third_Line_Address | nvarchar(100) NULL | from CONTACT_HD |
| Fourth_Line_Address | nvarchar(100) NULL | from CONTACT_HD |
| Postcode | nvarchar(20) NULL | from CONTACT_HD |
| CreatedAtUTC | datetime2(3) | ETL timestamp |
| UpdatedAtUTC | datetime2(3) | ETL timestamp |

Indexes (created by initial):
- `IX_tbl_Employees_Code` on `(Code)`
- `IX_tbl_Employees_Salaried` on `(Salaried)`
- `IX_tbl_Employees_PayrollSchedule` on `(Payroll_Schedule)`

## Incremental Strategy
- Watermark stored in `dbo.CT_Watermark` under ProcessName `Employees`.
- Fences upper bound using `CHANGE_TRACKING_CURRENT_VERSION()`.
- Builds changed EMP_REF list from:
  - `CHANGETABLE(CHANGES dbo.EMPLOYEE, @LastSyncVersion)` (I/U)
  - Optional expansions from CONTACT_DT / CONTACT_HD / CHSYSDEC (if CT enabled)
- Processes changed keys in chunks:
  - MERGE updates/inserts into `dbo.tbl_Employees`
  - Applies hard deletes from `dbo.EMPLOYEE` (CT operation = 'D')
- Advances watermark only on success.

## Operational Notes
- Concurrency guarded with applock resource: `DOM_LIVE:Sync:Employees`.
- If watermark < CT min valid v
