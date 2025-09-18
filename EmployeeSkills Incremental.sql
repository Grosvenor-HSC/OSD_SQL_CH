USE [DOM_LIVE];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Sync_EmployeeSkills_Incremental
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
            IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;
            RETURN -100;
        END

        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.SKILL_REQD'))
        BEGIN
            IF @EmitInfo=1 RAISERROR('CT not enabled on dbo.SKILL_REQD.',16,1);
            SET @Summary = N'EmployeeSkills incremental failed: CT not enabled on SKILL_REQD.';
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;
            RETURN -210;
        END

        DECLARE @CT_EMPLOYEE   bit = CASE WHEN EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.EMPLOYEE'))   THEN 1 ELSE 0 END;
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
                CASE WHEN @CT_EMPLOYEE=1   THEN OBJECT_ID(N'dbo.EMPLOYEE')   ELSE NULL END,
                CASE WHEN @CT_CHSYSDEC=1   THEN OBJECT_ID(N'dbo.CHSYSDEC')   ELSE NULL END,
                CASE WHEN @CT_SKILL_CATS=1 THEN OBJECT_ID(N'dbo.SKILL_CATS') ELSE NULL END
            )
        );

        IF @MinValid IS NOT NULL AND @LastSyncVersion < @MinValid
        BEGIN
            IF @EmitInfo=1 RAISERROR('Watermark %I64d < CT min valid %I64d (re-baseline).',16,1,@LastSyncVersion,@MinValid);
            SET @Summary = CONCAT(N'EmployeeSkills incremental failed: watermark ', @LastSyncVersion, N' < min valid ', @MinValid, N'.');
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;
            RETURN -200;
        END

        DECLARE @ToVersion bigint = CHANGE_TRACKING_CURRENT_VERSION();

        IF @EmitInfo=1
        BEGIN
            RAISERROR('EmployeeSkills CT window:', 0, 1) WITH NOWAIT;
            RAISERROR('  From=%I64d', 0, 1, @LastSyncVersion) WITH NOWAIT;
            RAISERROR('  To  =%I64d', 0, 1, @ToVersion) WITH NOWAIT;
        END

        /* ----------------------- 2) Build changed key set ----------------------- */
        IF OBJECT_ID('tempdb..#Changed') IS NOT NULL DROP TABLE #Changed;
        CREATE TABLE #Changed (EmployeeSkillReference int NOT NULL PRIMARY KEY);

        INSERT INTO #Changed(EmployeeSkillReference)
        SELECT DISTINCT x.SKILLREQ_REF
        FROM CHANGETABLE(CHANGES dbo.SKILL_REQD, @LastSyncVersion) x
        WHERE x.SYS_CHANGE_VERSION <= @ToVersion;

        IF @CT_EMPLOYEE = 1
        BEGIN
            INSERT INTO #Changed(EmployeeSkillReference)
            SELECT DISTINCT sr.SKILLREQ_REF
            FROM CHANGETABLE(CHANGES dbo.EMPLOYEE, @LastSyncVersion) ce
            JOIN dbo.SKILL_REQD sr ON TRY_CONVERT(int, sr.[REFERENCE]) = ce.EMP_REF
            WHERE sr.REF_TYPE = 2
              AND ce.SYS_CHANGE_VERSION <= @ToVersion
              AND NOT EXISTS (SELECT 1 FROM #Changed z WHERE z.EmployeeSkillReference = sr.SKILLREQ_REF);
        END
        ELSE IF @EmitInfo=1
            RAISERROR('Note: CT not enabled on EMPLOYEE; branch moves may be delayed.', 0, 1) WITH NOWAIT;

        IF @CT_CHSYSDEC = 1
        BEGIN
            INSERT INTO #Changed(EmployeeSkillReference)
            SELECT DISTINCT sr.SKILLREQ_REF
            FROM CHANGETABLE(CHANGES dbo.CHSYSDEC, @LastSyncVersion) d
            JOIN dbo.SKILL_REQD sr ON sr.SKILL_REF = d.DECODE_REF
            WHERE sr.REF_TYPE = 2
              AND d.SYS_CHANGE_VERSION <= @ToVersion
              AND NOT EXISTS (SELECT 1 FROM #Changed z WHERE z.EmployeeSkillReference = sr.SKILLREQ_REF);
        END
        ELSE IF @EmitInfo=1
            RAISERROR('Note: CT not enabled on CHSYSDEC; skill text changes may be delayed.', 0, 1) WITH NOWAIT;

        IF @CT_SKILL_CATS = 1
        BEGIN
            INSERT INTO #Changed(EmployeeSkillReference)
            SELECT DISTINCT sr.SKILLREQ_REF
            FROM CHANGETABLE(CHANGES dbo.SKILL_CATS, @LastSyncVersion) sc
            JOIN dbo.SKILL_REQD sr ON sr.REF_TYPE = 2
            JOIN dbo.CHSYSDEC d    ON d.DECODE_REF = sr.SKILL_REF AND d.GROUP1 = 2 AND d.CODE = 'SKIL'
            WHERE d.VALUE1 = sc.SKILL_REF
              AND sc.SYS_CHANGE_VERSION <= @ToVersion
              AND NOT EXISTS (SELECT 1 FROM #Changed z WHERE z.EmployeeSkillReference = sr.SKILLREQ_REF);
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

            IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;
            RETURN 0;
        END

        /* ----------------------- 3) Chunked UPSERT (no MERGE) ----------------------- */
        DECLARE @TotalInserted bigint = 0, @TotalUpdated bigint = 0, @TotalDeleted int = 0;

        WHILE EXISTS (SELECT 1 FROM #Changed)
        BEGIN
            IF OBJECT_ID('tempdb..#Next') IS NOT NULL DROP TABLE #Next;
            CREATE TABLE #Next (EmployeeSkillReference int NOT NULL PRIMARY KEY);

            INSERT INTO #Next(EmployeeSkillReference)
            SELECT TOP (@ChunkSize) EmployeeSkillReference
            FROM #Changed
            ORDER BY EmployeeSkillReference;

            IF OBJECT_ID('tempdb..#Src') IS NOT NULL DROP TABLE #Src;
            CREATE TABLE #Src (
                EmployeeSkillReference             int           NOT NULL PRIMARY KEY,
                EmployeeReference                  varchar(20)   NOT NULL,
                EmployeeKeySkillDescription        varchar(255)  NULL,
                EmployeeKeySkillValidFromDate      datetime2     NULL,
                EmployeeKeySkillValidToDate        datetime2     NULL,
                EmployeeKeySkillNotes              nvarchar(max) NULL,
                EmployeeKeySkillRefField           varchar(50)   NULL,
                UpdatedEmployeeKeySkillValidToDate datetime2     NULL,
                EmployeeKeySkillCategory           varchar(255)  NULL,
                BranchReference                    nvarchar(55)  NULL
            );

            ;WITH SR AS (
                SELECT
                    sr.SKILLREQ_REF,
                    EMP_REF      = TRY_CONVERT(int, sr.[REFERENCE]),
                    sr.SKILL_REF,
                    StartDT      = TRY_CONVERT(datetime2, sr.VAL_START_DTM),
                    EndDT        = TRY_CONVERT(datetime2, sr.VAL_END_DTM),
                    Notes        = CAST(sr.NOTES AS nvarchar(max)),
                    REFFIELD     = sr.REFFIELD
                FROM dbo.SKILL_REQD sr
                JOIN #Next n ON n.EmployeeSkillReference = sr.SKILLREQ_REF
                WHERE sr.REF_TYPE = 2
            )
            INSERT INTO #Src (
                EmployeeSkillReference, EmployeeReference, EmployeeKeySkillDescription,
                EmployeeKeySkillValidFromDate, EmployeeKeySkillValidToDate,
                EmployeeKeySkillNotes, EmployeeKeySkillRefField,
                UpdatedEmployeeKeySkillValidToDate, EmployeeKeySkillCategory, BranchReference
            )
            SELECT
                s.SKILLREQ_REF,
                CAST(s.EMP_REF AS varchar(20)),
                CAST(LTRIM(RTRIM(d.DESCRIPTION)) AS varchar(255)),
                s.StartDT,
                s.EndDT,
                s.Notes,
                s.REFFIELD,
                ISNULL(s.EndDT, SYSUTCDATETIME()),
                CAST(cat.DESC_TXT AS varchar(255)),
                CAST(b.BranchUID AS nvarchar(55))
            FROM SR s
            JOIN dbo.EMPLOYEE e   ON e.EMP_REF = s.EMP_REF
            JOIN dbo.tbl_Branch b ON e.GS_REF  = b.OldBranchUID
            CROSS APPLY (
                SELECT TOP (1) d.DESCRIPTION, d.VALUE1
                FROM dbo.CHSYSDEC d
                WHERE d.DECODE_REF = s.SKILL_REF
                  AND d.GROUP1 = 2 AND d.CODE = 'SKIL'
                ORDER BY d.DECODE_REF
            ) d
            OUTER APPLY (
                SELECT TOP (1) sc.DESC_TXT
                FROM dbo.SKILL_CATS sc
                WHERE sc.SKILL_REF = d.VALUE1
                ORDER BY sc.DESC_TXT
            ) cat;

            /* UPDATE */
            DECLARE @i int = 0, @u int = 0, @d int = 0;

            UPDATE tgt
            SET
                tgt.EmployeeReference                  = s.EmployeeReference,
                tgt.EmployeeKeySkillDescription        = s.EmployeeKeySkillDescription,
                tgt.EmployeeKeySkillValidFromDate      = s.EmployeeKeySkillValidFromDate,
                tgt.EmployeeKeySkillValidToDate        = s.EmployeeKeySkillValidToDate,
                tgt.EmployeeKeySkillNotes              = s.EmployeeKeySkillNotes,
                tgt.EmployeeKeySkillRefField           = s.EmployeeKeySkillRefField,
                tgt.UpdatedEmployeeKeySkillValidToDate = s.UpdatedEmployeeKeySkillValidToDate,
                tgt.EmployeeKeySkillCategory           = s.EmployeeKeySkillCategory,
                tgt.BranchReference                    = s.BranchReference,
                tgt.UpdatedAtUTC                       = @RunStartedAt
            FROM dbo.tbl_EmployeeSkills AS tgt
            JOIN #Src                     AS s
              ON s.EmployeeSkillReference = tgt.EmployeeSkillReference;

            SET @u = @@ROWCOUNT;

            /* INSERT */
            INSERT INTO dbo.tbl_EmployeeSkills (
                EmployeeReference, EmployeeKeySkillDescription, EmployeeSkillReference,
                EmployeeKeySkillValidFromDate, EmployeeKeySkillValidToDate, EmployeeKeySkillNotes,
                EmployeeKeySkillRefField, UpdatedEmployeeKeySkillValidToDate, EmployeeKeySkillCategory,
                BranchReference, CreatedAtUTC, UpdatedAtUTC
            )
            SELECT
                s.EmployeeReference, s.EmployeeKeySkillDescription, s.EmployeeSkillReference,
                s.EmployeeKeySkillValidFromDate, s.EmployeeKeySkillValidToDate, s.EmployeeKeySkillNotes,
                s.EmployeeKeySkillRefField, s.UpdatedEmployeeKeySkillValidToDate, s.EmployeeKeySkillCategory,
                s.BranchReference, @RunStartedAt, @RunStartedAt
            FROM #Src s
            WHERE NOT EXISTS (
                SELECT 1
                FROM dbo.tbl_EmployeeSkills t
                WHERE t.EmployeeSkillReference = s.EmployeeSkillReference
            );

            SET @i = @@ROWCOUNT;

            /* DELETE */
            DELETE t
            FROM dbo.tbl_EmployeeSkills t
            JOIN #Next nn ON nn.EmployeeSkillReference = t.EmployeeSkillReference
            LEFT JOIN #Src s ON s.EmployeeSkillReference = t.EmployeeSkillReference
            WHERE s.EmployeeSkillReference IS NULL;

            SET @d = @@ROWCOUNT;

            /* Tally + progress */
            SET @TotalInserted += ISNULL(@i,0);
            SET @TotalUpdated  += ISNULL(@u,0);
            SET @TotalDeleted  += ISNULL(@d,0);

            IF @EmitInfo=1
                RAISERROR('EmployeeSkills chunk: inserted=%d updated=%d deleted=%d (running %d/%d/%d)',
                          0,1,@i,@u,@d,@TotalInserted,@TotalUpdated,@TotalDeleted) WITH NOWAIT;

            /* Remove processed keys */
            DELETE c
            FROM #Changed c
            JOIN #Next   n ON n.EmployeeSkillReference = c.EmployeeSkillReference;

            DROP TABLE #Src;
        END

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
GO
