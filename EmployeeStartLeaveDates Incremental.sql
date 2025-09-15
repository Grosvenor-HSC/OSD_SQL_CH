USE [DOM_LIVE];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Sync_EmployeeStartLeaveDates_Incremental
    @ChunkSize        int  = 100000,  -- tune (50k–200k typical)
    @LockTimeoutMs    int  = 60000,
    @UseAppLock       bit  = 1,
    @EmitInfo         bit  = 1,                       -- 0=quiet
    @Summary          nvarchar(4000) = NULL OUTPUT,   -- one-line summary
    @ReturnSummaryRow bit  = 1                        -- 1=SELECT Stage/Summary row
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Process       sysname      = N'EmployeeStartLeaveDates';
    DECLARE @RunStartedAt  datetime2(3) = SYSUTCDATETIME();
    DECLARE @StartIso      varchar(33)  = CONVERT(varchar(33), @RunStartedAt, 126);
    DECLARE @EndUTC        datetime2(3);
    DECLARE @EndIso        varchar(33);
    DECLARE @DurationSec   int;

    /* 0) Concurrency guard */
    DECLARE @LockResource sysname = N'DOM_LIVE:Sync:EmployeeStartLeaveDates';
    DECLARE @LockOwner   sysname = N'Session';
    DECLARE @DbPrincipal sysname = N'dbo';
    DECLARE @lockResult  int;
    DECLARE @lockHeld    bit = 0;

    IF @UseAppLock = 1
    BEGIN
        EXEC @lockResult = sys.sp_getapplock
            @Resource=@LockResource, @LockMode='Exclusive',
            @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal,
            @LockTimeout=@LockTimeoutMs;

        IF @lockResult NOT IN (0,1)
        BEGIN
            IF @EmitInfo=1 RAISERROR('Could not acquire %s (sp_getapplock rc=%d).',16,1,@LockResource,@lockResult);
            SET @Summary = N'EmployeeStartLeaveDates incremental failed: could not acquire applock.';
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            RETURN @lockResult;
        END
        SET @lockHeld = 1;
    END

    BEGIN TRY
        /* 1) Preconditions & bounds */
        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_databases WHERE database_id = DB_ID())
        BEGIN
            IF @EmitInfo=1 RAISERROR('Change Tracking is not enabled at DB level.', 16, 1);
            SET @Summary = N'EmployeeStartLeaveDates incremental failed: CT not enabled at DB level.';
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;
            RETURN -100;
        END

        IF OBJECT_ID('dbo.tbl_EmployeeStartLeaveDates','U') IS NULL
        BEGIN
            IF @EmitInfo=1 RAISERROR('Target table dbo.tbl_EmployeeStartLeaveDates does not exist. Run the baseline first.', 16, 1);
            SET @Summary = N'EmployeeStartLeaveDates incremental failed: target missing (run initial).';
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;
            RETURN -110;
        END

        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.tbl_EmployeeBranch'))
        BEGIN
            IF @EmitInfo=1 RAISERROR('CT not enabled on dbo.tbl_EmployeeBranch.', 16, 1);
            SET @Summary = N'EmployeeStartLeaveDates incremental failed: CT not enabled on tbl_EmployeeBranch.';
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;
            RETURN -120;
        END

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

        DECLARE @MinValid bigint = CHANGE_TRACKING_MIN_VALID_VERSION(OBJECT_ID(N'dbo.tbl_EmployeeBranch'));

        IF @MinValid IS NOT NULL AND @LastSyncVersion < @MinValid
        BEGIN
            IF @EmitInfo=1 RAISERROR('Watermark (%I64d) is older than CT min valid (%I64d) on tbl_EmployeeBranch. Re-baseline required.',16,1,@LastSyncVersion,@MinValid);
            SET @Summary = CONCAT(N'EmployeeStartLeaveDates incremental failed: watermark ', @LastSyncVersion, N' < min valid ', @MinValid, N'.');
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;
            RETURN -200;
        END

        DECLARE @ToVersion bigint = CHANGE_TRACKING_CURRENT_VERSION();

        IF @EmitInfo=1
        BEGIN
            RAISERROR('EmployeeStartLeaveDates CT incremental window:', 0, 1) WITH NOWAIT;
            RAISERROR('  From = %I64d', 0, 1, @LastSyncVersion) WITH NOWAIT;
            RAISERROR('  To   = %I64d', 0, 1, @ToVersion) WITH NOWAIT;
        END

        /* 2) Hash->employee key map (for delete resolution) */
        IF OBJECT_ID('dbo.tbl_EmployeeBranch_KeyMap','U') IS NULL
        BEGIN
            CREATE TABLE dbo.tbl_EmployeeBranch_KeyMap
            (
              EmpBranchHash     varbinary(32) NOT NULL PRIMARY KEY,
              EmployeeReference int           NOT NULL,
              BranchReference   nvarchar(55)  NULL,
              UpdatedAtUTC      datetime2(3)  NOT NULL DEFAULT SYSUTCDATETIME()
            );

            INSERT INTO dbo.tbl_EmployeeBranch_KeyMap (EmpBranchHash, EmployeeReference, BranchReference)
            SELECT EmpBranchHash, EmployeeReference, BranchReference
            FROM dbo.tbl_EmployeeBranch;
        END
        ELSE
        BEGIN
            MERGE dbo.tbl_EmployeeBranch_KeyMap AS m
            USING (SELECT EmpBranchHash, EmployeeReference, BranchReference FROM dbo.tbl_EmployeeBranch) s
               ON m.EmpBranchHash = s.EmpBranchHash
            WHEN MATCHED AND (m.EmployeeReference <> s.EmployeeReference OR ISNULL(m.BranchReference,'') <> ISNULL(s.BranchReference,'')) THEN
                UPDATE SET m.EmployeeReference = s.EmployeeReference,
                           m.BranchReference   = s.BranchReference,
                           m.UpdatedAtUTC      = SYSUTCDATETIME()
            WHEN NOT MATCHED BY TARGET THEN
                INSERT (EmpBranchHash, EmployeeReference, BranchReference)
                VALUES (s.EmpBranchHash, s.EmployeeReference, s.BranchReference);
        END

        /* 3) Build changed EmployeeReference set */
        IF OBJECT_ID('tempdb..#Changed') IS NOT NULL DROP TABLE #Changed;
        CREATE TABLE #Changed (EmployeeReference int NOT NULL PRIMARY KEY);

        -- I/U from tbl_EmployeeBranch
        INSERT INTO #Changed(EmployeeReference)
        SELECT DISTINCT t.EmployeeReference
        FROM CHANGETABLE(CHANGES dbo.tbl_EmployeeBranch, @LastSyncVersion) ct
        JOIN dbo.tbl_EmployeeBranch t
          ON t.EmpBranchHash = ct.EmpBranchHash
        WHERE ct.SYS_CHANGE_VERSION <= @ToVersion
          AND ct.SYS_CHANGE_OPERATION IN ('I','U');

        -- D from tbl_EmployeeBranch using key map
        INSERT INTO #Changed(EmployeeReference)
        SELECT DISTINCT m.EmployeeReference
        FROM CHANGETABLE(CHANGES dbo.tbl_EmployeeBranch, @LastSyncVersion) ct
        JOIN dbo.tbl_EmployeeBranch_KeyMap m
          ON m.EmpBranchHash = ct.EmpBranchHash
        WHERE ct.SYS_CHANGE_VERSION <= @ToVersion
          AND ct.SYS_CHANGE_OPERATION = 'D'
          AND NOT EXISTS (SELECT 1 FROM #Changed z WHERE z.EmployeeReference = m.EmployeeReference);

        DECLARE @ToProcess int = (SELECT COUNT(*) FROM #Changed);
        IF @EmitInfo=1 RAISERROR('Changed employees to process: %d', 0, 1, @ToProcess) WITH NOWAIT;

        IF @ToProcess = 0
        BEGIN
            UPDATE dbo.CT_Watermark
              SET LastSyncVersion = @ToVersion, LastSyncTime = SYSUTCDATETIME()
            WHERE ProcessName = @Process;

            SET @EndUTC = SYSUTCDATETIME();
            SET @EndIso = CONVERT(varchar(33), @EndUTC, 126);
            SET @DurationSec = DATEDIFF(SECOND, @RunStartedAt, @EndUTC);

            SET @Summary = CONCAT(
                N'EmployeeStartLeaveDates incremental started ', @StartIso, N' UTC; ended ', @EndIso,
                N' UTC; inserted 0, updated 0; advanced watermark to ',
                CAST(@ToVersion AS nvarchar(30)), N'; duration=', @DurationSec, N' sec.'
            );
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;

            IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;
            RETURN 0;
        END

        /* 4) Chunked UPSERT */
        DECLARE @TotalInserted bigint = 0, @TotalUpdated bigint = 0;

        WHILE EXISTS (SELECT 1 FROM #Changed)
        BEGIN
            IF OBJECT_ID('tempdb..#Next') IS NOT NULL DROP TABLE #Next;
            CREATE TABLE #Next (EmployeeReference int NOT NULL PRIMARY KEY);

            INSERT INTO #Next(EmployeeReference)
            SELECT TOP (@ChunkSize) EmployeeReference
            FROM #Changed
            ORDER BY EmployeeReference;

            IF OBJECT_ID('tempdb..#ActLog') IS NOT NULL DROP TABLE #ActLog;
            CREATE TABLE #ActLog(Action nvarchar(10) NOT NULL);

            ;WITH Agg AS
            (
                SELECT
                    n.EmployeeReference,
                    MIN(eb.StartDate) AS MinStartDate,
                    MAX(eb.EndDate)   AS MaxEndDate,
                    SUM(CASE WHEN eb.EndDate IS NULL THEN 1 ELSE 0 END) AS OpenRows,
                    MAX(CASE WHEN eb.[Status] = 'Active' THEN 2
                             WHEN eb.[Status] = 'Temporarily Inactive' THEN 1
                             ELSE 0 END) AS StatusRank,
                    COUNT(DISTINCT eb.BranchReference) AS BranchCount
                FROM #Next n
                LEFT JOIN dbo.tbl_EmployeeBranch eb
                  ON eb.EmployeeReference = n.EmployeeReference
                GROUP BY n.EmployeeReference
            ),
            Final AS
            (
                SELECT
                    UpdatedGlobalStartDate = MinStartDate,
                    GlobalStartDate        = ISNULL(MinStartDate, CAST('1998-01-01' AS date)),
                    GlobalEndDate          = CASE WHEN OpenRows > 0 THEN NULL ELSE MaxEndDate END,
                    GlobalStatus           = CASE WHEN OpenRows > 0
                                                   THEN CASE WHEN StatusRank = 2 THEN 'Active'
                                                             WHEN StatusRank = 1 THEN 'Temporarily Inactive'
                                                        END
                                                   ELSE 'Permanently Inactive' END,
                    EmployeeReference      = CAST(a.EmployeeReference AS varchar(50)),
                    UpdatedLeaveDate       = ISNULL(CASE WHEN OpenRows > 0 THEN NULL ELSE MaxEndDate END,
                                                     CAST(@RunStartedAt AS date)),
                    NumberOfBranches       = ISNULL(a.BranchCount, 0)
                FROM Agg a
            )
            MERGE dbo.tbl_EmployeeStartLeaveDates AS tgt
            USING (
                SELECT
                    UpdatedGlobalStartDate, GlobalStartDate, GlobalEndDate, GlobalStatus,
                    EmployeeReference, UpdatedLeaveDate, NumberOfBranches
                FROM Final
            ) AS src
                ON tgt.EmployeeReference = src.EmployeeReference
            WHEN MATCHED THEN
                UPDATE SET
                    tgt.UpdatedGlobalStartDate = src.UpdatedGlobalStartDate,
                    tgt.GlobalStartDate        = src.GlobalStartDate,
                    tgt.GlobalEndDate          = src.GlobalEndDate,
                    tgt.GlobalStatus           = src.GlobalStatus,
                    tgt.UpdatedLeaveDate       = src.UpdatedLeaveDate,
                    tgt.NumberOfBranches       = src.NumberOfBranches,
                    tgt.UpdatedAtUTC           = @RunStartedAt
            WHEN NOT MATCHED BY TARGET THEN
                INSERT (
                    UpdatedGlobalStartDate, GlobalStartDate, GlobalEndDate, GlobalStatus,
                    EmployeeReference, UpdatedLeaveDate, NumberOfBranches,
                    CreatedAtUTC, UpdatedAtUTC
                )
                VALUES (
                    src.UpdatedGlobalStartDate, src.GlobalStartDate, src.GlobalEndDate, src.GlobalStatus,
                    src.EmployeeReference, src.UpdatedLeaveDate, src.NumberOfBranches,
                    @RunStartedAt, @RunStartedAt
                )
            OUTPUT $action INTO #ActLog(Action);

            DECLARE @i int=0, @u int=0;
            SELECT
                @i = SUM(CASE WHEN Action='INSERT' THEN 1 ELSE 0 END),
                @u = SUM(CASE WHEN Action='UPDATE' THEN 1 ELSE 0 END)
            FROM #ActLog;

            SET @TotalInserted += ISNULL(@i,0);
            SET @TotalUpdated  += ISNULL(@u,0);

            IF @EmitInfo=1
                RAISERROR('EmployeeStartLeaveDates chunk upserted: inserted=%d updated=%d (running %d/%d)',
                          0,1,@i,@u,@TotalInserted,@TotalUpdated) WITH NOWAIT;

            DELETE c
            FROM #Changed c
            JOIN #Next n ON n.EmployeeReference = c.EmployeeReference;
        END

        /* 5) Advance watermark + summary */
        UPDATE dbo.CT_Watermark
          SET LastSyncVersion = @ToVersion,
              LastSyncTime    = SYSUTCDATETIME()
        WHERE ProcessName = @Process;

        SET @EndUTC = SYSUTCDATETIME();
        SET @EndIso = CONVERT(varchar(33), @EndUTC, 126);
        SET @DurationSec = DATEDIFF(SECOND, @RunStartedAt, @EndUTC);

        SET @Summary = CONCAT(
            N'EmployeeStartLeaveDates incremental started ', @StartIso, N' UTC; ended ', @EndIso,
            N' UTC; inserted ', CAST(@TotalInserted AS nvarchar(20)),
            N', updated ', CAST(@TotalUpdated AS nvarchar(20)),
            N'; advanced watermark to ', CAST(@ToVersion AS nvarchar(30)),
            N'; duration=', CAST(@DurationSec AS nvarchar(20)), N' sec.'
        );

        IF @EmitInfo=1 RAISERROR('EmployeeStartLeaveDates incremental sync complete.', 0, 1) WITH NOWAIT;
        IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;

        IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;
        DECLARE @msg nvarchar(4000) = ERROR_MESSAGE();
        DECLARE @num int = ERROR_NUMBER(), @sev int = ERROR_SEVERITY(), @st int = ERROR_STATE(), @lin int = ERROR_LINE(), @proc sysname = ERROR_PROCEDURE();
        DECLARE @procName sysname = COALESCE(@proc, N'<adhoc>');
        IF @EmitInfo=1 RAISERROR('usp_Sync_EmployeeStartLeaveDates_Incremental failed (%d, sev %d, state %d) at %s line %d: %s',
                                 16,1,@num,@sev,@st,@procName,@lin,@msg);
        SET @Summary = CONCAT(N'EmployeeStartLeaveDates incremental failed: ', @msg);
        IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
        RETURN -50001;
    END CATCH
END
GO
