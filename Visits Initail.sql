USE DOM_LIVE;
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @db sysname = DB_NAME();

/* ============================================
   0) Preconditions and helpers (safe to rerun)
===============================================*/

-- 0a) Change Tracking must be ON at DB level
IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_databases WHERE database_id = DB_ID())
BEGIN
  RAISERROR('Change Tracking is NOT enabled at the database level for %s.', 16, 1, @db);
  RETURN;
END

-- 0b) Show CT retention to ensure baseline+gap won't fall out of window
DECLARE @retention_desc nvarchar(200) =
(
  SELECT CONCAT(retention_period, ' ', retention_period_units_desc,
                ' (auto_cleanup=', IIF(is_auto_cleanup_on=1,'ON','OFF'), ')')
  FROM sys.change_tracking_databases WHERE database_id = DB_ID()
);
PRINT CONCAT('CT retention: ', @retention_desc);

-- 0c) CT watermark table
IF OBJECT_ID('dbo.CT_Watermark','U') IS NULL
BEGIN
  CREATE TABLE dbo.CT_Watermark(
    ProcessName     sysname PRIMARY KEY,
    LastSyncVersion bigint       NOT NULL,
    LastSyncTime    datetime2(3) NOT NULL DEFAULT SYSUTCDATETIME()
  );
END

-- 0d) Target table (create if missing) + indexes
IF OBJECT_ID('dbo.tbl_Visits','U') IS NULL
BEGIN
  PRINT 'Creating dbo.tbl_Visits...';
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
    CancelPayFlag             NVARCHAR(4)    NULL,
    CreatedAtUTC              datetime2(3),
    UpdatedAtUTC              datetime2(3)
  );

  IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_tbl_Visits_ClientReference' AND object_id=OBJECT_ID('dbo.tbl_Visits'))
    CREATE INDEX IX_tbl_Visits_ClientReference           ON dbo.tbl_Visits (ClientReference);

  IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_tbl_Visits_EmployeeReference' AND object_id=OBJECT_ID('dbo.tbl_Visits'))
    CREATE INDEX IX_tbl_Visits_EmployeeReference         ON dbo.tbl_Visits (EmployeeReference);

  IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_tbl_Visits_CareplanEmployeeReference' AND object_id=OBJECT_ID('dbo.tbl_Visits'))
    CREATE INDEX IX_tbl_Visits_CareplanEmployeeReference ON dbo.tbl_Visits (CareplanEmployeeReference);

  IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_tbl_Visits_ContractReference' AND object_id=OBJECT_ID('dbo.tbl_Visits'))
    CREATE INDEX IX_tbl_Visits_ContractReference         ON dbo.tbl_Visits (ContractReference);

  IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_tbl_Visits_MultiCareRef' AND object_id=OBJECT_ID('dbo.tbl_Visits'))
    CREATE INDEX IX_tbl_Visits_MultiCareRef              ON dbo.tbl_Visits (MultiCareRef);

  IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_tbl_Visits_BranchReference' AND object_id=OBJECT_ID('dbo.tbl_Visits'))
    CREATE INDEX IX_tbl_Visits_BranchReference           ON dbo.tbl_Visits (BranchReference);

  IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_tbl_Visits_VisitInvoiceStatus' AND object_id=OBJECT_ID('dbo.tbl_Visits'))
    CREATE INDEX IX_tbl_Visits_VisitInvoiceStatus        ON dbo.tbl_Visits (VisitInvoiceStatus);

  IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_tbl_Visits_VisitPayStatus' AND object_id=OBJECT_ID('dbo.tbl_Visits'))
    CREATE INDEX IX_tbl_Visits_VisitPayStatus            ON dbo.tbl_Visits (VisitPayStatus);
END

