/*
daily_refresh.sql (PURE T-SQL)
Purpose:
  Daily refresh run for incremental loads + core transforms + reporting builds.

Key behavior:
  - Calls only procs that exist (fails fast by default)
  - Passes ONLY parameters the proc actually accepts
  - Streams progress output immediately (RAISERROR(@msg, 10, 1) WITH NOWAIT) - SQL 2016 safe
  - Step-level error context before re-throw
  - Optional special-case for Visits: direct EXEC for best NOWAIT streaming

SQL Server:
  - Compatible with SQL Server 2016 SP3 (13.x)
*/

USE [DOM_LIVE];
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @FailFast bit = 1;   -- 1 = missing proc stops run, 0 = missing proc is logged + skipped

/* Optional tuning defaults (only used if the proc supports these params) */
DECLARE @DefaultChunkSize int = 100000;
DECLARE @DefaultEmit bit = 0;    -- scheduled runs are quiet by default
DECLARE @DefaultLockTimeoutMs int = 600000;

/* Visits tuning (optional) */
DECLARE @VisitsChunkSize int = 200000;
DECLARE @VisitsEmit bit = 0;     -- scheduled runs are quiet by default

DECLARE @StartedAt datetime2(3) = SYSUTCDATETIME();
DECLARE @EndedAt   datetime2(3);
DECLARE @Msg       nvarchar(2047);

DECLARE @Steps TABLE
(
    StepOrder  int IDENTITY(1,1) NOT NULL,
    StepName   nvarchar(200) NOT NULL,
    ProcSchema sysname NOT NULL,
    ProcName   sysname NOT NULL
);

/* Define run order */
INSERT INTO @Steps (StepName, ProcSchema, ProcName)
VALUES
(N'Branches Incremental',             N'dbo', N'usp_Sync_Branch_Incremental'),
(N'Employees Incremental',            N'dbo', N'usp_Sync_Employees_Incremental'),
(N'Clients Incremental',              N'dbo', N'usp_Sync_Clients_Incremental'),
(N'Visits Incremental',               N'dbo', N'usp_Sync_Visits_Incremental'),

(N'EmployeeBranch Incremental',       N'dbo', N'usp_Sync_EmployeeBranch_Incremental'),
(N'EmployeeSkills Incremental',       N'dbo', N'usp_Sync_EmployeeSkills_Incremental'),
(N'EmployeeStartLeaveDates Incremental', N'dbo', N'usp_Sync_EmployeeStartLeaveDates_Incremental'),

/* Optional (only include if you have these as procs) */
(N'ClientDiary Incremental',          N'dbo', N'usp_Sync_ClientDiary_Incremental'),
(N'EmployeesDiary Incremental',       N'dbo', N'usp_Sync_EmployeesDiary_Incremental'),
(N'ClientAbsences Incremental',       N'dbo', N'usp_Sync_ClientAbsences_Incremental'),
(N'EmployeesAbsences Incremental',    N'dbo', N'usp_Sync_EmployeesAbsences_Incremental')
;

SET @Msg = N'============================================================';
RAISERROR(@Msg, 10, 1) WITH NOWAIT;
SET @Msg = N'DAILY_REFRESH START | DB=DOM_LIVE';
RAISERROR(@Msg, 10, 1) WITH NOWAIT;
SET @Msg = N'Started at (UTC): ' + CONVERT(varchar(33), @StartedAt, 126);
RAISERROR(@Msg, 10, 1) WITH NOWAIT;
SET @Msg = N'============================================================';
RAISERROR(@Msg, 10, 1) WITH NOWAIT;

DECLARE
    @i           int = 1,
    @n           int = (SELECT COUNT(1) FROM @Steps),
    @StepName    nvarchar(200),
    @ProcSchema  sysname,
    @ProcName    sysname,
    @ProcFull    nvarchar(512),
    @ProcForObj  nvarchar(512),
    @objid       int,

    /* Capability flags */
    @HasSummary          bit,
    @HasChunkSize        bit,
    @HasEmitInfo         bit,
    @HasEmitProgress     bit,
    @HasReturnSummaryRow bit,
    @HasLockTimeoutMs    bit,
    @HasUseAppLock       bit,

    @Summary     nvarchar(4000),
    @sql         nvarchar(max),
    @StepStarted datetime2(3),
    @StepEnded   datetime2(3),
    @DurSec      int;

