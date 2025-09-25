USE [DOM_LIVE]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE dbo.usp_Sync_ClientAbsences_Incremental
    @ChunkSize         int  = 100000,               -- tune as needed
    @LockTimeoutMs     int  = 60000,
    @UseAppLock        bit  = 1,
    @EmitInfo          bit  = 0,                    -- 0 = quiet, 1 = print progress
    @Summary           nvarchar(4000) = NULL OUTPUT,
    @ReturnSummaryRow  bit  = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET ANSI_WARNINGS ON;

    DECLARE @Process       sysname      = N'ClientAbsences';
    DECLARE @RunStartedAt  datetime2(3) = SYSUTCDATETIME();
    DECLARE @StartIso      varchar(33)  = CONVERT(varchar(33), @RunStartedAt, 126);
    DECLARE @EndUTC        datetime2(3);
    DECLARE @EndIso        varchar(33);
    DECLARE @DurationSec   int;

    -- 0) Concurrency guard (aligned with Initial)
    DECLARE @LockResource sysname = N'DOM_LIVE:Sync:ClientAbsences';
    DECLARE @LockOwner    sysname = N'Session';
    DECLARE @DbPrincipal  sysname = N'dbo';
    DECLARE @lockResult   int;
    DECLARE @lockHeld     bit = 0;

    IF @UseAppLock = 1
    BEGIN
        EXEC @lockResult = sys.sp_getapplock
            @Resource=@LockResource, @LockMode='Exclusive',
            @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal, @LockTimeout=@LockTimeoutMs;

        IF @lockResult NOT IN (0,1)
        BEGIN
            IF @EmitInfo=1 RAISERROR('Could not acquire %s (sp_getapplock rc=%d).',16,1,@LockResource,@lockResult);
            SET @Summary = N'ClientAbsences incremental failed: could not acquire applock.';
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            RETURN @lockResult;
        END
        SET @lockHeld = 1;
    END

    BEGIN TRY
        -- 1) Preconditions & bounds (consistent with Initial)
        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_databases WHERE database_id = DB_ID())
        BEGIN
            IF @EmitInfo=1 RAISERROR('Change Tracking is not enabled at the database level.', 16, 1);
            SET @Summary = N'ClientAbsences incremental failed: CT not enabled at DB level.';
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;
            RETURN -100;
        END

        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.INACTIVE_DY'))
        BEGIN
            IF @EmitInfo=1 RAISERROR('Change Tracking is not enabled on dbo.INACTIVE_DY. Cannot proceed.',16,1);
            SET @Summary = N'ClientAbsences incremental failed: CT not enabled on dbo.INACTIVE_DY.';
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;
            RETURN -210;
        END

        DECLARE @CT_CHSYSDEC bit =
            CASE WHEN EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.CHSYSDEC')) THEN 1 ELSE 0 END;

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

        -- Min valid version across referenced CT-enabled tables
        DECLARE @MinValid bigint =
        (
            SELECT MAX(CHANGE_TRACKING_MIN_VALID_VERSION(object_id))
            FROM sys.change_tracking_tables
            WHERE object_id IN (
                OBJECT_ID(N'dbo.INACTIVE_DY'),
                CASE WHEN @CT_CHSYSDEC=1 THEN OBJECT_ID(N'dbo.CHSYSDEC') ELSE NULL END
            )
        );

        IF @MinValid IS NOT NULL AND @LastSyncVersion < @MinValid
        BEGIN
            IF @EmitInfo=1 RAISERROR('Watermark (%I64d) is older than CT min valid version (%I64d). Re-baseline required.',16,1,@LastSyncVersion,@MinValid);
            SET @Summary = CONCAT(N'ClientAbsences incremental failed: watermark ', @LastSyncVersion, N' < min valid ', @MinValid, N' (re-baseline).');
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;
            RETURN -200;
        END

        DECLARE @ToVersion bigint = CHANGE_TRACKING_CURRENT_VERSION();

        IF @EmitInfo=1
        BEGIN
            RAISERROR('ClientAbsences CT incremental window:', 0, 1) WITH NOWAIT;
            RAISERROR('  From = %I64d', 0, 1, @LastSyncVersion) WITH NOWAIT;
            RAISERROR('  To   = %I64d', 0, 1, @ToVersion) WITH NOWAIT;
        END

        -- 2) Build changed key set
        IF OBJECT_ID('tempdb..#Changed') IS NOT NULL DROP TABLE #Changed;
        CREATE TABLE #Changed (InactiveReference nvarchar(55) NOT NULL PRIMARY KEY);

        -- INACTIVE_DY changes (I/U/D)
        INSERT INTO #Changed(InactiveReference)
        SELECT DISTINCT CAST(x.INACT_REF AS nvarchar(55))
        FROM CHANGETABLE(CHANGES dbo.INACTIVE_DY, @LastSyncVersion) x
        WHERE x.SYS_CHANGE_VERSION <= @ToVersion;

        -- Optional CHSYSDEC description changes
        IF @CT_CHSYSDEC = 1
        BEGIN
            INSERT INTO #Changed(InactiveReference)
            SELECT DISTINCT CAST(idy.INACT_REF AS nvarchar(55))
            FROM CHANGETABLE(CHANGES dbo.CHSYSDEC, @LastSyncVersion) d
            JOIN dbo.INACTIVE_DY idy ON idy.REASON = d.DECODE_REF
            WHERE d.SYS_CHANGE_VERSION <= @ToVersion
              AND NOT EXISTS (SELECT 1 FROM #Changed z WHERE z.InactiveReference = CAST(idy.INACT_REF AS nvarchar(55)));
        END
        ELSE
        BEGIN
            IF @EmitInfo=1 RAISERROR('Note: CT not enabled on CHSYSDEC; Absence_Reason text updates are not tracked.', 0, 1) WITH NOWAIT;
        END

        DECLARE @ToProcess int = (SELECT COUNT(*) FROM #Changed);
        IF @EmitInfo=1 RAISERROR('Inactive rows to process: %d', 0, 1, @ToProcess) WITH NOWAIT;

        IF @ToProcess = 0
        BEGIN
            UPDATE dbo.CT_Watermark
              SET LastSyncVersion=@ToVersion, LastSyncTime=SYSUTCDATETIME()
            WHERE ProcessName=@Process;

            SET @EndUTC = SYSUTCDATETIME();
            SET @EndIso = CONVERT(varchar(33), @EndUTC, 126);
            SET @DurationSec = DATEDIFF(SECOND, @RunStartedAt, @EndUTC);

            SET @Summary = CONCAT(
                N'ClientAbsences incremental started ', @StartIso, N' UTC; ended ', @EndIso,
                N' UTC; inserted 0, updated 0, deleted 0; advanced watermark to ',
                CAST(@ToVersion AS nvarchar(30)), N'; duration=', @DurationSec, N' sec.'
            );

            IF @EmitInfo=1 RAISERROR('No changes. Watermark advanced.', 0, 1) WITH NOWAIT;
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;

            IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;
            RETURN 0;
        END

        -- 3) Chunked MERGE into dbo.tbl_ClientAbsences (no NOLOCK; same filters as Initial)
        DECLARE @TotalInserted bigint = 0, @TotalUpdated bigint = 0, @TotalDeleted int = 0;

        WHILE EXISTS (SELECT 1 FROM #Changed)
        BEGIN
            IF OBJECT_ID('tempdb..#Next') IS NOT NULL DROP TABLE #Next;
            CREATE TABLE #Next (InactiveReference nvarchar(55) NOT NULL PRIMARY KEY);

            INSERT INTO #Next(InactiveReference)
            SELECT TOP (@ChunkSize) InactiveReference
            FROM #Changed
            ORDER BY InactiveReference;

            IF OBJECT_ID('tempdb..#ActLog') IS NOT NULL DROP TABLE #ActLog;
            CREATE TABLE #ActLog(Action nvarchar(10) NOT NULL);

            ;WITH Base AS
            (
                SELECT
                    UUID               = CAST(idy.INACT_REF AS nvarchar(55)),
                    Client_UUID        = CAST(idy.CLIENT_REF AS nvarchar(55)),
                    Absence_Reason     = cr.DESCRIPTION,
                    Absence_Start_Date = CAST(idy.START_DT AS date),
                    Absence_End_Date   = CAST(idy.END_DT   AS date)
                FROM dbo.INACTIVE_DY idy
                JOIN #Next n
                  ON n.InactiveReference = CAST(idy.INACT_REF AS nvarchar(55))
                LEFT JOIN dbo.CHSYSDEC cr
                  ON cr.DECODE_REF = idy.REASON
                WHERE idy.rectype NOT IN ('S','R','E')   -- aligned with Initial
            ),
            Shaped AS
            (
                SELECT
                    UUID,
                    Client_UUID,
                    Absence_Reason,
                    Absence_Start_Date,
                    Absence_End_Date
                FROM Base
            )
            MERGE dbo.tbl_ClientAbsences AS tgt
            USING Shaped AS src
               ON tgt.UUID = src.UUID
            WHEN MATCHED THEN
                UPDATE SET
                    tgt.Client_UUID        = src.Client_UUID,
                    tgt.Absence_Reason     = src.Absence_Reason,
                    tgt.Absence_Start_Date = src.Absence_Start_Date,
                    tgt.Absence_End_Date   = src.Absence_End_Date,
                    tgt.UpdatedAtUTC       = @RunStartedAt
            WHEN NOT MATCHED BY TARGET THEN
                INSERT (UUID, Client_UUID, Absence_Reason,
                        Absence_Start_Date, Absence_End_Date,
                        CreatedAtUTC, UpdatedAtUTC)
                VALUES (src.UUID, src.Client_UUID, src.Absence_Reason,
                        src.Absence_Start_Date, src.Absence_End_Date,
                        @RunStartedAt, @RunStartedAt)
            WHEN NOT MATCHED BY SOURCE
                 AND EXISTS (SELECT 1 FROM #Next nn WHERE nn.InactiveReference = tgt.UUID)
                 THEN DELETE
            OUTPUT $action INTO #ActLog(Action);

            DECLARE @i int = 0, @u int = 0, @d int = 0;
            SELECT
                @i = SUM(CASE WHEN Action='INSERT' THEN 1 ELSE 0 END),
                @u = SUM(CASE WHEN Action='UPDATE' THEN 1 ELSE 0 END),
                @d = SUM(CASE WHEN Action='DELETE' THEN 1 ELSE 0 END)
            FROM #ActLog;

            SET @TotalInserted += ISNULL(@i,0);
            SET @TotalUpdated  += ISNULL(@u,0);
            SET @TotalDeleted  += ISNULL(@d,0);

            IF @EmitInfo=1
                RAISERROR('ClientAbsences chunk: inserted=%d updated=%d deleted=%d (running %d/%d/%d)',
                          0,1,@i,@u,@d,@TotalInserted,@TotalUpdated,@TotalDeleted) WITH NOWAIT;

            DELETE c
            FROM #Changed c
            JOIN #Next n ON n.InactiveReference = c.InactiveReference;
        END

        -- 4) Advance watermark + summary (same style as Initial)
        UPDATE dbo.CT_Watermark
          SET LastSyncVersion=@ToVersion, LastSyncTime=SYSUTCDATETIME()
        WHERE ProcessName=@Process;

        SET @EndUTC = SYSUTCDATETIME();
        SET @EndIso = CONVERT(varchar(33), @EndUTC, 126);
        SET @DurationSec = DATEDIFF(SECOND, @RunStartedAt, @EndUTC);

        SET @Summary = CONCAT(
            N'ClientAbsences incremental started ', @StartIso, N' UTC; ended ', @EndIso,
            N' UTC; inserted ', CAST(@TotalInserted AS nvarchar(20)),
            N', updated ', CAST(@TotalUpdated AS nvarchar(20)),
            N', deleted ', CAST(@TotalDeleted AS nvarchar(20)),
            N'; advanced watermark to ', CAST(@ToVersion AS nvarchar(30)),
            N'; duration=', CAST(@DurationSec AS nvarchar(20)), N' sec.'
        );

        IF @EmitInfo=1
        BEGIN
            RAISERROR('ClientAbsences incremental sync complete.', 0, 1) WITH NOWAIT;
            RAISERROR('  Inserted = %d', 0, 1, @TotalInserted) WITH NOWAIT;
            RAISERROR('  Updated  = %d', 0, 1, @TotalUpdated) WITH NOWAIT;
            RAISERROR('  Deleted  = %d', 0, 1, @TotalDeleted) WITH NOWAIT;
        END

        IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;

        IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;
        DECLARE @msg nvarchar(4000)=ERROR_MESSAGE();
        DECLARE @num int=ERROR_NUMBER(), @sev int=ERROR_SEVERITY(), @st int=ERROR_STATE(), @lin int=ERROR_LINE(), @proc sysname=ERROR_PROCEDURE();
        DECLARE @procName sysname = ISNULL(@proc, N'<adhoc>');
        IF @EmitInfo=1 RAISERROR('usp_Sync_ClientAbsences_Incremental failed (%d, sev %d, state %d) at %s line %d: %s',
                                 16,1,@num,@sev,@st,@procName,@lin,@msg);
        SET @Summary = CONCAT(N'ClientAbsences incremental failed: ', @msg);
        IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
        RETURN -50001;
    END CATCH
END
GO
