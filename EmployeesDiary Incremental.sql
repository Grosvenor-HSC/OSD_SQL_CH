USE [DOM_LIVE];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Sync_EmployeesDiary_Incremental
    @ChunkSize        int  = 100000,
    @LockTimeoutMs    int  = 60000,
    @UseAppLock       bit  = 1,
    @EmitInfo         bit  = 1,                      -- 0=quiet, 1=print progress
    @Summary          nvarchar(4000) = NULL OUTPUT,  -- one-line summary text
    @ReturnSummaryRow bit  = 1                       -- 1=SELECT a Stage/Summary row
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Process       sysname      = N'EmployeesDiary';
    DECLARE @RunStartedAt  datetime2(3) = SYSUTCDATETIME();
    DECLARE @StartIso      varchar(33)  = CONVERT(varchar(33), @RunStartedAt, 126);
    DECLARE @EndUTC        datetime2(3);
    DECLARE @EndIso        varchar(33);
    DECLARE @DurationSec   int;

    -- concurrency
    DECLARE @LockResource sysname = N'DOM_LIVE:Sync:EmployeesDiary';
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
            SET @Summary = N'EmployeesDiary incremental failed: could not acquire applock.';
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            RETURN @lockResult;
        END
        SET @lockHeld = 1;
    END

    BEGIN TRY
        -- preconditions
        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_databases WHERE database_id = DB_ID())
        BEGIN
            IF @EmitInfo=1 RAISERROR('CT not enabled at DB level.',16,1);
            SET @Summary = N'EmployeesDiary incremental failed: CT not enabled at DB level.';
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;
            RETURN -100;
        END

        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.EMPLOYEE_DY'))
        BEGIN
            IF @EmitInfo=1 RAISERROR('CT not enabled on dbo.EMPLOYEE_DY.',16,1);
            SET @Summary = N'EmployeesDiary incremental failed: CT not enabled on EMPLOYEE_DY.';
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
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

        DECLARE @MinValid bigint =
        (
            SELECT MAX(CHANGE_TRACKING_MIN_VALID_VERSION(object_id))
            FROM sys.change_tracking_tables
            WHERE object_id IN (
                OBJECT_ID(N'dbo.EMPLOYEE_DY'),
                CASE WHEN @CT_CHSYSDEC=1 THEN OBJECT_ID(N'dbo.CHSYSDEC') ELSE NULL END
            )
        );

        IF @MinValid IS NOT NULL AND @LastSyncVersion < @MinValid
        BEGIN
            IF @EmitInfo=1 RAISERROR('Watermark %I64d < CT min valid %I64d (re-baseline).',16,1,@LastSyncVersion,@MinValid);
            SET @Summary = CONCAT(N'EmployeesDiary incremental failed: watermark ', @LastSyncVersion, N' < min valid ', @MinValid, N'.');
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;
            RETURN -200;
        END

        DECLARE @ToVersion bigint = CHANGE_TRACKING_CURRENT_VERSION();

        IF @EmitInfo=1
        BEGIN
            RAISERROR('EmployeesDiary CT window:', 0, 1) WITH NOWAIT;
            RAISERROR('  From=%I64d', 0, 1, @LastSyncVersion) WITH NOWAIT;
            RAISERROR('  To  =%I64d', 0, 1, @ToVersion) WITH NOWAIT;
        END

        -- changed keys
        IF OBJECT_ID('tempdb..#Changed') IS NOT NULL DROP TABLE #Changed;
        CREATE TABLE #Changed (EmployeeDiaryReference int NOT NULL PRIMARY KEY);

        INSERT INTO #Changed(EmployeeDiaryReference)
        SELECT DISTINCT x.EMP_DY_REF
        FROM CHANGETABLE(CHANGES dbo.EMPLOYEE_DY, @LastSyncVersion) x
        WHERE x.SYS_CHANGE_VERSION <= @ToVersion;

        IF @CT_CHSYSDEC = 1
        BEGIN
            INSERT INTO #Changed(EmployeeDiaryReference)
            SELECT DISTINCT edy.EMP_DY_REF
            FROM CHANGETABLE(CHANGES dbo.CHSYSDEC, @LastSyncVersion) d
            JOIN dbo.EMPLOYEE_DY edy ON edy.ENTRY_TYPE = d.DECODE_REF
            WHERE d.SYS_CHANGE_VERSION <= @ToVersion
              AND NOT EXISTS (SELECT 1 FROM #Changed z WHERE z.EmployeeDiaryReference = edy.EMP_DY_REF);
        END
        ELSE IF @EmitInfo=1
            RAISERROR('Note: CT not enabled on CHSYSDEC; entry-type text updates not tracked.', 0, 1) WITH NOWAIT;

        DECLARE @ToProcess int = (SELECT COUNT(*) FROM #Changed);
        IF @EmitInfo=1 RAISERROR('Employee diary rows to process: %d', 0, 1, @ToProcess) WITH NOWAIT;

        IF @ToProcess = 0
        BEGIN
            UPDATE dbo.CT_Watermark
              SET LastSyncVersion=@ToVersion, LastSyncTime=SYSUTCDATETIME()
            WHERE ProcessName=@Process;

            SET @EndUTC = SYSUTCDATETIME();
            SET @EndIso = CONVERT(varchar(33), @EndUTC, 126);
            SET @DurationSec = DATEDIFF(SECOND, @RunStartedAt, @EndUTC);

            SET @Summary = CONCAT(
                N'EmployeesDiary incremental started ', @StartIso, N' UTC; ended ', @EndIso,
                N' UTC; inserted 0, updated 0, deleted 0; advanced watermark to ',
                CAST(@ToVersion AS nvarchar(30)), N'; duration=', @DurationSec, N' sec.'
            );

            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;
            RETURN 0;
        END

        -- upsert
        DECLARE @TotalInserted bigint = 0, @TotalUpdated bigint = 0, @TotalDeleted int = 0;

        WHILE EXISTS (SELECT 1 FROM #Changed)
        BEGIN
            IF OBJECT_ID('tempdb..#Next') IS NOT NULL DROP TABLE #Next;
            CREATE TABLE #Next (EmployeeDiaryReference int NOT NULL PRIMARY KEY);

            INSERT INTO #Next(EmployeeDiaryReference)
            SELECT TOP (@ChunkSize) EmployeeDiaryReference
            FROM #Changed
            ORDER BY EmployeeDiaryReference;

            IF OBJECT_ID('tempdb..#ActLog') IS NOT NULL DROP TABLE #ActLog;
            CREATE TABLE #ActLog(Action nvarchar(10) NOT NULL);

            ;WITH Base AS
            (
                SELECT
                    EmployeeDiaryReference      = edy.EMP_DY_REF,
                    EmployeeReference           = CAST(edy.EMP_REF AS nvarchar(50)),
                    EmployeeDiaryEntryDate      = edy.ENTRY_DATE,
                    EmployeeDiaryReminded       = edy.REMINDED,
                    EmployeeDiaryReviewDate     = edy.REVIEW_DATE,
                    EmployeeDiaryEntryType      = cet.DESCRIPTION,
                    EmployeeDiaryAction         = edy.ACTION,
                    EmployeeDiaryActionDate     = edy.ACTIONDT,
                    EmployeeDiaryReviewDoneDate = edy.REVDONE_DT,
                    EmployeeDiaryBranchID       = e.BranchReference   -- NVARCHAR(55)
                FROM dbo.EMPLOYEE_DY edy
                JOIN #Next n ON n.EmployeeDiaryReference = edy.EMP_DY_REF
                LEFT JOIN dbo.CHSYSDEC cet ON cet.DECODE_REF = edy.ENTRY_TYPE
                LEFT JOIN dbo.tbl_Employees e ON e.EmployeeReference = edy.EMP_REF
            )
            MERGE dbo.tbl_EmployeesDiary AS tgt
            USING Base AS src
               ON  tgt.EmployeeReference      = src.EmployeeReference
               AND tgt.EmployeeDiaryReference = src.EmployeeDiaryReference
            WHEN MATCHED THEN
                UPDATE SET
                    tgt.EmployeeDiaryEntryDate        = src.EmployeeDiaryEntryDate,
                    tgt.EmployeeDiaryReminded         = src.EmployeeDiaryReminded,
                    tgt.EmployeeDiaryReviewDate       = src.EmployeeDiaryReviewDate,
                    tgt.EmployeeDiaryEntryType        = src.EmployeeDiaryEntryType,
                    tgt.EmployeeDiaryAction           = src.EmployeeDiaryAction,
                    tgt.EmployeeDiaryActionDate       = src.EmployeeDiaryActionDate,
                    tgt.EmployeeDiaryReviewDoneDate   = src.EmployeeDiaryReviewDoneDate,
                    tgt.EmployeeDiaryBranchID         = src.EmployeeDiaryBranchID,
                    tgt.UpdatedAtUTC                  = @RunStartedAt
            WHEN NOT MATCHED BY TARGET THEN
                INSERT (
                    EmployeeReference, EmployeeDiaryReference,
                    EmployeeDiaryEntryDate, EmployeeDiaryReminded, EmployeeDiaryReviewDate,
                    EmployeeDiaryEntryType, EmployeeDiaryAction, EmployeeDiaryActionDate,
                    EmployeeDiaryReviewDoneDate, EmployeeDiaryBranchID,
                    CreatedAtUTC, UpdatedAtUTC
                )
                VALUES (
                    src.EmployeeReference, src.EmployeeDiaryReference,
                    src.EmployeeDiaryEntryDate, src.EmployeeDiaryReminded, src.EmployeeDiaryReviewDate,
                    src.EmployeeDiaryEntryType, src.EmployeeDiaryAction, src.EmployeeDiaryActionDate,
                    src.EmployeeDiaryReviewDoneDate, src.EmployeeDiaryBranchID,
                    @RunStartedAt, @RunStartedAt
                )
            WHEN NOT MATCHED BY SOURCE
                 AND EXISTS (SELECT 1 FROM #Next nn WHERE nn.EmployeeDiaryReference = tgt.EmployeeDiaryReference)
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
                RAISERROR('EmployeesDiary chunk: inserted=%d updated=%d deleted=%d (running %d/%d/%d)',
                          0,1,@i,@u,@d,@TotalInserted,@TotalUpdated,@TotalDeleted) WITH NOWAIT;

            DELETE c
            FROM #Changed c
            JOIN #Next n ON n.EmployeeDiaryReference = c.EmployeeDiaryReference;
        END

        -- hard deletes safety
        IF OBJECT_ID('tempdb..#DelLog') IS NOT NULL DROP TABLE #DelLog;
        CREATE TABLE #DelLog(EmployeeDiaryReference int NOT NULL);

        DELETE t
        OUTPUT DELETED.EmployeeDiaryReference INTO #DelLog(EmployeeDiaryReference)
        FROM dbo.tbl_EmployeesDiary t
        JOIN (
            SELECT d.EMP_DY_REF
            FROM CHANGETABLE(CHANGES dbo.EMPLOYEE_DY, @LastSyncVersion) d
            WHERE d.SYS_CHANGE_OPERATION = 'D'
              AND d.SYS_CHANGE_VERSION   <= @ToVersion
        ) x ON t.EmployeeDiaryReference = x.EMP_DY_REF;

        DECLARE @DelCount int = (SELECT COUNT(*) FROM #DelLog);
        SET @TotalDeleted += @DelCount;
        IF @EmitInfo=1 RAISERROR('EmployeesDiary deletes applied from source: %d', 0, 1, @DelCount) WITH NOWAIT;

        -- watermark + summary
        UPDATE dbo.CT_Watermark
          SET LastSyncVersion=@ToVersion, LastSyncTime=SYSUTCDATETIME()
        WHERE ProcessName=@Process;

        SET @EndUTC = SYSUTCDATETIME();
        SET @EndIso = CONVERT(varchar(33), @EndUTC, 126);
        SET @DurationSec = DATEDIFF(SECOND, @RunStartedAt, @EndUTC);

        SET @Summary = CONCAT(
            N'EmployeesDiary incremental started ', @StartIso, N' UTC; ended ', @EndIso,
            N' UTC; inserted ', CAST(@TotalInserted AS nvarchar(20)),
            N', updated ', CAST(@TotalUpdated AS nvarchar(20)),
            N', deleted ', CAST(@TotalDeleted AS nvarchar(20)),
            N'; advanced watermark to ', CAST(@ToVersion AS nvarchar(30)),
            N'; duration=', CAST(@DurationSec AS nvarchar(20)), N' sec.'
        );

        IF @EmitInfo=1 RAISERROR('EmployeesDiary incremental sync complete.', 0, 1) WITH NOWAIT;
        IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;

        IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;
        DECLARE @msg nvarchar(4000)=ERROR_MESSAGE();
        DECLARE @num int=ERROR_NUMBER(), @sev int=ERROR_SEVERITY(), @st int=ERROR_STATE(), @lin int=ERROR_LINE(), @proc sysname=ERROR_PROCEDURE();
        DECLARE @procName sysname = ISNULL(@proc, N'<adhoc>');
        IF @EmitInfo=1 RAISERROR('usp_Sync_EmployeesDiary_Incremental failed (%d, sev %d, state %d) at %s line %d: %s',16,1,@num,@sev,@st,@procName,@lin,@msg);
        SET @Summary = CONCAT(N'EmployeesDiary incremental failed: ', @msg);
        IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
        RETURN -50001;
    END CATCH
END
GO
