USE [DOM_LIVE];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

/* ============================================================
   File: Branch_Incremental.sql
   Proc: dbo.usp_Sync_Branch_Incremental

   Refactor goals (match NEW Branch_Initial):
     - Same CT fencing + watermark discipline
     - Same mapping logic + Portsmouth synthetic row
     - Consistent applock pattern + clean release
     - Optional auto-initial (off by default)
     - Chunked, deterministic upsert + explicit delete pass
     - SQL 2016-safe streaming messages via RAISERROR(...,10,1) WITH NOWAIT
     - Single Summary output and single-row result (SELECT [Summary]=@Summary)
     - No variable name collisions (case-insensitive)
   ============================================================ */

ALTER PROCEDURE [dbo].[usp_Sync_Branch_Incremental]
    @ChunkSize      int  = 50000,
    @LockTimeoutMs  int  = 60000,
    @UseAppLock     bit  = 1,
    @EmitProgress   bit  = 0,
    @AutoInitial    bit  = 0, -- 0=fail if baseline missing/stale, 1=run Initial automatically
    @Summary        nvarchar(4000) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* ---------- Run context ---------- */
    DECLARE @Process        sysname      = N'Branch';
    DECLARE @RunStartedAt   datetime2(3) = SYSUTCDATETIME();
    DECLARE @StartIso       varchar(33)  = CONVERT(varchar(33), @RunStartedAt, 126);
    DECLARE @EndUTC         datetime2(3);
    DECLARE @EndIso         varchar(33);
    DECLARE @DurationSec    int;

    DECLARE @Msg            nvarchar(2047);

    /* ---------- Concurrency ---------- */
    DECLARE @LockResource sysname = N'DOM_LIVE:Sync:Branch';
    DECLARE @LockOwner    sysname = N'Session';
    DECLARE @DbPrincipal  sysname = N'dbo';
    DECLARE @lockResult   int;
    DECLARE @lockHeld     bit = 0;

    IF @UseAppLock = 1
    BEGIN
        EXEC @lockResult = sys.sp_getapplock
            @Resource    = @LockResource,
            @LockMode    = 'Exclusive',
            @LockOwner   = @LockOwner,
            @DbPrincipal = @DbPrincipal,
            @LockTimeout = @LockTimeoutMs;

        IF @lockResult NOT IN (0,1)
        BEGIN
            SET @Summary = N'Branch incremental failed: could not acquire applock.';
            SELECT [Summary] = @Summary;
            RETURN -1;
        END;

        SET @lockHeld = 1;
    END;

    BEGIN TRY
        /* ============================================================
           1) Preconditions
           ============================================================ */
        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_databases WHERE database_id = DB_ID())
            RAISERROR('Change Tracking is not enabled at the database level.', 16, 1);

        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.GLOB_SITE'))
            RAISERROR('Change Tracking is not enabled on dbo.GLOB_SITE.', 16, 1);

        /* ============================================================
           2) Ensure baseline exists (or auto-run Initial)
           ============================================================ */
        DECLARE @NeedInitial bit = 0;

        IF OBJECT_ID(N'dbo.tbl_Branch', N'U') IS NULL
            SET @NeedInitial = 1;

        IF @NeedInitial = 0
        BEGIN
            IF OBJECT_ID(N'dbo.CT_Watermark', N'U') IS NULL
                SET @NeedInitial = 1;
            ELSE IF NOT EXISTS (SELECT 1 FROM dbo.CT_Watermark WHERE ProcessName = @Process)
                SET @NeedInitial = 1;
        END

        IF @NeedInitial = 1
        BEGIN
            IF @AutoInitial = 1 AND OBJECT_ID(N'dbo.usp_Sync_Branch_Initial', N'P') IS NOT NULL
            BEGIN
                IF @EmitProgress=1
                    RAISERROR(N'Auto-running Branch initial (table/watermark missing).', 10, 1) WITH NOWAIT;

                EXEC dbo.usp_Sync_Branch_Initial;
            END
            ELSE
            BEGIN
                RAISERROR('Branch baseline missing. Run dbo.usp_Sync_Branch_Initial first (or set @AutoInitial=1).', 16, 1);
            END
        END

        /* ============================================================
           3) Read watermark and validate CT retention
           ============================================================ */
        IF OBJECT_ID(N'dbo.CT_Watermark', N'U') IS NULL
            RAISERROR('CT_Watermark missing. Run Branch initial first.', 16, 1);

        IF NOT EXISTS (SELECT 1 FROM dbo.CT_Watermark WHERE ProcessName=@Process)
            RAISERROR('CT watermark row missing for Branch. Run Branch initial first.', 16, 1);

        DECLARE @LastSyncVersion bigint;

        SELECT @LastSyncVersion = LastSyncVersion
        FROM dbo.CT_Watermark WITH (HOLDLOCK, UPDLOCK)
        WHERE ProcessName = @Process;

        DECLARE @MinValid bigint = CHANGE_TRACKING_MIN_VALID_VERSION(OBJECT_ID(N'dbo.GLOB_SITE'));

        IF @MinValid IS NOT NULL AND @LastSyncVersion < @MinValid
        BEGIN
            IF @AutoInitial = 1 AND OBJECT_ID(N'dbo.usp_Sync_Branch_Initial', N'P') IS NOT NULL
            BEGIN
                IF @EmitProgress=1
                    RAISERROR(N'Auto-running Branch initial (watermark stale vs CT min valid).', 10, 1) WITH NOWAIT;

                EXEC dbo.usp_Sync_Branch_Initial;

                SELECT @LastSyncVersion = LastSyncVersion
                FROM dbo.CT_Watermark WITH (HOLDLOCK, UPDLOCK)
                WHERE ProcessName = @Process;
            END
            ELSE
            BEGIN
                RAISERROR('Branch watermark (%I64d) < CT min valid (%I64d). Re-baseline required.', 16, 1, @LastSyncVersion, @MinValid);
            END
        END

        /* Fence CT window at START */
        DECLARE @ToVersion bigint = CHANGE_TRACKING_CURRENT_VERSION();

        IF @EmitProgress=1
        BEGIN
            SET @Msg = CONCAT(N'Branch CT window: From=', @LastSyncVersion, N' To=', @ToVersion);
            RAISERROR(@Msg, 10, 1) WITH NOWAIT;
        END

        /* ============================================================
           4) Detect changed keys (GS_REF -> Old_Branch_UUID)
           ============================================================ */
        IF OBJECT_ID('tempdb..#Changed') IS NOT NULL DROP TABLE #Changed;
        CREATE TABLE #Changed (Old_Branch_UUID int NOT NULL PRIMARY KEY);

        INSERT INTO #Changed(Old_Branch_UUID)
        SELECT DISTINCT TRY_CONVERT(int, ct.GS_REF)
        FROM CHANGETABLE(CHANGES dbo.GLOB_SITE, @LastSyncVersion) ct
        WHERE ct.SYS_CHANGE_VERSION <= @ToVersion
          AND TRY_CONVERT(int, ct.GS_REF) IS NOT NULL;

        DECLARE @ToProcess int = (SELECT COUNT(*) FROM #Changed);

        IF @EmitProgress=1
        BEGIN
            SET @Msg = CONCAT(N'Branches to process: ', @ToProcess);
            RAISERROR(@Msg, 10, 1) WITH NOWAIT;
        END

        /* ============================================================
           5) No-op fast path
           ============================================================ */
        IF @ToProcess = 0
        BEGIN
            UPDATE dbo.CT_Watermark
              SET LastSyncVersion=@ToVersion, LastSyncTime=SYSUTCDATETIME()
            WHERE ProcessName=@Process;

            SET @EndUTC = SYSUTCDATETIME();
            SET @EndIso = CONVERT(varchar(33), @EndUTC, 126);
            SET @DurationSec = DATEDIFF(SECOND, @RunStartedAt, @EndUTC);

            SET @Summary = CONCAT(
                N'Branch incremental started ', @StartIso, N' UTC; ended ', @EndIso,
                N' UTC; inserted 0, updated 0, deleted 0; advanced watermark to ',
                CAST(@ToVersion AS nvarchar(30)), N'; duration=', @DurationSec, N' sec.'
            );

            SELECT [Summary] = @Summary;

            IF @lockHeld=1
                EXEC sys.sp_releaseapplock @Resource=@LockResource,@LockOwner=@LockOwner,@DbPrincipal=@DbPrincipal;

            RETURN 0;
        END

        /* ============================================================
           6) Chunked MERGE upsert (same mapping as Initial)
           ============================================================ */
        DECLARE @TotalInserted int = 0;
        DECLARE @TotalUpdated  int = 0;

        WHILE EXISTS (SELECT 1 FROM #Changed)
        BEGIN
            IF OBJECT_ID('tempdb..#Next') IS NOT NULL DROP TABLE #Next;
            CREATE TABLE #Next (Old_Branch_UUID int NOT NULL PRIMARY KEY);

            INSERT INTO #Next(Old_Branch_UUID)
            SELECT TOP (@ChunkSize) Old_Branch_UUID
            FROM #Changed
            ORDER BY Old_Branch_UUID;

            IF OBJECT_ID('tempdb..#ActLog') IS NOT NULL DROP TABLE #ActLog;
            CREATE TABLE #ActLog (MergeAction nvarchar(10) NOT NULL);

            ;WITH Base AS
            (
                SELECT
                    Old_Branch_UUID = TRY_CONVERT(int, gs.GS_REF),

                    Branch_Name =
                        CASE
                            WHEN TRY_CONVERT(int, gs.GS_REF) = 1970000043 THEN N'Southampton'
                            WHEN TRY_CONVERT(int, gs.GS_REF) = 1970000069 THEN N'Old_Southampton'
                            ELSE LTRIM(RTRIM(gs.NAME))
                        END,

                    Brand  = NULLIF(CAST(LTRIM(RTRIM(gs.VATREG))   AS NVARCHAR(100)), N''),
                    Active = NULLIF(CAST(LTRIM(RTRIM(gs.NHS_DEPT)) AS NVARCHAR(20)),  N''),

                    Early_Pay_Rate = NULLIF(TRY_CONVERT(DECIMAL(10,2), ep.LowestBasicRate), 0)
                FROM dbo.GLOB_SITE gs
                JOIN #Next n
                  ON n.Old_Branch_UUID = TRY_CONVERT(int, gs.GS_REF)
                LEFT JOIN dbo.tbl_EarlyPayInitialRatesTable ep
                  ON ep.Branch =
                        CASE
                            WHEN TRY_CONVERT(int, gs.GS_REF) = 1970000043 THEN N'Southampton'
                            WHEN TRY_CONVERT(int, gs.GS_REF) = 1970000069 THEN N'Old_Southampton'
                            ELSE gs.NAME
                        END
            ),
            Expanded AS
            (
                SELECT * FROM Base

                UNION ALL
                SELECT
                    Old_Branch_UUID = 1970000043,
                    Branch_Name     = N'Portsmouth',
                    Brand           = (SELECT TOP (1) Brand          FROM Base WHERE Old_Branch_UUID = 1970000043),
                    Active          = (SELECT TOP (1) Active         FROM Base WHERE Old_Branch_UUID = 1970000043),
                    Early_Pay_Rate  = (SELECT TOP (1) Early_Pay_Rate FROM Base WHERE Old_Branch_UUID = 1970000043)
                WHERE EXISTS (SELECT 1 FROM Base WHERE Old_Branch_UUID = 1970000043)
            )
            MERGE dbo.tbl_Branch AS tgt
            USING
            (
                SELECT
                    Old_Branch_UUID,
                    Branch_Name,
                    Brand,
                    Active,
                    Early_Pay_Rate
                FROM Expanded
                WHERE Old_Branch_UUID IS NOT NULL
                  AND Branch_Name IS NOT NULL
            ) AS src
               ON  tgt.Old_Branch_UUID = src.Old_Branch_UUID
               AND tgt.Branch_Name     = src.Branch_Name
            WHEN MATCHED THEN
                UPDATE SET
                    tgt.Brand          = src.Brand,
                    tgt.Active         = src.Active,
                    tgt.Early_Pay_Rate = src.Early_Pay_Rate,
                    tgt.UpdatedAtUTC   = @RunStartedAt
            WHEN NOT MATCHED BY TARGET THEN
                INSERT
                (
                    Old_Branch_UUID,
                    Branch_Name,
                    Brand,
                    Active,
                    Early_Pay_Rate,
                    CreatedAtUTC,
                    UpdatedAtUTC
                )
                VALUES
                (
                    src.Old_Branch_UUID,
                    src.Branch_Name,
                    src.Brand,
                    src.Active,
                    src.Early_Pay_Rate,
                    @RunStartedAt,
                    @RunStartedAt
                )
            OUTPUT $action AS MergeAction INTO #ActLog(MergeAction);

            DECLARE @i int=0, @u int=0;
            SELECT
                @i = SUM(CASE WHEN MergeAction='INSERT' THEN 1 ELSE 0 END),
                @u = SUM(CASE WHEN MergeAction='UPDATE' THEN 1 ELSE 0 END)
            FROM #ActLog;

            SET @TotalInserted += ISNULL(@i,0);
            SET @TotalUpdated  += ISNULL(@u,0);

            IF @EmitProgress=1
            BEGIN
                SET @Msg = CONCAT(
                    N'Branch chunk: inserted=', @i,
                    N' updated=', @u,
                    N' (running ', @TotalInserted, N'/', @TotalUpdated, N')'
                );
                RAISERROR(@Msg, 10, 1) WITH NOWAIT;
            END

            DELETE c
            FROM #Changed c
            JOIN #Next n ON n.Old_Branch_UUID = c.Old_Branch_UUID;
        END

        /* ============================================================
           7) Deletions (rows deleted in GLOB_SITE since last sync)
              - This may delete multiple target rows per GS_REF (e.g. Portsmouth+Southampton)
           ============================================================ */
        DECLARE @DeletedThisRun int = 0;

        IF OBJECT_ID('tempdb..#DelLog') IS NOT NULL DROP TABLE #DelLog;
        CREATE TABLE #DelLog(UUID int NOT NULL);

        DELETE t
        OUTPUT DELETED.UUID INTO #DelLog(UUID)
        FROM dbo.tbl_Branch t
        JOIN
        (
            SELECT TRY_CONVERT(int, d.GS_REF) AS Old_Branch_UUID
            FROM CHANGETABLE(CHANGES dbo.GLOB_SITE, @LastSyncVersion) d
            WHERE d.SYS_CHANGE_OPERATION='D'
              AND d.SYS_CHANGE_VERSION<=@ToVersion
              AND TRY_CONVERT(int, d.GS_REF) IS NOT NULL
        ) x
          ON t.Old_Branch_UUID = x.Old_Branch_UUID;

        SET @DeletedThisRun = (SELECT COUNT(*) FROM #DelLog);

        /* ============================================================
           8) Advance watermark + summary
           ============================================================ */
        UPDATE dbo.CT_Watermark
          SET LastSyncVersion=@ToVersion, LastSyncTime=SYSUTCDATETIME()
        WHERE ProcessName=@Process;

        SET @EndUTC = SYSUTCDATETIME();
        SET @EndIso = CONVERT(varchar(33), @EndUTC, 126);
        SET @DurationSec = DATEDIFF(SECOND, @RunStartedAt, @EndUTC);

        SET @Summary = CONCAT(
            N'Branch incremental started ', @StartIso, N' UTC; ended ', @EndIso,
            N' UTC; inserted ', @TotalInserted, N', updated ', @TotalUpdated,
            N', deleted ', @DeletedThisRun, N'; advanced watermark to ',
            CAST(@ToVersion AS nvarchar(30)), N'; duration=', @DurationSec, N' sec.'
        );

        SELECT [Summary] = @Summary;

        IF @lockHeld=1
            EXEC sys.sp_releaseapplock @Resource=@LockResource,@LockOwner=@LockOwner,@DbPrincipal=@DbPrincipal;

        RETURN 0;
    END TRY
    BEGIN CATCH
        IF @lockHeld=1
            EXEC sys.sp_releaseapplock @Resource=@LockResource,@LockOwner=@LockOwner,@DbPrincipal=@DbPrincipal;

        DECLARE @ErrMsg nvarchar(4000) = ERROR_MESSAGE();

        SET @Summary = CONCAT(N'Branch incremental failed: ', @ErrMsg);
        SELECT [Summary] = @Summary;

        RETURN -50001;
    END CATCH
END;
GO
