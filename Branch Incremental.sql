USE [DOM_LIVE];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE [dbo].[usp_Sync_Branch_Incremental]
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
        -- 1) Preconditions / auto-initial
        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_databases WHERE database_id = DB_ID())
        BEGIN
            SET @Summary = N'Incremental failed: Change Tracking is not enabled at DB level.';
            SELECT [Summary] = @Summary;
            IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource,@LockOwner=@LockOwner,@DbPrincipal=@DbPrincipal;
            RETURN -100;
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

        -- 2) Ensure watermark row and read it
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

        -- 3) Detect changed GLOB_SITE rows
        IF OBJECT_ID('tempdb..#Changed') IS NOT NULL DROP TABLE #Changed;
        CREATE TABLE #Changed (GS_REF varchar(20) NOT NULL PRIMARY KEY);

        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.GLOB_SITE'))
        BEGIN
            SET @Summary = N'Incremental failed: CT not enabled on dbo.GLOB_SITE.';
            SELECT [Summary] = @Summary;
            IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource,@LockOwner=@LockOwner,@DbPrincipal=@DbPrincipal;
            RETURN -210;
        END;

        INSERT INTO #Changed(GS_REF)
        SELECT DISTINCT CAST(ct.GS_REF AS varchar(20))
        FROM CHANGETABLE(CHANGES dbo.GLOB_SITE, @LastSyncVersion) ct
        WHERE ct.SYS_CHANGE_VERSION <= @ToVersion;

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

        -- 4) Chunked upsert into tbl_Branch (schema aligned with Initial)
        DECLARE @TotalInserted int=0, @TotalUpdated int=0;

        WHILE EXISTS (SELECT 1 FROM #Changed)
        BEGIN
            IF OBJECT_ID('tempdb..#Next') IS NOT NULL DROP TABLE #Next;
            CREATE TABLE #Next (GS_REF varchar(20) NOT NULL PRIMARY KEY);

            INSERT INTO #Next(GS_REF)
            SELECT TOP (@ChunkSize) GS_REF FROM #Changed ORDER BY GS_REF;

            IF OBJECT_ID('tempdb..#ActLog') IS NOT NULL DROP TABLE #ActLog;
            CREATE TABLE #ActLog(Action nvarchar(10) NOT NULL);

            ;WITH Base AS
            (
                SELECT
                    UUID = CAST(LOWER(master.dbo.fn_varbintohexstr(HASHBYTES('SHA1',
                                CASE WHEN gs.GS_REF='1970000043' THEN N'Southampton'
                                     WHEN gs.GS_REF='1970000069' THEN N'Old_Southampton'
                                     ELSE gs.NAME END))) AS VARCHAR(42)),
                    Branch_Name     = CASE WHEN gs.GS_REF='1970000043' THEN N'Southampton'
                                           WHEN gs.GS_REF='1970000069' THEN N'Old_Southampton'
                                           ELSE LTRIM(RTRIM(gs.NAME)) END,
                    Brand           = CAST(LTRIM(RTRIM(gs.VATREG))   AS NVARCHAR(100)),
                    Active          = CAST(LTRIM(RTRIM(gs.NHS_DEPT)) AS NVARCHAR(20)),
                    Early_Pay_Rate  = CAST(LTRIM(RTRIM(ep.LowestBasicRate)) AS DECIMAL(10,2)),
                    Old_Branch_UUID = CAST(LTRIM(RTRIM(gs.GS_REF))   AS VARCHAR(20))
                FROM dbo.GLOB_SITE gs
                JOIN #Next n ON n.GS_REF = gs.GS_REF
                LEFT JOIN dbo.tbl_EarlyPayInitialRatesTable ep ON ep.Branch = (
                    CASE WHEN gs.GS_REF='1970000043' THEN N'Southampton'
                         WHEN gs.GS_REF='1970000069' THEN N'Old_Southampton'
                         ELSE gs.NAME END
                )
            )
            MERGE dbo.tbl_Branch AS tgt
            USING Base AS src
               ON tgt.UUID = src.UUID
            WHEN MATCHED THEN
                UPDATE SET
                    tgt.Branch_Name     = src.Branch_Name,
                    tgt.Brand           = src.Brand,
                    tgt.Active          = src.Active,
                    tgt.Early_Pay_Rate  = src.Early_Pay_Rate,
                    tgt.Old_Branch_UUID = src.Old_Branch_UUID,
                    tgt.UpdatedAtUTC    = @RunStartedAt
            WHEN NOT MATCHED BY TARGET THEN
                INSERT (UUID, Branch_Name, Brand, Active, Early_Pay_Rate, Old_Branch_UUID, CreatedAtUTC, UpdatedAtUTC)
                VALUES (src.UUID, src.Branch_Name, src.Brand, src.Active, src.Early_Pay_Rate, src.Old_Branch_UUID, @RunStartedAt, @RunStartedAt)
            OUTPUT $action INTO #ActLog(Action);

            DECLARE @i int=0,@u int=0;
            SELECT @i=SUM(CASE WHEN Action='INSERT' THEN 1 ELSE 0 END),
                   @u=SUM(CASE WHEN Action='UPDATE' THEN 1 ELSE 0 END)
            FROM #ActLog;

            SET @TotalInserted+=ISNULL(@i,0);
            SET @TotalUpdated+=ISNULL(@u,0);

            DELETE c
            FROM #Changed c
            JOIN #Next n ON n.GS_REF = c.GS_REF;
        END;

        -- 5) Deletions (rows deleted in GLOB_SITE since last sync)
        DECLARE @TotalDeleted int=0;
        IF OBJECT_ID('tempdb..#DelLog') IS NOT NULL DROP TABLE #DelLog;
        CREATE TABLE #DelLog(UUID varchar(42) NOT NULL);

        DELETE t
        OUTPUT DELETED.UUID INTO #DelLog(UUID)
        FROM dbo.tbl_Branch t
        JOIN (
            SELECT CAST(LTRIM(RTRIM(d.GS_REF)) AS VARCHAR(20)) AS GS_REF
            FROM CHANGETABLE(CHANGES dbo.GLOB_SITE, @LastSyncVersion) d
            WHERE d.SYS_CHANGE_OPERATION='D'
              AND d.SYS_CHANGE_VERSION<=@ToVersion
        ) x ON t.Old_Branch_UUID = x.GS_REF;

        SET @TotalDeleted = (SELECT COUNT(*) FROM #DelLog);

        -- 6) Advance watermark + summary
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
