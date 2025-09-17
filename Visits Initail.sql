USE [DOM_LIVE];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Sync_Visits_Initial
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET ANSI_WARNINGS ON;

    DECLARE @Process       sysname      = N'Visits';
    DECLARE @RunStartedAt  datetime2(3) = SYSUTCDATETIME();
    DECLARE @StartIso      varchar(33)  = CONVERT(varchar(33), @RunStartedAt, 126);
    DECLARE @BaselineFrom  bigint;
    DECLARE @LockResource  sysname      = N'DOM_LIVE:Sync:Visits';
    DECLARE @lockResult    int;
    DECLARE @lockHeld      bit          = 0;

    /* -------------------------
       0) Concurrency / checks
    --------------------------*/
    EXEC @lockResult = sys.sp_getapplock
        @Resource=@LockResource, @LockMode='Exclusive',
        @LockOwner='Session', @DbPrincipal='dbo', @LockTimeout=600000;  -- 10 min
    IF @lockResult NOT IN (0,1)
    BEGIN
        SELECT 'Initial' AS Stage, CAST(N'Visits initial failed: could not acquire applock.' AS nvarchar(4000)) AS Summary;
        RETURN -1;
    END
    SET @lockHeld = 1;

    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_databases WHERE database_id = DB_ID())
            RAISERROR('Change Tracking is not enabled at the database level.', 16, 1);

        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.ACTIVITY_HD'))
            RAISERROR('Change Tracking is not enabled on dbo.ACTIVITY_HD.', 16, 1);

        /* -----------------------------------------------
           1) Fence CT window (seed watermark at START)
        ------------------------------------------------*/
        SET @BaselineFrom = CHANGE_TRACKING_CURRENT_VERSION();

        IF OBJECT_ID('dbo.CT_Watermark','U') IS NULL
        BEGIN
            CREATE TABLE dbo.CT_Watermark
            (
              ProcessName     sysname      PRIMARY KEY,
              LastSyncVersion bigint       NOT NULL,
              LastSyncTime    datetime2(3) NOT NULL DEFAULT SYSUTCDATETIME()
            );
        END

        MERGE dbo.CT_Watermark AS t
        USING (SELECT @Process AS ProcessName) s
          ON t.ProcessName = s.ProcessName
        WHEN MATCHED THEN
            UPDATE SET LastSyncVersion = @BaselineFrom, LastSyncTime = SYSUTCDATETIME()
        WHEN NOT MATCHED THEN
            INSERT (ProcessName, LastSyncVersion, LastSyncTime) VALUES (@Process, @BaselineFrom, SYSUTCDATETIME());

        /* -----------------------------------------------
           2) Recreate target table + indexes
        ------------------------------------------------*/
        IF OBJECT_ID('dbo.tbl_Visits','U') IS NOT NULL
            DROP TABLE dbo.tbl_Visits;

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
            CreatedAtUTC              datetime2(3)   NOT NULL CONSTRAINT DF_tbl_Visits_CreatedAtUTC DEFAULT SYSUTCDATETIME(),
            UpdatedAtUTC              datetime2(3)   NOT NULL CONSTRAINT DF_tbl_Visits_UpdatedAtUTC DEFAULT SYSUTCDATETIME()
        );

        CREATE INDEX IX_tbl_Visits_ClientReference           ON dbo.tbl_Visits (ClientReference);
        CREATE INDEX IX_tbl_Visits_EmployeeReference         ON dbo.tbl_Visits (EmployeeReference);
        CREATE INDEX IX_tbl_Visits_CareplanEmployeeReference ON dbo.tbl_Visits (CareplanEmployeeReference);
        CREATE INDEX IX_tbl_Visits_ContractReference         ON dbo.tbl_Visits (ContractReference);
        CREATE INDEX IX_tbl_Visits_MultiCareRef              ON dbo.tbl_Visits (MultiCareRef);
        CREATE INDEX IX_tbl_Visits_BranchReference           ON dbo.tbl_Visits (BranchReference);
        CREATE INDEX IX_tbl_Visits_VisitInvoiceStatus        ON dbo.tbl_Visits (VisitInvoiceStatus);
        CREATE INDEX IX_tbl_Visits_VisitPayStatus            ON dbo.tbl_Visits (VisitPayStatus);

        /* -----------------------------------------------
           3) Baseline load (chunked + detailed progress)
        ------------------------------------------------*/
        DECLARE @ChunkSize int = 1000000;

        IF OBJECT_ID('tempdb..#Keys') IS NOT NULL DROP TABLE #Keys;
        CREATE TABLE #Keys (ACT_REF int NOT NULL PRIMARY KEY);

        INSERT INTO #Keys (ACT_REF)
        SELECT AHD.ACT_REF
        FROM dbo.ACTIVITY_HD AHD
        WHERE AHD.[TYPE] <> 1
          AND EXISTS (SELECT 1 FROM dbo.tbl_Clients C WHERE C.ClientReference = AHD.CLIENT_REF);

        DECLARE @Total int = (SELECT COUNT(*) FROM #Keys);
        DECLARE @EstBatches int = CASE WHEN @Total = 0 THEN 0 ELSE (@Total + @ChunkSize - 1) / @ChunkSize END;

        RAISERROR('Visits baseline: total=%d, chunkSize=%d, est_batches=%d', 0, 1, @Total, @ChunkSize, @EstBatches) WITH NOWAIT;

        DECLARE @InsertedTotal bigint = 0;
        DECLARE @BatchNo int = 0;

        WHILE EXISTS (SELECT 1 FROM #Keys)
        BEGIN
            SET @BatchNo += 1;

            IF OBJECT_ID('tempdb..#NextKeys') IS NOT NULL DROP TABLE #NextKeys;
            CREATE TABLE #NextKeys (ACT_REF int NOT NULL PRIMARY KEY);

            INSERT INTO #NextKeys (ACT_REF)
            SELECT TOP (@ChunkSize) ACT_REF
            FROM #Keys
            ORDER BY ACT_REF;

            DECLARE @NextCount int = (SELECT COUNT(*) FROM #NextKeys);
            DECLARE @RemainBefore int = (SELECT COUNT(*) FROM #Keys);
            DECLARE @NowStart varchar(23) = CONVERT(varchar(23), SYSDATETIME(), 121);

            RAISERROR('Batch %d/%d starting at %s: picking %d rows (remaining before=%d, inserted so far=%d of %d)',
                      0, 1, @BatchNo, @EstBatches, @NowStart, @NextCount, @RemainBefore, @InsertedTotal, @Total) WITH NOWAIT;

            BEGIN TRAN;

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
                IIF(v.NoEmpInTemplate = 0 AND v.EmpChangedFromTemplate = 0 AND v.TimeChangedFromTemplate = 0, 1, 0),
                ISNULL(cc.NumberCarers, 1),
                v.CancelPayFlag,
                @RunStartedAt, @RunStartedAt
            FROM VisitsBase v
            LEFT JOIN CarerCounts cc ON v.MultiCareRef = cc.MLINKREF;

            DECLARE @InsertedChunk int = @@ROWCOUNT;
            SET @InsertedTotal += @InsertedChunk;

            COMMIT TRAN;

            DECLARE @NowEnd varchar(23) = CONVERT(varchar(23), SYSDATETIME(), 121);

            RAISERROR('Batch %d/%d finished at %s: inserted=%d (running_total=%d of %d)',
                      0, 1, @BatchNo, @EstBatches, @NowEnd, @InsertedChunk, @InsertedTotal, @Total) WITH NOWAIT;

            /* remove processed keys */
            DELETE K
            FROM #Keys K
            JOIN #NextKeys NK ON NK.ACT_REF = K.ACT_REF;

            DECLARE @RemainAfter int = (SELECT COUNT(*) FROM #Keys);
            RAISERROR('Remaining after batch %d: %d', 0, 1, @BatchNo, @RemainAfter) WITH NOWAIT;
        END

        /* -----------------------------------------------
           4) Quiet incremental top-off + summary
        ------------------------------------------------*/
        DECLARE @EndInitialUTC datetime2(3) = SYSUTCDATETIME();
        DECLARE @EndInitialIso varchar(33)  = CONVERT(varchar(33), @EndInitialUTC, 126);
        DECLARE @InitialMsg   nvarchar(4000) =
            CONCAT(N'Visits initial started ', @StartIso, N' UTC; ended ', @EndInitialIso,
                   N' UTC; baseline inserted ', @InsertedTotal, N' rows.');

        DECLARE @IncrMsg nvarchar(4000) = N'Incremental skipped.';
        IF OBJECT_ID('dbo.usp_Sync_Visits_Incremental','P') IS NOT NULL
        BEGIN
            DECLARE @rc int;
            EXEC @rc = dbo.usp_Sync_Visits_Incremental
                @ChunkSize=100000, @LockTimeoutMs=600000, @UseAppLock=0,
                @EmitInfo=0, @Summary=@IncrMsg OUTPUT, @ReturnSummaryRow=0;
            IF (@rc < 0)
                SET @IncrMsg = CONCAT(@IncrMsg, N' (rc=', @rc, N')');
        END

        SELECT 'Initial' AS Stage,     @InitialMsg AS Summary
        UNION ALL
        SELECT 'Incremental',          @IncrMsg;

        IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner='Session', @DbPrincipal='dbo';
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner='Session', @DbPrincipal='dbo';
        DECLARE @msg nvarchar(4000)=ERROR_MESSAGE();
        SELECT 'Initial' AS Stage, CAST(CONCAT(N'Visits initial failed: ', @msg) AS nvarchar(4000)) AS Summary;
        RETURN -50001;
    END CATCH
END
GO
