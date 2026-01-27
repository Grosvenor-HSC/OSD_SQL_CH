/*
Purpose:
    Build the QDS reporting table dbo.tbl_QDS (drop/recreate + reload) for Quick Discharge Service clients,
    including visit counts/durations, double-ups, day-of-week and time-of-day breakdowns.

Source:
    tbl_Clients
    tbl_ClientStartLeaveDates
    tbl_Visits
    tbl_Contracts
    vw_ClientHours
    tbl_Branch
    dbo.fn_GetFullAddress

Target:
    dbo.tbl_QDS (full rebuild) :contentReference[oaicite:13]{index=13}

Run type:
    Rebuild (DROP + CREATE + INSERT)

Run frequency:
    Daily (recommended) or on-demand before QDS reporting refresh

Safe to re-run:
    Yes, but disruptive: it DROPs and recreates dbo.tbl_QDS. Do not run during report usage windows. :contentReference[oaicite:14]{index=14}

Notes:
    - Filters clients to a rolling window: Start >= (today-366) and End <= (today+7). :contentReference[oaicite:15]{index=15}
    - Restricts to QDS fund source names ('Quick Discharge Service(s)') and invoice statuses (4,5). :contentReference[oaicite:16]{index=16} :contentReference[oaicite:17]{index=17}
    - Produces multiple aggregates (double-up vs single-handed, DOW pivot, time-of-day buckets) before inserting. :contentReference[oaicite:18]{index=18} :contentReference[oaicite:19]{index=19}
*/


IF OBJECT_ID('dbo.tbl_QDS','U') IS NOT NULL
  DROP TABLE dbo.tbl_QDS;
GO

CREATE TABLE dbo.tbl_QDS (
  ClientReference              INT           NOT NULL PRIMARY KEY,
  BranchName                   NVARCHAR(200) NULL,
  ClientGroup                  NVARCHAR(100) NULL,
  ClientCode                   NVARCHAR(50)  NULL,
  ClientDateOfBirth            DATE          NULL,
  ClientForenames              NVARCHAR(200) NULL,
  ClientSurname                NVARCHAR(200) NULL,
  ClientCaseNo                 NVARCHAR(100) NULL,
  ExternalReference            NVARCHAR(100) NULL,
  ClientFullAddress            NVARCHAR(600) NULL,
  ClientPostcode               NVARCHAR(20)  NULL,
  ClientStartDate              DATE          NULL,
  ClientLeaveDate              DATE          NULL,
  ClientStatus                 NVARCHAR(50)  NULL,
  ClientLeftReason             NVARCHAR(200) NULL,

  DoubleUpVisits               INT           NULL,
  DoubleUpHours                INT           NULL,
  SingleHandedVisits           INT           NULL,
  SingleHandedHours            INT           NULL,
  MultiCareCount               INT           NULL,
  TotalVisitDuration           INT           NULL,

  Num_Visits_Mon               INT           NULL,
  Num_Visits_Tue               INT           NULL,
  Num_Visits_Wed               INT           NULL,
  Num_Visits_Thu               INT           NULL,
  Num_Visits_Fri               INT           NULL,
  Num_Visits_Sat               INT           NULL,
  Num_Visits_Sun               INT           NULL,

  StartLeaveTOD                NVARCHAR(20)  NULL,
  FirstVisit                   DATETIME2     NULL,
  LastVisit                    DATETIME2     NULL,

  Total_Hours_Visits_AM_1      INT           NULL,
  Total_Hours_Visits_AM_2      INT           NULL,
  Total_Hours_Visits_PM_1      INT           NULL,
  Total_Hours_Visits_PM_2      INT           NULL,
  Num_Visits_AM_1              INT           NULL,
  Num_Visits_AM_2              INT           NULL,
  Num_Visits_PM_1              INT           NULL,
  Num_Visits_PM_2              INT           NULL,

  LoadTimestamp                DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME()
);

DECLARE @StartWindow date = CAST(DATEADD(DAY, -366, GETDATE()) AS date);
DECLARE @EndWindow   date = CAST(DATEADD(DAY,    7, GETDATE()) AS date);

