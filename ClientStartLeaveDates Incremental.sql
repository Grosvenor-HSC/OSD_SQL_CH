CREATE OR ALTER PROCEDURE [dbo].[usp_Sync_ClientStartLeaveDates_Incremental]
    @ChunkSize         int  = 100000,
    @LockTimeoutMs     int  = 60000,
    @UseAppLock        bit  = 1,
    @EmitInfo          bit  = 0,                 -- quiet by default
    @Summary           nvarchar(4000) = NULL OUTPUT,
    @ReturnSummaryRow  bit  = 1                  -- return Stage/Summary row
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Process       sysname      = N'ClientStartLeaveDates';
    DECLARE @RunStartedAt  datetime2(3) = SYSUTCDATETIME();
    DECLARE @StartIso      varchar(33)  = CONVERT(varchar(33), @RunStartedAt, 126);
    DECLARE @EndUTC        datetime2(3);
    DECLARE @EndIso        varchar(33);
    DECLARE @DurationSec   int;

    -- Concurrency guard
    DECLARE @LockResource sysname = N'DOM_LIVE:Sync:ClientStartLeaveDates';
    DECLARE @lockResult  int;
    DECLARE @lockHeld    bit = 0;

    IF @UseAppLock = 1
    BEGIN
        EXEC @lockResult = sys.sp_getapplock
            @Resource=@LockResource, @LockMode='Exclusive',
            @LockOwner='Session', @DbPrincipal='dbo', @LockTimeout=@LockTimeoutMs;
        IF @lockResult NOT IN (0,1)
        BEGIN
            IF @EmitInfo=1 RAISERROR('Could not acquire %s (rc=%d).',16,1,@LockResource,@lockResult);
            SET @Summary = N'ClientStartLeaveDates incremental failed: could not acquire applock.';
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            RETURN @lockResult;
        END
        SET @lockHeld = 1;
    END

    BEGIN TRY
        -- 1) Preconditions & bounds
        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_databases WHERE database_id = DB_ID())
        BEGIN
            IF @EmitInfo=1 RAISERROR('Change Tracking is not enabled at the database level.',16,1);
            SET @Summary = N'ClientStartLeaveDates incremental failed: CT not enabled at DB level.';
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner='Session', @DbPrincipal='dbo';
            RETURN -100;
        END

        DECLARE @CT_Clients bit =
            CASE WHEN EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.tbl_Clients')) THEN 1 ELSE 0 END;
        DECLARE @CT_Visits  bit =
            CASE WHEN EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.tbl_Visits'))  THEN 1 ELSE 0 END;

        IF @CT_Clients = 0
        BEGIN
            IF @EmitInfo=1 RAISERROR('CT not enabled on dbo.tbl_Clients.',16,1);
            SET @Summary = N'ClientStartLeaveDates incremental failed: CT not enabled on dbo.tbl_Clients.';
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner='Session', @DbPrincipal='dbo';
            RETURN -210;
        END

        IF @CT_Visits = 0 AND @EmitInfo=1
            RAISERROR('Note: CT not enabled on dbo.tbl_Visits; visit-only changes will be ignored.', 0, 1) WITH NOWAIT;

        -- Watermark
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

        DECLARE @MinValid bigint =
        (
            SELECT MAX(CHANGE_TRACKING_MIN_VALID_VERSION(object_id))
            FROM sys.change_tracking_tables
            WHERE object_id IN (
                OBJECT_ID(N'dbo.tbl_Clients'),
                CASE WHEN @CT_Visits=1 THEN OBJECT_ID(N'dbo.tbl_Visits') ELSE NULL END
            )
        );

        IF @MinValid IS NOT NULL AND @LastSyncVersion < @MinValid
        BEGIN
            IF @EmitInfo=1 RAISERROR('Watermark (%I64d) < CT min valid (%I64d). Re-baseline required.',16,1,@LastSyncVersion,@MinValid);
            SET @Summary = CONCAT(N'ClientStartLeaveDates incremental failed: watermark ', @LastSyncVersion, N' < min valid ', @MinValid, N'.');
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner='Session', @DbPrincipal='dbo';
            RETURN -200;
        END

        DECLARE @ToVersion bigint = CHANGE_TRACKING_CURRENT_VERSION();

        IF @EmitInfo=1
        BEGIN
            RAISERROR('ClientStartLeaveDates CT incremental window:', 0, 1) WITH NOWAIT;
            RAISERROR('  From = %I64d', 0, 1, @LastSyncVersion) WITH NOWAIT;
            RAISERROR('  To   = %I64d', 0, 1, @ToVersion) WITH NOWAIT;
        END

        -- 2) Build changed ClientReference set
        IF OBJECT_ID('tempdb..#Changed') IS NOT NULL DROP TABLE #Changed;
        CREATE TABLE #Changed (ClientReference varchar(50) NOT NULL PRIMARY KEY);

        INSERT INTO #Changed(ClientReference)
        SELECT DISTINCT CAST(c.ClientReference AS varchar(50))
        FROM CHANGETABLE(CHANGES dbo.tbl_Clients, @LastSyncVersion) x
        JOIN dbo.tbl_Clients c ON c.ClientReference = x.ClientReference
        WHERE x.SYS_CHANGE_VERSION <= @ToVersion;

        IF @CT_Visits = 1
        BEGIN
            DECLARE @Join NVARCHAR(MAX);
            ;WITH pk AS (
                SELECT c.name AS colname, ic.key_ordinal
                FROM sys.indexes i
                JOIN sys.index_columns ic ON i.object_id=ic.object_id AND i.index_id=ic.index_id
                JOIN sys.columns c ON c.object_id=ic.object_id AND c.column_id=ic.column_id
                WHERE i.object_id = OBJECT_ID(N'dbo.tbl_Visits') AND i.is_primary_key = 1
            )
            SELECT @Join = STUFF((
                SELECT ' AND v.' + QUOTENAME(colname) + ' = x.' + QUOTENAME(colname)
                FROM pk
                ORDER BY key_ordinal
                FOR XML PATH(''), TYPE).value('.','nvarchar(max)'),1,5,'');

            IF @Join IS NOT NULL AND LEN(@Join)>0
            BEGIN
                DECLARE @sql NVARCHAR(MAX) = N'