BEGIN TRY
    WHILE @i <= @n
    BEGIN
        SELECT
            @StepName   = StepName,
            @ProcSchema = ProcSchema,
            @ProcName   = ProcName
        FROM @Steps
        WHERE StepOrder = @i;

        SET @ProcFull   = QUOTENAME(@ProcSchema) + N'.' + QUOTENAME(@ProcName);
        SET @ProcForObj = @ProcSchema + N'.' + @ProcName;
        SET @objid      = OBJECT_ID(@ProcForObj, N'P');

        SET @StepStarted = SYSUTCDATETIME();

        SET @Msg = N'--- ' + CONVERT(varchar(10), @i) + N'/' + CONVERT(varchar(10), @n) +
                   N' | ' + @StepName + N' | PROC=' + @ProcFull + N' ---';
        RAISERROR(@Msg, 10, 1) WITH NOWAIT;

        /* Fail fast if proc missing */
        IF @objid IS NULL
        BEGIN
            SET @Msg = N'Missing stored procedure: ' + @ProcFull;
            RAISERROR(@Msg, 10, 1) WITH NOWAIT;

            IF @FailFast = 1
                THROW 50000, 'Missing stored procedure (see prior message).', 1;

            SET @i += 1;
            CONTINUE;
        END;

        /* Detect optional parameters (ONLY pass what exists) */
        SET @HasSummary =
            CASE WHEN EXISTS (SELECT 1 FROM sys.parameters p WHERE p.object_id = @objid AND p.name = N'@Summary')
                 THEN 1 ELSE 0 END;

        SET @HasChunkSize =
            CASE WHEN EXISTS (SELECT 1 FROM sys.parameters p WHERE p.object_id = @objid AND p.name = N'@ChunkSize')
                 THEN 1 ELSE 0 END;

        SET @HasEmitInfo =
            CASE WHEN EXISTS (SELECT 1 FROM sys.parameters p WHERE p.object_id = @objid AND p.name = N'@EmitInfo')
                 THEN 1 ELSE 0 END;

        SET @HasEmitProgress =
            CASE WHEN EXISTS (SELECT 1 FROM sys.parameters p WHERE p.object_id = @objid AND p.name = N'@EmitProgress')
                 THEN 1 ELSE 0 END;

        SET @HasReturnSummaryRow =
            CASE WHEN EXISTS (SELECT 1 FROM sys.parameters p WHERE p.object_id = @objid AND p.name = N'@ReturnSummaryRow')
                 THEN 1 ELSE 0 END;

        SET @HasLockTimeoutMs =
            CASE WHEN EXISTS (SELECT 1 FROM sys.parameters p WHERE p.object_id = @objid AND p.name = N'@LockTimeoutMs')
                 THEN 1 ELSE 0 END;

        SET @HasUseAppLock =
            CASE WHEN EXISTS (SELECT 1 FROM sys.parameters p WHERE p.object_id = @objid AND p.name = N'@UseAppLock')
                 THEN 1 ELSE 0 END;

        SET @Summary = NULL;

        BEGIN TRY
            /* ============================================================
               Special case: Visits Incremental (direct EXEC for NOWAIT)
               ============================================================ */
            IF @ProcSchema = N'dbo' AND @ProcName = N'usp_Sync_Visits_Incremental'
            BEGIN
                /* If proc supports @UseAppLock, we keep it ON (default). */
                /* If proc supports @LockTimeoutMs, pass a sane timeout. */
                /* If proc supports @EmitInfo or @EmitProgress, pass @VisitsEmit */
                /* If proc supports @ChunkSize, pass @VisitsChunkSize */
                /* If proc supports @ReturnSummaryRow, keep it ON for runner usage */
                IF @HasSummary = 1
                BEGIN
                    IF @HasChunkSize = 1
                    BEGIN
                        IF @HasEmitInfo = 1 AND @HasReturnSummaryRow = 1 AND @HasLockTimeoutMs = 1 AND @HasUseAppLock = 1
                        BEGIN
                            EXEC dbo.usp_Sync_Visits_Incremental
                                @ChunkSize        = @VisitsChunkSize,
                                @LockTimeoutMs    = @DefaultLockTimeoutMs,
                                @UseAppLock       = 1,
                                @EmitInfo         = @VisitsEmit,
                                @Summary          = @Summary OUTPUT,
                                @ReturnSummaryRow = 0;
                        END
                        ELSE IF @HasEmitInfo = 1 AND @HasReturnSummaryRow = 1
                        BEGIN
                            EXEC dbo.usp_Sync_Visits_Incremental
                                @ChunkSize        = @VisitsChunkSize,
                                @EmitInfo         = @VisitsEmit,
                                @Summary          = @Summary OUTPUT,
                                @ReturnSummaryRow = 0;
                        END
                        ELSE IF @HasEmitInfo = 1
                        BEGIN
                            EXEC dbo.usp_Sync_Visits_Incremental
                                @ChunkSize = @VisitsChunkSize,
                                @EmitInfo  = @VisitsEmit,
                                @Summary   = @Summary OUTPUT;
                        END
                        ELSE IF @HasEmitProgress = 1
                        BEGIN
                            EXEC dbo.usp_Sync_Visits_Incremental
                                @ChunkSize     = @VisitsChunkSize,
                                @EmitProgress  = @VisitsEmit,
                                @Summary       = @Summary OUTPUT;
                        END
                        ELSE
                        BEGIN
                            EXEC dbo.usp_Sync_Visits_Incremental
                                @ChunkSize = @VisitsChunkSize,
                                @Summary   = @Summary OUTPUT;
                        END
                    END
                    ELSE
                    BEGIN
                        /* no ChunkSize param */
                        IF @HasEmitInfo = 1
                            EXEC dbo.usp_Sync_Visits_Incremental @EmitInfo=@VisitsEmit, @Summary=@Summary OUTPUT;
                        ELSE IF @HasEmitProgress = 1
                            EXEC dbo.usp_Sync_Visits_Incremental @EmitProgress=@VisitsEmit, @Summary=@Summary OUTPUT;
                        ELSE
                            EXEC dbo.usp_Sync_Visits_Incremental @Summary=@Summary OUTPUT;
                    END

                    SET @Msg = ISNULL(@Summary, N'(no summary returned)');
                    RAISERROR(@Msg, 10, 1) WITH NOWAIT;
                END
                ELSE
                BEGIN
                    /* No @Summary available */
                    IF @HasChunkSize = 1
                    BEGIN
                        IF @HasEmitInfo = 1
                            EXEC dbo.usp_Sync_Visits_Incremental @ChunkSize=@VisitsChunkSize, @EmitInfo=@VisitsEmit;
                        ELSE IF @HasEmitProgress = 1
                            EXEC dbo.usp_Sync_Visits_Incremental @ChunkSize=@VisitsChunkSize, @EmitProgress=@VisitsEmit;
                        ELSE
                            EXEC dbo.usp_Sync_Visits_Incremental @ChunkSize=@VisitsChunkSize;
                    END
                    ELSE
                    BEGIN
                        EXEC dbo.usp_Sync_Visits_Incremental;
                    END

                    SET @Msg = N'(proc does not expose @Summary)';
                    RAISERROR(@Msg, 10, 1) WITH NOWAIT;
                END
            END
            ELSE
            BEGIN
                /* ============================================================
                   Generic call path (dynamic SQL, only pass supported params)
                   ============================================================ */

                SET @sql = N'EXEC ' + @ProcFull + N' ';

                /* Build param list deterministically */
                DECLARE @sep nvarchar(2) = N'';
                IF @HasChunkSize = 1
                BEGIN
                    SET @sql += @sep + N'@ChunkSize = @pChunkSize';
                    SET @sep = N', ';
                END

                IF @HasLockTimeoutMs = 1
                BEGIN
                    SET @sql += @sep + N'@LockTimeoutMs = @pLockTimeoutMs';
                    SET @sep = N', ';
                END

                IF @HasUseAppLock = 1
                BEGIN
                    SET @sql += @sep + N'@UseAppLock = @pUseAppLock';
                    SET @sep = N', ';
                END

                /* Emit param name differs across procs; support both */
                IF @HasEmitInfo = 1
                BEGIN
                    SET @sql += @sep + N'@EmitInfo = @pEmit';
                    SET @sep = N', ';
                END
                ELSE IF @HasEmitProgress = 1
                BEGIN
                    SET @sql += @sep + N'@EmitProgress = @pEmit';
                    SET @sep = N', ';
                END

                IF @HasReturnSummaryRow = 1
                BEGIN
                    SET @sql += @sep + N'@ReturnSummaryRow = @pReturnSummaryRow';
                    SET @sep = N', ';
                END

                IF @HasSummary = 1
                BEGIN
                    SET @sql += @sep + N'@Summary = @pSummary OUTPUT';
                    SET @sep = N', ';
                END

                /* If no params added, remove trailing space (harmless anyway) */
                SET @sql += N';';

                EXEC sys.sp_executesql
                    @sql,
                    N'@pChunkSize int,
                      @pLockTimeoutMs int,
                      @pUseAppLock bit,
                      @pEmit bit,
                      @pReturnSummaryRow bit,
                      @pSummary nvarchar(4000) OUTPUT',
                    @pChunkSize        = @DefaultChunkSize,
                    @pLockTimeoutMs    = @DefaultLockTimeoutMs,
                    @pUseAppLock       = 1,
                    @pEmit             = @DefaultEmit,
                    @pReturnSummaryRow = 0,
                    @pSummary          = @Summary OUTPUT;

                IF @HasSummary = 1
                BEGIN
                    SET @Msg = ISNULL(@Summary, N'(no summary returned)');
                    RAISERROR(@Msg, 10, 1) WITH NOWAIT;
                END
                ELSE
                BEGIN
                    SET @Msg = N'(proc does not expose @Summary)';
                    RAISERROR(@Msg, 10, 1) WITH NOWAIT;
                END
            END

            SET @StepEnded = SYSUTCDATETIME();
            SET @DurSec = DATEDIFF(SECOND, @StepStarted, @StepEnded);

            SET @Msg = N'Step completed (UTC): start=' + CONVERT(varchar(33), @StepStarted, 126) +
                       N' end=' + CONVERT(varchar(33), @StepEnded, 126) +
                       N' dur_sec=' + CONVERT(varchar(20), @DurSec);
            RAISERROR(@Msg, 10, 1) WITH NOWAIT;
        END TRY
        BEGIN CATCH
            DECLARE @En int = ERROR_NUMBER();
            DECLARE @Es int = ERROR_SEVERITY();
            DECLARE @Est int = ERROR_STATE();
            DECLARE @El int = ERROR_LINE();
            DECLARE @Em nvarchar(2047) = ERROR_MESSAGE();

            SET @Msg = N'*** STEP FAILED: ' + @StepName + N' | PROC=' + @ProcFull;
            RAISERROR(@Msg, 10, 1) WITH NOWAIT;

            SET @Msg = N'*** ERROR: ' + ISNULL(@Em, N'(null)');
            RAISERROR(@Msg, 10, 1) WITH NOWAIT;

            SET @Msg = N'*** Number=' + CONVERT(varchar(20), @En) +
                       N' Severity=' + CONVERT(varchar(20), @Es) +
                       N' State=' + CONVERT(varchar(20), @Est) +
                       N' Line=' + CONVERT(varchar(20), @El);
            RAISERROR(@Msg, 10, 1) WITH NOWAIT;

            THROW;
        END CATCH;

        SET @i += 1;
    END;

    SET @EndedAt = SYSUTCDATETIME();

    SET @Msg = N'============================================================';
    RAISERROR(@Msg, 10, 1) WITH NOWAIT;

    SET @Msg = N'DAILY_REFRESH END';
    RAISERROR(@Msg, 10, 1) WITH NOWAIT;

    SET @Msg = N'Ended at (UTC): ' + CONVERT(varchar(33), @EndedAt, 126);
    RAISERROR(@Msg, 10, 1) WITH NOWAIT;

    SET @Msg = N'Duration (sec): ' + CONVERT(varchar(20), DATEDIFF(SECOND, @StartedAt, @EndedAt));
    RAISERROR(@Msg, 10, 1) WITH NOWAIT;

    SET @Msg = N'============================================================';
    RAISERROR(@Msg, 10, 1) WITH NOWAIT;
