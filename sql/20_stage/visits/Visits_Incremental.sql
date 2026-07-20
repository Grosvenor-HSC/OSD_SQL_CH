USE [DOM_LIVE];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Sync_Visits_Incremental
    @ChunkSize        int            = 100000,
    @LockTimeoutMs    int            = 60000,
    @UseAppLock       bit            = 1,
    @EmitInfo         bit            = 1,
    @Summary          nvarchar(4000) = NULL OUTPUT,
    @ReturnSummaryRow bit            = 1,
    @PurgeOldVisits   bit            = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET ANSI_WARNINGS ON;

    DECLARE @Process       sysname      = N'Visits';
    DECLARE @RunStartedAt  datetime2(3) = SYSUTCDATETIME();
    DECLARE @StartIso      varchar(33)  = CONVERT(varchar(33), @RunStartedAt, 126);
    DECLARE @EndUTC        datetime2(3);
    DECLARE @EndIso        varchar(33);
    DECLARE @DurationSec   int;

    IF @ChunkSize IS NULL OR @ChunkSize <= 0
    BEGIN
        SET @Summary = N'Visits incremental failed: @ChunkSize must be > 0.';
        IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
        RETURN -10;
    END

    /* Retention is normally handled by dbo.usp_Purge_Visits_Expired. */
    IF @PurgeOldVisits IS NULL
        SET @PurgeOldVisits = 0;

    DECLARE @ScopeStart datetime2(3) = DATEADD(YEAR, -3, SYSUTCDATETIME());

    /* 0) Concurrency guard */
    DECLARE @LockResource sysname = N'DOM_LIVE:Sync:Visits';
    DECLARE @LockOwner    sysname = N'Session';
    DECLARE @DbPrincipal  sysname = N'dbo';
    DECLARE @lockResult   int;
    DECLARE @lockHeld     bit = 0;

    IF @UseAppLock = 1
    BEGIN
        EXEC @lockResult = sys.sp_getapplock
            @Resource=@LockResource,
            @LockMode='Exclusive',
            @LockOwner=@LockOwner,
            @DbPrincipal=@DbPrincipal,
            @LockTimeout=@LockTimeoutMs;

        IF @lockResult NOT IN (0,1)
        BEGIN
            IF @EmitInfo=1 RAISERROR('Could not acquire %s (rc=%d).',16,1,@LockResource,@lockResult);
            SET @Summary = N'Visits incremental failed: could not acquire applock.';
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            RETURN @lockResult;
        END
        SET @lockHeld = 1;
    END

    BEGIN TRY
        /* 1) Preconditions */
        IF OBJECT_ID(N'dbo.tbl_Visits', N'U') IS NULL
        BEGIN
            IF @EmitInfo=1 RAISERROR('Target dbo.tbl_Visits is missing. Run Visits initial first.',16,1);
            SET @Summary = N'Visits incremental failed: target missing (run initial).';
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            GOTO FinallyRelease;
        END

        IF OBJECT_ID(N'dbo.tbl_Clients', N'U') IS NULL
        BEGIN
            IF @EmitInfo=1 RAISERROR('dbo.tbl_Clients missing. Run Clients load before Visits incremental.',16,1);
            SET @Summary = N'Visits incremental failed: tbl_Clients missing.';
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            GOTO FinallyRelease;
        END

        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_databases WHERE database_id = DB_ID())
        BEGIN
            IF @EmitInfo=1 RAISERROR('CT not enabled at DB level.',16,1);
            SET @Summary = N'Visits incremental failed: CT not enabled at DB level.';
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            GOTO FinallyRelease;
        END

        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.ACTIVITY_HD'))
        BEGIN
            IF @EmitInfo=1 RAISERROR('CT not enabled on dbo.ACTIVITY_HD.',16,1);
            SET @Summary = N'Visits incremental failed: CT not enabled on ACTIVITY_HD.';
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            GOTO FinallyRelease;
        END

        /* 2) Watermark */
        IF OBJECT_ID(N'dbo.CT_Watermark', N'U') IS NULL
        BEGIN
            CREATE TABLE dbo.CT_Watermark
            (
                ProcessName     sysname      PRIMARY KEY,
                LastSyncVersion bigint       NOT NULL,
                LastSyncTime    datetime2(3) NOT NULL DEFAULT SYSUTCDATETIME()
            );
        END

        IF NOT EXISTS (SELECT 1 FROM dbo.CT_Watermark WITH (HOLDLOCK, UPDLOCK) WHERE ProcessName=@Process)
            INSERT INTO dbo.CT_Watermark(ProcessName, LastSyncVersion) VALUES (@Process, 0);

        DECLARE @LastSyncVersion bigint =
            (SELECT LastSyncVersion FROM dbo.CT_Watermark WITH (HOLDLOCK, UPDLOCK) WHERE ProcessName=@Process);

        DECLARE @MinValid bigint = CHANGE_TRACKING_MIN_VALID_VERSION(OBJECT_ID(N'dbo.ACTIVITY_HD'));
        IF @MinValid IS NOT NULL AND @LastSyncVersion < @MinValid
        BEGIN
            IF @EmitInfo=1 RAISERROR('Watermark %I64d < CT min valid %I64d (re-baseline).',16,1,@LastSyncVersion,@MinValid);
            SET @Summary = CONCAT(N'Visits incremental failed: watermark ', @LastSyncVersion, N' < min valid ', @MinValid, N'.');
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            GOTO FinallyRelease;
        END

        DECLARE @ToVersion bigint = CHANGE_TRACKING_CURRENT_VERSION();

        /* EmitInfo (FIXED) */
        IF @EmitInfo = 1
        BEGIN
            DECLARE @ScopeStartIso varchar(33) = CONVERT(varchar(33), @ScopeStart, 126);

            RAISERROR('Visits CT window:', 0, 1) WITH NOWAIT;
            RAISERROR('  From=%I64d', 0, 1, @LastSyncVersion) WITH NOWAIT;
            RAISERROR('  To  =%I64d', 0, 1, @ToVersion)       WITH NOWAIT;
            RAISERROR('  ScopeStart=%s', 0, 1, @ScopeStartIso) WITH NOWAIT;
        END;

        /* 3) Changed keys */
        IF OBJECT_ID('tempdb..#Changed') IS NOT NULL DROP TABLE #Changed;
        CREATE TABLE #Changed (ACT_REF int NOT NULL PRIMARY KEY);

        INSERT INTO #Changed(ACT_REF)
        SELECT DISTINCT ct.ACT_REF
        FROM CHANGETABLE(CHANGES dbo.ACTIVITY_HD, @LastSyncVersion) ct
        WHERE ct.SYS_CHANGE_VERSION <= @ToVersion;

        DECLARE @ToProcess int = (SELECT COUNT(*) FROM #Changed);
        IF @EmitInfo=1 RAISERROR('Visits CT keys to process: %d', 0, 1, @ToProcess) WITH NOWAIT;

        IF @ToProcess = 0
        BEGIN
            UPDATE dbo.CT_Watermark
              SET LastSyncVersion=@ToVersion, LastSyncTime=SYSUTCDATETIME()
            WHERE ProcessName=@Process;

            SET @EndUTC      = SYSUTCDATETIME();
            SET @EndIso      = CONVERT(varchar(33), @EndUTC, 126);
            SET @DurationSec = DATEDIFF(SECOND, @RunStartedAt, @EndUTC);

            SET @Summary = CONCAT(
                N'Visits incremental started ', @StartIso, N' UTC; ended ', @EndIso,
                N' UTC; inserted 0, updated 0, deleted 0, agedout 0; advanced watermark to ',
                CAST(@ToVersion AS nvarchar(30)), N'; duration=', @DurationSec, N' sec.'
            );

            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            GOTO FinallyRelease;
        END

        /* temp tables reused */
        IF OBJECT_ID('tempdb..#NextKeys') IS NOT NULL DROP TABLE #NextKeys;
        CREATE TABLE #NextKeys (ACT_REF int NOT NULL PRIMARY KEY);

        IF OBJECT_ID('tempdb..#ActLog') IS NOT NULL DROP TABLE #ActLog;
        CREATE TABLE #ActLog(Action nvarchar(10) NOT NULL);

        DECLARE @TotalInserted bigint = 0,
                @TotalUpdated  bigint = 0,
                @TotalDeleted  bigint = 0,
                @TotalAgedOut  bigint = 0;

        /* 4) Chunked upsert */
        WHILE EXISTS (SELECT 1 FROM #Changed)
        BEGIN
            TRUNCATE TABLE #NextKeys;

            INSERT INTO #NextKeys(ACT_REF)
            SELECT TOP (@ChunkSize) ACT_REF
            FROM #Changed
            ORDER BY ACT_REF;

            TRUNCATE TABLE #ActLog;

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
                JOIN #NextKeys       AS NK   ON NK.ACT_REF = AHD.ACT_REF
                LEFT JOIN dbo.CAREPLAN_DT  AS CPDT ON AHD.CPLAN_DET_REF = CPDT.CPLAN_DET_REF
                LEFT JOIN dbo.CONTRACT_DT  AS CDT  ON AHD.CONT_DET_REF  = CDT.CONT_DET_REF
                LEFT JOIN dbo.CONTRACT_HD  AS CHD  ON CDT.CONTRACT_REF  = CHD.CONTRACT_REF
                LEFT JOIN dbo.SERVICE_HD   AS SHD  ON AHD.SERVICE_REF   = SHD.SERVICE_REF
                JOIN dbo.tbl_Clients       AS C    ON C.UUID            = AHD.CLIENT_REF
                WHERE AHD.[TYPE] <> 1
                  AND AHD.START_DTM >= @ScopeStart
            )
            MERGE dbo.tbl_Visits AS tgt
            USING VisitsBase AS src
              ON tgt.UUID = src.UUID
            WHEN MATCHED THEN
                UPDATE SET
                    tgt.Client_UUID                   = src.Client_UUID,
                    tgt.Employee_UUID                 = src.Employee_UUID,
                    tgt.Planned_Employee_UUID         = src.Planned_Employee_UUID,
                    tgt.Careplan_UUID                 = src.Careplan_UUID,
                    tgt.Care_Group                    = src.Care_Group,
                    tgt.Branch_UUID                   = src.Branch_UUID,
                    tgt.Contract_UUID                 = src.Contract_UUID,
                    tgt.Linked_Visit_UUID             = src.Linked_Visit_UUID,
                    tgt.Planned_Duration              = src.Planned_Duration,
                    tgt.Planned_Visit_Start_Date_Time = src.Planned_Visit_Start_Date_Time,
                    tgt.Planned_Visit_End_Date_Time   = src.Planned_Visit_End_Date_Time,
                    tgt.Actual_Duration               = src.Actual_Duration,
                    tgt.Actual_Visit_Start_Date_Time  = src.Actual_Visit_Start_Date_Time,
                    tgt.Actual_Visit_End_Date_Time    = src.Actual_Visit_End_Date_Time,
                    tgt.Visit_Code                    = src.Visit_Code,
                    tgt.Visit_Origin                  = src.Visit_Origin,
                    tgt.Visit_Invoice_Status          = src.Visit_Invoice_Status,
                    tgt.Visit_Pay_Status              = src.Visit_Pay_Status,
                    tgt.Cancel_Pay_Flag               = src.Cancel_Pay_Flag,
                    tgt.UpdatedAtUTC                  = @RunStartedAt
            WHEN NOT MATCHED BY TARGET THEN
                INSERT
                (
                    UUID, Client_UUID, Employee_UUID, Planned_Employee_UUID,
                    Careplan_UUID, Care_Group, Branch_UUID, Contract_UUID,
                    Linked_Visit_UUID, Planned_Duration,
                    Planned_Visit_Start_Date_Time, Planned_Visit_End_Date_Time,
                    Actual_Duration, Actual_Visit_Start_Date_Time, Actual_Visit_End_Date_Time,
                    Visit_Code, Visit_Origin, Visit_Invoice_Status, Visit_Pay_Status,
                    Cancel_Pay_Flag, CreatedAtUTC, UpdatedAtUTC
                )
                VALUES
                (
                    src.UUID, src.Client_UUID, src.Employee_UUID, src.Planned_Employee_UUID,
                    src.Careplan_UUID, src.Care_Group, src.Branch_UUID, src.Contract_UUID,
                    src.Linked_Visit_UUID, src.Planned_Duration,
                    src.Planned_Visit_Start_Date_Time, src.Planned_Visit_End_Date_Time,
                    src.Actual_Duration, src.Actual_Visit_Start_Date_Time, src.Actual_Visit_End_Date_Time,
                    src.Visit_Code, src.Visit_Origin, src.Visit_Invoice_Status, src.Visit_Pay_Status,
                    src.Cancel_Pay_Flag, @RunStartedAt, @RunStartedAt
                )
            OUTPUT $action INTO #ActLog(Action);

            DECLARE @i int=0, @u int=0;
            SELECT
                @i = SUM(CASE WHEN Action='INSERT' THEN 1 ELSE 0 END),
                @u = SUM(CASE WHEN Action='UPDATE' THEN 1 ELSE 0 END)
            FROM #ActLog;

            SET @TotalInserted += ISNULL(@i,0);
            SET @TotalUpdated  += ISNULL(@u,0);

            DELETE c
            FROM #Changed c
            JOIN #NextKeys n ON n.ACT_REF = c.ACT_REF;
        END

        /* 5) Hard deletes (CT op = D) */
        IF OBJECT_ID('tempdb..#DelLog') IS NOT NULL DROP TABLE #DelLog;
        CREATE TABLE #DelLog(UUID int NOT NULL);

        DELETE t
        OUTPUT DELETED.UUID INTO #DelLog(UUID)
        FROM dbo.tbl_Visits t
        JOIN
        (
            SELECT d.ACT_REF
            FROM CHANGETABLE(CHANGES dbo.ACTIVITY_HD, @LastSyncVersion) d
            WHERE d.SYS_CHANGE_OPERATION = 'D'
              AND d.SYS_CHANGE_VERSION   <= @ToVersion
        ) x
          ON x.ACT_REF = t.UUID;

        SET @TotalDeleted = (SELECT COUNT(*) FROM #DelLog);

        /* 6) Optional scope purge. Prefer the dedicated purge job. */
        IF @PurgeOldVisits = 1
        BEGIN
            /*
               Keep any opt-in retention purge in small autocommit batches.
               The normal daily runner leaves @PurgeOldVisits at 0 and uses
               dbo.usp_Purge_Visits_Expired on its own schedule.
            */
            DECLARE @PurgeBatchDeleted int = 1;
            DECLARE @PurgeBatchSize    int = 10000;

            WHILE @PurgeBatchDeleted > 0
            BEGIN
                DELETE TOP (@PurgeBatchSize)
                FROM dbo.tbl_Visits
                WHERE Actual_Visit_Start_Date_Time < @ScopeStart;

                SET @PurgeBatchDeleted = @@ROWCOUNT;
                SET @TotalAgedOut += @PurgeBatchDeleted;

                IF @EmitInfo = 1 AND @PurgeBatchDeleted > 0
                    RAISERROR('Visits age purge batch: deleted=%d (running total=%I64d)',
                              0, 1, @PurgeBatchDeleted, @TotalAgedOut) WITH NOWAIT;
            END;
        END;

        /* 7) Watermark + summary */
        UPDATE dbo.CT_Watermark
          SET LastSyncVersion=@ToVersion, LastSyncTime=SYSUTCDATETIME()
        WHERE ProcessName=@Process;

        SET @EndUTC      = SYSUTCDATETIME();
        SET @EndIso      = CONVERT(varchar(33), @EndUTC, 126);
        SET @DurationSec = DATEDIFF(SECOND, @RunStartedAt, @EndUTC);

        SET @Summary = CONCAT(
            N'Visits incremental started ', @StartIso, N' UTC; ended ', @EndIso,
            N' UTC; inserted ', CAST(@TotalInserted AS nvarchar(20)),
            N', updated ', CAST(@TotalUpdated AS nvarchar(20)),
            N', deleted ', CAST(@TotalDeleted AS nvarchar(20)),
            N', agedout ', CAST(@TotalAgedOut AS nvarchar(20)),
            N'; advanced watermark to ', CAST(@ToVersion AS nvarchar(30)),
            N'; duration=', CAST(@DurationSec AS nvarchar(20)), N' sec.'
        );

        IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;

FinallyRelease:
        IF @lockHeld=1
            EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;

        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK;

        IF @lockHeld=1
            EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;

        DECLARE @msg nvarchar(4000)=ERROR_MESSAGE();
        SET @Summary = CONCAT(N'Visits incremental failed: ', @msg);
        IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
        RETURN -50001;
    END CATCH
END
GO
