USE [DOM_LIVE]
GO
/****** Object:  StoredProcedure [dbo].[usp_Sync_EmployeesAbsences_Incremental]    Script Date: 26/01/2026 20:47:36 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

ALTER   PROCEDURE [dbo].[usp_Sync_EmployeesAbsences_Incremental]
    @ChunkSize        int  = 100000,
    @LockTimeoutMs    int  = 60000,
    @UseAppLock       bit  = 1,
    @EmitInfo         bit  = 1,                          -- 0=quiet, 1=progress
    @Summary          nvarchar(4000) = NULL OUTPUT,      -- one-line summary
    @ReturnSummaryRow bit  = 1                           -- Initial sets this to 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Process       sysname      = N'EmployeesAbsences';
    DECLARE @RunStartedAt  datetime2(3) = SYSUTCDATETIME();
    DECLARE @StartIso      varchar(33)  = CONVERT(varchar(33), @RunStartedAt, 126);
    DECLARE @EndUTC        datetime2(3);
    DECLARE @EndIso        varchar(33);
    DECLARE @DurationSec   int;

    /* 0) Concurrency guard */
    DECLARE @LockResource sysname = N'DOM_LIVE:Sync:EmployeesAbsences';
    DECLARE @LockOwner   sysname  = N'Session';
    DECLARE @DbPrincipal sysname  = N'dbo';
    DECLARE @lockResult  int;
    DECLARE @lockHeld    bit      = 0;

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
            SET @Summary = N'EmployeesAbsences incremental failed: could not acquire applock.';
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            RETURN @lockResult;
        END
        SET @lockHeld = 1;
    END

    BEGIN TRY
        /* 1) Preconditions and watermark */
        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_databases WHERE database_id = DB_ID())
        BEGIN
            IF @EmitInfo=1 RAISERROR('Change Tracking is not enabled at the database level.',16,1);
            SET @Summary = N'EmployeesAbsences incremental failed: CT not enabled at DB level.';
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            GOTO FinallyRelease;
        END

        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.INACTIVE_DY'))
        BEGIN
            IF @EmitInfo=1 RAISERROR('Change Tracking is not enabled on dbo.INACTIVE_DY.',16,1);
            SET @Summary = N'EmployeesAbsences incremental failed: CT not enabled on INACTIVE_DY.';
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            GOTO FinallyRelease;
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

        -- Make sure watermark is still valid for the CT window
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
            IF @EmitInfo=1 RAISERROR('Watermark (%I64d) < CT min valid (%I64d). Re-baseline required.',16,1,@LastSyncVersion,@MinValid);
            SET @Summary = CONCAT(N'EmployeesAbsences incremental failed: watermark ', @LastSyncVersion, N' < min valid ', @MinValid, N' (re-baseline).');
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            GOTO FinallyRelease;
        END

        DECLARE @ToVersion bigint = CHANGE_TRACKING_CURRENT_VERSION();

        IF @EmitInfo=1
        BEGIN
            RAISERROR('EmployeesAbsences CT window:', 0, 1) WITH NOWAIT;
            RAISERROR('  From = %I64d', 0, 1, @LastSyncVersion) WITH NOWAIT;
            RAISERROR('  To   = %I64d', 0, 1, @ToVersion) WITH NOWAIT;
        END

        /* 2) Build changed set (keys = INACT_REF) */
        IF OBJECT_ID('tempdb..#Changed') IS NOT NULL DROP TABLE #Changed;
        CREATE TABLE #Changed
        (
            UUID nvarchar(50) NOT NULL PRIMARY KEY  -- matches target PK type
        );

        -- INACTIVE_DY inserted/updated
        INSERT INTO #Changed(UUID)
        SELECT DISTINCT CAST(idy.INACT_REF AS nvarchar(50))
        FROM CHANGETABLE(CHANGES dbo.INACTIVE_DY, @LastSyncVersion) ct
        JOIN dbo.INACTIVE_DY idy ON idy.INACT_REF = ct.INACT_REF
        WHERE ct.SYS_CHANGE_VERSION <= @ToVersion
          AND ct.SYS_CHANGE_OPERATION IN ('I','U');

        -- CHSYSDEC description changes that affect reasons used by INACTIVE_DY (optional)
        IF @CT_CHSYSDEC = 1
        BEGIN
            INSERT INTO #Changed(UUID)
            SELECT DISTINCT CAST(idy.INACT_REF AS nvarchar(50))
            FROM CHANGETABLE(CHANGES dbo.CHSYSDEC, @LastSyncVersion) d
            JOIN dbo.INACTIVE_DY idy ON idy.REASON = d.DECODE_REF
            WHERE d.SYS_CHANGE_VERSION <= @ToVersion
              AND NOT EXISTS (SELECT 1 FROM #Changed z WHERE z.UUID = CAST(idy.INACT_REF AS nvarchar(50)));
        END

        DECLARE @ToProcess int = (SELECT COUNT(*) FROM #Changed);
        IF @EmitInfo=1 RAISERROR('Absence rows to upsert: %d', 0, 1, @ToProcess) WITH NOWAIT;

        /* 3) Chunked UPSERT */
        DECLARE @TotalInserted int=0, @TotalUpdated int=0, @TotalDeleted int=0;

        WHILE EXISTS (SELECT 1 FROM #Changed)
        BEGIN
            IF OBJECT_ID('tempdb..#Next') IS NOT NULL DROP TABLE #Next;
            CREATE TABLE #Next(UUID nvarchar(50) NOT NULL PRIMARY KEY);

            INSERT INTO #Next(UUID)
            SELECT TOP (@ChunkSize) UUID FROM #Changed ORDER BY UUID;

            IF OBJECT_ID('tempdb..#ActLog') IS NOT NULL DROP TABLE #ActLog;
            CREATE TABLE #ActLog(Action nvarchar(10) NOT NULL);

            ;WITH Base AS
            (
                SELECT
                    UUID            = CAST(idy.INACT_REF AS nvarchar(50)),
                    Employee_UUID   = CAST(idy.EMP_REF   AS int),
                    Reason          = cr.DESCRIPTION,
                    [End_Date]      = idy.END_DTM,
                    [Start_Date]    = idy.START_DTM,
                    [Status]        = CASE idy.ALEAVESTAT
                                        WHEN ''  THEN 'Entered'
                                        WHEN 'C' THEN 'Confirmed'
                                        WHEN 'P' THEN 'Part-Paid'
                                        WHEN 'F' THEN 'Fully-Paid'
                                        ELSE 'Unknown'
                                      END,
                    Comment         = idy.COMMENT
                FROM dbo.INACTIVE_DY idy
                JOIN #Next n                ON n.UUID = CAST(idy.INACT_REF AS nvarchar(50))
                LEFT JOIN dbo.CHSYSDEC cr   ON cr.DECODE_REF = idy.REASON
            )
            MERGE dbo.tbl_EmployeesAbsences AS tgt
            USING Base AS src
               ON tgt.UUID = src.UUID
            WHEN MATCHED THEN
                UPDATE SET
                    tgt.Employee_UUID = src.Employee_UUID,
                    tgt.Reason        = src.Reason,
                    tgt.[End_Date]    = src.[End_Date],
                    tgt.[Start_Date]  = src.[Start_Date],
                    tgt.[Status]      = src.[Status],
                    tgt.Comment       = src.Comment,
                    tgt.UpdatedAtUTC  = @RunStartedAt
            WHEN NOT MATCHED BY TARGET THEN
                INSERT (Employee_UUID, Reason, [End_Date], [Start_Date], [Status], UUID, Comment, CreatedAtUTC, UpdatedAtUTC)
                VALUES (src.Employee_UUID, src.Reason, src.[End_Date], src.[Start_Date], src.[Status], src.UUID, src.Comment, @RunStartedAt, @RunStartedAt)
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
            JOIN #Next n ON n.UUID = c.UUID;
        END

        /* 4) Apply deletes from INACTIVE_DY */
        IF OBJECT_ID('tempdb..#DelLog') IS NOT NULL DROP TABLE #DelLog;
        CREATE TABLE #DelLog(UUID nvarchar(50) NOT NULL);

        DELETE t
        OUTPUT DELETED.UUID INTO #DelLog(UUID)
        FROM dbo.tbl_EmployeesAbsences t
        JOIN (
            SELECT d.INACT_REF
            FROM CHANGETABLE(CHANGES dbo.INACTIVE_DY, @LastSyncVersion) d
            WHERE d.SYS_CHANGE_OPERATION='D'
              AND d.SYS_CHANGE_VERSION   <= @ToVersion
        ) x ON t.UUID = CAST(x.INACT_REF AS nvarchar(50));

        SET @TotalDeleted = (SELECT COUNT(*) FROM #DelLog);
        IF @EmitInfo=1 RAISERROR('Deleted due to source deletes: %d', 0, 1, @TotalDeleted) WITH NOWAIT;

        /* 5) Advance watermark + summary */
        UPDATE dbo.CT_Watermark
          SET LastSyncVersion=@ToVersion, LastSyncTime=SYSUTCDATETIME()
        WHERE ProcessName=@Process;

        SET @EndUTC = SYSUTCDATETIME();
        SET @EndIso = CONVERT(varchar(33), @EndUTC, 126);
        SET @DurationSec = DATEDIFF(SECOND, @RunStartedAt, @EndUTC);

        SET @Summary = CONCAT(
            N'EmployeesAbsences incremental started ', @StartIso, N' UTC; ended ', @EndIso,
            N' UTC; inserted ', @TotalInserted, N', updated ', @TotalUpdated,
            N', deleted ', @TotalDeleted, N'; advanced watermark to ',
            CAST(@ToVersion AS nvarchar(30)), N'; duration=', @DurationSec, N' sec.'
        );

        IF @EmitInfo=1
        BEGIN
            RAISERROR('EmployeesAbsences incremental complete.', 0, 1) WITH NOWAIT;
            RAISERROR('  Inserted = %d', 0, 1, @TotalInserted) WITH NOWAIT;
            RAISERROR('  Updated  = %d', 0, 1, @TotalUpdated) WITH NOWAIT;
            RAISERROR('  Deleted  = %d', 0, 1, @TotalDeleted) WITH NOWAIT;
        END

        IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;

FinallyRelease:
        IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;
        DECLARE @msg nvarchar(4000)=ERROR_MESSAGE();
        DECLARE @num int=ERROR_NUMBER(), @sev int=ERROR_SEVERITY(), @st int=ERROR_STATE(), @lin int=ERROR_LINE(), @proc sysname=ERROR_PROCEDURE();
        DECLARE @procName sysname = ISNULL(@proc, N'<adhoc>');
        IF @EmitInfo=1 RAISERROR('usp_Sync_EmployeesAbsences_Incremental failed (%d, sev %d, state %d) at %s line %d: %s',16,1,@num,@sev,@st,@procName,@lin,@msg);
        SET @Summary = CONCAT(N'EmployeesAbsences incremental failed: ', @msg);
        IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
        RETURN -50001;
    END CATCH
END
