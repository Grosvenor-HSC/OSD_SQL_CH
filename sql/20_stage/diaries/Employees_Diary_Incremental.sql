/*
Purpose:
    Incrementally load new and updated employee diary records into the staging diary table.

Source:
    Source employee diary tables/views (OSD / care system source).

Target:
    Staging employee diary table.

Run type:
    Incremental.

Run frequency:
    Daily.

Safe to re-run:
    Usually YES.

Notes:
    - Must run AFTER employees incremental.
    - Used by reporting and operational analysis.
*/

/* ============================================================
   File: Employees_Diary_Incremental.sql
   Refactor: Ensure Employee_UUID is INT in Base (remove nvarchar cast)
   Notes:
     - #Changed uses EMP_DY_REF INT keys
     - MERGE targets dbo.tbl_EmployeesDiary with INT keys
     - Includes delete handling via CHANGETABLE deletes
   ============================================================ */

USE [DOM_LIVE];
GO

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

ALTER PROCEDURE [dbo].[usp_Sync_EmployeesDiary_Incremental]
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

    /* concurrency */
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
        /* Preconditions */
        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_databases WHERE database_id = DB_ID())
        BEGIN
            IF @EmitInfo=1 RAISERROR('CT not enabled at DB level.',16,1);
            SET @Summary = N'EmployeesDiary incremental failed: CT not enabled at DB level.';
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            GOTO FinallyRelease;
        END

        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.EMPLOYEE_DY'))
        BEGIN
            IF @EmitInfo=1 RAISERROR('CT not enabled on dbo.EMPLOYEE_DY.',16,1);
            SET @Summary = N'EmployeesDiary incremental failed: CT not enabled on EMPLOYEE_DY.';
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            GOTO FinallyRelease;
        END

        DECLARE @CT_CHSYSDEC bit =
            CASE WHEN EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.CHSYSDEC')) THEN 1 ELSE 0 END;

        /* Watermark */
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

        /* Min valid across CT tables we look at */
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
            GOTO FinallyRelease;
        END

        DECLARE @ToVersion bigint = CHANGE_TRACKING_CURRENT_VERSION();

        IF @EmitInfo=1
        BEGIN
            RAISERROR('EmployeesDiary CT window:', 0, 1) WITH NOWAIT;
            RAISERROR('  From=%I64d', 0, 1, @LastSyncVersion) WITH NOWAIT;
            RAISERROR('  To  =%I64d', 0, 1, @ToVersion) WITH NOWAIT;
        END

        /* Build changed set (by EMP_DY_REF) */
        IF OBJECT_ID('tempdb..#Changed') IS NOT NULL DROP TABLE #Changed;
        CREATE TABLE #Changed (EmpDyRef int NOT NULL PRIMARY KEY);

        INSERT INTO #Changed(EmpDyRef)
        SELECT DISTINCT x.EMP_DY_REF
        FROM CHANGETABLE(CHANGES dbo.EMPLOYEE_DY, @LastSyncVersion) x
        WHERE x.SYS_CHANGE_VERSION <= @ToVersion;

        IF @CT_CHSYSDEC = 1
        BEGIN
            INSERT INTO #Changed(EmpDyRef)
            SELECT DISTINCT edy.EMP_DY_REF
            FROM CHANGETABLE(CHANGES dbo.CHSYSDEC, @LastSyncVersion) d
            JOIN dbo.EMPLOYEE_DY edy ON edy.ENTRY_TYPE = d.DECODE_REF
            WHERE d.SYS_CHANGE_VERSION <= @ToVersion
              AND NOT EXISTS (SELECT 1 FROM #Changed z WHERE z.EmpDyRef = edy.EMP_DY_REF);
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
            GOTO FinallyRelease;
        END

        /* Resolve actual target column names (kept from your original) */
        DECLARE @ColEmp sysname =
            CASE
                WHEN COL_LENGTH('dbo.tbl_EmployeesDiary','Employee_UUID')     IS NOT NULL THEN 'Employee_UUID'
                WHEN COL_LENGTH('dbo.tbl_EmployeesDiary','EmployeeReference') IS NOT NULL THEN 'EmployeeReference'
                ELSE NULL
            END;

        DECLARE @ColRef sysname =
            CASE
                WHEN COL_LENGTH('dbo.tbl_EmployeesDiary','UUID')                   IS NOT NULL THEN 'UUID'
                WHEN COL_LENGTH('dbo.tbl_EmployeesDiary','EmployeeDiaryReference') IS NOT NULL THEN 'EmployeeDiaryReference'
                WHEN COL_LENGTH('dbo.tbl_EmployeesDiary','EMP_DY_REF')             IS NOT NULL THEN 'EMP_DY_REF'
                ELSE NULL
            END;

        DECLARE @ColEntryDate  sysname = CASE WHEN COL_LENGTH('dbo.tbl_EmployeesDiary','Entry_Date')  IS NOT NULL THEN 'Entry_Date'  ELSE NULL END;
        DECLARE @ColReviewDate sysname = CASE WHEN COL_LENGTH('dbo.tbl_EmployeesDiary','Review_Date') IS NOT NULL THEN 'Review_Date' ELSE NULL END;
        DECLARE @ColEntryType  sysname = CASE WHEN COL_LENGTH('dbo.tbl_EmployeesDiary','Entry_Type')  IS NOT NULL THEN 'Entry_Type'  ELSE NULL END;

        IF @ColEmp IS NULL OR @ColRef IS NULL OR @ColEntryDate IS NULL OR @ColReviewDate IS NULL OR @ColEntryType IS NULL
        BEGIN
            DECLARE @missing nvarchar(400) = N'';
            IF @ColEmp IS NULL        SET @missing += N' Employee_UUID ';
            IF @ColRef IS NULL        SET @missing += N' UUID ';
            IF @ColEntryDate IS NULL  SET @missing += N' Entry_Date ';
            IF @ColReviewDate IS NULL SET @missing += N' Review_Date ';
            IF @ColEntryType IS NULL  SET @missing += N' Entry_Type ';
            RAISERROR('tbl_EmployeesDiary is missing expected columns:%s',16,1,@missing);
            SET @Summary = N'EmployeesDiary incremental failed: target schema mismatch.';
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            GOTO FinallyRelease;
        END

        /* Chunked upsert */
        DECLARE @TotalInserted bigint = 0, @TotalUpdated bigint = 0, @TotalDeleted int = 0;

        WHILE EXISTS (SELECT 1 FROM #Changed)
        BEGIN
            IF OBJECT_ID('tempdb..#Next') IS NOT NULL DROP TABLE #Next;
            CREATE TABLE #Next (EmpDyRef int NOT NULL PRIMARY KEY);

            INSERT INTO #Next(EmpDyRef)
            SELECT TOP (@ChunkSize) EmpDyRef
            FROM #Changed
            ORDER BY EmpDyRef;

            IF OBJECT_ID('tempdb..#ActLog') IS NOT NULL DROP TABLE #ActLog;
            CREATE TABLE #ActLog(Action nvarchar(10) NOT NULL);

            /* IMPORTANT FIX: Employee_UUID is INT (no nvarchar cast) */
            DECLARE @sql nvarchar(max) = N'
;WITH Base AS
(
    SELECT
        Employee_UUID = edy.EMP_REF,
        EmpDyRef      = edy.EMP_DY_REF,
        Entry_Date    = edy.ENTRY_DATE,
        Review_Date   = edy.REVIEW_DATE,
        Entry_Type    = cet.DESCRIPTION
    FROM dbo.EMPLOYEE_DY edy
    JOIN #Next n ON n.EmpDyRef = edy.EMP_DY_REF
    LEFT JOIN dbo.CHSYSDEC cet ON cet.DECODE_REF = edy.ENTRY_TYPE
    WHERE edy.EMP_REF <> 0
)
MERGE dbo.tbl_EmployeesDiary AS tgt
USING Base AS src
   ON  tgt.' + QUOTENAME(@ColEmp) + N' = src.Employee_UUID
   AND tgt.' + QUOTENAME(@ColRef) + N' = src.EmpDyRef
WHEN MATCHED THEN
    UPDATE SET
        tgt.' + QUOTENAME(@ColEntryDate)  + N' = src.Entry_Date,
        tgt.' + QUOTENAME(@ColReviewDate) + N' = src.Review_Date,
        tgt.' + QUOTENAME(@ColEntryType)  + N' = src.Entry_Type,
        tgt.UpdatedAtUTC = @RunStartedAt
WHEN NOT MATCHED BY TARGET THEN
    INSERT (' + QUOTENAME(@ColEmp) + N',' + QUOTENAME(@ColRef) + N',' +
                     QUOTENAME(@ColEntryDate) + N',' + QUOTENAME(@ColReviewDate) + N',' + QUOTENAME(@ColEntryType) + N',
            CreatedAtUTC, UpdatedAtUTC)
    VALUES (src.Employee_UUID, src.EmpDyRef, src.Entry_Date, src.Review_Date, src.Entry_Type,
            @RunStartedAt, @RunStartedAt)
OUTPUT $action INTO #ActLog(Action);';

            EXEC sp_executesql @sql, N'@RunStartedAt datetime2(3)', @RunStartedAt=@RunStartedAt;

            DECLARE @i int = 0, @u int = 0;
            SELECT
                @i = SUM(CASE WHEN Action='INSERT' THEN 1 ELSE 0 END),
                @u = SUM(CASE WHEN Action='UPDATE' THEN 1 ELSE 0 END)
            FROM #ActLog;

            SET @TotalInserted += ISNULL(@i,0);
            SET @TotalUpdated  += ISNULL(@u,0);

            IF @EmitInfo=1
                RAISERROR('EmployeesDiary chunk: inserted=%d updated=%d (running %d/%d)',
                          0,1,@i,@u,@TotalInserted,@TotalUpdated) WITH NOWAIT;

            DELETE c
            FROM #Changed c
            JOIN #Next n ON n.EmpDyRef = c.EmpDyRef;
        END

        /* Apply deletes from EMPLOYEE_DY */
        IF OBJECT_ID('tempdb..#DelLog') IS NOT NULL DROP TABLE #DelLog;
        CREATE TABLE #DelLog(Ref int NOT NULL);

        DECLARE @sqlDel nvarchar(max) = N'
DELETE t
OUTPUT DELETED.' + QUOTENAME(@ColRef) + N' INTO #DelLog(Ref)
FROM dbo.tbl_EmployeesDiary t
JOIN (
    SELECT d.EMP_DY_REF
    FROM CHANGETABLE(CHANGES dbo.EMPLOYEE_DY, @LastSyncVersion) d
    WHERE d.SYS_CHANGE_OPERATION = ''D''
      AND d.SYS_CHANGE_VERSION   <= @ToVersion
) x ON t.' + QUOTENAME(@ColRef) + N' = x.EMP_DY_REF;';

        EXEC sp_executesql @sqlDel,
            N'@LastSyncVersion bigint, @ToVersion bigint',
            @LastSyncVersion=@LastSyncVersion, @ToVersion=@ToVersion;

        DECLARE @DelCount int = (SELECT COUNT(*) FROM #DelLog);
        SET @TotalDeleted += @DelCount;
        IF @EmitInfo=1 RAISERROR('EmployeesDiary deletes applied from source: %d', 0, 1, @DelCount) WITH NOWAIT;

        /* Advance watermark + summary */
        UPDATE dbo.CT_Watermark
          SET LastSyncVersion=@ToVersion, LastSyncTime=SYSUTCDATETIME()
        WHERE ProcessName=@Process;

        SET @EndUTC = SYSUTCDATETIME();
        SET @EndIso = CONVERT(varchar(33), @EndUTC, 126);
        SET @DurationSec = DATEDIFF(SECOND, @RunStartedAt, @EndUTC);

        SET @Summary = CONCAT(
            N'EmployeesDiary incremental started ', @StartIso, N' UTC; ended ', @EndIso,
            N' UTC; inserted ', CAST(@TotalInserted AS nvarchar(20)),
            N', updated ', CAST(@TotalUpdated  AS nvarchar(20)),
            N', deleted ', CAST(@TotalDeleted  AS nvarchar(20)),
            N'; advanced watermark to ', CAST(@ToVersion AS nvarchar(30)),
            N'; duration=', CAST(@DurationSec  AS nvarchar(20)), N' sec.'
        );

        IF @EmitInfo=1 RAISERROR('EmployeesDiary incremental sync complete.', 0, 1) WITH NOWAIT;
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
        DECLARE @num int=ERROR_NUMBER(), @sev int=ERROR_SEVERITY(), @st int=ERROR_STATE(), @lin int=ERROR_LINE(), @proc sysname=ERROR_PROCEDURE();
        DECLARE @procName sysname = ISNULL(@proc, N'<adhoc>');

        IF @EmitInfo=1
            RAISERROR('usp_Sync_EmployeesDiary_Incremental failed (%d, sev %d, state %d) at %s line %d: %s',
                      16,1,@num,@sev,@st,@procName,@lin,@msg);

        SET @Summary = CONCAT(N'EmployeesDiary incremental failed: ', @msg);
        IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
        RETURN -50001;
    END CATCH
END;
GO
