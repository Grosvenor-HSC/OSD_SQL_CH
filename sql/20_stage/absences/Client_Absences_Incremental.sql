USE [DOM_LIVE];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Sync_ClientAbsences_Incremental
    @ChunkSize        int            = 100000,
    @LockTimeoutMs    int            = 60000,
    @UseAppLock       bit            = 1,
    @EmitInfo         bit            = 1,                       -- 0=quiet, 1=progress
    @Summary          nvarchar(4000) = NULL OUTPUT,              -- one-line summary
    @ReturnSummaryRow bit            = 1                        -- 1=SELECT Stage/Summary row
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

    /* ----------------------- 0) Concurrency guard ----------------------- */
    DECLARE @LockResource sysname = N'DOM_LIVE:Sync:ClientAbsences';
    DECLARE @LockOwner    sysname = N'Session';
    DECLARE @DbPrincipal  sysname = N'dbo';
    DECLARE @lockResult   int;
    DECLARE @lockHeld     bit = 0;

    IF @UseAppLock = 1
    BEGIN
        EXEC @lockResult = sys.sp_getapplock
            @Resource=@LockResource, @LockMode='Exclusive',
            @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal,
            @LockTimeout=@LockTimeoutMs;

        IF @lockResult NOT IN (0,1)
        BEGIN
            IF @EmitInfo=1 RAISERROR('Could not acquire %s (rc=%d).',16,1,@LockResource,@lockResult);
            SET @Summary = N'ClientAbsences incremental failed: could not acquire applock.';
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            RETURN @lockResult;
        END

        SET @lockHeld = 1;
    END

    BEGIN TRY
        /* ----------------------- 1) Preconditions & bounds ----------------------- */
        IF OBJECT_ID(N'dbo.tbl_ClientAbsences', N'U') IS NULL
        BEGIN
            IF @EmitInfo=1 RAISERROR('Target dbo.tbl_ClientAbsences missing. Run initial first.',16,1);
            SET @Summary = N'ClientAbsences incremental failed: target missing (run initial).';
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            GOTO FinallyRelease;
        END

        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_databases WHERE database_id = DB_ID())
        BEGIN
            IF @EmitInfo=1 RAISERROR('CT not enabled at DB level.',16,1);
            SET @Summary = N'ClientAbsences incremental failed: CT not enabled at DB level.';
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            GOTO FinallyRelease;
        END

        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.INACTIVE_DY'))
        BEGIN
            IF @EmitInfo=1 RAISERROR('CT not enabled on dbo.INACTIVE_DY.',16,1);
            SET @Summary = N'ClientAbsences incremental failed: CT not enabled on INACTIVE_DY.';
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            GOTO FinallyRelease;
        END

        DECLARE @CT_CHSYSDEC bit =
            CASE WHEN EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.CHSYSDEC'))
                 THEN 1 ELSE 0 END;

        /* Watermark table/row */
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
        BEGIN
            IF @EmitInfo=1 RAISERROR('Watermark %I64d < CT min valid %I64d (re-baseline).',16,1,@LastSyncVersion,@MinValid);
            SET @Summary = CONCAT(N'ClientAbsences incremental failed: watermark ', @LastSyncVersion, N' < min valid ', @MinValid, N'.');
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            GOTO FinallyRelease;
        END

        DECLARE @ToVersion bigint = CHANGE_TRACKING_CURRENT_VERSION();

        IF @EmitInfo=1
        BEGIN
            RAISERROR('ClientAbsences CT window: From=%I64d To=%I64d', 0, 1, @LastSyncVersion, @ToVersion) WITH NOWAIT;
            IF @CT_CHSYSDEC = 0
                RAISERROR('Note: CT not enabled on CHSYSDEC; Absence_Reason text changes may be delayed.', 0, 1) WITH NOWAIT;
        END

        /* ----------------------- 2) Build changed key set ----------------------- */
        IF OBJECT_ID('tempdb..#Changed') IS NOT NULL DROP TABLE #Changed;
        CREATE TABLE #Changed (InactiveReference int NOT NULL PRIMARY KEY); -- INACT_REF

        INSERT INTO #Changed(InactiveReference)
        SELECT DISTINCT x.INACT_REF
        FROM CHANGETABLE(CHANGES dbo.INACTIVE_DY, @LastSyncVersion) x
        WHERE x.SYS_CHANGE_VERSION <= @ToVersion;

        IF @CT_CHSYSDEC = 1
        BEGIN
            INSERT INTO #Changed(InactiveReference)
            SELECT DISTINCT idy.INACT_REF
            FROM CHANGETABLE(CHANGES dbo.CHSYSDEC, @LastSyncVersion) d
            JOIN dbo.INACTIVE_DY idy
              ON idy.REASON = d.DECODE_REF
            WHERE d.SYS_CHANGE_VERSION <= @ToVersion
              AND NOT EXISTS (SELECT 1 FROM #Changed z WHERE z.InactiveReference = idy.INACT_REF);
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
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            GOTO FinallyRelease;
        END

        /* ----------------------- 3) Chunked UPSERT ----------------------- */
        DECLARE @TotalInserted bigint = 0, @TotalUpdated bigint = 0, @TotalDeleted bigint = 0;

        WHILE EXISTS (SELECT 1 FROM #Changed)
        BEGIN
            IF OBJECT_ID('tempdb..#Next') IS NOT NULL DROP TABLE #Next;
            CREATE TABLE #Next (InactiveReference int NOT NULL PRIMARY KEY);

            INSERT INTO #Next(InactiveReference)
            SELECT TOP (@ChunkSize) InactiveReference
            FROM #Changed
            ORDER BY InactiveReference;

            IF OBJECT_ID('tempdb..#ActLog') IS NOT NULL DROP TABLE #ActLog;
            CREATE TABLE #ActLog(Action nvarchar(10) NOT NULL);

            ;WITH Base AS
            (
                SELECT
                    UUID               = idy.INACT_REF,
                    Client_UUID        = idy.CLIENT_REF,
                    Absence_Reason     = NULLIF(LTRIM(RTRIM(cr.DESCRIPTION)), N''),
                    Absence_Start_Date = TRY_CONVERT(date, idy.START_DT),
                    Absence_End_Date   = TRY_CONVERT(date, idy.END_DT)
                FROM dbo.INACTIVE_DY idy
                JOIN #Next n
                  ON n.InactiveReference = idy.INACT_REF
                LEFT JOIN dbo.CHSYSDEC cr
                  ON cr.DECODE_REF = idy.REASON
                WHERE idy.rectype NOT IN ('S','R','E')
            )
            MERGE dbo.tbl_ClientAbsences AS tgt
            USING Base AS src
               ON tgt.UUID = src.UUID
            WHEN MATCHED THEN
                UPDATE SET
                    tgt.Client_UUID        = src.Client_UUID,
                    tgt.Absence_Reason     = src.Absence_Reason,
                    tgt.Absence_Start_Date = src.Absence_Start_Date,
                    tgt.Absence_End_Date   = src.Absence_End_Date,
                    tgt.UpdatedAtUTC       = @RunStartedAt
            WHEN NOT MATCHED BY TARGET THEN
                INSERT
                (
                    UUID, Client_UUID, Absence_Reason,
                    Absence_Start_Date, Absence_End_Date,
                    CreatedAtUTC, UpdatedAtUTC
                )
                VALUES
                (
                    src.UUID, src.Client_UUID, src.Absence_Reason,
                    src.Absence_Start_Date, src.Absence_End_Date,
                    @RunStartedAt, @RunStartedAt
                )
            OUTPUT $action INTO #ActLog(Action);

            DECLARE @i int = 0, @u int = 0;
            SELECT
                @i = ISNULL(SUM(CASE WHEN Action='INSERT' THEN 1 ELSE 0 END), 0),
                @u = ISNULL(SUM(CASE WHEN Action='UPDATE' THEN 1 ELSE 0 END), 0)
            FROM #ActLog;

            SET @TotalInserted += @i;
            SET @TotalUpdated  += @u;

            IF @EmitInfo=1
                RAISERROR('ClientAbsences chunk: inserted=%d updated=%d (running %I64d/%I64d)',
                          0,1,@i,@u,@TotalInserted,@TotalUpdated) WITH NOWAIT;

            DELETE c
            FROM #Changed c
            JOIN #Next n ON n.InactiveReference = c.InactiveReference;
        END

        /* ----------------------- 3b) Hard deletes from INACTIVE_DY ----------------------- */
        IF OBJECT_ID('tempdb..#DelLog') IS NOT NULL DROP TABLE #DelLog;
        CREATE TABLE #DelLog(UUID int NOT NULL);

        DELETE t
        OUTPUT DELETED.UUID INTO #DelLog(UUID)
        FROM dbo.tbl_ClientAbsences t
        JOIN
        (
            SELECT d.INACT_REF
            FROM CHANGETABLE(CHANGES dbo.INACTIVE_DY, @LastSyncVersion) d
            WHERE d.SYS_CHANGE_OPERATION = 'D'
              AND d.SYS_CHANGE_VERSION   <= @ToVersion
        ) x
          ON x.INACT_REF = t.UUID;

        SET @TotalDeleted += (SELECT COUNT(*) FROM #DelLog);

        /* ----------------------- 4) Advance watermark + summary ----------------------- */
        UPDATE dbo.CT_Watermark
          SET LastSyncVersion=@ToVersion,
              LastSyncTime=SYSUTCDATETIME()
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

        IF @EmitInfo=1 RAISERROR('ClientAbsences incremental sync complete.',0,1) WITH NOWAIT;
        IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;

FinallyRelease:
        IF @lockHeld=1
            EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;

        RETURN 0;
    END TRY
    BEGIN CATCH
        IF @lockHeld=1
            EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;

        DECLARE @msg nvarchar(4000)=ERROR_MESSAGE();
        DECLARE @num int=ERROR_NUMBER(), @sev int=ERROR_SEVERITY(), @st int=ERROR_STATE(),
                @lin int=ERROR_LINE(), @proc sysname=ERROR_PROCEDURE();
        DECLARE @procName sysname = ISNULL(@proc, N'<adhoc>');

        IF @EmitInfo=1
            RAISERROR('usp_Sync_ClientAbsences_Incremental failed (%d, sev %d, state %d) at %s line %d: %s',
                      16,1,@num,@sev,@st,@procName,@lin,@msg);

        SET @Summary = CONCAT(N'ClientAbsences incremental failed: ', @msg);
        IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
        RETURN -50001;
    END CATCH
END;
GO
