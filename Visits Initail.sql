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
            UUID                          VARCHAR(50)    NOT NULL CONSTRAINT PK_tbl_Visits PRIMARY KEY CLUSTERED,
                Client_UUID                   VARCHAR(50)    NULL,
                Employee_UUID                 VARCHAR(50)    NULL,
                Planned_Employee_UUID         VARCHAR(50)    NULL,
                Careplan_UUID                 INT            NULL,
                Branch_UUID                   VARCHAR(50)    NULL,
                Contract_UUID                 VARCHAR(50)    NULL,
                Linked_Visit_UUID             INT            NULL,
                Planned_Duration              INT            NULL,
                Planned_Visit_Start_Date_Time DATETIME2      NULL,
                Planned_Visit_End_Date_Time   DATETIME2      NULL,
                Actual_Duration               INT            NULL,
                Actual_Visit_Start_Date_Time  DATETIME2      NULL,
                Actual_Visit_End_Date_Time    DATETIME2      NULL,
                Visit_Code                    VARCHAR(50)    NULL,
                Visit_Origin                  VARCHAR(30)    NULL,
                Visit_Invoice_Status          INT            NULL,
                Visit_Pay_Status              INT            NULL,
                Cancel_Pay_Flag               NVARCHAR(4)    NULL,
                CreatedAtUTC                  datetime2(3)   NOT NULL CONSTRAINT DF_tbl_Visits_CreatedAtUTC DEFAULT SYSUTCDATETIME(),
                UpdatedAtUTC                  datetime2(3)   NOT NULL CONSTRAINT DF_tbl_Visits_UpdatedAtUTC DEFAULT SYSUTCDATETIME()
        );

        CREATE INDEX IX_tbl_Visits_ClientReference           ON dbo.tbl_Visits (Client_UUID);
        CREATE INDEX IX_tbl_Visits_EmployeeReference         ON dbo.tbl_Visits (Employee_UUID);
        CREATE INDEX IX_tbl_Visits_CareplanEmployeeReference ON dbo.tbl_Visits (Planned_Employee_UUID);
        CREATE INDEX IX_tbl_Visits_ContractReference         ON dbo.tbl_Visits (Contract_UUID);
        CREATE INDEX IX_tbl_Visits_MultiCareRef              ON dbo.tbl_Visits (Linked_Visit_UUID);
        CREATE INDEX IX_tbl_Visits_BranchReference           ON dbo.tbl_Visits (Branch_UUID);
        CREATE INDEX IX_tbl_Visits_VisitInvoiceStatus        ON dbo.tbl_Visits (Visit_Invoice_Status);
        CREATE INDEX IX_tbl_Visits_VisitPayStatus            ON dbo.tbl_Visits (Visit_Pay_Status);

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
          AND AHD.START_DTM >= DATEADD(YEAR, -3, SYSUTCDATETIME());  -- only last 3 years;

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

            ;WITH VisitsBase AS (
                SELECT
                    CAST(AHD.ACT_REF     AS varchar(50)) AS UUID,
                    CAST(AHD.CLIENT_REF  AS varchar(50)) AS Client_UUID,
                    CASE WHEN AHD.EMP_REF = 0  THEN NULL ELSE CAST(AHD.EMP_REF  AS varchar(50)) END AS Employee_UUID,
                    CASE WHEN CPDT.EMP_REF = 0 THEN NULL ELSE CAST(CPDT.EMP_REF AS varchar(50)) END AS Planned_Employee_UUID,
                    CASE WHEN AHD.CPLAN_DET_REF = 0 THEN NULL ELSE AHD.CPLAN_DET_REF END          AS Careplan_UUID,
                    CASE WHEN AHD.GS_REF = 0 THEN NULL ELSE AHD.GS_REF END                       AS Group_UUID,         
                    CAST(AHD.GS_REF AS varchar(50))       AS Branch_UUID,
                    CAST(CHD.CONTRACT_REF AS varchar(50)) AS Contract_UUID,
                    CASE WHEN AHD.MLINKREF = 0 THEN NULL ELSE AHD.MLINKREF END                     AS Linked_Visit_UUID,
                    CAST(COALESCE(CPDT.QUANTITY,0) * 60 AS INT)                                    AS Planned_Duration,
                    CAST(AHD.ORIGSTDTM AS DATETIME2)                                              AS Planned_Visit_Start_Date_Time,
                    CAST(DATEADD(MINUTE, COALESCE(CPDT.QUANTITY,0), AHD.ORIGSTDTM) AS DATETIME2)  AS Planned_Visit_End_Date_Time,
                    DATEDIFF(MINUTE, AHD.START_DTM, AHD.END_DTM)                                   AS Actual_Duration,
                    CAST(AHD.START_DTM AS DATETIME2)                                              AS Actual_Visit_Start_Date_Time,
                    CAST(AHD.END_DTM   AS DATETIME2)                                              AS Actual_Visit_End_Date_Time,
                    SHD.SERVICE_CODE                                                                AS Visit_Code,
                    CASE 
                        WHEN AHD.CPLAN_DET_REF <> 0                        THEN 'From Template Careplan'
                        WHEN AHD.CPLAN_DET_REF = 0 AND AHD.RNB_VISIT = 'Y' THEN 'From Booking'
                        WHEN AHD.CPLAN_DET_REF = 0 AND AHD.RNB_VISIT <> 'Y' THEN 'Ad-Hoc Entry'
                        ELSE '' 
                    END                                                                             AS Visit_Origin,
                    AHD.INV_STATUS                                                                  AS Visit_Invoice_Status,
                    AHD.PAY_STATUS                                                                  AS Visit_Pay_Status,
                    CASE WHEN LEN(AHD.CANC_PAY) >= 1 THEN AHD.CANC_PAY ELSE NULL END                AS Cancel_Pay_Flag
                FROM dbo.ACTIVITY_HD AS AHD
                JOIN #NextKeys NK                 ON NK.ACT_REF       = AHD.ACT_REF          -- <<< missing in your proc
                LEFT JOIN dbo.CONTRACT_DT  AS CDT ON AHD.CONT_DET_REF = CDT.CONT_DET_REF
                LEFT JOIN dbo.CONTRACT_HD  AS CHD ON CDT.CONTRACT_REF = CHD.CONTRACT_REF
                LEFT JOIN dbo.SERVICE_HD   AS SHD ON AHD.SERVICE_REF  = SHD.SERVICE_REF
                LEFT JOIN dbo.CAREPLAN_DT  AS CPDT ON AHD.CPLAN_DET_REF = CPDT.CPLAN_DET_REF
                WHERE AHD.[TYPE] <> 1
                AND AHD.START_DTM >= DATEADD(YEAR, -3, SYSUTCDATETIME())  -- only last 3 years
            )
            INSERT INTO dbo.tbl_Visits (
                UUID, Client_UUID, Employee_UUID, Planned_Employee_UUID, Careplan_UUID,
                Branch_UUID, Contract_UUID, Linked_Visit_UUID, Planned_Duration,
                Planned_Visit_Start_Date_Time, Planned_Visit_End_Date_Time, Actual_Duration,
                Actual_Visit_Start_Date_Time, Actual_Visit_End_Date_Time, Visit_Code,
                Visit_Origin, Visit_Invoice_Status, Visit_Pay_Status, Cancel_Pay_Flag,
                CreatedAtUTC, UpdatedAtUTC
            )
            SELECT
                v.UUID,
                v.Client_UUID,
                v.Employee_UUID,
                v.Planned_Employee_UUID,
                v.Careplan_UUID,
                v.Branch_UUID,
                v.Contract_UUID,
                v.Linked_Visit_UUID,
                v.Planned_Duration,
                v.Planned_Visit_Start_Date_Time,
                v.Planned_Visit_End_Date_Time,
                v.Actual_Duration,
                v.Actual_Visit_Start_Date_Time,
                v.Actual_Visit_End_Date_Time,
                v.Visit_Code,
                v.Visit_Origin,
                v.Visit_Invoice_Status,
                v.Visit_Pay_Status,
                v.Cancel_Pay_Flag,
                @RunStartedAt, @RunStartedAt
            FROM VisitsBase v;

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
