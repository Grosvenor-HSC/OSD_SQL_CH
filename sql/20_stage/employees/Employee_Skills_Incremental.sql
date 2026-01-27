/*
Purpose:
    Incrementally load new or updated employee skill records.

Source:
    Source employee skills tables/views.

Target:
    Staging employee skills table.

Run type:
    Incremental.

Run frequency:
    Daily.

Safe to re-run:
    Usually YES.

Notes:
    - Must run AFTER employee incremental.
*/


USE [DOM_LIVE]
GO
/****** Object:  StoredProcedure [dbo].[usp_Sync_EmployeeSkills_Incremental]    Script Date: 26/01/2026 20:49:18 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

ALTER   PROCEDURE [dbo].[usp_Sync_EmployeeSkills_Incremental]
    @ChunkSize        int  = 100000,
    @LockTimeoutMs    int  = 60000,
    @UseAppLock       bit  = 1,
    @EmitInfo         bit  = 1,                       -- 0=quiet, 1=print progress
    @Summary          nvarchar(4000) = NULL OUTPUT,   -- one-line summary
    @ReturnSummaryRow bit  = 1                        -- 1=SELECT Stage/Summary row
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Process       sysname      = N'EmployeeSkills';
    DECLARE @RunStartedAt  datetime2(3) = SYSUTCDATETIME();
    DECLARE @StartIso      varchar(33)  = CONVERT(varchar(33), @RunStartedAt, 126);
    DECLARE @EndUTC        datetime2(3);
    DECLARE @EndIso        varchar(33);
    DECLARE @DurationSec   int;

    /* ----------------------- 0) Concurrency guard ----------------------- */
    DECLARE @LockResource sysname = N'DOM_LIVE:Sync:EmployeeSkills';
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
            SET @Summary = N'EmployeeSkills incremental failed: could not acquire applock.';
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            RETURN @lockResult;
        END
        SET @lockHeld = 1;
    END

    BEGIN TRY
        /* ----------------------- 1) Preconditions & bounds ----------------------- */
        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_databases WHERE database_id = DB_ID())
        BEGIN
            IF @EmitInfo=1 RAISERROR('CT not enabled at DB level.',16,1);
            SET @Summary = N'EmployeeSkills incremental failed: CT not enabled at DB level.';
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            GOTO FinallyRelease;
        END

        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.SKILL_REQD'))
        BEGIN
            IF @EmitInfo=1 RAISERROR('CT not enabled on dbo.SKILL_REQD.',16,1);
            SET @Summary = N'EmployeeSkills incremental failed: CT not enabled on SKILL_REQD.';
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            GOTO FinallyRelease;
        END

        DECLARE @CT_CHSYSDEC   bit = CASE WHEN EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.CHSYSDEC'))   THEN 1 ELSE 0 END;
        DECLARE @CT_SKILL_CATS bit = CASE WHEN EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.SKILL_CATS')) THEN 1 ELSE 0 END;

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
                OBJECT_ID(N'dbo.SKILL_REQD'),
                CASE WHEN @CT_CHSYSDEC=1   THEN OBJECT_ID(N'dbo.CHSYSDEC')   ELSE NULL END,
                CASE WHEN @CT_SKILL_CATS=1 THEN OBJECT_ID(N'dbo.SKILL_CATS') ELSE NULL END
            )
        );

        IF @MinValid IS NOT NULL AND @LastSyncVersion < @MinValid
        BEGIN
            IF @EmitInfo=1 RAISERROR('Watermark %I64d < CT min valid %I64d (re-baseline).',16,1,@LastSyncVersion,@MinValid);
            SET @Summary = CONCAT(N'EmployeeSkills incremental failed: watermark ', @LastSyncVersion, N' < min valid ', @MinValid, N'.');
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            GOTO FinallyRelease;
        END

        DECLARE @ToVersion bigint = CHANGE_TRACKING_CURRENT_VERSION();

        IF @EmitInfo=1
        BEGIN
            RAISERROR('EmployeeSkills CT window:', 0, 1) WITH NOWAIT;
            RAISERROR('  From=%I64d', 0, 1, @LastSyncVersion) WITH NOWAIT;
            RAISERROR('  To  =%I64d', 0, 1, @ToVersion)       WITH NOWAIT;
        END

        /* ----------------------- 2) Build changed key set ----------------------- */
        IF OBJECT_ID('tempdb..#Changed') IS NOT NULL DROP TABLE #Changed;
        CREATE TABLE #Changed (UUID int NOT NULL PRIMARY KEY);  -- UUID == SKILLREQ_REF

        -- SKILL_REQD changes (I/U/D — we’ll also handle deletes later)
        INSERT INTO #Changed(UUID)
        SELECT DISTINCT x.SKILLREQ_REF
        FROM CHANGETABLE(CHANGES dbo.SKILL_REQD, @LastSyncVersion) x
        WHERE x.SYS_CHANGE_VERSION <= @ToVersion;

        -- Description text changes (CHSYSDEC) → touch affected SKILL_REQD rows
        IF @CT_CHSYSDEC = 1
        BEGIN
            INSERT INTO #Changed(UUID)
            SELECT DISTINCT sr.SKILLREQ_REF
            FROM CHANGETABLE(CHANGES dbo.CHSYSDEC, @LastSyncVersion) d
            JOIN dbo.SKILL_REQD sr
              ON sr.SKILL_REF = d.DECODE_REF
            WHERE sr.REF_TYPE = 2
              AND d.SYS_CHANGE_VERSION <= @ToVersion
              AND NOT EXISTS (SELECT 1 FROM #Changed z WHERE z.UUID = sr.SKILLREQ_REF);
        END
        ELSE IF @EmitInfo=1
            RAISERROR('Note: CT not enabled on CHSYSDEC; skill text changes may be delayed.', 0, 1) WITH NOWAIT;

        -- Category text changes (SKILL_CATS) → touch affected SKILL_REQD rows
        IF @CT_SKILL_CATS = 1
        BEGIN
            INSERT INTO #Changed(UUID)
            SELECT DISTINCT sr.SKILLREQ_REF
            FROM CHANGETABLE(CHANGES dbo.SKILL_CATS, @LastSyncVersion) sc
            JOIN dbo.CHSYSDEC d  ON d.GROUP1 = 2 AND d.CODE = 'SKIL'
            JOIN dbo.SKILL_REQD sr
              ON sr.REF_TYPE = 2
             AND sr.SKILL_REF = d.DECODE_REF
             AND d.VALUE1 = sc.SKILL_REF
            WHERE sc.SYS_CHANGE_VERSION <= @ToVersion
              AND NOT EXISTS (SELECT 1 FROM #Changed z WHERE z.UUID = sr.SKILLREQ_REF);
        END
        ELSE IF @EmitInfo=1
            RAISERROR('Note: CT not enabled on SKILL_CATS; category text changes may be delayed.', 0, 1) WITH NOWAIT;

        DECLARE @ToProcess int = (SELECT COUNT(*) FROM #Changed);
        IF @EmitInfo=1 RAISERROR('Employee skills to process: %d', 0, 1, @ToProcess) WITH NOWAIT;

        IF @ToProcess = 0
        BEGIN
            UPDATE dbo.CT_Watermark
              SET LastSyncVersion=@ToVersion, LastSyncTime=SYSUTCDATETIME()
            WHERE ProcessName=@Process;

            SET @EndUTC = SYSUTCDATETIME();
            SET @EndIso = CONVERT(varchar(33), @EndUTC, 126);
            SET @DurationSec = DATEDIFF(SECOND, @RunStartedAt, @EndUTC);

            SET @Summary = CONCAT(
                N'EmployeeSkills incremental started ', @StartIso, N' UTC; ended ', @EndIso,
                N' UTC; inserted 0, updated 0, deleted 0; advanced watermark to ',
                CAST(@ToVersion AS nvarchar(30)), N'; duration=', @DurationSec, N' sec.'
            );
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;

            GOTO FinallyRelease;
        END

        /* ----------------------- 3) Chunked UPSERT ----------------------- */
        DECLARE @TotalInserted bigint = 0, @TotalUpdated bigint = 0, @TotalDeleted int = 0;

        WHILE EXISTS (SELECT 1 FROM #Changed)
        BEGIN
            IF OBJECT_ID('tempdb..#Next') IS NOT NULL DROP TABLE #Next;
            CREATE TABLE #Next (UUID int NOT NULL PRIMARY KEY);

            INSERT INTO #Next(UUID)
            SELECT TOP (@ChunkSize) UUID
            FROM #Changed
            ORDER BY UUID;

            IF OBJECT_ID('tempdb..#ActLog') IS NOT NULL DROP TABLE #ActLog;
            CREATE TABLE #ActLog(Action nvarchar(10) NOT NULL);

            ;WITH SR AS (
                SELECT
                    sr.SKILLREQ_REF                                      AS UUID,
                    TRY_CONVERT(int, sr.[REFERENCE])                     AS EMP_REF,
                    sr.SKILL_REF,
                    TRY_CONVERT(datetime2, sr.VAL_START_DTM)             AS StartDT,
                    TRY_CONVERT(datetime2, sr.VAL_END_DTM)               AS EndDT,
                    CAST(sr.NOTES AS nvarchar(max))                      AS Notes
                FROM dbo.SKILL_REQD sr
                JOIN #Next n ON n.UUID = sr.SKILLREQ_REF
                WHERE sr.REF_TYPE = 2
            ),
            D AS (  -- decode table rows for skills (same rule as initial)
                SELECT d.DECODE_REF, LTRIM(RTRIM(d.DESCRIPTION)) AS DESCRIPTION, d.VALUE1
                FROM dbo.CHSYSDEC d
                WHERE d.GROUP1 = 2 AND d.CODE = 'SKIL'
            ),
            Base AS (
                SELECT
                    s.UUID,
                    Employee_UUID     = CAST(s.EMP_REF AS varchar(20)),
                    Skill_Description = CAST(d.DESCRIPTION AS varchar(255)),
                    Valid_From_Date   = s.StartDT,
                    Valid_To_Date     = s.EndDT,
                    Notes             = s.Notes,
                    Skill_Category    = CAST(sc.DESC_TXT AS varchar(255))
                FROM SR s
                LEFT JOIN D              d  ON d.DECODE_REF = s.SKILL_REF
                LEFT JOIN dbo.SKILL_CATS sc ON sc.SKILL_REF = d.VALUE1
            )
            MERGE dbo.tbl_EmployeeSkills AS tgt
            USING Base AS src
               ON tgt.UUID = src.UUID
            WHEN MATCHED THEN
                UPDATE SET
                    tgt.Employee_UUID     = src.Employee_UUID,
                    tgt.Skill_Description = src.Skill_Description,
                    tgt.Valid_From_Date   = src.Valid_From_Date,
                    tgt.Valid_To_Date     = src.Valid_To_Date,
                    tgt.Notes             = src.Notes,
                    tgt.Skill_Category    = src.Skill_Category,
                    tgt.UpdatedAtUTC      = @RunStartedAt
            WHEN NOT MATCHED BY TARGET THEN
                INSERT (
                    Employee_UUID, Skill_Description, UUID,
                    Valid_From_Date, Valid_To_Date, Notes, Skill_Category,
                    CreatedAtUTC, UpdatedAtUTC
                )
                VALUES (
                    src.Employee_UUID, src.Skill_Description, src.UUID,
                    src.Valid_From_Date, src.Valid_To_Date, src.Notes, src.Skill_Category,
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
                RAISERROR('EmployeeSkills chunk: inserted=%d updated=%d (running %d/%d)',
                          0,1,@i,@u,@TotalInserted,@TotalUpdated) WITH NOWAIT;

            DELETE c
            FROM #Changed c
            JOIN #Next n ON n.UUID = c.UUID;
        END

        /* ----------------------- 3b) Apply hard deletes from SKILL_REQD ----------------------- */
        IF OBJECT_ID('tempdb..#DelLog') IS NOT NULL DROP TABLE #DelLog;
        CREATE TABLE #DelLog(UUID int NOT NULL);

        DELETE t
        OUTPUT DELETED.UUID INTO #DelLog(UUID)
        FROM dbo.tbl_EmployeeSkills t
        JOIN (
            SELECT d.SKILLREQ_REF
            FROM CHANGETABLE(CHANGES dbo.SKILL_REQD, @LastSyncVersion) d
            WHERE d.SYS_CHANGE_OPERATION = 'D'
              AND d.SYS_CHANGE_VERSION   <= @ToVersion
        ) x ON t.UUID = x.SKILLREQ_REF;

        SET @TotalDeleted += (SELECT COUNT(*) FROM #DelLog);

        /* ----------------------- 4) Advance watermark + summary ----------------------- */
        UPDATE dbo.CT_Watermark
          SET LastSyncVersion=@ToVersion, LastSyncTime=SYSUTCDATETIME()
        WHERE ProcessName=@Process;

        SET @EndUTC = SYSUTCDATETIME();
        SET @EndIso = CONVERT(varchar(33), @EndUTC, 126);
        SET @DurationSec = DATEDIFF(SECOND, @RunStartedAt, @EndUTC);

        SET @Summary = CONCAT(
            N'EmployeeSkills incremental started ', @StartIso, N' UTC; ended ', @EndIso,
            N' UTC; inserted ', CAST(@TotalInserted AS nvarchar(20)),
            N', updated ', CAST(@TotalUpdated AS nvarchar(20)),
            N', deleted ', CAST(@TotalDeleted AS nvarchar(20)),
            N'; advanced watermark to ', CAST(@ToVersion AS nvarchar(30)),
            N'; duration=', CAST(@DurationSec AS nvarchar(20)), N' sec.'
        );

        IF @EmitInfo=1 RAISERROR('EmployeeSkills incremental sync complete.', 0, 1) WITH NOWAIT;
        IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;

FinallyRelease:
        IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;
        DECLARE @msg nvarchar(4000)=ERROR_MESSAGE();
        DECLARE @num int=ERROR_NUMBER(), @sev int=ERROR_SEVERITY(), @st int=ERROR_STATE(), @lin int=ERROR_LINE(), @proc sysname=ERROR_PROCEDURE();
        DECLARE @procName sysname = ISNULL(@proc, N'<adhoc>');
        IF @EmitInfo=1 RAISERROR('usp_Sync_EmployeeSkills_Incremental failed (%d, sev %d, state %d) at %s line %d: %s',16,1,@num,@sev,@st,@procName,@lin,@msg);
        SET @Summary = CONCAT(N'EmployeeSkills incremental failed: ', @msg);
        IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
        RETURN -50001;
    END CATCH
END
