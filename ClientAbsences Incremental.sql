ALTER PROCEDURE [dbo].[usp_Sync_ClientAbsences_Incremental]
    @ChunkSize      int  = 100000,   -- tune as needed
    @LockTimeoutMs  int  = 60000,
    @UseAppLock     bit  = 1,
    @EmitInfo       bit  = 0,                 -- NEW: 0 = quiet, 1 = print progress
    @Summary        nvarchar(4000) = NULL OUTPUT   -- NEW: one-line summary
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Process       sysname      = N'ClientAbsences';
    DECLARE @RunStartedAt  datetime2(3) = SYSUTCDATETIME();
    DECLARE @StartIso      varchar(33)  = CONVERT(varchar(33), @RunStartedAt, 126);
    DECLARE @EndUTC        datetime2(3);
    DECLARE @EndIso        varchar(33);
    DECLARE @DurationSec   int;

    /* -----------------------
       0) Concurrency guard
    ------------------------*/
    DECLARE @LockResource sysname = N'DOM_LIVE:Sync:ClientAbsences';
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
            IF @EmitInfo=1 RAISERROR('Could not acquire %s (sp_getapplock rc=%d).',16,1,@LockResource,@lockResult);
            SET @Summary = N'ClientAbsences incremental failed: could not acquire applock.';
            RETURN @lockResult;
        END
        SET @lockHeld = 1;
    END

    BEGIN TRY
        /* -----------------------
           1) Preconditions & bounds
        ------------------------*/
        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_databases WHERE database_id = DB_ID())
        BEGIN
            IF @EmitInfo=1 RAISERROR('Change Tracking is not enabled at the database level.', 16, 1);
            SET @Summary = N'ClientAbsences incremental failed: CT not enabled at DB level.';
            IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;
            RETURN -100;
        END

        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.INACTIVE_DY'))
        BEGIN
            IF @EmitInfo=1 RAISERROR('Change Tracking is not enabled on dbo.INACTIVE_DY. Cannot proceed.',16,1);
            SET @Summary = N'ClientAbsences incremental failed: CT not enabled on dbo.INACTIVE_DY.';
            IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;
            RETURN -210;
        END

        DECLARE @CT_CHSYSDEC bit =
            CASE WHEN EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.CHSYSDEC')) THEN 1 ELSE 0 END;

        IF OBJECT_ID('dbo.CT_Watermark','U') IS NULL
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

        -- Min valid across referenced CT-enabled tables
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

        /* ------------------------------------------
           2) Build changed InactiveReference set
        -------------------------------------------*/
        IF OBJECT_ID('tempdb..#Changed') IS NOT NULL DROP TABLE #Changed;
        CREATE TABLE #Changed (InactiveReference nvarchar(55) NOT NULL PRIMARY KEY);

        -- All operations (I/U/D) from INACTIVE_DY
        INSERT INTO #Changed(InactiveReference)
        SELECT DISTINCT CAST(x.INACT_REF AS nvarchar(55))
        FROM CHANGETABLE(CHANGES dbo.INACTIVE_DY, @LastSyncVersion) x
        WHERE x.SYS_CHANGE_VERSION <= @ToVersion;

        -- Optional: CHSYSDEC description changes
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
            IF @EmitInfo=1 RAISERROR('Note: CT not enabled on CHSYSDEC; AbsenceReason text updates are not tracked.', 0, 1) WITH NOWAIT;
        END

        DECLARE @ToProcess int = (SELECT COUNT(*) FROM #Changed);
        IF @EmitInfo=1 RAISERROR('Inactive rows to process: %d', 0, 1, @ToProcess) WITH NOWAIT;

        IF @ToProcess = 0
        BEGIN
            UPDATE dbo.CT_Watermark
              SET LastSyncVersion = @ToVersion, LastSyncTime = SYSUTCDATETIME()
            WHERE ProcessName = @Process;

            SET @EndUTC = SYSUTCDATETIME();
            SET @EndIso = CONVERT(varchar(33), @EndUTC, 126);
            SET @DurationSec = DATEDIFF(SECOND, @RunStartedAt, @EndUTC);

            SET @Summary = CONCAT(
                N'ClientAbsences incremental started ', @StartIso, N' UTC; ended ', @EndIso,
                N' UTC; inserted 0, updated 0, deleted 0; advanced watermark to ',
                CAST(@ToVersion AS nvarchar(30)), N'; duration=', @DurationSec, N' sec.'
            );

            IF @EmitInfo=1 RAISERROR('No changes. Watermark advanced.', 0, 1) WITH NOWAIT;
            IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;
            RETURN 0;
        END

        /* ------------------------------------------
           3) Chunked MERGE into dbo.tbl_ClientAbsences
        -------------------------------------------*/
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

            SET DATEFIRST 1; -- Monday week

            ;WITH Base AS
            (
                SELECT
                    InactiveReference = CAST(idy.INACT_REF AS nvarchar(55)),
                    ClientReference   = idy.CLIENT_REF,
                    AbsenceReason     = cr.DESCRIPTION,
                    AbsenceStartDate  = CAST(idy.START_DT AS date),
                    AbsenceEndDate    = CAST(idy.END_DT   AS date),
                    UpdatedLeaveDate  = CAST(idy.END_DT   AS date)
                FROM dbo.INACTIVE_DY idy
                JOIN #Next n
                  ON n.InactiveReference = CAST(idy.INACT_REF AS nvarchar(55))
                LEFT JOIN dbo.CHSYSDEC cr
                  ON cr.DECODE_REF = idy.REASON
                WHERE idy.rectype NOT IN ('S','R')
            ),
            Shaped AS
            (
                SELECT
                    InactiveReference,
                    ClientReference,
                    AbsenceReason,
                    AbsenceStartDate,
                    AbsenceEndDate,
                    UpdatedLeaveDate,
                    AbsenceEndDate_Week   = CASE WHEN UpdatedLeaveDate IS NOT NULL
                                                  THEN DATEADD(day, 1 - DATEPART(weekday, UpdatedLeaveDate), UpdatedLeaveDate)
                                                  ELSE NULL END,
                    AbsenceStartDate_Week = CASE WHEN AbsenceStartDate IS NOT NULL
                                                  THEN DATEADD(day, 1 - DATEPART(weekday, AbsenceStartDate), AbsenceStartDate)
                                                  ELSE NULL END,
                    AbsenceEndMonth       = CASE WHEN UpdatedLeaveDate IS NOT NULL THEN MONTH(UpdatedLeaveDate) END,
                    AbsenceStartMonth     = CASE WHEN AbsenceStartDate IS NOT NULL THEN MONTH(AbsenceStartDate) END,
                    AbsenceEndYear        = CASE WHEN UpdatedLeaveDate IS NOT NULL THEN YEAR(UpdatedLeaveDate) END,
                    AbsenceStartYear      = CASE WHEN AbsenceStartDate IS NOT NULL THEN YEAR(AbsenceStartDate) END,
                    DaysOnLeave           = CASE WHEN UpdatedLeaveDate IS NOT NULL AND AbsenceStartDate IS NOT NULL
                                                  THEN DATEDIFF(day, AbsenceStartDate, UpdatedLeaveDate)
                                                  ELSE NULL END
                FROM Base
            )
            MERGE dbo.tbl_ClientAbsences AS tgt
            USING Shaped AS src
               ON tgt.InactiveReference = src.InactiveReference
            WHEN MATCHED THEN
                UPDATE SET
                    tgt.ClientReference       = src.ClientReference,
                    tgt.AbsenceReason         = src.AbsenceReason,
                    tgt.AbsenceStartDate      = src.AbsenceStartDate,
                    tgt.AbsenceEndDate        = src.AbsenceEndDate,
                    tgt.UpdatedLeaveDate      = src.UpdatedLeaveDate,
                    tgt.AbsenceEndDate_Week   = src.AbsenceEndDate_Week,
                    tgt.AbsenceStartDate_Week = src.AbsenceStartDate_Week,
                    tgt.AbsenceEndMonth       = src.AbsenceEndMonth,
                    tgt.AbsenceStartMonth     = src.AbsenceStartMonth,
                    tgt.AbsenceEndYear        = src.AbsenceEndYear,
                    tgt.AbsenceStartYear      = src.AbsenceStartYear,
                    tgt.DaysOnLeave           = src.DaysOnLeave,
                    tgt.UpdatedAtUTC          = @RunStartedAt
            WHEN NOT MATCHED BY TARGET THEN
                INSERT (InactiveReference, ClientReference, AbsenceReason,
                        AbsenceStartDate, AbsenceEndDate, UpdatedLeaveDate,
                        AbsenceEndDate_Week, AbsenceStartDate_Week,
                        AbsenceEndMonth, AbsenceStartMonth,
                        AbsenceEndYear, AbsenceStartYear, DaysOnLeave,
                        CreatedAtUTC, UpdatedAtUTC)
                VALUES (src.InactiveReference, src.ClientReference, src.AbsenceReason,
                        src.AbsenceStartDate, src.AbsenceEndDate, src.UpdatedLeaveDate,
                        src.AbsenceEndDate_Week, src.AbsenceStartDate_Week,
                        src.AbsenceEndMonth, src.AbsenceStartMonth,
                        src.AbsenceEndYear, src.AbsenceStartYear, src.DaysOnLeave,
                        @RunStartedAt, @RunStartedAt)
            WHEN NOT MATCHED BY SOURCE 
                 AND EXISTS (SELECT 1 FROM #Next nn WHERE nn.InactiveReference = tgt.InactiveReference)
                 THEN DELETE
            OUTPUT $action INTO #ActLog(Action);

            DECLARE @i int = 0, @u int = 0, @d int = 0;
            SELECT @i = SUM(CASE WHEN Action='INSERT' THEN 1 ELSE 0 END),
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

        /* ------------------------------------------
           4) Advance watermark + build summary
        -------------------------------------------*/
        UPDATE dbo.CT_Watermark
          SET LastSyncVersion = @ToVersion,
              LastSyncTime    = SYSUTCDATETIME()
        WHERE ProcessName = @Process;

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

        IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;
        DECLARE @msg nvarchar(4000) = ERROR_MESSAGE();
        DECLARE @num int = ERROR_NUMBER(), @sev int = ERROR_SEVERITY(), @st int = ERROR_STATE(), @lin int = ERROR_LINE(), @proc sysname = ERROR_PROCEDURE();
        DECLARE @procName sysname = ISNULL(@proc, N'<adhoc>');
        IF @EmitInfo=1 RAISERROR('usp_Sync_ClientAbsences_Incremental failed (%d, sev %d, state %d) at %s line %d: %s',16,1,@num,@sev,@st,@procName,@lin,@msg);
        SET @Summary = CONCAT(N'ClientAbsences incremental failed: ', @msg);
        RETURN -50001;
    END CATCH
END
