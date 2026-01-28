USE [DOM_LIVE];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

ALTER PROCEDURE [dbo].[usp_Sync_Branch_Incremental]
    @ChunkSize      int  = 50000,
    @LockTimeoutMs  int  = 60000,
    @UseAppLock     bit  = 1,
    @Summary        nvarchar(4000) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Process        sysname      = N'Branch';
    DECLARE @RunStartedAt   datetime2(3) = SYSUTCDATETIME();
    DECLARE @StartIso       varchar(33)  = CONVERT(varchar(33), @RunStartedAt, 126);
    DECLARE @EndUTC         datetime2(3);
    DECLARE @EndIso         varchar(33);
    DECLARE @DurationSec    int;

    -- 0) Concurrency guard
    DECLARE @LockResource sysname = N'DOM_LIVE:Sync:Branch';
    DECLARE @LockOwner   sysname = N'Session';
    DECLARE @DbPrincipal sysname = N'dbo';
    DECLARE @lockResult  int;
    DECLARE @lockHeld    bit = 0;

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
            SET @Summary = N'Incremental failed: could not acquire applock.';
            SELECT [Summary] = @Summary;
            RETURN @lockResult;
        END;

        SET @lockHeld = 1;
    END;

    BEGIN TRY
        /* 1) Preconditions / auto-initial */
        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_databases WHERE database_id = DB_ID())
        BEGIN
            SET @Summary = N'Incremental failed: Change Tracking is not enabled at DB level.';
            SELECT [Summary] = @Summary;
            IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource,@LockOwner=@LockOwner,@DbPrincipal=@DbPrincipal;
            RETURN -100;
        END;

        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.GLOB_SITE'))
        BEGIN
            SET @Summary = N'Incremental failed: CT not enabled on dbo.GLOB_SITE.';
            SELECT [Summary] = @Summary;
            IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource,@LockOwner=@LockOwner,@DbPrincipal=@DbPrincipal;
            RETURN -210;
        END;

        DECLARE @NeedsInitial bit = 0;
        DECLARE @LastSyncVersion bigint = NULL;

        IF OBJECT_ID('dbo.tbl_Branch','U') IS NULL SET @NeedsInitial = 1;

        IF @NeedsInitial = 0
        BEGIN
            IF OBJECT_ID('dbo.CT_Watermark','U') IS NULL
                SET @NeedsInitial = 1;
            ELSE IF NOT EXISTS (SELECT 1 FROM dbo.CT_Watermark WHERE ProcessName=@Process)
                SET @NeedsInitial = 1;
            ELSE
            BEGIN
                SELECT @LastSyncVersion = LastSyncVersion
                FROM dbo.CT_Watermark WITH (UPDLOCK, HOLDLOCK)
                WHERE ProcessName=@Process;

                DECLARE @MinValid bigint = CHANGE_TRACKING_MIN_VALID_VERSION(OBJECT_ID(N'dbo.GLOB_SITE'));
                IF @MinValid IS NOT NULL AND @LastSyncVersion < @MinValid
                    SET @NeedsInitial = 1;
            END
        END

        IF @NeedsInitial = 1
        BEGIN
            RAISERROR('Auto-running Branch initial (table/watermark missing or stale).',0,1) WITH NOWAIT;
            EXEC dbo.usp_Sync_Branch_Initial;

            SELECT @LastSyncVersion = LastSyncVersion
            FROM dbo.CT_Watermark
            WHERE ProcessName=@Process;
        END

        /* 2) Ensure watermark row and read it */
        IF OBJECT_ID('dbo.CT_Watermark','U') IS NULL
        BEGIN
            CREATE TABLE dbo.CT_Watermark
            (
              ProcessName     sysname      PRIMARY KEY,
              LastSyncVersion bigint       NOT NULL,
              LastSyncTime    datetime2(3) NOT NULL DEFAULT SYSUTCDATETIME()
            );

            INSERT INTO dbo.CT_Watermark(ProcessName, LastSyncVersion) VALUES (@Process, 0);
            SELECT @LastSyncVersion = 0;
        END
        ELSE IF @LastSyncVersion IS NULL
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM dbo.CT_Watermark WHERE ProcessName=@Process)
                INSERT INTO dbo.CT_Watermark(ProcessName, LastSyncVersion) VALUES (@Process, 0);

            SELECT @LastSyncVersion = LastSyncVersion
            FROM dbo.CT_Watermark WITH (UPDLOCK, HOLDLOCK)
            WHERE ProcessName=@Process;
        END

        DECLARE @ToVersion bigint = CHANGE_TRACKING_CURRENT_VERSION();

        /* 3) Detect changed GLOB_SITE rows */
        IF OBJECT_ID('tempdb..#Changed') IS NOT NULL DROP TABLE #Changed;
        CREATE TABLE #Changed
        (
            Old_Branch_UUID int NOT NULL PRIMARY KEY
        );

        INSERT INTO #Changed(Old_Branch_UUID)
        SELECT DISTINCT TRY_CONVERT(int, ct.GS_REF)
        FROM CHANGETABLE(CHANGES dbo.GLOB_SITE, @LastSyncVersion) ct
        WHERE ct.SYS_CHANGE_VERSION <= @ToVersion
          AND TRY_CONVERT(int, ct.GS_REF) IS NOT NULL;

        DECLARE @ToProcess int = (SELECT COUNT(*) FROM #Changed);
        RAISERROR('Branches to process: %d', 0, 1, @ToProcess) WITH NOWAIT;

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

            IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource,@LockOwner=@LockOwner,@DbPrincipal=@DbPrincipal;
            RETURN 0;
        END;

        /* 4) Chunked upsert into tbl_Branch (MATCHES INITIAL SCHEMA) */
        DECLARE @TotalInserted int=0, @TotalUpdated int=0;

        WHILE EXISTS (SELECT 1 FROM #Changed)
        BEGIN
            IF OBJECT_ID('tempdb..#Next') IS NOT NULL DROP TABLE #Next;
            CREATE TABLE #Next (Old_Branch_UUID int NOT NULL PRIMARY KEY);

            INSERT INTO #Next(Old_Branch_UUID)
            SELECT TOP (@ChunkSize) Old_Branch_UUID
            FROM #Changed
            ORDER BY Old_Branch_UUID;

            IF OBJECT_ID('tempdb..#ActLog') IS NOT NULL DROP TABLE #ActLog;
            CREATE TABLE #ActLog(Action nvarchar(10) NOT NULL);

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
            OUTPUT $action INTO #ActLog(Action);

            DECLARE @i int=0,@u int=0;
            SELECT
                @i = SUM(CASE WHEN Action='INSERT' THEN 1 ELSE 0 END),
                @u = SUM(CASE WHEN Action='UPDATE' THEN 1 ELSE 0 END)
            FROM #ActLog;

            SET @TotalInserted += ISNULL(@i,0);
            SET @TotalUpdated  += ISNULL(@u,0);

            DELETE c
            FROM #Changed c
            JOIN #Next n ON n.Old_Branch_UUID = c.Old_Branch_UUID;
        END;

        /* 5) Deletions (rows deleted in GLOB_SITE since last sync) */
        DECLARE @TotalDeleted int=0;

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

        SET @TotalDeleted = (SELECT COUNT(*) FROM #DelLog);

        /* 6) Advance watermark + summary */
        UPDATE dbo.CT_Watermark
          SET LastSyncVersion=@ToVersion, LastSyncTime=SYSUTCDATETIME()
        WHERE ProcessName=@Process;

        RAISERROR('Branch sync complete. Inserted=%d Updated=%d Deleted=%d',0,1,@TotalInserted,@TotalUpdated,@TotalDeleted) WITH NOWAIT;

        SET @EndUTC = SYSUTCDATETIME();
        SET @EndIso = CONVERT(varchar(33), @EndUTC, 126);
        SET @DurationSec = DATEDIFF(SECOND, @RunStartedAt, @EndUTC);

        SET @Summary = CONCAT(
            N'Branch incremental started ', @StartIso, N' UTC; ended ', @EndIso,
            N' UTC; inserted ', @TotalInserted, N', updated ', @TotalUpdated,
            N', deleted ', @TotalDeleted, N'; advanced watermark to ',
            CAST(@ToVersion AS nvarchar(30)), N'; duration=', @DurationSec, N' sec.'
        );
        SELECT [Summary] = @Summary;

        IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource,@LockOwner=@LockOwner,@DbPrincipal=@DbPrincipal;
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource,@LockOwner=@LockOwner,@DbPrincipal=@DbPrincipal;

        DECLARE @msg nvarchar(4000)=ERROR_MESSAGE();
        SET @Summary = CONCAT(N'usp_Sync_Branch_Incremental failed: ', @msg);
        SELECT [Summary] = @Summary;

        RAISERROR('usp_Sync_Branch_Incremental failed: %s',16,1,@msg);
        RETURN -50001;
    END CATCH;
END;
GO