END TRY
BEGIN CATCH
    DECLARE @En2 int = ERROR_NUMBER();
    DECLARE @Es2 int = ERROR_SEVERITY();
    DECLARE @Est2 int = ERROR_STATE();
    DECLARE @El2 int = ERROR_LINE();
    DECLARE @Em2 nvarchar(2047) = ERROR_MESSAGE();

    SET @Msg = N'============================================================';
    RAISERROR(@Msg, 10, 1) WITH NOWAIT;

    SET @Msg = N'DAILY_REFRESH FAILED';
    RAISERROR(@Msg, 10, 1) WITH NOWAIT;

    SET @Msg = N'Error: ' + ISNULL(@Em2, N'(null)');
    RAISERROR(@Msg, 10, 1) WITH NOWAIT;

    SET @Msg = N'Number=' + CONVERT(varchar(20), @En2) +
               N' Severity=' + CONVERT(varchar(20), @Es2) +
               N' State=' + CONVERT(varchar(20), @Est2) +
               N' Line=' + CONVERT(varchar(20), @El2);
    RAISERROR(@Msg, 10, 1) WITH NOWAIT;

    SET @Msg = N'============================================================';
    RAISERROR(@Msg, 10, 1) WITH NOWAIT;

    THROW;
END CATCH;
GO
