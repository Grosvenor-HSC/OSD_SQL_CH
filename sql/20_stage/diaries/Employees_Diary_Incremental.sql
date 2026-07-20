/*
Purpose:
    Incrementally load new/updated/deleted employee diary records into dbo.tbl_EmployeesDiary
    using SQL Server Change Tracking.

Source:
    dbo.EMPLOYEE_DY (+ optional dbo.CHSYSDEC)

Target:
    dbo.tbl_EmployeesDiary

Run type:
    Incremental (daily)

Design:
    - Fences CT window at start (From watermark -> ToVersion)
    - Chunked MERGE to control log/locks
    - Applies deletes based on CHANGETABLE deletes from dbo.EMPLOYEE_DY
    - Optional refresh when decode text changes (if CT enabled on dbo.CHSYSDEC)
    - Advances watermark only after successful sync

Requires:
    - CT enabled at DB level and on dbo.EMPLOYEE_DY
    - dbo.tbl_EmployeesDiary exists and matches Initial schema:
        (Employee_UUID int, UUID int, Entry_Date datetime, Review_Date datetime, Entry_Type nvarchar(255), CreatedAtUTC, UpdatedAtUTC)
*/

USE [DOM_LIVE];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Sync_EmployeesDiary_Incremental
    @ChunkSize         int  = 100000,
    @LockTimeoutMs     int  = 60000,
    @UseAppLock        bit  = 1,
    @EmitInfo          bit  = 0,                          -- 0=silent, 1=progress
    @Summary           nvarchar(4000) = NULL OUTPUT,      -- one-line summary
    @ReturnSummaryRow  bit  = 1                           -- emit SELECT Stage/Summary row
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET ANSI_WARNINGS ON;

    DECLARE @Process       sysname      = N'EmployeesDiary';
    DECLARE @RunStartedAt  datetime2(3) = SYSUTCDATETIME();
    DECLARE @StartIso      varchar(33)  = CONVERT(varchar(33), @RunStartedAt, 126);
    DECLARE @EndUTC        datetime2(3);
    DECLARE @EndIso        varchar(33);
    DECLARE @DurationSec   int;

    /* Concurrency */
    DECLARE @LockResource sysname = N'DOM_LIVE:Sync:EmployeesDiary';
    DECLARE @LockOwner    sysname = N'Session';
    DECLARE @DbPrincipal  sysname = N'dbo';
    DECLARE @lockResult   int;
    DECLARE @lockHeld     bit = 0;

    DECLARE @rc int = 0;

    IF @UseAppLock = 1
    BEGIN
        EXEC @lockResult = sys.sp_getapplock
            @Resource=@LockResource,
            @LockMode='Exclusive',
            @LockOwner=@LockOwner,
            @DbPrincipal=@DbPrincipal,
            @LockTimeout=@LockTimeoutMs;

        IF @lockResult NOT IN (0,1)
        BEGIN
            SET @Summary = N'EmployeesDiary incremental failed: could not acquire applock.';
            IF @ReturnSummaryRow=1 SELECT N'Incremental' AS Stage, @Summary AS Summary;
            RETURN @lockResult;
        END

        SET @lockHeld = 1;
    END

    BEGIN TRY
        /* ------------------------------------------------------------
           1) Preconditions
           ------------------------------------------------------------ */
        IF OBJECT_ID(N'dbo.tbl_EmployeesDiary', N'U') IS NULL
        BEGIN
            SET @Summary = N'EmployeesDiary incremental failed: missing dbo.tbl_EmployeesDiary (run EmployeesDiary initial first).';
            IF @ReturnSummaryRow=1 SELECT N'Incremental' AS Stage, @Summary AS Summary;
            SET @rc = -300;
            GOTO Finally;
        END

        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_databases WHERE database_id = DB_ID())
        BEGIN
            SET @Summary = N'EmployeesDiary incremental failed: Change Tracking is not enabled at DB level.';
            IF @ReturnSummaryRow=1 SELECT N'Incremental' AS Stage, @Summary AS Summary;
            SET @rc = -100;
            GOTO Finally;
        END

        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.EMPLOYEE_DY'))
        BEGIN
            SET @Summary = N'EmployeesDiary incremental failed: CT not enabled on dbo.EMPLOYEE_DY.';
            IF @ReturnSummaryRow=1 SELECT N'Incremental' AS Stage, @Summary AS Summary;
            SET @rc = -210;
            GOTO Finally;
        END

        /* Schema contract check (align with Initial) */
        IF COL_LENGTH(N'dbo.tbl_EmployeesDiary', N'Employee_UUID') IS NULL
           OR COL_LENGTH(N'dbo.tbl_EmployeesDiary', N'UUID') IS NULL
           OR COL_LENGTH(N'dbo.tbl_EmployeesDiary', N'Entry_Date') IS NULL
           OR COL_LENGTH(N'dbo.tbl_EmployeesDiary', N'Review_Date') IS NULL
           OR COL_LENGTH(N'dbo.tbl_EmployeesDiary', N'Entry_Type') IS NULL
           OR COL_LENGTH(N'dbo.tbl_EmployeesDiary', N'CreatedAtUTC') IS NULL
           OR COL_LENGTH(N'dbo.tbl_EmployeesDiary', N'UpdatedAtUTC') IS NULL
        BEGIN
            SET @Summary = N'EmployeesDiary incremental failed: dbo.tbl_EmployeesDiary schema mismatch (does not match Initial contract).';
            IF @ReturnSummaryRow=1 SELECT N'Incremental' AS Stage, @Summary AS Summary;
            SET @rc = -310;
            GOTO Finally;
        END

        DECLARE @CT_DEC bit = CASE WHEN EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.CHSYSDEC')) THEN 1 ELSE 0 END;

        /* Watermark */
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

        DECLARE @ToVersion bigint = CHANGE_TRACKING_CURRENT_VERSION();

        /* Min valid protection (CT retention) */
        DECLARE @MinValid bigint =
        (
            SELECT MAX(CHANGE_TRACKING_MIN_VALID_VERSION(object_id))
            FROM sys.change_tracking_tables
            WHERE object_id IN
            (
                OBJECT_ID(N'dbo.EMPLOYEE_DY'),
                CASE WHEN @CT_DEC=1 THEN OBJECT_ID(N'dbo.CHSYSDEC') ELSE NULL END
            )
        );

        IF @MinValid IS NOT NULL AND @LastSyncVersion < @MinValid
        BEGIN
            SET @Summary = CONCAT(
                N'EmployeesDiary incremental failed: watermark ', @LastSyncVersion,
                N' < CT min valid ', @MinValid, N' (re-baseline required).'
            );
            IF @ReturnSummaryRow=1 SELECT N'Incremental' AS Stage, @Summary AS Summary;
            SET @rc = -200;
            GOTO Finally;
        END

        IF @EmitInfo=1
            RAISERROR('EmployeesDiary CT window: From=%I64d To=%I64d', 0, 1, @LastSyncVersion, @ToVersion) WITH NOWAIT;

        /* ------------------------------------------------------------
           2) Build changed set (EMP_DY_REF)
           ------------------------------------------------------------ */
        IF OBJECT_ID('tempdb..#Changed') IS NOT NULL DROP TABLE #Changed;
        CREATE TABLE #Changed
        (
            EmpDyRef int NOT NULL PRIMARY KEY
        );

        INSERT INTO #Changed(EmpDyRef)
        SELECT DISTINCT x.EMP_DY_REF
        FROM CHANGETABLE(CHANGES dbo.EMPLOYEE_DY, @LastSyncVersion) x
        WHERE x.SYS_CHANGE_VERSION <= @ToVersion;

        /* Optional: decode changes affecting ENTRY_TYPE */
        IF @CT_DEC = 1
        BEGIN
            INSERT INTO #Changed(EmpDyRef)
            SELECT DISTINCT edy.EMP_DY_REF
            FROM CHANGETABLE(CHANGES dbo.CHSYSDEC, @LastSyncVersion) d
            JOIN dbo.EMPLOYEE_DY edy
              ON edy.ENTRY_TYPE = d.DECODE_REF
            WHERE d.SYS_CHANGE_VERSION <= @ToVersion
              AND NOT EXISTS (SELECT 1 FROM #Changed z WHERE z.EmpDyRef = edy.EMP_DY_REF);
        END
        ELSE IF @EmitInfo=1
            RAISERROR('Note: CT not enabled on CHSYSDEC; ENTRY_TYPE text changes will not trigger refresh.', 0, 1) WITH NOWAIT;

        DECLARE @ToProcess int = (SELECT COUNT(*) FROM #Changed);

        IF @EmitInfo=1
            RAISERROR('EmployeesDiary rows to process: %d', 0, 1, @ToProcess) WITH NOWAIT;

        IF @ToProcess = 0
        BEGIN
            UPDATE dbo.CT_Watermark
              SET LastSyncVersion=@ToVersion,
                  LastSyncTime=SYSUTCDATETIME()
            WHERE ProcessName=@Process;

            SET @EndUTC = SYSUTCDATETIME();
            SET @EndIso = CONVERT(varchar(33), @EndUTC, 126);
            SET @DurationSec = DATEDIFF(SECOND, @RunStartedAt, @EndUTC);

            SET @Summary = CONCAT(
                N'EmployeesDiary incremental started ', @StartIso, N' UTC; ended ', @EndIso,
                N' UTC; inserted 0, updated 0, deleted 0; advanced watermark to ',
                CAST(@ToVersion AS nvarchar(30)), N'; duration=', @DurationSec, N' sec.'
            );

            IF @ReturnSummaryRow=1 SELECT N'Incremental' AS Stage, @Summary AS Summary;
            SET @rc = 0;
            GOTO Finally;
        END

        /* ------------------------------------------------------------
           3) Chunked MERGE
           ------------------------------------------------------------ */
        DECLARE @TotalInserted bigint = 0, @TotalUpdated bigint = 0;

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

            ;WITH Base AS
            (
                SELECT
                    Employee_UUID = edy.EMP_REF,
                    UUID          = edy.EMP_DY_REF,
                    Entry_Date    = edy.ENTRY_DATE,
                    Review_Date   = edy.REVIEW_DATE,
                    Entry_Type    = NULLIF(LTRIM(RTRIM(cet.DESCRIPTION)), N'')
                FROM dbo.EMPLOYEE_DY edy
                JOIN #Next n
                  ON n.EmpDyRef = edy.EMP_DY_REF
                LEFT JOIN dbo.CHSYSDEC cet
                  ON cet.DECODE_REF = edy.ENTRY_TYPE
                WHERE edy.EMP_REF <> 0
            )
            MERGE dbo.tbl_EmployeesDiary AS tgt
            USING Base AS src
              ON  tgt.Employee_UUID = src.Employee_UUID
              AND tgt.UUID          = src.UUID
            WHEN MATCHED THEN
                UPDATE SET
                    tgt.Entry_Date   = src.Entry_Date,
                    tgt.Review_Date  = src.Review_Date,
                    tgt.Entry_Type   = src.Entry_Type,
                    tgt.UpdatedAtUTC = @RunStartedAt
            WHEN NOT MATCHED BY TARGET THEN
                INSERT
                (
                    Employee_UUID, UUID,
                    Entry_Date, Review_Date, Entry_Type,
                    CreatedAtUTC, UpdatedAtUTC
                )
                VALUES
                (
                    src.Employee_UUID, src.UUID,
                    src.Entry_Date, src.Review_Date, src.Entry_Type,
                    @RunStartedAt, @RunStartedAt
                )
            OUTPUT $action INTO #ActLog(Action);

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

        /* ------------------------------------------------------------
           4) Apply deletes from source EMPLOYEE_DY
           ------------------------------------------------------------ */
        IF OBJECT_ID('tempdb..#DelLog') IS NOT NULL DROP TABLE #DelLog;
        CREATE TABLE #DelLog (UUID int NOT NULL);

        DELETE tgt
        OUTPUT DELETED.UUID INTO #DelLog(UUID)
        FROM dbo.tbl_EmployeesDiary tgt
        JOIN
        (
            SELECT d.EMP_DY_REF
            FROM CHANGETABLE(CHANGES dbo.EMPLOYEE_DY, @LastSyncVersion) d
            WHERE d.SYS_CHANGE_OPERATION = 'D'
              AND d.SYS_CHANGE_VERSION  <= @ToVersion
        ) x
          ON tgt.UUID = x.EMP_DY_REF;

        DECLARE @TotalDeleted int = (SELECT COUNT(*) FROM #DelLog);

        IF @EmitInfo=1
            RAISERROR('EmployeesDiary deletes applied: %d', 0, 1, @TotalDeleted) WITH NOWAIT;

        /* ------------------------------------------------------------
           5) Advance watermark + summary
           ------------------------------------------------------------ */
        UPDATE dbo.CT_Watermark
          SET LastSyncVersion=@ToVersion,
              LastSyncTime=SYSUTCDATETIME()
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

        IF @ReturnSummaryRow=1
            SELECT N'Incremental' AS Stage, @Summary AS Summary;

        SET @rc = 0;

Finally:
        IF @lockHeld=1
            EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;

        RETURN @rc;
    END TRY
    BEGIN CATCH
        IF @lockHeld=1
            EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;

        DECLARE @err nvarchar(4000)=ERROR_MESSAGE();
        DECLARE @num int=ERROR_NUMBER(), @sev int=ERROR_SEVERITY(), @st int=ERROR_STATE(),
                @lin int=ERROR_LINE(), @proc sysname=ERROR_PROCEDURE();
        DECLARE @procName sysname = ISNULL(@proc, N'<adhoc>');

        IF @EmitInfo=1
            RAISERROR('usp_Sync_EmployeesDiary_Incremental failed (%d, sev %d, state %d) at %s line %d: %s',
                      16,1,@num,@sev,@st,@procName,@lin,@err);

        SET @Summary = CONCAT(N'EmployeesDiary incremental failed: ', @err);
        IF @ReturnSummaryRow=1 SELECT N'Incremental' AS Stage, @Summary AS Summary;

        RETURN -50001;
    END CATCH
END;
GO
