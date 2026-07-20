USE [DOM_LIVE];
GO

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

ALTER PROCEDURE [dbo].[usp_Sync_EmployeesAbsences_Incremental]
    @ChunkSize       int  = 100000,
    @LockTimeoutMs   int  = 60000,
    @UseAppLock      bit  = 1,
    @EmitProgress    bit  = 0,
    @Summary         nvarchar(4000) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET ANSI_WARNINGS ON;

    DECLARE @Process       sysname      = N'EmployeesAbsences';
    DECLARE @RunStartedAt  datetime2(3) = SYSUTCDATETIME();
    DECLARE @StartIso      varchar(33)  = CONVERT(varchar(33), @RunStartedAt, 126);
    DECLARE @EndUTC        datetime2(3);
    DECLARE @EndIso        varchar(33);
    DECLARE @DurationSec   int;

    DECLARE @Msg nvarchar(2047);

    /* Concurrency */
    DECLARE @LockResource sysname = N'DOM_LIVE:Sync:EmployeesAbsences';
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
            SET @Summary = N'EmployeesAbsences incremental failed: could not acquire applock.';
            SELECT 'Incremental' AS Stage, @Summary AS Summary;
            RETURN -1;
        END

        SET @lockHeld = 1;
    END

    BEGIN TRY
        /* Preconditions */
        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_databases WHERE database_id = DB_ID())
            RAISERROR('Change Tracking is not enabled at DB level.', 16, 1);

        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.INACTIVE_DY'))
            RAISERROR('Change Tracking is not enabled on dbo.INACTIVE_DY.', 16, 1);

        IF OBJECT_ID(N'dbo.tbl_EmployeesAbsences', N'U') IS NULL
            RAISERROR('Target dbo.tbl_EmployeesAbsences not found. Run usp_Sync_EmployeesAbsences_Initial first.', 16, 1);

        DECLARE @CT_CHSYSDEC bit =
            CASE WHEN EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.CHSYSDEC')) THEN 1 ELSE 0 END;

        /* Watermark table */
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

        /* Fence CT window at START */
        DECLARE @ToVersion bigint = CHANGE_TRACKING_CURRENT_VERSION();

        /* Min valid across referenced tables */
        DECLARE @MinValid bigint =
        (
            SELECT MAX(CHANGE_TRACKING_MIN_VALID_VERSION(object_id))
            FROM sys.change_tracking_tables
            WHERE object_id IN
            (
                OBJECT_ID(N'dbo.INACTIVE_DY'),
                CASE WHEN @CT_CHSYSDEC=1 THEN OBJECT_ID(N'dbo.CHSYSDEC') ELSE NULL END
            )
        );

        IF @MinValid IS NOT NULL AND @LastSyncVersion < @MinValid
            RAISERROR('Watermark (%I64d) < CT min valid (%I64d). Re-baseline required.', 16, 1, @LastSyncVersion, @MinValid);

        IF @EmitProgress=1
        BEGIN
            SET @Msg = CONCAT(N'EmployeesAbsences CT window: From=', @LastSyncVersion, N' To=', @ToVersion);
            RAISERROR(@Msg, 10, 1) WITH NOWAIT;

            IF @CT_CHSYSDEC = 0
                RAISERROR(N'Note: CT not enabled on CHSYSDEC; Reason text changes won''t be tracked.', 10, 1) WITH NOWAIT;
        END

        /* Build changed key set (UUID = INACT_REF) */
        IF OBJECT_ID('tempdb..#Changed') IS NOT NULL DROP TABLE #Changed;
        CREATE TABLE #Changed (UUID INT NOT NULL PRIMARY KEY);

        INSERT INTO #Changed(UUID)
        SELECT DISTINCT ct.INACT_REF
        FROM CHANGETABLE(CHANGES dbo.INACTIVE_DY, @LastSyncVersion) ct
        WHERE ct.SYS_CHANGE_VERSION <= @ToVersion;

        IF @CT_CHSYSDEC = 1
        BEGIN
            INSERT INTO #Changed(UUID)
            SELECT DISTINCT idy.INACT_REF
            FROM CHANGETABLE(CHANGES dbo.CHSYSDEC, @LastSyncVersion) d
            JOIN dbo.INACTIVE_DY idy ON idy.REASON = d.DECODE_REF
            WHERE d.SYS_CHANGE_VERSION <= @ToVersion
              AND NOT EXISTS (SELECT 1 FROM #Changed z WHERE z.UUID = idy.INACT_REF);
        END

        DECLARE @ToProcess int = (SELECT COUNT(*) FROM #Changed);

        IF @EmitProgress=1
        BEGIN
            SET @Msg = CONCAT(N'EmployeesAbsences changed keys: ', @ToProcess);
            RAISERROR(@Msg, 10, 1) WITH NOWAIT;
        END

        /* Fast path: no changes */
        IF @ToProcess = 0
        BEGIN
            UPDATE dbo.CT_Watermark
              SET LastSyncVersion=@ToVersion, LastSyncTime=SYSUTCDATETIME()
            WHERE ProcessName=@Process;

            SET @EndUTC = SYSUTCDATETIME();
            SET @EndIso = CONVERT(varchar(33), @EndUTC, 126);
            SET @DurationSec = DATEDIFF(SECOND, @RunStartedAt, @EndUTC);

            SET @Summary = CONCAT(
                N'EmployeesAbsences incremental started ', @StartIso, N' UTC; ended ', @EndIso,
                N' UTC; inserted 0, updated 0, deleted 0; advanced watermark to ',
                CAST(@ToVersion AS nvarchar(30)), N'; duration=', @DurationSec, N' sec.'
            );

            SELECT 'Incremental' AS Stage, @Summary AS Summary;

            IF @lockHeld=1
                EXEC sys.sp_releaseapplock @Resource=@LockResource,@LockOwner=@LockOwner,@DbPrincipal=@DbPrincipal;

            RETURN 0;
        END

        /* Chunked MERGE */
        DECLARE @TotalInserted bigint = 0, @TotalUpdated bigint = 0, @TotalDeleted bigint = 0;

        WHILE EXISTS (SELECT 1 FROM #Changed)
        BEGIN
            IF OBJECT_ID('tempdb..#Next') IS NOT NULL DROP TABLE #Next;
            CREATE TABLE #Next (UUID INT NOT NULL PRIMARY KEY);

            INSERT INTO #Next(UUID)
            SELECT TOP (@ChunkSize) UUID
            FROM #Changed
            ORDER BY UUID;
            
            IF OBJECT_ID('tempdb..#ActLog') IS NOT NULL DROP TABLE #ActLog;
            CREATE TABLE #ActLog (Action nvarchar(10) NOT NULL);

            ;WITH Base AS
            (
                SELECT
                    UUID          = idy.INACT_REF,
                    Employee_UUID = CAST(idy.EMP_REF AS int),
                    Reason        = cr.DESCRIPTION,
                    [End_Date]    = idy.END_DTM,
                    [Start_Date]  = idy.START_DTM,
                    [Status]      = CASE idy.ALEAVESTAT
                                    WHEN ''  THEN 'Entered'
                                    WHEN 'C' THEN 'Confirmed'
                                    WHEN 'P' THEN 'Part-Paid'
                                    WHEN 'F' THEN 'Fully-Paid'
                                    ELSE 'Unknown'
                                    END,
                    Comment       = idy.COMMENT
                FROM dbo.INACTIVE_DY idy
                JOIN #Next n              ON n.UUID = idy.INACT_REF
                LEFT JOIN dbo.CHSYSDEC cr ON cr.DECODE_REF = idy.REASON
                WHERE idy.EMP_REF <> 0
                AND idy.rectype = 'E'
                AND (cr.DESCRIPTION IS NULL OR cr.DESCRIPTION NOT IN ('From Another Branch','Input Error','Resigned ','Do not use'))
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
            WHEN NOT MATCHED BY SOURCE
                AND EXISTS (SELECT 1 FROM #Next nn WHERE nn.UUID = tgt.UUID)
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

            IF @EmitProgress=1
            BEGIN
                SET @Msg = CONCAT(
                    N'EmployeesAbsences chunk: inserted=', @i,
                    N' updated=', @u,
                    N' deleted=', @d,
                    N' (running ', @TotalInserted, N'/', @TotalUpdated, N'/', @TotalDeleted, N')'
                );
                RAISERROR(@Msg, 10, 1) WITH NOWAIT;
            END

            DELETE c
            FROM #Changed c
            JOIN #Next n ON n.UUID = c.UUID;
        END

        /* Advance watermark */
        UPDATE dbo.CT_Watermark
          SET LastSyncVersion=@ToVersion, LastSyncTime=SYSUTCDATETIME()
        WHERE ProcessName=@Process;

        SET @EndUTC = SYSUTCDATETIME();
        SET @EndIso = CONVERT(varchar(33), @EndUTC, 126);
        SET @DurationSec = DATEDIFF(SECOND, @RunStartedAt, @EndUTC);

        SET @Summary = CONCAT(
            N'EmployeesAbsences incremental started ', @StartIso, N' UTC; ended ', @EndIso,
            N' UTC; inserted ', CAST(@TotalInserted AS nvarchar(20)),
            N', updated ', CAST(@TotalUpdated AS nvarchar(20)),
            N', deleted ', CAST(@TotalDeleted AS nvarchar(20)),
            N'; advanced watermark to ', CAST(@ToVersion AS nvarchar(30)),
            N'; duration=', CAST(@DurationSec AS nvarchar(20)), N' sec.'
        );

        SELECT 'Incremental' AS Stage, @Summary AS Summary;

        IF @lockHeld=1
            EXEC sys.sp_releaseapplock @Resource=@LockResource,@LockOwner=@LockOwner,@DbPrincipal=@DbPrincipal;

        RETURN 0;
    END TRY
    BEGIN CATCH
        IF @lockHeld=1
            EXEC sys.sp_releaseapplock @Resource=@LockResource,@LockOwner=@LockOwner,@DbPrincipal=@DbPrincipal;

        DECLARE @err nvarchar(4000) = ERROR_MESSAGE();
        SET @Summary = CONCAT(N'EmployeesAbsences incremental failed: ', @err);
        SELECT 'Incremental' AS Stage, @Summary AS Summary;
        RETURN -50001;
    END CATCH
END;
GO
