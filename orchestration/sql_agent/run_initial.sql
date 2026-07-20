/*
run_initial.sql (PURE T-SQL)
Purpose:
  Bootstrap run for initial loads by executing the Initial procs in the correct order.

Key behavior:
  - Calls only procs that exist (fails fast by default)
  - Passes @Summary only when the proc accepts it
  - Streams progress output immediately (RAISERROR(@msg, 10, 1) WITH NOWAIT) - SQL 2016 safe
  - Step-level error context before re-throw
  - SPECIAL CASE:
      Visits Initial is called via direct EXEC (not dynamic SQL) so:
        - any NOWAIT output has the best chance to stream
        - @ChunkSize and @EmitProgress are passed
      And we print a helper query for dbo.ETL_BatchProgress (if you implement it in Visits)

How to run:
  - SQL Agent job step: Transact-SQL script (T-SQL)
  - No SQLCMD mode required
  - When run manually, the configured daily SQL Agent job is disabled before
    the initial load and re-enabled only after a successful completion.
  - Do not run this script as a step inside the daily job itself.

SQL Server:
  - Compatible with SQL Server 2016 SP3 (13.x)
*/

USE [DOM_LIVE];
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @FailFast bit = 1;   -- 1 = missing proc stops run, 0 = missing proc is logged + skipped

/* Daily-job protection during the destructive initial load */
DECLARE @DailyJobName sysname = N'update new db';
DECLARE @ProtectDailyJob bit = 1;
DECLARE @ReEnableDailyJobOnSuccess bit = 0; -- manually re-enable after validation

/* Visits tuning (Option A) */
DECLARE @VisitsChunkSize int = 100000;  -- e.g. 5000 (more chatter) / 100000 (reasonable) / 1000000 (quiet)
DECLARE @VisitsEmitProgress bit = 1;    -- 1 = progress on, 0 = off

DECLARE @StartedAt datetime2(3) = SYSUTCDATETIME();
DECLARE @EndedAt   datetime2(3);
DECLARE @Msg       nvarchar(2047);

DECLARE @DailyJobId uniqueidentifier = NULL;
DECLARE @DailyJobWasEnabled bit = 0;
DECLARE @AgentSessionId int = NULL;

SET @Msg = N'============================================================';
RAISERROR(@Msg, 10, 1) WITH NOWAIT;
SET @Msg = N'RUN_INITIAL START | DB=DOM_LIVE';
RAISERROR(@Msg, 10, 1) WITH NOWAIT;
SET @Msg = N'Started at (UTC): ' + CONVERT(varchar(33), @StartedAt, 126);
RAISERROR(@Msg, 10, 1) WITH NOWAIT;
SET @Msg = N'============================================================';
RAISERROR(@Msg, 10, 1) WITH NOWAIT;

DECLARE @Steps TABLE
(
    StepOrder  int IDENTITY(1,1) NOT NULL,
    StepName   nvarchar(200) NOT NULL,
    ProcSchema sysname NOT NULL,
    ProcName   sysname NOT NULL
);

/*
Choose your order here.

I’ve moved Clients+Visits BEFORE EmployeeBranch, because your EmployeeBranch initial can optionally
use Visits for better date shaping. If your EmployeeBranch proc is written to not require Visits,
this ordering is still safe.
*/
INSERT INTO @Steps (StepName, ProcSchema, ProcName)
VALUES
(N'Branch Initial',                  N'dbo', N'usp_Sync_Branch_Initial'),
(N'Employees Initial',               N'dbo', N'usp_Sync_Employees_Initial'),
(N'Clients Initial',                 N'dbo', N'usp_Sync_Clients_Initial'),
(N'Visits Initial',                  N'dbo', N'usp_Sync_Visits_Initial'),
(N'EmployeeBranch Initial',          N'dbo', N'usp_Sync_EmployeeBranch_Initial'),
(N'EmployeeSkills Initial',          N'dbo', N'usp_Sync_EmployeeSkills_Initial'),
(N'EmployeeStartLeaveDates Initial', N'dbo', N'usp_Sync_EmployeeStartLeaveDates_Initial'),
(N'ClientDiary Initial',             N'dbo', N'usp_Sync_ClientDiary_Initial'),
(N'EmployeesDiary Initial',          N'dbo', N'usp_Sync_EmployeesDiary_Initial'),
(N'ClientAbsences Initial',          N'dbo', N'usp_Sync_ClientAbsences_Initial'),
(N'EmployeesAbsences Initial',       N'dbo', N'usp_Sync_EmployeesAbsences_Initial');

DECLARE
    @i           int = 1,
    @n           int = (SELECT COUNT(1) FROM @Steps),
    @StepName    nvarchar(200),
    @ProcSchema  sysname,
    @ProcName    sysname,
    @ProcFull    nvarchar(512),
    @ProcForObj  nvarchar(512),
    @objid       int,
    @HasSummary  bit,
    @Summary     nvarchar(4000),
    @sql         nvarchar(max),
    @StepStarted datetime2(3),
    @StepEnded   datetime2(3),
    @DurSec      int;