WITH filteredclients AS (
    SELECT C.ClientReference
    FROM tbl_Clients C
    JOIN tbl_ClientStartLeaveDates CSD
      ON C.ClientReference = CSD.ClientReference
    WHERE CSD.GLOBAL_START_DATE >= @StartWindow
      AND CSD.GLOBAL_END_DATE   <= @EndWindow
      AND EXISTS (
          SELECT 1
          FROM tbl_Visits V
          JOIN tbl_Contracts CON
            ON CON.[$ContractReference] = V.ContractReference
          WHERE V.ClientReference = C.ClientReference
            AND TRY_CONVERT(int, V.VisitInvoiceStatus) IN (4,5)
            AND CON.ContractFundSourceName IN ('Quick Discharge Service','Quick Discharge Services')
      )
),
filteredvisits AS (
    SELECT
        UV.ClientReference,
        UV.MultiCareRef,
        UV.VisitCalculatedDuration,
        UV.VisitReference,
        UV.VisitStartDate,
        uv.VisitStartDateTime
    FROM tbl_Visits UV
    JOIN tbl_Contracts CON
      ON CON.[$ContractReference] = UV.ContractReference
    JOIN filteredclients FC
      ON FC.ClientReference = UV.ClientReference
    WHERE TRY_CONVERT(int, UV.VisitInvoiceStatus) IN (4,5)
      AND CON.ContractFundSourceName IN ('Quick Discharge Service','Quick Discharge Services')
),
visitagg AS (
    SELECT
        V.ClientReference,
        DoubleUpVisits      = SUM(CASE WHEN COALESCE(V.MultiCareRef,0) <> 0 THEN 1 ELSE 0 END),
        DoubleUpHours       = SUM(CASE WHEN COALESCE(V.MultiCareRef,0) <> 0 THEN V.VisitCalculatedDuration ELSE 0 END),
        SingleHandedVisits  = SUM(CASE WHEN COALESCE(V.MultiCareRef,0) = 0 THEN 1 ELSE 0 END),
        SingleHandedHours   = SUM(CASE WHEN COALESCE(V.MultiCareRef,0) = 0 THEN V.VisitCalculatedDuration ELSE 0 END),
        MultiCareCount      = COUNT(DISTINCT CASE WHEN COALESCE(V.MultiCareRef,0) <> 0 THEN V.MultiCareRef END),
        TotalVisitDuration  = SUM(V.VisitCalculatedDuration)
    FROM filteredvisits V
    GROUP BY V.ClientReference
),
VisitDowPivot AS (
  SELECT
      UV.ClientReference,
      Num_Visits_Mon = SUM(CASE WHEN DATEPART(WEEKDAY, UV.VisitStartDate) = 1 THEN 1 ELSE 0 END),
      Num_Visits_Tue = SUM(CASE WHEN DATEPART(WEEKDAY, UV.VisitStartDate) = 2 THEN 1 ELSE 0 END),
      Num_Visits_Wed = SUM(CASE WHEN DATEPART(WEEKDAY, UV.VisitStartDate) = 3 THEN 1 ELSE 0 END),
      Num_Visits_Thu = SUM(CASE WHEN DATEPART(WEEKDAY, UV.VisitStartDate) = 4 THEN 1 ELSE 0 END),
      Num_Visits_Fri = SUM(CASE WHEN DATEPART(WEEKDAY, UV.VisitStartDate) = 5 THEN 1 ELSE 0 END),
      Num_Visits_Sat = SUM(CASE WHEN DATEPART(WEEKDAY, UV.VisitStartDate) = 6 THEN 1 ELSE 0 END),
      Num_Visits_Sun = SUM(CASE WHEN DATEPART(WEEKDAY, UV.VisitStartDate) = 7 THEN 1 ELSE 0 END)
  FROM filteredvisits AS UV
  GROUP BY UV.ClientReference
),
startleaveagg as (
    select 
        CH.ClientReference,
        CH.FirstVisit,
        CH.[LastVisit],
         CASE 
    WHEN CH.FirstVisit IS NULL THEN 'Not Recorded'
    WHEN DATEPART(HOUR, CH.FirstVisit) < 6                  THEN '00:00-05:59'  -- 00:00–05:59
    WHEN DATEPART(HOUR, CH.FirstVisit) < 12                 THEN '06:00-11:59'  -- 06:00–11:59
    WHEN DATEPART(HOUR, CH.FirstVisit) < 18                 THEN '12:00-17:59'  -- 12:00–17:59
    ELSE                                                         '18:00-23:59'  -- 18:00–23:59
  END AS StartLeaveTOD
    from vw_ClientHours CH
    where ClientReference in (select ClientReference from filteredclients)
),
TimeOfDayAgg AS (
  SELECT
    UV.ClientReference,     

    Total_Hours_Visits_AM_1 = SUM(CASE WHEN DATEPART(HOUR, UV.VisitStartDateTime) <  6 THEN UV.VisitCalculatedDuration ELSE 0 END),
    Total_Hours_Visits_AM_2 = SUM(CASE WHEN DATEPART(HOUR, UV.VisitStartDateTime) >= 6 AND DATEPART(HOUR, UV.VisitStartDateTime) < 12 THEN UV.VisitCalculatedDuration ELSE 0 END),
    Total_Hours_Visits_PM_1 = SUM(CASE WHEN DATEPART(HOUR, UV.VisitStartDateTime) >=12 AND DATEPART(HOUR, UV.VisitStartDateTime) < 18 THEN UV.VisitCalculatedDuration ELSE 0 END),
    Total_Hours_Visits_PM_2 = SUM(CASE WHEN DATEPART(HOUR, UV.VisitStartDateTime) >=18 THEN UV.VisitCalculatedDuration ELSE 0 END),

    Num_Visits_AM_1 = SUM(CASE WHEN DATEPART(HOUR, UV.VisitStartDateTime) <  6 THEN 1 ELSE 0 END),
    Num_Visits_AM_2 = SUM(CASE WHEN DATEPART(HOUR, UV.VisitStartDateTime) >= 6 AND DATEPART(HOUR, UV.VisitStartDateTime) < 12 THEN 1 ELSE 0 END),
    Num_Visits_PM_1 = SUM(CASE WHEN DATEPART(HOUR, UV.VisitStartDateTime) >=12 AND DATEPART(HOUR, UV.VisitStartDateTime) < 18 THEN 1 ELSE 0 END),
    Num_Visits_PM_2 = SUM(CASE WHEN DATEPART(HOUR, UV.VisitStartDateTime) >=18 THEN 1 ELSE 0 END)
  FROM filteredvisits UV
  WHERE UV.VisitStartDateTime <= GETDATE()
  GROUP BY UV.ClientReference
)
INSERT INTO dbo.tbl_QDS (
  ClientReference,
  BranchName,
  ClientGroup,
  ClientCode,
  ClientDateOfBirth,
  ClientForenames,
  ClientSurname,
  ClientCaseNo,
  ExternalReference,
  ClientFullAddress,
  ClientPostcode,
  ClientStartDate,
  ClientLeaveDate,
  ClientStatus,
  ClientLeftReason,
  DoubleUpVisits,
  DoubleUpHours,
  SingleHandedVisits,
  SingleHandedHours,
  MultiCareCount,
  TotalVisitDuration,
  Num_Visits_Mon,
  Num_Visits_Tue,
  Num_Visits_Wed,
  Num_Visits_Thu,
  Num_Visits_Fri,
  Num_Visits_Sat,
  Num_Visits_Sun,
  StartLeaveTOD,
  FirstVisit,
  LastVisit,
  Total_Hours_Visits_AM_1,
  Total_Hours_Visits_AM_2,
  Total_Hours_Visits_PM_1,
  Total_Hours_Visits_PM_2,
  Num_Visits_AM_1, 
  Num_Visits_AM_2, 
  Num_Visits_PM_1, 
  Num_Visits_PM_2
)
SELECT
  C.ClientReference,                                -- << first!
  B.BranchName,
  C.ClientGroup,
  C.ClientCode,
  C.ClientDateOfBirth,
  C.ClientForenames,
  C.ClientSurname,
  C.ClientCaseNo,
  C.ExternalReference,
  dbo.fn_GetFullAddress(C.Address1, C.Address2, C.Address3, C.Address4, C.ClientPostcode) AS ClientFullAddress,
  C.ClientPostcode,
  C.ClientStartDate,
  ISNULL(C.ClientLeaveDate, GETDATE()) AS ClientLeaveDate,
  C.ClientStatus,
  C.ClientLeftReason,
  VA.DoubleUpVisits,
  VA.DoubleUpHours,
  VA.SingleHandedVisits,
  VA.SingleHandedHours,
  VA.MultiCareCount,
  VA.TotalVisitDuration,
  VDP.Num_Visits_Mon,
  VDP.Num_Visits_Tue,
  VDP.Num_Visits_Wed,
  VDP.Num_Visits_Thu,
  VDP.Num_Visits_Fri,
  VDP.Num_Visits_Sat,
  VDP.Num_Visits_Sun,
  FV.StartLeaveTOD,
  FV.FirstVisit,
  FV.LastVisit,
  TOA.Total_Hours_Visits_AM_1,
  TOA.Total_Hours_Visits_AM_2,
  TOA.Total_Hours_Visits_PM_1,
  TOA.Total_Hours_Visits_PM_2,
  TOA.Num_Visits_AM_1,
  TOA.Num_Visits_AM_2,
  TOA.Num_Visits_PM_1,
  TOA.Num_Visits_PM_2
FROM filteredclients FC
JOIN tbl_Clients      C   ON C.ClientReference  = FC.ClientReference
JOIN tbl_Branch       B   ON C.BranchReference  = B.BranchUID
LEFT JOIN visitagg    VA  ON VA.ClientReference  = C.ClientReference
LEFT JOIN VisitDowPivot VDP ON VDP.ClientReference = C.ClientReference
LEFT JOIN startleaveagg  FV  ON FV.ClientReference  = C.ClientReference
LEFT JOIN TimeOfDayAgg  TOA ON TOA.ClientReference  = C.ClientReference;