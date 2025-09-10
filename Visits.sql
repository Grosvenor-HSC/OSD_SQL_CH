/* 0) Fresh target table */
IF OBJECT_ID('dbo.tbl_Visits', 'U') IS NOT NULL DROP TABLE dbo.tbl_Visits;
CREATE TABLE dbo.tbl_Visits (
    VisitReference            VARCHAR(50)    NOT NULL PRIMARY KEY,
    ClientReference           VARCHAR(50)    NULL,
    EmployeeReference         VARCHAR(50)    NULL,
    CareplanEmployeeReference VARCHAR(50)    NULL,
    VisitAllocation           VARCHAR(20)    NULL,
    PlannedQuantity           FLOAT          NULL,
    NoEmpInTemplate           BIT            NULL,
    EmpChangedFromTemplate    BIT            NULL,
    TimeChangedFromTemplate   BIT            NULL,
    VisitEndTime              TIME           NULL,
    VisitEndDate              DATE           NULL,
    VisitEndDateTime          DATETIME2      NULL,
    BranchReference           VARCHAR(50)    NULL,
    VisitOriginalStartTime    TIME           NULL,
    VisitOriginalStartDate    DATE           NULL,
    VisitStartTime            TIME           NULL,
    CareplanVisitStartTime    TIME           NULL,
    VisitStartDate            DATE           NULL,
    VisitStartDateTime        DATETIME2      NULL,
    WeekStartDate             DATE           NULL,
    WeekEndDate               DATE           NULL,
    CareplanRef               INT            NULL,
    VisitServiceCode          VARCHAR(50)    NULL,
    ContractReference         VARCHAR(50)    NULL,
    VisitOrigin               VARCHAR(30)    NULL,
    VisitInvoiceStatus        INT            NULL,
    VisitPayStatus            INT            NULL,
    VisitMultiEmployeeFlag    VARCHAR(3)     NULL,
    VisitCalculatedDuration   FLOAT          NULL,
    ServiceCode               VARCHAR(50)    NULL,
    ContractSource            VARCHAR(100)   NULL,
    MultiCareRef              INT            NULL,
    NotChangedFromTemplate    BIT            NULL,
    NumberCarersOnVisit       INT            NULL,
    CancelPayFlag             NVARCHAR(4)            NULL

);

CREATE INDEX IX_tbl_Visits_ClientReference           ON dbo.tbl_Visits (ClientReference);
CREATE INDEX IX_tbl_Visits_EmployeeReference         ON dbo.tbl_Visits (EmployeeReference);
CREATE INDEX IX_tbl_Visits_CareplanEmployeeReference ON dbo.tbl_Visits (CareplanEmployeeReference);
CREATE INDEX IX_tbl_Visits_ContractReference         ON dbo.tbl_Visits (ContractReference);
CREATE INDEX IX_tbl_Visits_MultiCareRef              ON dbo.tbl_Visits (MultiCareRef);
CREATE INDEX IX_tbl_Visits_BranchReference           ON dbo.tbl_Visits (BranchReference);
CREATE INDEX IX_tbl_Visits_VisitInvoiceStatus        ON dbo.tbl_Visits (VisitInvoiceStatus);
CREATE INDEX IX_tbl_Visits_VisitPayStatus            ON dbo.tbl_Visits (VisitPayStatus);

/* 1) Define range and chunk size */
DECLARE @ChunkSize int = 1000000;

DECLARE @RangeStart datetime2 = (
    DATEADD(year, -6, CAST(GETDATE() AS date))
);

DECLARE @RangeEnd   datetime2 = DATEADD(year, 1, CAST(GETDATE() AS date));

IF @RangeStart IS NULL
BEGIN
    RAISERROR('No matching activities for clients in tbl_Clients. Aborting.', 16, 1) WITH NOWAIT;
    RETURN;
END;

DECLARE @RangeStartTxt varchar(19) = CONVERT(varchar(19), @RangeStart, 120);
DECLARE @RangeEndTxt   varchar(19) = CONVERT(varchar(19), @RangeEnd,   120);

;RAISERROR('Range: %s  to  %s', 0, 1, @RangeStartTxt, @RangeEndTxt) WITH NOWAIT;


/* 2) Stage ALL keys in range for those clients (sargable) */
IF OBJECT_ID('tempdb..#Keys') IS NOT NULL DROP TABLE #Keys;
CREATE TABLE #Keys (ACT_REF int NOT NULL PRIMARY KEY);

INSERT INTO #Keys (ACT_REF)
SELECT AHD.ACT_REF
FROM dbo.ACTIVITY_HD AHD WITH (NOLOCK)
INNER JOIN dbo.tbl_Clients C WITH (NOLOCK)
    ON C.ClientReference = AHD.CLIENT_REF