BEGIN TRY
    /*
       Prevent the scheduled incremental refresh from running against tables
       that the initial procedures drop and recreate.  Disable first so a new
       schedule tick cannot start while the current run is being stopped.
    */
    IF @ProtectDailyJob = 1
    BEGIN
        IF APP_NAME() LIKE N'SQLAgent - TSQL JobStep%'
            THROW 50001, 'run_initial.sql must be started manually, not from a SQL Agent job step.', 1;

        SELECT
            @DailyJobId = job_id,
            @DailyJobWasEnabled = CONVERT(bit, enabled)
        FROM msdb.dbo.sysjobs
        WHERE name = @DailyJobName;

        IF @DailyJobId IS NULL
            THROW 50002, 'Configured daily SQL Agent job was not found.', 1;

        EXEC msdb.dbo.sp_update_job
            @job_id = @DailyJobId,
            @enabled = 0;

        SELECT @AgentSessionId = MAX(session_id)
        FROM msdb.dbo.syssessions;

        IF EXISTS
        (
            SELECT 1
            FROM msdb.dbo.sysjobactivity ja
            WHERE ja.session_id = @AgentSessionId
              AND ja.job_id = @DailyJobId
              AND ja.start_execution_date IS NOT NULL
              AND ja.stop_execution_date IS NULL
        )
        BEGIN
            RAISERROR('Stopping and waiting for daily job: %s', 10, 1, @DailyJobName) WITH NOWAIT;

            EXEC msdb.dbo.sp_stop_job @job_id = @DailyJobId;

            DECLARE @StopWaitStartedAt datetime2(3) = SYSUTCDATETIME();

            WHILE EXISTS
            (
                SELECT 1
                FROM msdb.dbo.sysjobactivity ja
                WHERE ja.session_id = @AgentSessionId
                  AND ja.job_id = @DailyJobId
                  AND ja.start_execution_date IS NOT NULL
                  AND ja.stop_execution_date IS NULL
            )
            BEGIN
                IF DATEDIFF(SECOND, @StopWaitStartedAt, SYSUTCDATETIME()) >= 120
                    THROW 50003, 'Daily SQL Agent job did not stop within 120 seconds; it remains disabled.', 1;

                WAITFOR DELAY '00:00:01';
            END;
        END;

        RAISERROR('Daily job disabled for initial load: %s', 10, 1, @DailyJobName) WITH NOWAIT;
    END;

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

        /* Detect whether proc accepts @Summary */
        SET @HasSummary =
            CASE WHEN EXISTS
            (
                SELECT 1
                FROM sys.parameters p
                WHERE p.object_id = @objid
                  AND p.name = N'@Summary'
            )
            THEN 1 ELSE 0 END;

        SET @Summary = NULL;

        BEGIN TRY
            /* SPECIAL CASE: Visits Initial (direct EXEC; passes chunk/progress) */
            IF @ProcSchema = N'dbo' AND @ProcName = N'usp_Sync_Visits_Initial'
            BEGIN
                IF @HasSummary = 1
                BEGIN
                    EXEC dbo.usp_Sync_Visits_Initial
                        @ChunkSize = @VisitsChunkSize,
                        @EmitProgress = @VisitsEmitProgress,
                        @Summary = @Summary OUTPUT;

                    SET @Msg = ISNULL(@Summary, N'(no summary returned)');
                    RAISERROR(@Msg, 10, 1) WITH NOWAIT;
                END
                ELSE
                BEGIN
                    EXEC dbo.usp_Sync_Visits_Initial
                        @ChunkSize = @VisitsChunkSize,
                        @EmitProgress = @VisitsEmitProgress;

                    SET @Msg = N'(proc does not expose @Summary)';
                    RAISERROR(@Msg, 10, 1) WITH NOWAIT;
                END

                /* If you use dbo.ETL_BatchProgress in Visits, this is how to monitor it */
                SET @Msg = N'Monitor Visits batches (if enabled): SELECT TOP (200) LoggedAtUTC,BatchNo,InsertedBatch,InsertedTotal,RemainingKeys,Message,RunId FROM dbo.ETL_BatchProgress WHERE ProcessName=''Visits'' ORDER BY LoggedAtUTC DESC;';
                RAISERROR(@Msg, 10, 1) WITH NOWAIT;
            END
            ELSE
            BEGIN
                /* Generic calls for everything else */
                IF @HasSummary = 1
                BEGIN
                    SET @sql = N'EXEC ' + @ProcFull + N' @Summary = @Summary OUTPUT;';
                    EXEC sys.sp_executesql
                        @sql,
                        N'@Summary nvarchar(4000) OUTPUT',
                        @Summary = @Summary OUTPUT;

                    SET @Msg = ISNULL(@Summary, N'(no summary returned)');
                    RAISERROR(@Msg, 10, 1) WITH NOWAIT;
                END
                ELSE
                BEGIN
                    SET @sql = N'EXEC ' + @ProcFull + N';';
                    EXEC sys.sp_executesql @sql;

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

    IF @ProtectDailyJob = 1
       AND @ReEnableDailyJobOnSuccess = 1
       AND @DailyJobWasEnabled = 1
       AND @DailyJobId IS NOT NULL
    BEGIN
        EXEC msdb.dbo.sp_update_job
            @job_id = @DailyJobId,
            @enabled = 1;

        RAISERROR('Daily job re-enabled after successful initial load: %s', 10, 1, @DailyJobName) WITH NOWAIT;
    END;

    SET @Msg = N'============================================================';
    RAISERROR(@Msg, 10, 1) WITH NOWAIT;

    SET @Msg = N'RUN_INITIAL END';
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

    SET @Msg = N'RUN_INITIAL FAILED';
    RAISERROR(@Msg, 10, 1) WITH NOWAIT;

    IF @ProtectDailyJob = 1 AND @DailyJobId IS NOT NULL
    BEGIN
        SET @Msg = N'Daily job remains disabled after initial-load failure: ' + @DailyJobName;
        RAISERROR(@Msg, 10, 1) WITH NOWAIT;
    END;

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