-- 0e) Ensure the incremental proc exists (you'll run it later)
IF OBJECT_ID('dbo.usp_Sync_Visits_Incremental','P') IS NULL
BEGIN
  RAISERROR('Required proc dbo.usp_Sync_Visits_Incremental not found.',16,1);
  RETURN;
END


/* =====================================================
   1) Fence CT window at baseline start (advance watermark)
   - This guarantees the later incremental covers all changes
     happening DURING and AFTER the baseline.
========================================================*/
DECLARE @Process sysname = N'Visits';
DECLARE @BaselineStartCT bigint = CHANGE_TRACKING_CURRENT_VERSION();

MERGE dbo.CT_Watermark AS t
USING (SELECT @Process AS ProcessName) s
ON t.ProcessName = s.ProcessName
WHEN MATCHED THEN
  UPDATE SET LastSyncVersion = @BaselineStartCT, LastSyncTime = SYSUTCDATETIME()
WHEN NOT MATCHED THEN
  INSERT (ProcessName, LastSyncVersion) VALUES (@Process, @BaselineStartCT);

PRINT CONCAT('Baseline fence set. CT FromVersion=', @BaselineStartCT, ' at ', CONVERT(varchar(23), SYSUTCDATETIME(), 121));


/* ============================================
   2) Baseline load INTO the LIVE table (chunked commits)
   - Commits per chunk to avoid huge UNDO at restart.
===============================================*/
DECLARE @ChunkSize int = 1000000;                 -- tune
DECLARE @RebuildStartedAt datetime2(3) = SYSUTCDATETIME();
DECLARE @BaselineStartedAt datetime2(3) = SYSDATETIME();

BEGIN TRY
  -- Clean slate (fallback to DELETE if TRUNCATE blocked by FKs)
  BEGIN TRY
    TRUNCATE TABLE dbo.tbl_Visits;
    PRINT 'Live table truncated.';
  END TRY
  BEGIN CATCH
    PRINT 'TRUNCATE failed (FKs?). Doing DELETE...';
    DELETE FROM dbo.tbl_Visits;
    PRINT CONCAT('Deleted ', @@ROWCOUNT, ' rows from live.');
  END CATCH;

  -- Seed queue deterministically
  IF OBJECT_ID('tempdb..#Keys') IS NOT NULL DROP TABLE #Keys;
  CREATE TABLE #Keys (ACT_REF int NOT NULL PRIMARY KEY);

  INSERT INTO #Keys (ACT_REF)
  SELECT AHD.ACT_REF
  FROM dbo.ACTIVITY_HD AS AHD
  WHERE AHD.[TYPE] <> 1
    AND EXISTS (SELECT 1 FROM dbo.tbl_Clients AS C WHERE C.ClientReference = AHD.CLIENT_REF);

  DECLARE @Total int = (SELECT COUNT(*) FROM #Keys);
  RAISERROR('Baseline seed total activities: %d', 0, 1, @Total) WITH NOWAIT;
  IF @Total = 0
  BEGIN
    PRINT 'No baseline rows to load.';
    GOTO AfterBaseline;
  END

  DECLARE @InsertedTotal bigint = 0;
  DECLARE @LoopNo int = 0;

  WHILE EXISTS (SELECT 1 FROM #Keys)
  BEGIN
    SET @LoopNo += 1;

    IF OBJECT_ID('tempdb..#NextKeys') IS NOT NULL DROP TABLE #NextKeys;
    CREATE TABLE #NextKeys (ACT_REF int NOT NULL PRIMARY KEY);

    INSERT INTO #NextKeys (ACT_REF)
    SELECT TOP (@ChunkSize) ACT_REF
    FROM #Keys
    ORDER BY ACT_REF;

    BEGIN TRAN;  -- per-chunk transaction

    ;WITH CarerCounts AS (
      SELECT AHD.MLINKREF, COUNT(*) AS NumberCarers
      FROM dbo.ACTIVITY_HD AHD
      JOIN #NextKeys NK ON NK.ACT_REF = AHD.ACT_REF
      WHERE AHD.MLINKREF <> 0
      GROUP BY AHD.MLINKREF
    ),
    VisitsBase AS (
      SELECT
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
        CASE WHEN AHD.CPLAN_DET_REF <> 0 THEN 'From Template Careplan'
             WHEN AHD.CPLAN_DET_REF = 0 AND AHD.RNB_VISIT = 'Y' THEN 'From Booking'
             WHEN AHD.CPLAN_DET_REF = 0 AND AHD.RNB_VISIT <> 'Y' THEN 'Ad-Hoc Entry'
             ELSE '' END AS VisitOrigin,
        AHD.INV_STATUS                   AS VisitInvoiceStatus,
        AHD.PAY_STATUS                   AS VisitPayStatus,
        CASE WHEN AHD.MLINKREF > 0 THEN 'Yes' ELSE 'No' END AS VisitMultiEmployeeFlag,
        CAST(DATEDIFF(MINUTE, AHD.START_DTM, AHD.END_DTM) AS FLOAT) / 60 AS VisitCalculatedDuration,
        SHD.SERVICE_CODE                 AS ServiceCode,
        CS.DESCRIPTION                   AS ContractSource,
        AHD.MLINKREF                     AS MultiCareRef,
        AHD.CANC_PAY                     AS CancelPayFlag
      FROM dbo.ACTIVITY_HD AS AHD
      JOIN #NextKeys NK ON NK.ACT_REF = AHD.ACT_REF
      LEFT JOIN dbo.tbl_Clients  AS CL  ON CL.ClientReference  = AHD.CLIENT_REF
      LEFT JOIN dbo.CONTRACT_DT  AS CDT ON AHD.CONT_DET_REF    = CDT.CONT_DET_REF
      LEFT JOIN dbo.CONTRACT_HD  AS CHD ON CDT.CONTRACT_REF    = CHD.CONTRACT_REF
      LEFT JOIN dbo.SERVICE_HD   AS SHD ON AHD.SERVICE_REF     = SHD.SERVICE_REF
      LEFT JOIN dbo.CAREPLAN_DT  AS CPDT ON AHD.CPLAN_DET_REF  = CPDT.CPLAN_DET_REF
      LEFT JOIN dbo.CHSYSDEC     AS CS  ON CHD.CONTRACT_SOURCE = CS.DECODE_REF
      WHERE AHD.[TYPE] <> 1
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
      NotChangedFromTemplate, NumberCarersOnVisit, CancelPayFlag,
      CreatedAtUTC, UpdatedAtUTC
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
      v.CancelPayFlag,
      @RebuildStartedAt, @RebuildStartedAt
    FROM VisitsBase v
    LEFT JOIN CarerCounts cc ON v.MultiCareRef = cc.MLINKREF;

    DECLARE @InsertedChunk int = @@ROWCOUNT;
    SET @InsertedTotal += @InsertedChunk;

    COMMIT TRAN;

    RAISERROR('Chunk %d inserted %d rows (total so far %d).', 0, 1, @LoopNo, @InsertedChunk, @InsertedTotal) WITH NOWAIT;

    DELETE K
    FROM #Keys K
    JOIN #NextKeys NK ON NK.ACT_REF = K.ACT_REF;

    DECLARE @Remain int = (SELECT COUNT(*) FROM #Keys);
    RAISERROR('%d remaining in baseline queue', 0, 1, @Remain) WITH NOWAIT;
  END

  DECLARE @LiveAfterBaseline bigint = (SELECT COUNT(*) FROM dbo.tbl_Visits);
  PRINT CONCAT('Baseline into LIVE completed. Rows now in dbo.tbl_Visits = ', @LiveAfterBaseline);
END TRY
BEGIN CATCH
  IF XACT_STATE() <> 0 ROLLBACK TRAN;
  DECLARE @msg nvarchar(4000)=ERROR_MESSAGE();
  RAISERROR('Baseline failed: %s',16,1,@msg);
  RETURN;
END CATCH

AfterBaseline:
PRINT CONCAT('Baseline started at ', CONVERT(varchar(23), @BaselineStartedAt, 121),
             ', finished at ', CONVERT(varchar(23), SYSDATETIME(), 121), '.');

-- Optional quick sanity after baseline
SELECT 
  LiveRows         = COUNT(*),
  MinCreatedAtUTC  = MIN(CreatedAtUTC),
  MaxUpdatedAtUTC  = MAX(UpdatedAtUTC)
FROM dbo.tbl_Visits;

-- Plan-only note
DECLARE @BeforeIncWM bigint = (SELECT LastSyncVersion FROM dbo.CT_Watermark WHERE ProcessName='Visits');
DECLARE @CurrentCT  bigint = CHANGE_TRACKING_CURRENT_VERSION();
PRINT REPLICATE('-',80);
PRINT 'Incremental TOP-OFF (plan only). When ready, process CT window:';
PRINT '  FromVersion = ' + CAST(@BeforeIncWM AS varchar);
PRINT '  ToVersion   = ' + CAST(@CurrentCT AS varchar) + '  (capture a fresh upper bound at actual start time)';
PRINT 'Then run the manual incremental wrapper shown below.';
PRINT REPLICATE('-',80);
