/*
Purpose:
    Remove Visits older than the configured retention window.

Run type:
    Maintenance / retention purge.

Recommended schedule:
    Weekly, outside the daily refresh window.

Safety:
    Deletes in small autocommit batches and uses the same application lock as
    usp_Sync_Visits_Incremental so the two processes cannot overlap.
*/

USE [DOM_LIVE];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Purge_Visits_Expired
    @RetentionYears  int            = 3,
    @BatchSize       int            = 10000,
    @LockTimeoutMs   int            = 600000,
    @UseAppLock      bit            = 1,
    @EmitInfo        bit            = 1,
    @Summary         nvarchar(4000) = NULL OUTPUT,
    @ReturnSummaryRow bit           = 1,
    @PreviewOnly     bit            = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET ANSI_WARNINGS ON;

    DECLARE @Process      sysname      = N'VisitsPurge';
    DECLARE @RunStartedAt datetime2(3) = SYSUTCDATETIME();
    DECLARE @CutoffUTC    datetime2(3);
    DECLARE @CutoffText   varchar(33);
    DECLARE @BatchDeleted int;
    DECLARE @TotalDeleted bigint = 0;
    DECLARE @CandidateRows bigint = 0;
    DECLARE @BatchNo      int = 0;
    DECLARE @LockHeld     bit = 0;
    DECLARE @LockResult   int;
    DECLARE @LockResource sysname = N'DOM_LIVE:Sync:Visits';
    DECLARE @LockOwner    sysname = N'Session';
    DECLARE @DbPrincipal  sysname = N'dbo';

    IF @RetentionYears IS NULL OR @RetentionYears <= 0
        THROW 50010, 'Visits purge: @RetentionYears must be greater than zero.', 1;

    IF @BatchSize IS NULL OR @BatchSize <= 0
        THROW 50011, 'Visits purge: @BatchSize must be greater than zero.', 1;

    IF @LockTimeoutMs IS NULL OR @LockTimeoutMs < 0
        THROW 50012, 'Visits purge: @LockTimeoutMs must be zero or greater.', 1;

    SET @CutoffUTC = DATEADD(YEAR, -@RetentionYears, SYSUTCDATETIME());
    SET @CutoffText = CONVERT(varchar(33), @CutoffUTC, 126);

    BEGIN TRY
        IF @UseAppLock = 1
        BEGIN
            EXEC @LockResult = sys.sp_getapplock
                @Resource    = @LockResource,
                @LockMode    = 'Exclusive',
                @LockOwner   = @LockOwner,
                @DbPrincipal = @DbPrincipal,
                @LockTimeout = @LockTimeoutMs;

            IF @LockResult NOT IN (0, 1)
                THROW 50014, 'Visits purge: could not acquire the Visits application lock.', 1;

            SET @LockHeld = 1;
        END;

        /* Check after the lock so an initial Visits rebuild cannot race this check. */
        IF OBJECT_ID(N'dbo.tbl_Visits', N'U') IS NULL
            THROW 50013, 'Visits purge: dbo.tbl_Visits does not exist.', 1;

        IF @PreviewOnly = 1
        BEGIN
            SELECT @CandidateRows = COUNT_BIG(*)
            FROM dbo.tbl_Visits
            WHERE Actual_Visit_Start_Date_Time < @CutoffUTC;

            SET @Summary = CONCAT(
                N'Visits purge preview; ', CAST(@CandidateRows AS nvarchar(30)),
                N' rows are older than ', @CutoffText, N' UTC. No rows deleted.'
            );

            IF @ReturnSummaryRow = 1
                SELECT
                    N'Preview' AS Stage,
                    @CutoffUTC AS CutoffUTC,
                    @CandidateRows AS CandidateRows,
                    @Summary AS Summary;

            IF @LockHeld = 1
                EXEC sys.sp_releaseapplock
                    @Resource = @LockResource,
                    @LockOwner = @LockOwner,
                    @DbPrincipal = @DbPrincipal;

            RETURN 0;
        END;

        IF @EmitInfo = 1
            RAISERROR('Visits purge started. Cutoff UTC=%s, batch size=%d',
                      10, 1, @CutoffText, @BatchSize) WITH NOWAIT;

        SET @BatchDeleted = 1;

        WHILE @BatchDeleted > 0
        BEGIN
            DELETE TOP (@BatchSize)
            FROM dbo.tbl_Visits
            WHERE Actual_Visit_Start_Date_Time < @CutoffUTC;

            SET @BatchDeleted = @@ROWCOUNT;
            SET @TotalDeleted += @BatchDeleted;

            IF @BatchDeleted > 0
            BEGIN
                SET @BatchNo += 1;

                IF @EmitInfo = 1
                    RAISERROR('Visits purge batch %d: deleted=%d (running total=%I64d)',
                              10, 1, @BatchNo, @BatchDeleted, @TotalDeleted) WITH NOWAIT;
            END;
        END;

        SET @Summary = CONCAT(
            N'Visits purge completed; deleted ', CAST(@TotalDeleted AS nvarchar(30)),
            N' rows older than ', CONVERT(varchar(33), @CutoffUTC, 126), N' UTC.'
        );

        IF @ReturnSummaryRow = 1
            SELECT N'Purge' AS Stage, @Summary AS Summary;

        IF @LockHeld = 1
            EXEC sys.sp_releaseapplock
                @Resource = @LockResource,
                @LockOwner = @LockOwner,
                @DbPrincipal = @DbPrincipal;

        RETURN 0;
    END TRY
    BEGIN CATCH
        IF @LockHeld = 1
            EXEC sys.sp_releaseapplock
                @Resource = @LockResource,
                @LockOwner = @LockOwner,
                @DbPrincipal = @DbPrincipal;

        SET @Summary = CONCAT(N'Visits purge failed: ', ERROR_MESSAGE());

        IF @ReturnSummaryRow = 1
            SELECT N'Purge' AS Stage, @Summary AS Summary;

        THROW;
    END CATCH;
END;
GO