WHERE AHD.START_DTM >= @RangeStart
  AND AHD.START_DTM <  @RangeEnd;

DECLARE @Total int = (SELECT COUNT(*) FROM #Keys);
RAISERROR('Total matching activities: %d', 0, 1, @Total) WITH NOWAIT;

IF @Total = 0 RETURN;

/* 3) Chunk loop: process #Keys in 100k blocks */
WHILE EXISTS (SELECT 1 FROM #Keys)
BEGIN
    IF OBJECT_ID('tempdb..#NextKeys') IS NOT NULL DROP TABLE #NextKeys;
    CREATE TABLE #NextKeys (ACT_REF int NOT NULL PRIMARY KEY);

    INSERT INTO #NextKeys (ACT_REF)
    SELECT TOP (@ChunkSize) ACT_REF
    FROM #Keys
    ORDER BY ACT_REF;

    ;WITH CarerCounts AS (
        SELECT AHD.MLINKREF, COUNT(*) AS NumberCarers
        FROM dbo.ACTIVITY_HD AHD WITH (NOLOCK)
        INNER JOIN #NextKeys NK ON NK.ACT_REF = AHD.ACT_REF
        WHERE AHD.MLINKREF <> 0
        GROUP BY AHD.MLINKREF
    ),
    VisitsBase AS (
        SELECT        
            /* explicit casts to match target types */
            CAST(AHD.ACT_REF     AS varchar(50)) AS VisitReference,
            CAST(AHD.CLIENT_REF  AS varchar(50)) AS ClientReference,
            CAST(AHD.EMP_REF     AS varchar(50)) AS EmployeeReference,
            CAST(CPDT.EMP_REF    AS varchar(50)) AS CareplanEmployeeReference,

            CASE WHEN AHD.EMP_REF = 0 THEN 'Unallocated' ELSE 'Allocated' END AS VisitAllocation, 
            CPDT.QUANTITY AS PlannedQuantity,

            IIF(CPDT.EMP_REF IS NULL OR CPDT.EMP_REF = 0, 1, 0) AS NoEmpInTemplate, 
            IIF(CPDT.EMP_REF IS NOT NULL AND CPDT.EMP_REF <> AHD.EMP_REF, 1, 0) AS EmpChangedFromTemplate,
            IIF(TRY_CAST(CPDT.TIMEOFDAY AS TIME) IS NOT NULL
                AND TRY_CAST(CPDT.TIMEOFDAY AS TIME) <> CAST(AHD.START_DTM AS TIME), 1, 0) AS TimeChangedFromTemplate,

            CAST(AHD.END_DTM   AS TIME)      AS VisitEndTime, 
            CAST(AHD.END_DTM   AS DATE)      AS VisitEndDate, 
            CAST(AHD.END_DTM   AS DATETIME2) AS VisitEndDateTime, 
            CAST(CL.BranchReference AS varchar(50)) AS BranchReference, 
            CAST(AHD.ORIGSTDTM AS TIME)      AS VisitOriginalStartTime,
            CAST(AHD.ORIGSTDTM AS DATE)      AS VisitOriginalStartDate, 
            CAST(AHD.START_DTM AS TIME)      AS VisitStartTime,
            TRY_CAST(CPDT.TIMEOFDAY AS TIME) AS CareplanVisitStartTime,
            CAST(AHD.START_DTM AS DATE)      AS VisitStartDate, 
            CAST(AHD.START_DTM AS DATETIME2) AS VisitStartDateTime,

            DATEADD(day, 1 - DATEPART(weekday, CAST(AHD.START_DTM AS DATE)), CAST(AHD.START_DTM AS DATE)) AS WeekStartDate,
            DATEADD(day, 7 - DATEPART(weekday, CAST(AHD.END_DTM   AS DATE)), CAST(AHD.END_DTM   AS DATE)) AS WeekEndDate,

            AHD.CPLAN_DET_REF                AS CareplanRef,
            SHD.SERVICE_CODE                 AS VisitServiceCode,
            CAST(CHD.CONTRACT_REF AS varchar(50)) AS ContractReference,

            CASE 
                WHEN AHD.CPLAN_DET_REF <> 0 THEN 'From Template Careplan'
                WHEN AHD.CPLAN_DET_REF = 0 AND AHD.RNB_VISIT = 'Y' THEN 'From Booking'
                WHEN AHD.CPLAN_DET_REF = 0 AND AHD.RNB_VISIT <> 'Y' THEN 'Ad-Hoc Entry'
                ELSE '' 
            END AS VisitOrigin,

            AHD.INV_STATUS                   AS VisitInvoiceStatus,
            AHD.PAY_STATUS                   AS VisitPayStatus,
            CASE WHEN AHD.MLINKREF > 0 THEN 'Yes' ELSE 'No' END AS VisitMultiEmployeeFlag, 

            CAST(DATEDIFF(MINUTE, AHD.START_DTM, AHD.END_DTM) AS FLOAT) / 60 AS VisitCalculatedDuration, 

            SHD.SERVICE_CODE                 AS ServiceCode,
            CS.DESCRIPTION                   AS ContractSource,
            AHD.MLINKREF                     AS MultiCareRef,
            AHD.CANC_PAY          AS CancelPayFlag
        FROM dbo.ACTIVITY_HD AS AHD WITH (NOLOCK)
        INNER JOIN #NextKeys NK ON NK.ACT_REF = AHD.ACT_REF
        LEFT  JOIN dbo.tbl_Clients      AS CL WITH (NOLOCK) ON CL.ClientReference = AHD.CLIENT_REF
        LEFT  JOIN dbo.CONTRACT_DT AS CDT WITH (NOLOCK) ON AHD.CONT_DET_REF = CDT.CONT_DET_REF
        LEFT  JOIN dbo.CONTRACT_HD AS CHD WITH (NOLOCK) ON CDT.CONTRACT_REF = CHD.CONTRACT_REF
        LEFT  JOIN dbo.SERVICE_HD  AS SHD WITH (NOLOCK) ON AHD.SERVICE_REF = SHD.SERVICE_REF
        LEFT  JOIN dbo.CAREPLAN_DT AS CPDT WITH (NOLOCK) ON AHD.CPLAN_DET_REF = CPDT.CPLAN_DET_REF
        LEFT  JOIN dbo.CHSYSDEC    AS CS  WITH (NOLOCK) ON CHD.CONTRACT_SOURCE = CS.DECODE_REF
        WHERE AHD.START_DTM >= @RangeStart
          AND AHD.START_DTM <  @RangeEnd
          AND AHD.[TYPE] <> 1
    )
    INSERT INTO dbo.tbl_Visits (
        VisitReference, ClientReference, EmployeeReference, CareplanEmployeeReference,
        VisitAllocation, PlannedQuantity, NoEmpInTemplate, EmpChangedFromTemplate, TimeChangedFromTemplate,
        VisitEndTime, VisitEndDate, VisitEndDateTime,
        BranchReference, VisitOriginalStartTime, VisitOriginalStartDate,
        VisitStartTime, CareplanVisitStartTime, VisitStartDate, VisitStartDateTime,
        WeekStartDate, WeekEndDate,
        CareplanRef, VisitServiceCode, ContractReference, VisitOrigin,
        VisitInvoiceStatus, VisitPayStatus, VisitMultiEmployeeFlag,
        VisitCalculatedDuration, ServiceCode, ContractSource, MultiCareRef,
        NotChangedFromTemplate, NumberCarersOnVisit, CancelPayFlag
    )
    SELECT 
        v.VisitReference,
        v.ClientReference,
        v.EmployeeReference,
        v.CareplanEmployeeReference,
        v.VisitAllocation,
        v.PlannedQuantity,
        v.NoEmpInTemplate,
        v.EmpChangedFromTemplate,
        v.TimeChangedFromTemplate,
        v.VisitEndTime,
        v.VisitEndDate,
        v.VisitEndDateTime,
        v.BranchReference,
        v.VisitOriginalStartTime,
        v.VisitOriginalStartDate,
        v.VisitStartTime,
        v.CareplanVisitStartTime,
        v.VisitStartDate,
        v.VisitStartDateTime,
        v.WeekStartDate,
        v.WeekEndDate,
        v.CareplanRef,
        v.VisitServiceCode,
        v.ContractReference,
        v.VisitOrigin,
        v.VisitInvoiceStatus,
        v.VisitPayStatus,
        v.VisitMultiEmployeeFlag,
        v.VisitCalculatedDuration,
        v.ServiceCode,
        v.ContractSource,
        v.MultiCareRef,
        IIF(v.NoEmpInTemplate = 0 AND v.EmpChangedFromTemplate = 0 AND v.TimeChangedFromTemplate = 0, 1, 0) AS NotChangedFromTemplate,
        ISNULL(cc.NumberCarers, 1) AS NumberCarersOnVisit,
        v.CancelPayFlag
    FROM VisitsBase v
    LEFT JOIN CarerCounts cc ON v.MultiCareRef = cc.MLINKREF;

    DECLARE @Inserted int = @@ROWCOUNT;
    RAISERROR('Inserted %d rows this chunk', 0, 1, @Inserted) WITH NOWAIT;

    /* remove processed keys */
    DELETE K
    FROM #Keys K
    INNER JOIN #NextKeys NK ON NK.ACT_REF = K.ACT_REF;

    DECLARE @Remain int = (SELECT COUNT(*) FROM #Keys);
    RAISERROR('%d remaining', 0, 1, @Remain) WITH NOWAIT;
END
