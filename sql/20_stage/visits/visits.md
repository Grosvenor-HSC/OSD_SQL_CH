# Visits (Staging) — Initial + Incremental

## Objects
- **Source (driver):** `dbo.ACTIVITY_HD` (Change Tracking required)
- **Lookups:** `dbo.CAREPLAN_DT`, `dbo.CONTRACT_DT`, `dbo.CONTRACT_HD`, `dbo.SERVICE_HD`
- **Staged dependency:** `dbo.tbl_Clients` (required; provides Branch_UUID)
- **Target:** `dbo.tbl_Visits`
- **Initial proc:** `dbo.usp_Sync_Visits_Initial`
- **Incremental proc:** `dbo.usp_Sync_Visits_Incremental`
- **Watermark table:** `dbo.CT_Watermark` (`ProcessName = 'Visits'`)
- **Applock:** `DOM_LIVE:Sync:Visits`

## Scope / Business Rules
- Exclude template-only: `ACTIVITY_HD.[TYPE] <> 1`
- Only include last 3 years: `ACTIVITY_HD.START_DTM >= DATEADD(YEAR, -3, SYSUTCDATETIME())`
- Only include visits for staged clients: join `dbo.tbl_Clients` on `CLIENT_REF`

## Target Schema (`dbo.tbl_Visits`)
Primary key: `UUID` (int) = `ACTIVITY_HD.ACT_REF`

Columns:
- UUID (int, PK)
- Client_UUID (int)
- Employee_UUID (int)
- Planned_Employee_UUID (int)
- Careplan_UUID (int)
- Care_Group (int)
- Branch_UUID (int) — from `dbo.tbl_Clients`
- Contract_UUID (int)
- Linked_Visit_UUID (int) — from `MLINKREF`
- Planned_Duration (int) — `CPDT.QUANTITY * 60`
- Planned_Visit_Start_Date_Time (datetime2)
- Planned_Visit_End_Date_Time (datetime2)
- Actual_Duration (int) — `DATEDIFF(minute, START_DTM, END_DTM)`
- Actual_Visit_Start_Date_Time (datetime2)
- Actual_Visit_End_Date_Time (datetime2)
- Visit_Code (varchar(50)) — `SERVICE_HD.SERVICE_CODE`
- Visit_Origin (varchar(30)) — derived:
  - `CPLAN_DET_REF <> 0` -> From Template Careplan
  - `RNB_VISIT = 'Y'` -> From Booking
  - else -> Ad-Hoc Entry
- Visit_Invoice_Status (int)
- Visit_Pay_Status (int)
- Cancel_Pay_Flag (nvarchar(4)) — `NULLIF(CANC_PAY,'')`
- CreatedAtUTC, UpdatedAtUTC (datetime2(3))

Recommended indexes (created by initial):
- IX_tbl_Visits_Client_UUID (Client_UUID)
- IX_tbl_Visits_Employee_UUID (Employee_UUID)
- IX_tbl_Visits_Branch_UUID (Branch_UUID)
- IX_tbl_Visits_ActualStart (Actual_Visit_Start_Date_Time)

## Incremental Strategy
1. Acquire applock `DOM_LIVE:Sync:Visits`
2. Validate CT enabled at DB level and on `dbo.ACTIVITY_HD`
3. Load watermark from `dbo.CT_Watermark` for `Visits`
4. Validate watermark >= CT min valid version
5. Fence upper bound: `@ToVersion = CHANGE_TRACKING_CURRENT_VERSION()`
6. Build changed key set: `CHANGETABLE(CHANGES dbo.ACTIVITY_HD, @LastSyncVersion)`
7. Chunk keys and MERGE rows into `dbo.tbl_Visits` using same business rules as initial
8. Apply hard deletes where CT operation = 'D'
9. Enforce 3-year scope (optional): delete rows older than scope start
10. Advance watermark to `@ToVersion` on success

## Notes / Gotchas
- Do **not** use `WHEN NOT MATCHED BY SOURCE THEN DELETE` for chunked merges; it can delete valid rows.
- Deletes must be driven by CT operation = 'D'.
- If scope purge is enabled, visits aging out of the 3-year window will be removed from staging.
