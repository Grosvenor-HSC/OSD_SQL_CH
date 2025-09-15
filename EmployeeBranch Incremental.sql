USE [DOM_LIVE];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE [dbo].[usp_Sync_EmployeeBranch_Incremental]
    @ChunkSize        int  = 100000,
    @LockTimeoutMs    int  = 60000,
    @UseAppLock       bit  = 1,
    @EmitInfo         bit  = 1,                         -- 0=quiet, 1=progress
    @Summary          nvarchar(4000) = NULL OUTPUT,     -- one-line summary
    @ReturnSummaryRow bit  = 1                          -- return Stage/Summary row (Initial sets this to 0)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET ANSI_WARNINGS ON;  -- required due to persisted computed column + indexes

    DECLARE @Process       sysname      = N'EmployeeBranch';
    DECLARE @RunStartedAt  datetime2(3) = SYSUTCDATETIME();
    DECLARE @StartIso      varchar(33)  = CONVERT(varchar(33), @RunStartedAt, 126);
    DECLARE @EndUTC        datetime2(3);
    DECLARE @EndIso        varchar(33);
    DECLARE @DurationSec   int;

    /* 0) Concurrency guard */
    DECLARE @LockResource sysname = N'DOM_LIVE:Sync:EmployeeBranch';
    DECLARE @LockOwner   sysname = N'Session';
    DECLARE @DbPrincipal sysname = N'dbo';
    DECLARE @lockResult  int;
    DECLARE @lockHeld    bit = 0;

    IF @UseAppLock = 1
    BEGIN
        EXEC @lockResult = sys.sp_getapplock
            @Resource    = @LockResource,
            @LockMode    = 'Exclusive',
            @LockOwner   = @LockOwner,
            @DbPrincipal = @DbPrincipal,
            @LockTimeout = @LockTimeoutMs;

        IF @lockResult NOT IN (0,1)
        BEGIN
            IF @EmitInfo=1 RAISERROR('Could not acquire %s (sp_getapplock rc=%d).',16,1,@LockResource,@lockResult);
            SET @Summary = N'EmployeeBranch incremental failed: could not acquire applock.';
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            RETURN @lockResult;
        END
        SET @lockHeld = 1;
    END

    BEGIN TRY
        /* 1) Preconditions & bounds */
        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_databases WHERE database_id = DB_ID())
        BEGIN
            IF @EmitInfo=1 RAISERROR('Change Tracking is not enabled at the database level.', 16, 1);
            SET @Summary = N'EmployeeBranch incremental failed: CT not enabled at DB level.';
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            GOTO FinallyRelease;
        END

        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.DISTKEY'))
        BEGIN
            IF @EmitInfo=1 RAISERROR('Change Tracking is not enabled on dbo.DISTKEY. Cannot proceed.',16,1);
            SET @Summary = N'EmployeeBranch incremental failed: CT not enabled on dbo.DISTKEY.';
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            GOTO FinallyRelease;
        END

        DECLARE @CT_EMPLOYEE bit =
            CASE WHEN EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.EMPLOYEE')) THEN 1 ELSE 0 END;
        DECLARE @CT_CHSYSDEC bit =
            CASE WHEN EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.CHSYSDEC')) THEN 1 ELSE 0 END;

        -- Watermark table
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

        -- Min valid across referenced CT tables
        DECLARE @MinValid bigint =
        (
            SELECT MAX(CHANGE_TRACKING_MIN_VALID_VERSION(object_id))
            FROM sys.change_tracking_tables
            WHERE object_id IN (
                OBJECT_ID(N'dbo.DISTKEY'),
                CASE WHEN @CT_EMPLOYEE=1 THEN OBJECT_ID(N'dbo.EMPLOYEE') ELSE NULL END,
                CASE WHEN @CT_CHSYSDEC=1 THEN OBJECT_ID(N'dbo.CHSYSDEC') ELSE NULL END
            )
        );

        IF @MinValid IS NOT NULL AND @LastSyncVersion < @MinValid
        BEGIN
            IF @EmitInfo=1 RAISERROR('Watermark (%I64d) is older than CT min valid version (%I64d). Re-baseline required.',16,1,@LastSyncVersion,@MinValid);
            SET @Summary = CONCAT(N'EmployeeBranch incremental failed: watermark ', @LastSyncVersion, N' < min valid ', @MinValid, N' (re-baseline).');
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            GOTO FinallyRelease;
        END

        DECLARE @ToVersion bigint = CHANGE_TRACKING_CURRENT_VERSION();

        IF @EmitInfo=1
        BEGIN
            RAISERROR('EmployeeBranch CT window:', 0, 1) WITH NOWAIT;
            RAISERROR('  From = %I64d', 0, 1, @LastSyncVersion) WITH NOWAIT;
            RAISERROR('  To   = %I64d', 0, 1, @ToVersion) WITH NOWAIT;
        END

        /* 2) Build changed (EmployeeReference, DISTBranchReference) pairs */
        IF OBJECT_ID('tempdb..#Changed') IS NOT NULL DROP TABLE #Changed;
        CREATE TABLE #Changed
        (
            EmployeeReference       int          NOT NULL,
            DISTBranchReference     nvarchar(55) NOT NULL,
            PRIMARY KEY (EmployeeReference, DISTBranchReference)
        );

        -- 2a) From DISTKEY via dynamic PK-join
        DECLARE @join nvarchar(max);
        DECLARE @sql  nvarchar(max);

        DECLARE @pkcols TABLE (ord int, name sysname);
        INSERT INTO @pkcols(ord, name)
        SELECT ic.key_ordinal, c.name
        FROM sys.indexes i
        JOIN sys.index_columns ic ON i.object_id=ic.object_id AND i.index_id=ic.index_id
        JOIN sys.columns c        ON c.object_id=ic.object_id AND c.column_id=ic.column_id
        WHERE i.object_id = OBJECT_ID(N'dbo.DISTKEY')
          AND i.is_primary_key = 1
        ORDER BY ic.key_ordinal;

        IF NOT EXISTS (SELECT 1 FROM @pkcols)
        BEGIN
            IF @EmitInfo=1 RAISERROR('dbo.DISTKEY does not have a primary key (required for Change Tracking).',16,1);
            SET @Summary = N'EmployeeBranch incremental failed: DISTKEY has no PK.';
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            GOTO FinallyRelease;
        END

        SELECT @join =
            STUFF((
                SELECT ' AND dk.' + QUOTENAME(name) + ' = ct.' + QUOTENAME(name)
                FROM @pkcols ORDER BY ord
                FOR XML PATH(''), TYPE
            ).value('.','nvarchar(max)'), 1, 5, '');

        SET @sql = N'
            INSERT INTO #Changed(EmployeeReference, DISTBranchReference)
            SELECT DISTINCT dk.INPRIKEY, dk.OUTPRIKEY
            FROM CHANGETABLE(CHANGES dbo.DISTKEY, @LastSyncVersion) ct
            JOIN dbo.DISTKEY dk ON ' + @join + N'
            WHERE ct.SYS_CHANGE_VERSION <= @ToVersion
              AND ct.SYS_CHANGE_OPERATION IN (''I'',''U'');';

        EXEC sp_executesql @sql,
            N'@LastSyncVersion bigint, @ToVersion bigint',
            @LastSyncVersion=@LastSyncVersion, @ToVersion=@ToVersion;

        -- 2b) EMPLOYEE changes (optional)
        IF @CT_EMPLOYEE = 1
        BEGIN
            INSERT INTO #Changed(EmployeeReference, DISTBranchReference)
            SELECT DISTINCT dk.INPRIKEY, dk.OUTPRIKEY
            FROM CHANGETABLE(CHANGES dbo.EMPLOYEE, @LastSyncVersion) ce
            JOIN dbo.EMPLOYEE e ON e.EMP_REF = ce.EMP_REF
            JOIN dbo.DISTKEY dk ON dk.INPRIKEY = e.EMP_REF
            WHERE ce.SYS_CHANGE_VERSION <= @ToVersion
              AND NOT EXISTS (
                    SELECT 1 FROM #Changed z
                    WHERE z.EmployeeReference   = dk.INPRIKEY
                      AND z.DISTBranchReference = dk.OUTPRIKEY
                );
        END
        ELSE IF @EmitInfo=1
            RAISERROR('Note: CT not enabled on EMPLOYEE; split/location updates may be delayed.', 0, 1) WITH NOWAIT;

        -- 2c) CHSYSDEC changes (optional)
        IF @CT_CHSYSDEC = 1
        BEGIN
            -- direct decode refs from DISTKEY (status/care group/left reason/location)
            INSERT INTO #Changed(EmployeeReference, DISTBranchReference)
            SELECT DISTINCT dk.INPRIKEY, dk.OUTPRIKEY
            FROM CHANGETABLE(CHANGES dbo.CHSYSDEC, @LastSyncVersion) cd
            JOIN dbo.DISTKEY dk
              ON dk.[STATUS]      = cd.DECODE_REF
              OR dk.CARE_GRP_REF  = cd.DECODE_REF
              OR dk.LEFTREASON    = cd.DECODE_REF
              OR dk.LOCATION_REF  = cd.DECODE_REF
            WHERE cd.SYS_CHANGE_VERSION <= @ToVersion
              AND NOT EXISTS (
                    SELECT 1 FROM #Changed z
                    WHERE z.EmployeeReference   = dk.INPRIKEY
                      AND z.DISTBranchReference = dk.OUTPRIKEY
                );

            -- employee location via CHSYSDEC
            INSERT INTO #Changed(EmployeeReference, DISTBranchReference)
            SELECT DISTINCT dk.INPRIKEY, dk.OUTPRIKEY
            FROM CHANGETABLE(CHANGES dbo.CHSYSDEC, @LastSyncVersion) cd
            JOIN dbo.EMPLOYEE e ON e.LOCATION_REF = cd.DECODE_REF
            JOIN dbo.DISTKEY dk ON dk.INPRIKEY = e.EMP_REF
            WHERE cd.SYS_CHANGE_VERSION <= @ToVersion
              AND NOT EXISTS (
                    SELECT 1 FROM #Changed z
                    WHERE z.EmployeeReference   = dk.INPRIKEY
                      AND z.DISTBranchReference = dk.OUTPRIKEY
                );
        END
        ELSE IF @EmitInfo=1
            RAISERROR('Note: CT not enabled on CHSYSDEC; description updates may be delayed.', 0, 1) WITH NOWAIT;

        DECLARE @ToProcess int = (SELECT COUNT(*) FROM #Changed);
        IF @EmitInfo=1 RAISERROR('Employee/Branch pairs to process: %d', 0, 1, @ToProcess) WITH NOWAIT;

        IF @ToProcess = 0
        BEGIN
            UPDATE dbo.CT_Watermark
              SET LastSyncVersion = @ToVersion, LastSyncTime = SYSUTCDATETIME()
            WHERE ProcessName = @Process;

            SET @EndUTC = SYSUTCDATETIME();
            SET @EndIso = CONVERT(varchar(33), @EndUTC, 126);
            SET @DurationSec = DATEDIFF(SECOND, @RunStartedAt, @EndUTC);

            SET @Summary = CONCAT(
                N'EmployeeBranch incremental started ', @StartIso, N' UTC; ended ', @EndIso,
                N' UTC; inserted 0, updated 0; advanced watermark to ',
                CAST(@ToVersion AS nvarchar(30)), N'; duration=', @DurationSec, N' sec.'
            );

            IF @EmitInfo=1 RAISERROR('No changes. Watermark advanced.', 0, 1) WITH NOWAIT;
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            GOTO FinallyRelease;
        END

        /* 3) Chunked UPSERT (no hard deletes) */
        DECLARE @TotalInserted bigint = 0, @TotalUpdated bigint = 0;

        WHILE EXISTS (SELECT 1 FROM #Changed)
        BEGIN
            IF OBJECT_ID('tempdb..#Next') IS NOT NULL DROP TABLE #Next;
            CREATE TABLE #Next
            (
                EmployeeReference   int          NOT NULL,
                DISTBranchReference nvarchar(55) NOT NULL,
                PRIMARY KEY (EmployeeReference, DISTBranchReference)
            );

            INSERT INTO #Next(EmployeeReference, DISTBranchReference)
            SELECT TOP (@ChunkSize) EmployeeReference, DISTBranchReference
            FROM #Changed
            ORDER BY EmployeeReference, DISTBranchReference;

            IF OBJECT_ID('tempdb..#ActLog') IS NOT NULL DROP TABLE #ActLog;
            CREATE TABLE #ActLog(Action nvarchar(10) NOT NULL);

            ;WITH DKRows AS
            (
                SELECT DISTINCT
                    dk.INPRIKEY      AS EmployeeReference,
                    dk.OUTPRIKEY     AS DISTBranchReference,
                    dk.START_DATE    AS DK_StartDate,
                    dk.[DATE]        AS DK_EndDate,
                    dk.LEFTREASON,
                    dk.LOCATION_REF,
                    dk.[STATUS]      AS DK_STATUS,
                    dk.CARE_GRP_REF
                FROM dbo.DISTKEY dk
                JOIN #Next n
                  ON n.EmployeeReference   = dk.INPRIKEY
                 AND n.DISTBranchReference = dk.OUTPRIKEY
            ),
            Emp AS (
                SELECT e.EMP_REF, e.GS_REF, e.LOCATION_REF AS EMP_LOC_REF
                FROM dbo.EMPLOYEE e
                WHERE EXISTS (SELECT 1 FROM #Next n WHERE n.EmployeeReference = e.EMP_REF)
            ),
            Lookups AS ( SELECT d.DECODE_REF, d.DESCRIPTION FROM dbo.CHSYSDEC d ),
            VisitsAgg AS (
                SELECT
                    v.EmployeeReference,
                    b.OldBranchUID,
                    MIN(v.VisitStartDate) AS FirstVisitStartDate,
                    MAX(v.VisitEndDate)   AS LastVisitEndDate
                FROM dbo.tbl_Visits v
                JOIN dbo.tbl_Branch b ON v.BranchReference = b.BranchUID
                WHERE EXISTS (SELECT 1 FROM #Next n WHERE n.EmployeeReference = v.EmployeeReference)
                GROUP BY v.EmployeeReference, b.OldBranchUID
            ),
            Base AS (
                SELECT
                    dk.EmployeeReference,
                    dk.DISTBranchReference,
                    dk.DK_StartDate,
                    dk.DK_EndDate,
                    dk.LEFTREASON,
                    dk.LOCATION_REF,
                    dk.DK_STATUS,
                    dk.CARE_GRP_REF,
                    e.GS_REF,
                    EL.DESCRIPTION  AS EmpLocationDesc,
                    ES.DESCRIPTION  AS StatusDesc,
                    ECG.DESCRIPTION AS CareGroupDesc,
                    ELR.DESCRIPTION AS LeftReasonDesc,
                    EBL.DESCRIPTION AS EmpBranchLocDesc,
                    va.FirstVisitStartDate,
                    va.LastVisitEndDate
                FROM DKRows dk
                LEFT JOIN Emp e            ON e.EMP_REF       = dk.EmployeeReference
                LEFT JOIN Lookups EL       ON EL.DECODE_REF   = e.EMP_LOC_REF
                LEFT JOIN Lookups ES       ON ES.DECODE_REF   = dk.DK_STATUS
                LEFT JOIN Lookups ECG      ON ECG.DECODE_REF  = dk.CARE_GRP_REF
                LEFT JOIN Lookups ELR      ON ELR.DECODE_REF  = dk.LEFTREASON
                LEFT JOIN Lookups EBL      ON EBL.DECODE_REF  = dk.LOCATION_REF
                LEFT JOIN VisitsAgg va     ON va.EmployeeReference = dk.EmployeeReference
                                          AND va.OldBranchUID      = dk.DISTBranchReference
            ),
            Shaped AS (
                SELECT
                    b.EmployeeReference,

                    BranchReference = CAST(bpick.BranchUID AS nvarchar(55)),
                    BranchName      = bpick.BranchName,

                    StartDate =
                        CASE
                            WHEN b.DK_StartDate IS NULL THEN b.FirstVisitStartDate
                            WHEN b.DK_StartDate IS NOT NULL AND b.FirstVisitStartDate IS NOT NULL
                                 AND b.FirstVisitStartDate < b.DK_StartDate THEN b.FirstVisitStartDate
                            ELSE b.DK_StartDate
                        END,
                    EndDate =
                        CASE
                            WHEN b.DK_EndDate IS NULL THEN NULL
                            WHEN b.DK_EndDate IS NOT NULL AND b.LastVisitEndDate IS NOT NULL
                                 AND b.LastVisitEndDate > b.DK_EndDate THEN b.LastVisitEndDate
                            ELSE b.DK_EndDate
                        END,

                    [Status]               = CASE WHEN b.StatusDesc       = '<No Selection>' THEN N'' ELSE b.StatusDesc       END,
                    CareGroup              = CASE WHEN b.CareGroupDesc    = '<No Selection>' THEN N'' ELSE b.CareGroupDesc    END,
                    LeftReason             = CASE WHEN b.LeftReasonDesc   = '<No Selection>' THEN N'' ELSE b.LeftReasonDesc   END,
                    EmployeeBranchLocation = CASE WHEN b.EmpBranchLocDesc = '<No Selection>' THEN N'' ELSE b.EmpBranchLocDesc END,

                    BranchEmployeeMainBranch = CASE WHEN b.DISTBranchReference = b.GS_REF THEN 'Y' ELSE 'N' END
                FROM Base b
                OUTER APPLY (
                    SELECT TOP (1) tb.BranchUID, tb.BranchName
                    FROM dbo.tbl_Branch tb
                    WHERE
                        (b.DISTBranchReference = '1970000043' AND b.EmpLocationDesc = 'Southampton' AND tb.BranchName = 'Southampton')
                        OR
                        (b.DISTBranchReference = '1970000043' AND (b.EmpLocationDesc IS NULL OR b.EmpLocationDesc <> 'Southampton') AND tb.BranchName = 'Portsmouth')
                        OR
                        (b.DISTBranchReference <> '1970000043' AND tb.OldBranchUID = b.DISTBranchReference)
                ) bpick
            ),
            -- Aggregate to ONE row per (EmployeeReference, BranchReference) – use COALESCE to avoid ANSI warnings
            FinalAgg AS (
                SELECT
                    s.EmployeeReference,
                    s.BranchReference,
                    MIN(s.StartDate) AS StartDate,  -- earliest
                    CASE WHEN SUM(CASE WHEN s.EndDate IS NULL THEN 1 ELSE 0 END) > 0
                         THEN NULL
                         ELSE MAX(s.EndDate)
                    END AS EndDate,                 -- NULL if any open
                    MAX(COALESCE(s.[Status],               N'')) AS [Status],
                    MAX(COALESCE(s.CareGroup,              N'')) AS CareGroup,
                    MAX(COALESCE(s.LeftReason,             N'')) AS LeftReason,
                    MAX(COALESCE(s.EmployeeBranchLocation, N'')) AS EmployeeBranchLocation,
                    MAX(COALESCE(s.BranchEmployeeMainBranch, 'N')) AS BranchEmployeeMainBranch, -- 'Y' beats 'N'
                    MAX(COALESCE(s.BranchName,             N'')) AS BranchName
                FROM Shaped s
                WHERE s.BranchReference IS NOT NULL
                  AND s.StartDate      IS NOT NULL
                GROUP BY s.EmployeeReference, s.BranchReference
            ),
            Final AS (
                SELECT
                    f.EmployeeReference,
                    f.BranchReference,
                    f.StartDate,
                    f.EndDate,
                    f.[Status],
                    f.CareGroup,
                    f.LeftReason,
                    f.EmployeeBranchLocation,
                    f.BranchEmployeeMainBranch,
                    f.BranchName,
                    HASHBYTES(
                        'SHA2_256',
                        CONCAT(
                            CONVERT(nvarchar(20), f.EmployeeReference),
                            N'|',
                            COALESCE(UPPER(LTRIM(RTRIM(f.BranchReference))), N'<NULL>')
                        )
                    ) AS EmpBranchHash
                FROM FinalAgg f
            )
            MERGE dbo.tbl_EmployeeBranch AS tgt
            USING Final AS src
               ON tgt.EmpBranchHash = src.EmpBranchHash
            WHEN MATCHED THEN
                UPDATE SET
                    tgt.EmployeeReference        = src.EmployeeReference,
                    tgt.BranchReference          = src.BranchReference,
                    tgt.StartDate                = src.StartDate,
                    tgt.EndDate                  = src.EndDate,
                    tgt.[Status]                 = src.[Status],
                    tgt.CareGroup                = src.CareGroup,
                    tgt.LeftReason               = src.LeftReason,
                    tgt.EmployeeBranchLocation   = src.EmployeeBranchLocation,
                    tgt.BranchEmployeeMainBranch = src.BranchEmployeeMainBranch,
                    tgt.BranchName               = src.BranchName,
                    tgt.UpdatedAtUTC             = @RunStartedAt
            WHEN NOT MATCHED BY TARGET THEN
                INSERT (
                    EmployeeReference, BranchReference, StartDate, EndDate,
                    [Status], CareGroup, LeftReason, EmployeeBranchLocation,
                    BranchEmployeeMainBranch, BranchName,
                    CreatedAtUTC, UpdatedAtUTC
                )
                VALUES (
                    src.EmployeeReference, src.BranchReference, src.StartDate, src.EndDate,
                    src.[Status], src.CareGroup, src.LeftReason, src.EmployeeBranchLocation,
                    src.BranchEmployeeMainBranch, src.BranchName,
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

            IF @EmitInfo=1 RAISERROR('EmployeeBranch chunk upserted: inserted=%d updated=%d (running %d/%d)', 0,1, @i, @u, @TotalInserted, @TotalUpdated) WITH NOWAIT;

            DELETE c
            FROM #Changed c
            JOIN #Next n
              ON n.EmployeeReference   = c.EmployeeReference
             AND n.DISTBranchReference = c.DISTBranchReference;
        END

        /* 4) Advance watermark + summary */
        UPDATE dbo.CT_Watermark
          SET LastSyncVersion = @ToVersion,
              LastSyncTime    = SYSUTCDATETIME()
        WHERE ProcessName = @Process;

        SET @EndUTC = SYSUTCDATETIME();
        SET @EndIso = CONVERT(varchar(33), @EndUTC, 126);
        SET @DurationSec = DATEDIFF(SECOND, @RunStartedAt, @EndUTC);

        SET @Summary = CONCAT(
            N'EmployeeBranch incremental started ', @StartIso, N' UTC; ended ', @EndIso,
            N' UTC; inserted ', CAST(@TotalInserted AS nvarchar(20)),
            N', updated ', CAST(@TotalUpdated AS nvarchar(20)),
            N'; advanced watermark to ', CAST(@ToVersion AS nvarchar(30)),
            N'; duration=', CAST(@DurationSec AS nvarchar(20)), N' sec.'
        );

        IF @EmitInfo=1 RAISERROR('EmployeeBranch incremental sync complete.', 0, 1) WITH NOWAIT;
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

        IF @EmitInfo=1 RAISERROR('usp_Sync_EmployeeBranch_Incremental failed (%d, sev %d, state %d) at %s line %d: %s',16,1,@num,@sev,@st,@procName,@lin,@msg);
        SET @Summary = CONCAT(N'EmployeeBranch incremental failed: ', @msg);
        IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
        RETURN -50001;
    END CATCH
END
GO