INSERT INTO #Changed(ClientReference)
SELECT DISTINCT CAST(v.ClientReference AS varchar(50))
FROM CHANGETABLE(CHANGES dbo.tbl_Visits, @fromV) AS x
JOIN dbo.tbl_Visits AS v ON ' + @Join + N'
WHERE x.SYS_CHANGE_VERSION <= @toV
  AND NOT EXISTS (SELECT 1 FROM #Changed z WHERE z.ClientReference = v.ClientReference);';
                EXEC sp_executesql @sql, N'@fromV bigint, @toV bigint', @fromV=@LastSyncVersion, @toV=@ToVersion;
            END
            ELSE IF @EmitInfo=1 RAISERROR('tbl_Visits has no PK; skipping visit change detection.',0,1) WITH NOWAIT;
        END

        DECLARE @ToProcess int = (SELECT COUNT(*) FROM #Changed);
        IF @EmitInfo=1 RAISERROR('Changed clients to process: %d', 0, 1, @ToProcess) WITH NOWAIT;

        IF @ToProcess = 0
        BEGIN
            UPDATE dbo.CT_Watermark
              SET LastSyncVersion = @ToVersion, LastSyncTime = SYSUTCDATETIME()
            WHERE ProcessName = @Process;

            SET @EndUTC = SYSUTCDATETIME();
            SET @EndIso = CONVERT(varchar(33), @EndUTC, 126);
            SET @DurationSec = DATEDIFF(SECOND, @RunStartedAt, @EndUTC);

            SET @Summary = CONCAT(
                N'ClientStartLeaveDates incremental started ', @StartIso, N' UTC; ended ', @EndIso,
                N' UTC; inserted 0, updated 0, deleted 0; advanced watermark to ',
                CAST(@ToVersion AS nvarchar(30)), N'; duration=', @DurationSec, N' sec.'
            );

            IF @EmitInfo=1 RAISERROR('No changes. Watermark advanced.', 0, 1) WITH NOWAIT;
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner='Session', @DbPrincipal='dbo';
            RETURN 0;
        END

        -- 3) Chunked UPSERT
        DECLARE @TotalInserted bigint = 0, @TotalUpdated bigint = 0, @TotalDeleted int = 0;  -- @TotalDeleted declared ONCE

        WHILE EXISTS (SELECT 1 FROM #Changed)
        BEGIN
            IF OBJECT_ID('tempdb..#Next') IS NOT NULL DROP TABLE #Next;
            CREATE TABLE #Next (ClientReference varchar(50) NOT NULL PRIMARY KEY);

            INSERT INTO #Next(ClientReference)
            SELECT TOP (@ChunkSize) ClientReference
            FROM #Changed
            ORDER BY ClientReference;

            IF OBJECT_ID('tempdb..#ActLog') IS NOT NULL DROP TABLE #ActLog;
            CREATE TABLE #ActLog(Action nvarchar(10) NOT NULL);

            SET DATEFIRST 1;

            ;WITH Agg AS (
                SELECT
                    c.ClientReference,
                    c.BranchReference,
                    MIN(c.ClientStartDate) AS MinClientStartDate,
                    MAX(c.ClientLeaveDate) AS MaxClientLeaveDate,
                    MIN(v.VisitStartDate)  AS MinVisitStartDate,
                    MAX(c.ClientStatus)    AS ClientStatus
                FROM dbo.tbl_Clients c
                LEFT JOIN dbo.tbl_Visits v
                  ON v.ClientReference = c.ClientReference
                JOIN #Next n
                  ON n.ClientReference = c.ClientReference
                GROUP BY c.ClientReference, c.BranchReference, c.ClientStatus
            ),
            Final AS (
                SELECT
                    ClientReference,
                    BranchReference,
                    CASE 
                        WHEN MinClientStartDate IS NULL AND MinVisitStartDate IS NOT NULL THEN MinVisitStartDate
                        WHEN MinClientStartDate IS NOT NULL AND MinVisitStartDate IS NULL THEN MinClientStartDate
                        WHEN MinClientStartDate >= MinVisitStartDate THEN MinVisitStartDate
                        ELSE MinClientStartDate
                    END AS GLOBAL_START_DATE,
                    MaxClientLeaveDate AS GLOBAL_END_DATE,
                    ClientStatus       AS GLOBAL_STATUS
                FROM Agg
            ),
            Shaped AS (
                SELECT
                    f.ClientReference,
                    f.BranchReference,
                    f.GLOBAL_START_DATE,
                    CASE WHEN f.GLOBAL_START_DATE IS NOT NULL
                         THEN DATEADD(DAY, 1 - DATEPART(WEEKDAY, f.GLOBAL_START_DATE), f.GLOBAL_START_DATE) END AS GLOBAL_WEEK_START,
                    MONTH(f.GLOBAL_START_DATE)  AS GLOBAL_START_MONTH,
                    YEAR(f.GLOBAL_START_DATE)   AS GLOBAL_START_YEAR,
                    f.GLOBAL_END_DATE,
                    CASE WHEN f.GLOBAL_END_DATE IS NOT NULL
                         THEN DATEADD(DAY, 1 - DATEPART(WEEKDAY, f.GLOBAL_END_DATE), f.GLOBAL_END_DATE) END AS GLOBAL_WEEK_END,
                    MONTH(f.GLOBAL_END_DATE) AS GLOBAL_END_MONTH,
                    YEAR(f.GLOBAL_END_DATE)  AS GLOBAL_END_YEAR,
                    ISNULL(CONVERT(DATE, f.GLOBAL_END_DATE), CONVERT(DATE, GETDATE())) AS UPDATED_LEAVE_DATES,
                    f.GLOBAL_STATUS
                FROM Final f
            )
            MERGE dbo.tbl_ClientStartLeaveDates AS tgt
            USING Shaped AS src
                ON tgt.ClientReference = src.ClientReference
            WHEN MATCHED THEN
                UPDATE SET
                    tgt.BranchReference     = src.BranchReference,
                    tgt.GLOBAL_START_DATE   = src.GLOBAL_START_DATE,
                    tgt.GLOBAL_WEEK_START   = src.GLOBAL_WEEK_START,
                    tgt.GLOBAL_START_MONTH  = src.GLOBAL_START_MONTH,
                    tgt.GLOBAL_START_YEAR   = src.GLOBAL_START_YEAR,
                    tgt.GLOBAL_END_DATE     = src.GLOBAL_END_DATE,
                    tgt.GLOBAL_WEEK_END     = src.GLOBAL_WEEK_END,
                    tgt.GLOBAL_END_MONTH    = src.GLOBAL_END_MONTH,
                    tgt.GLOBAL_END_YEAR     = src.GLOBAL_END_YEAR,
                    tgt.UPDATED_LEAVE_DATES = src.UPDATED_LEAVE_DATES,
                    tgt.GLOBAL_STATUS       = src.GLOBAL_STATUS
            WHEN NOT MATCHED BY TARGET THEN
                INSERT (ClientReference, BranchReference,
                        GLOBAL_START_DATE, GLOBAL_WEEK_START, GLOBAL_START_MONTH, GLOBAL_START_YEAR,
                        GLOBAL_END_DATE,   GLOBAL_WEEK_END,   GLOBAL_END_MONTH,   GLOBAL_END_YEAR,
                        UPDATED_LEAVE_DATES, GLOBAL_STATUS)
                VALUES (src.ClientReference, src.BranchReference,
                        src.GLOBAL_START_DATE, src.GLOBAL_WEEK_START, src.GLOBAL_START_MONTH, src.GLOBAL_START_YEAR,
                        src.GLOBAL_END_DATE,   src.GLOBAL_WEEK_END,   src.GLOBAL_END_MONTH,   src.GLOBAL_END_YEAR,
                        src.UPDATED_LEAVE_DATES, src.GLOBAL_STATUS)
            OUTPUT $action INTO #ActLog(Action);

            DECLARE @i int = 0, @u int = 0;
            SELECT @i = SUM(CASE WHEN Action='INSERT' THEN 1 ELSE 0 END),
                   @u = SUM(CASE WHEN Action='UPDATE' THEN 1 ELSE 0 END)
            FROM #ActLog;

            SET @TotalInserted += ISNULL(@i,0);
            SET @TotalUpdated  += ISNULL(@u,0);

            IF @EmitInfo=1 RAISERROR('Chunk upserted: inserted=%d updated=%d (running %d / %d)',0,1,@i,@u,@TotalInserted,@TotalUpdated) WITH NOWAIT;

            DELETE c
            FROM #Changed c
            JOIN #Next n ON n.ClientReference = c.ClientReference;
        END

        -- 4) Apply deletes (from tbl_Clients)
        IF OBJECT_ID('tempdb..#DelLog') IS NOT NULL DROP TABLE #DelLog;
        CREATE TABLE #DelLog(ClientReference varchar(50) NOT NULL);

        DELETE t
        OUTPUT DELETED.ClientReference INTO #DelLog(ClientReference)
        FROM dbo.tbl_ClientStartLeaveDates t
        JOIN (
            SELECT x.ClientReference
            FROM CHANGETABLE(CHANGES dbo.tbl_Clients, @LastSyncVersion) x
            WHERE x.SYS_CHANGE_OPERATION = 'D'
              AND x.SYS_CHANGE_VERSION   <= @ToVersion
        ) d ON d.ClientReference = t.ClientReference;

        SET @TotalDeleted = (SELECT COUNT(*) FROM #DelLog);   -- reuse existing variable
        IF @EmitInfo=1 RAISERROR('Deleted due to tbl_Clients deletes: %d', 0, 1, @TotalDeleted) WITH NOWAIT;

        -- 5) Advance watermark + summary
        UPDATE dbo.CT_Watermark
          SET LastSyncVersion = @ToVersion,
              LastSyncTime    = SYSUTCDATETIME()
        WHERE ProcessName = @Process;

        SET @EndUTC = SYSUTCDATETIME();
        SET @EndIso = CONVERT(varchar(33), @EndUTC, 126);
        SET @DurationSec = DATEDIFF(SECOND, @RunStartedAt, @EndUTC);

        SET @Summary = CONCAT(
            N'ClientStartLeaveDates incremental started ', @StartIso, N' UTC; ended ', @EndIso,
            N' UTC; inserted ', CAST(@TotalInserted AS nvarchar(20)),
            N', updated ', CAST(@TotalUpdated AS nvarchar(20)),
            N', deleted ', CAST(@TotalDeleted AS nvarchar(20)),
            N'; advanced watermark to ', CAST(@ToVersion AS nvarchar(30)),
            N'; duration=', CAST(@DurationSec AS nvarchar(20)), N' sec.'
        );

        IF @EmitInfo=1
        BEGIN
            RAISERROR('ClientStartLeaveDates incremental sync complete.', 0, 1) WITH NOWAIT;
            RAISERROR('  Inserted = %d', 0, 1, @TotalInserted) WITH NOWAIT;
            RAISERROR('  Updated  = %d', 0, 1, @TotalUpdated) WITH NOWAIT;
            RAISERROR('  Deleted  = %d', 0, 1, @TotalDeleted) WITH NOWAIT;
        END

        IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;

        IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner='Session', @DbPrincipal='dbo';
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner='Session', @DbPrincipal='dbo';
        DECLARE @msg nvarchar(4000) = ERROR_MESSAGE();
        DECLARE @num int = ERROR_NUMBER(), @sev int = ERROR_SEVERITY(), @st int = ERROR_STATE(), @lin int = ERROR_LINE(), @proc sysname = ERROR_PROCEDURE();
        DECLARE @procName sysname = ISNULL(@proc, N'<adhoc>');  -- precompute to avoid ISNULL(...) in RAISERROR
        IF @EmitInfo=1 RAISERROR('usp_Sync_ClientStartLeaveDates_Incremental failed (%d, sev %d, state %d) at %s line %d: %s',16,1,@num,@sev,@st,@procName,@lin,@msg);
        SET @Summary = CONCAT(N'ClientStartLeaveDates incremental failed: ', @msg);
        IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
        RETURN -50001;
    END CATCH
END
