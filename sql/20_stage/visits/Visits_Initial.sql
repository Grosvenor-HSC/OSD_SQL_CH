/*
Purpose:
    Perform the initial full load of visit records into dbo.tbl_Visits (baseline backfill).

Design goals:
    - Destructive + deterministic
    - Safe to re-run in non-prod
    - Immune to leftover objects (table/view/synonym)
    - Chunked load with temp table reuse
    - Reliable progress reporting via dbo.ETL_BatchProgress

Notes:
    - Requires dbo.tbl_Clients to exist (Clients initial must run first)
*/

USE [DOM_LIVE];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Sync_Visits_Initial
    @ChunkSize    int = 1000000,
    @EmitProgress bit = 1,
    @Summary      nvarchar(4000) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET ANSI_WARNINGS ON;

    DECLARE @Process      sysname      = N'Visits';
    DECLARE @RunStartedAt datetime2(3) = SYSUTCDATETIME();
    DECLARE @StartIso     varchar(33)  = CONVERT(varchar(33), @RunStartedAt, 126);
    DECLARE @BaselineFrom bigint;

    DECLARE @RunId uniqueidentifier = NEWID();

    DECLARE @LockResource sysname = N'DOM_LIVE:Sync:Visits';
    DECLARE @lockResult   int;
    DECLARE @lockHeld     bit = 0;

    DECLARE @InsertedTotal bigint = 0;
    DECLARE @InsertedBatch int;
    DECLARE @BatchNo int = 0;
    DECLARE @RemainingKeys bigint;

    IF @ChunkSize IS NULL OR @ChunkSize <= 0
        THROW 50000, 'Visits initial: @ChunkSize must be > 0.', 1;

    BEGIN TRY
        /* Ensure progress table exists (idempotent) */
        IF OBJECT_ID(N'dbo.ETL_BatchProgress', N'U') IS NULL
        BEGIN
            CREATE TABLE dbo.ETL_BatchProgress
            (
                RunId         uniqueidentifier NOT NULL,
                ProcessName   sysname          NOT NULL,
                BatchNo       int              NOT NULL,
                InsertedBatch int              NULL,
                InsertedTotal bigint           NULL,
                RemainingKeys bigint           NULL,
                Message       nvarchar(4000)   NULL,
                LoggedAtUTC   datetime2(3)     NOT NULL CONSTRAINT DF_ETL_BatchProgress_LoggedAtUTC DEFAULT SYSUTCDATETIME(),
                CONSTRAINT PK_ETL_BatchProgress PRIMARY KEY CLUSTERED (RunId, ProcessName, BatchNo, LoggedAtUTC)
            );

            CREATE INDEX IX_ETL_BatchProgress_Run
                ON dbo.ETL_BatchProgress (RunId, ProcessName, LoggedAtUTC DESC);
        END;

        /* Concurrency */
        EXEC @lockResult = sys.sp_getapplock
            @Resource=@LockResource,
            @LockMode='Exclusive',
            @LockOwner='Session',
            @DbPrincipal='dbo',
            @LockTimeout=600000;

        IF @lockResult NOT IN (0,1)
            THROW 50000, 'Visits initial failed: could not acquire applock.', 1;

        SET @lockHeld = 1;

        /* Preconditions */
        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_databases WHERE database_id = DB_ID())
            THROW 50000, 'Change Tracking not enabled at DB level.', 1;

        IF OBJECT_ID(N'dbo.ACTIVITY_HD', N'U') IS NULL
            THROW 50000, 'Source table dbo.ACTIVITY_HD not found.', 1;

        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.ACTIVITY_HD'))
            THROW 50000, 'Change Tracking not enabled on dbo.ACTIVITY_HD.', 1;

        IF OBJECT_ID(N'dbo.tbl_Clients', N'U') IS NULL
            THROW 50000, 'dbo.tbl_Clients missing. Run Clients initial before Visits initial.', 1;

        /* Fence CT window + seed watermark */
        SET @BaselineFrom = CHANGE_TRACKING_CURRENT_VERSION();

        IF OBJECT_ID(N'dbo.CT_Watermark', N'U') IS NULL
        BEGIN
            CREATE TABLE dbo.CT_Watermark
            (
                ProcessName     sysname      NOT NULL CONSTRAINT PK_CT_Watermark PRIMARY KEY,
                LastSyncVersion bigint       NOT NULL,
                LastSyncTime    datetime2(3) NOT NULL CONSTRAINT DF_CT_Watermark_LastSyncTime DEFAULT SYSUTCDATETIME()
            );
        END;

        MERGE dbo.CT_Watermark AS t
        USING (SELECT @Process AS ProcessName) s
          ON t.ProcessName = s.ProcessName
        WHEN MATCHED THEN
            UPDATE SET LastSyncVersion=@BaselineFrom, LastSyncTime=SYSUTCDATETIME()
        WHEN NOT MATCHED THEN
            INSERT (ProcessName, LastSyncVersion, LastSyncTime)
            VALUES (@Process, @BaselineFrom, SYSUTCDATETIME());

        BEGIN TRAN;

        /* Hard reset target safely (synonym/view/table safe) */
        IF EXISTS (SELECT 1 FROM sys.synonyms WHERE schema_id = SCHEMA_ID(N'dbo') AND name = N'tbl_Visits')
            EXEC sys.sp_executesql N'DROP SYNONYM dbo.tbl_Visits;';

        IF EXISTS (SELECT 1 FROM sys.views WHERE object_id = OBJECT_ID(N'dbo.tbl_Visits'))
            EXEC sys.sp_executesql N'DROP VIEW dbo.tbl_Visits;';

        IF OBJECT_ID(N'dbo.tbl_Visits', N'U') IS NOT NULL
            DROP TABLE dbo.tbl_Visits;

        CREATE TABLE dbo.tbl_Visits
        (
            UUID                          int           NOT NULL,
            Client_UUID                   int           NULL,
            Employee_UUID                 int           NULL,
            Planned_Employee_UUID         int           NULL,
            Careplan_UUID                 int           NULL,
            Care_Group                    int           NULL,
            Branch_UUID                   int           NULL,
            Contract_UUID                 int           NULL,
            Linked_Visit_UUID             int           NULL,
            Planned_Duration              int           NULL,
            Planned_Visit_Start_Date_Time datetime2     NULL,
            Planned_Visit_End_Date_Time   datetime2     NULL,
            Actual_Duration               int           NULL,
            Actual_Visit_Start_Date_Time  datetime2     NULL,
            Actual_Visit_End_Date_Time    datetime2     NULL,
            Visit_Code                    varchar(50)   NULL,
            Visit_Origin                  varchar(30)   NULL,
            Visit_Invoice_Status          int           NULL,
            Visit_Pay_Status              int           NULL,
            Cancel_Pay_Flag               nvarchar(4)   NULL,
            CreatedAtUTC                  datetime2(3)  NOT NULL CONSTRAINT DF_tbl_Visits_CreatedAtUTC DEFAULT SYSUTCDATETIME(),
            UpdatedAtUTC                  datetime2(3)  NOT NULL CONSTRAINT DF_tbl_Visits_UpdatedAtUTC DEFAULT SYSUTCDATETIME(),
            CONSTRAINT PK_tbl_Visits PRIMARY KEY CLUSTERED (UUID)
        );

        /* Temp tables: create once, reuse */
        IF OBJECT_ID('tempdb..#Keys') IS NOT NULL DROP TABLE #Keys;
        IF OBJECT_ID('tempdb..#NextKeys') IS NOT NULL DROP TABLE #NextKeys;

        CREATE TABLE #Keys (ACT_REF int NOT NULL PRIMARY KEY);
        CREATE TABLE #NextKeys (ACT_REF int NOT NULL PRIMARY KEY);

        INSERT INTO #Keys (ACT_REF)
        SELECT AHD.ACT_REF
        FROM dbo.ACTIVITY_HD AS AHD
        WHERE AHD.[TYPE] <> 1
          AND AHD.START_DTM >= DATEADD(YEAR, -3, SYSUTCDATETIME());

        SET @RemainingKeys = (SELECT COUNT_BIG(1) FROM #Keys);

        COMMIT;

        /* Log start */
        INSERT dbo.ETL_BatchProgress (RunId, ProcessName, BatchNo, InsertedBatch, InsertedTotal, RemainingKeys, Message)
        VALUES (@RunId, @Process, 0, NULL, 0, @RemainingKeys,
                N'Starting batches. ChunkSize=' + CONVERT(nvarchar(30), @ChunkSize));

        IF @EmitProgress = 1
            RAISERROR('Visits initial: progress logging enabled. Query dbo.ETL_BatchProgress by RunId.', 10, 1) WITH NOWAIT;

        /* Chunk loop */
        WHILE EXISTS (SELECT 1 FROM #Keys)
        BEGIN
            SET @BatchNo += 1;

            TRUNCATE TABLE #NextKeys;

            INSERT INTO #NextKeys (ACT_REF)
            SELECT TOP (@ChunkSize) k.ACT_REF
            FROM #Keys AS k
            ORDER BY k.ACT_REF;

            BEGIN TRAN;

            ;WITH VisitsBase AS
            (
                SELECT
                    UUID                          = AHD.ACT_REF,
                    Client_UUID                   = AHD.CLIENT_REF,
                    Employee_UUID                 = NULLIF(AHD.EMP_REF,0),
                    Planned_Employee_UUID         = NULLIF(CPDT.EMP_REF,0),
                    Careplan_UUID                 = NULLIF(AHD.CPLAN_DET_REF,0),
                    Care_Group                    = NULLIF(AHD.GS_REF,0),
                    Branch_UUID                   = C.Branch_UUID,
                    Contract_UUID                 = CHD.CONTRACT_REF,
                    Linked_Visit_UUID             = NULLIF(AHD.MLINKREF,0),
                    Planned_Duration              = CAST(COALESCE(CPDT.QUANTITY,0) * 60 AS int),
                    Planned_Visit_Start_Date_Time = AHD.ORIGSTDTM,
                    Planned_Visit_End_Date_Time   = DATEADD(MINUTE, COALESCE(CPDT.QUANTITY,0), AHD.ORIGSTDTM),
                    Actual_Duration               = DATEDIFF(MINUTE, AHD.START_DTM, AHD.END_DTM),
                    Actual_Visit_Start_Date_Time  = AHD.START_DTM,
                    Actual_Visit_End_Date_Time    = AHD.END_DTM,
                    Visit_Code                    = SHD.SERVICE_CODE,
                    Visit_Origin                  =
                        CASE
                            WHEN AHD.CPLAN_DET_REF <> 0 THEN 'From Template Careplan'
                            WHEN AHD.RNB_VISIT = 'Y'    THEN 'From Booking'
                            ELSE 'Ad-Hoc Entry'
                        END,
                    Visit_Invoice_Status          = AHD.INV_STATUS,
                    Visit_Pay_Status              = AHD.PAY_STATUS,
                    Cancel_Pay_Flag               = NULLIF(AHD.CANC_PAY,'')
                FROM dbo.ACTIVITY_HD AS AHD
                JOIN #NextKeys       AS NK  ON NK.ACT_REF = AHD.ACT_REF
                LEFT JOIN dbo.CAREPLAN_DT  AS CPDT ON AHD.CPLAN_DET_REF = CPDT.CPLAN_DET_REF
                LEFT JOIN dbo.CONTRACT_DT  AS CDT  ON AHD.CONT_DET_REF  = CDT.CONT_DET_REF
                LEFT JOIN dbo.CONTRACT_HD  AS CHD  ON CDT.CONTRACT_REF  = CHD.CONTRACT_REF
                LEFT JOIN dbo.SERVICE_HD   AS SHD  ON AHD.SERVICE_REF   = SHD.SERVICE_REF
                JOIN dbo.tbl_Clients       AS C    ON C.UUID            = AHD.CLIENT_REF
            )
            INSERT dbo.tbl_Visits
            (
                UUID, Client_UUID, Employee_UUID, Planned_Employee_UUID,
                Careplan_UUID, Care_Group, Branch_UUID, Contract_UUID,
                Linked_Visit_UUID, Planned_Duration,
                Planned_Visit_Start_Date_Time, Planned_Visit_End_Date_Time,
                Actual_Duration, Actual_Visit_Start_Date_Time, Actual_Visit_End_Date_Time,
                Visit_Code, Visit_Origin, Visit_Invoice_Status, Visit_Pay_Status,
                Cancel_Pay_Flag, CreatedAtUTC, UpdatedAtUTC
            )
            SELECT
                v.UUID, v.Client_UUID, v.Employee_UUID, v.Planned_Employee_UUID,
                v.Careplan_UUID, v.Care_Group, v.Branch_UUID, v.Contract_UUID,
                v.Linked_Visit_UUID, v.Planned_Duration,
                v.Planned_Visit_Start_Date_Time, v.Planned_Visit_End_Date_Time,
                v.Actual_Duration, v.Actual_Visit_Start_Date_Time, v.Actual_Visit_End_Date_Time,
                v.Visit_Code, v.Visit_Origin, v.Visit_Invoice_Status, v.Visit_Pay_Status,
                v.Cancel_Pay_Flag, @RunStartedAt, @RunStartedAt
            FROM VisitsBase v;

            SET @InsertedBatch = @@ROWCOUNT;
            SET @InsertedTotal += @InsertedBatch;

            DELETE k
            FROM #Keys k
            JOIN #NextKeys n ON n.ACT_REF = k.ACT_REF;

            SET @RemainingKeys = (SELECT COUNT_BIG(1) FROM #Keys);

            COMMIT;

            /* Log batch */
            INSERT dbo.ETL_BatchProgress (RunId, ProcessName, BatchNo, InsertedBatch, InsertedTotal, RemainingKeys, Message)
            VALUES (@RunId, @Process, @BatchNo, @InsertedBatch, @InsertedTotal, @RemainingKeys, NULL);
        END;

        /* Helpful indexes */
        CREATE INDEX IX_tbl_Visits_Client_UUID   ON dbo.tbl_Visits (Client_UUID);
        CREATE INDEX IX_tbl_Visits_Employee_UUID ON dbo.tbl_Visits (Employee_UUID);
        CREATE INDEX IX_tbl_Visits_Branch_UUID   ON dbo.tbl_Visits (Branch_UUID);
        CREATE INDEX IX_tbl_Visits_ActualStart   ON dbo.tbl_Visits (Actual_Visit_Start_Date_Time);

        /* Enable CT on target (optional) */
        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.tbl_Visits'))
        BEGIN
            ALTER TABLE dbo.tbl_Visits ENABLE CHANGE_TRACKING WITH (TRACK_COLUMNS_UPDATED = ON);
        END;

        DECLARE @EndUTC datetime2(3) = SYSUTCDATETIME();
        DECLARE @EndIso varchar(33)  = CONVERT(varchar(33), @EndUTC, 126);

        SET @Summary =
            N'Visits initial RunId=' + CONVERT(nvarchar(36), @RunId) +
            N' started ' + @StartIso +
            N' UTC; ended ' + @EndIso +
            N' UTC; inserted ' + CAST(@InsertedTotal AS nvarchar(30)) +
            N' rows; watermark set to ' + CAST(@BaselineFrom AS nvarchar(30)) + N'.';

        SELECT N'Initial' AS Stage, @Summary AS Summary;

        IF @lockHeld = 1
            EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner='Session', @DbPrincipal='dbo';

        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK;

        IF @lockHeld = 1
            EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner='Session', @DbPrincipal='dbo';

        DECLARE @msg nvarchar(4000) = ERROR_MESSAGE();
        SET @Summary = N'Visits initial failed RunId=' + CONVERT(nvarchar(36), @RunId) + N': ' + ISNULL(@msg, N'(null)');
        SELECT N'Initial' AS Stage, @Summary AS Summary;

        /* Log failure */
        INSERT dbo.ETL_BatchProgress (RunId, ProcessName, BatchNo, InsertedBatch, InsertedTotal, RemainingKeys, Message)
        VALUES (@RunId, @Process, -1, NULL, @InsertedTotal, NULL, @Summary);

        THROW;
    END CATCH
END;
GO
