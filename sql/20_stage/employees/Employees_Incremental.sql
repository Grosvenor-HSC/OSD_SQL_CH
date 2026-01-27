/*
Purpose:
    Incrementally load new and updated employee records into the staging employees table.

Source:
    Source employee tables/views (OSD / care system source).

Target:
    Staging employees table (e.g. dbo.tbl_Employees or equivalent).

Run type:
    Incremental.

Run frequency:
    Daily.

Safe to re-run:
    Usually YES, depending on implementation (MERGE / NOT EXISTS logic).

Notes:
    - Relies on a date or last-modified column to detect changes.
    - Must run BEFORE employee relationship incrementals (branch, skills, start/leave dates).
*/

USE [DOM_LIVE]
GO
/****** Object:  StoredProcedure [dbo].[usp_Sync_Employees_Incremental]    Script Date: 26/01/2026 20:45:52 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

ALTER   PROCEDURE [dbo].[usp_Sync_Employees_Incremental]
    @ChunkSize        int  = 100000,
    @LockTimeoutMs    int  = 60000,
    @UseAppLock       bit  = 1,
    @EmitInfo         bit  = 1,                          -- 0=quiet, 1=progress
    @Summary          nvarchar(4000) = NULL OUTPUT,      -- one-line summary
    @ReturnSummaryRow bit  = 1                           -- Initial sets this to 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Process       sysname      = N'Employees';
    DECLARE @RunStartedAt  datetime2(3) = SYSUTCDATETIME();
    DECLARE @StartIso      varchar(33)  = CONVERT(varchar(33), @RunStartedAt, 126);
    DECLARE @EndUTC        datetime2(3);
    DECLARE @EndIso        varchar(33);
    DECLARE @DurationSec   int;
    DECLARE @ret           int = 0;

    /* 0) Concurrency guard */
    DECLARE @LockResource sysname = N'DOM_LIVE:Sync:Employees';
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
            IF @EmitInfo=1 RAISERROR('Could not acquire %s (sp_getapplock rc=%d).', 0, 1, @LockResource, @lockResult);
            SET @Summary = N'Employees incremental failed: could not acquire applock.';
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            RETURN @lockResult;
        END
        SET @lockHeld = 1;
    END

    BEGIN TRY
        /* 1) Preconditions & bounds */
        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_databases WHERE database_id = DB_ID())
        BEGIN
            IF @EmitInfo=1 RAISERROR('Change Tracking is not enabled at the database level.', 0, 1);
            SET @Summary = N'Employees incremental failed: CT not enabled at DB level.';
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            SET @ret = -100; GOTO FinallyRelease;
        END

        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.EMPLOYEE'))
        BEGIN
            IF @EmitInfo=1 RAISERROR('Change Tracking is not enabled on dbo.EMPLOYEE.', 0, 1);
            SET @Summary = N'Employees incremental failed: CT not enabled on dbo.EMPLOYEE.';
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            SET @ret = -210; GOTO FinallyRelease;
        END

        DECLARE @CT_CONTACT_DT bit = CASE WHEN EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.CONTACT_DT')) THEN 1 ELSE 0 END;
        DECLARE @CT_CONTACT_HD bit = CASE WHEN EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.CONTACT_HD')) THEN 1 ELSE 0 END;
        DECLARE @CT_CHSYSDEC   bit = CASE WHEN EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.CHSYSDEC'))   THEN 1 ELSE 0 END;

        -- Watermark table/row
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
                OBJECT_ID(N'dbo.EMPLOYEE'),
                CASE WHEN @CT_CONTACT_DT=1 THEN OBJECT_ID(N'dbo.CONTACT_DT') ELSE NULL END,
                CASE WHEN @CT_CONTACT_HD=1 THEN OBJECT_ID(N'dbo.CONTACT_HD') ELSE NULL END,
                CASE WHEN @CT_CHSYSDEC  =1 THEN OBJECT_ID(N'dbo.CHSYSDEC')   ELSE NULL END
            )
        );

        IF @MinValid IS NOT NULL AND @LastSyncVersion < @MinValid
        BEGIN
            IF @EmitInfo=1 RAISERROR('Watermark (%I64d) < CT min valid (%I64d). Re-baseline required.', 0, 1, @LastSyncVersion, @MinValid);
            SET @Summary = CONCAT(N'Employees incremental failed: watermark ', @LastSyncVersion, N' < min valid ', @MinValid, N' (re-baseline).');
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            SET @ret = -200; GOTO FinallyRelease;
        END

        DECLARE @ToVersion bigint = CHANGE_TRACKING_CURRENT_VERSION();

        IF @EmitInfo=1
        BEGIN
            RAISERROR('Employees CT incremental window:', 0, 1) WITH NOWAIT;
            RAISERROR('  From = %I64d', 0, 1, @LastSyncVersion) WITH NOWAIT;
            RAISERROR('  To   = %I64d', 0, 1, @ToVersion) WITH NOWAIT;
        END

        /* 2) Build changed set (keys = EMP_REF) */
        IF OBJECT_ID('tempdb..#Changed') IS NOT NULL DROP TABLE #Changed;
        CREATE TABLE #Changed (UUID int NOT NULL PRIMARY KEY);  -- matches tbl_Employees primary key

        -- EMPLOYEE (I/U)
        INSERT INTO #Changed(UUID)
        SELECT DISTINCT e.EMP_REF
        FROM CHANGETABLE(CHANGES dbo.EMPLOYEE, @LastSyncVersion) ct
        JOIN dbo.EMPLOYEE e ON e.EMP_REF = ct.EMP_REF
        WHERE ct.SYS_CHANGE_VERSION <= @ToVersion
          AND ct.SYS_CHANGE_OPERATION IN ('I','U');

        -- CONTACT_DT (opt)
        IF @CT_CONTACT_DT = 1
        BEGIN
            INSERT INTO #Changed(UUID)
            SELECT DISTINCT e.EMP_REF
            FROM CHANGETABLE(CHANGES dbo.CONTACT_DT, @LastSyncVersion) x
            JOIN dbo.EMPLOYEE e ON e.CNTA_DET_REF = x.CNTA_DET_REF
            WHERE x.SYS_CHANGE_VERSION <= @ToVersion
              AND NOT EXISTS (SELECT 1 FROM #Changed z WHERE z.UUID = e.EMP_REF);
        END
        ELSE IF @EmitInfo=1
            RAISERROR('Note: CT not enabled on CONTACT_DT; contact changes not captured.', 0, 1) WITH NOWAIT;

        -- CONTACT_HD (opt)
        IF @CT_CONTACT_HD = 1
        BEGIN
            INSERT INTO #Changed(UUID)
            SELECT DISTINCT e.EMP_REF
            FROM CHANGETABLE(CHANGES dbo.CONTACT_HD, @LastSyncVersion) h
            JOIN dbo.CONTACT_DT dt ON dt.CONTACT_REF = h.CONTACT_REF
            JOIN dbo.EMPLOYEE  e  ON e.CNTA_DET_REF  = dt.CNTA_DET_REF
            WHERE h.SYS_CHANGE_VERSION <= @ToVersion
              AND NOT EXISTS (SELECT 1 FROM #Changed z WHERE z.UUID = e.EMP_REF);
        END
        ELSE IF @EmitInfo=1
            RAISERROR('Note: CT not enabled on CONTACT_HD; header changes not captured.', 0, 1) WITH NOWAIT;

        -- CHSYSDEC (opt) — only decodes we actually project
        IF @CT_CHSYSDEC = 1
        BEGIN
            INSERT INTO #Changed(UUID)
            SELECT DISTINCT e.EMP_REF
            FROM CHANGETABLE(CHANGES dbo.CHSYSDEC, @LastSyncVersion) d
            JOIN dbo.EMPLOYEE e
              ON e.ETHNICITY  = d.DECODE_REF
              OR e.RELORG_REF = d.DECODE_REF
              OR e.JOBTITLE   = d.DECODE_REF
              OR e.JOB_QUAL   = d.DECODE_REF
            WHERE d.SYS_CHANGE_VERSION <= @ToVersion
              AND NOT EXISTS (SELECT 1 FROM #Changed z WHERE z.UUID = e.EMP_REF);
        END
        ELSE IF @EmitInfo=1
            RAISERROR('Note: CT not enabled on CHSYSDEC; decoded text changes not captured.', 0, 1) WITH NOWAIT;

        DECLARE @ToProcess int = (SELECT COUNT(*) FROM #Changed);
        IF @EmitInfo=1 RAISERROR('Employees to process: %d', 0, 1, @ToProcess) WITH NOWAIT;

        IF @ToProcess = 0
        BEGIN
            UPDATE dbo.CT_Watermark
              SET LastSyncVersion=@ToVersion, LastSyncTime=SYSUTCDATETIME()
            WHERE ProcessName=@Process;

            SET @EndUTC = SYSUTCDATETIME();
            SET @EndIso = CONVERT(varchar(33), @EndUTC, 126);
            SET @DurationSec = DATEDIFF(SECOND, @RunStartedAt, @EndUTC);

            SET @Summary = CONCAT(
                N'Employees incremental started ', @StartIso, N' UTC; ended ', @EndIso,
                N' UTC; inserted 0, updated 0, deleted 0; advanced watermark to ',
                CAST(@ToVersion AS nvarchar(30)), N'; duration=', @DurationSec, N' sec.'
            );

            IF @EmitInfo=1 RAISERROR('No changes. Watermark advanced.', 0, 1) WITH NOWAIT;
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            SET @ret = 0; GOTO FinallyRelease;
        END

        /* 3) Chunked MERGE into dbo.tbl_Employees (schema aligned with Initial) */
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

            ;WITH Base AS
            (
                SELECT
                    UUID                = E.EMP_REF,
                    DOB                 = CAST(E.BIRTH_DATE AS DATE),
                    Code                = E.EMP_CODE,
                    Gender              = CASE E.SEX WHEN 'M' THEN 'Male'
                                                    WHEN 'F' THEN 'Female'
                                                    WHEN 'N' THEN 'Not Applicable'
                                                    ELSE 'Unknown' END,
                    Forenames           = NULLIF(LTRIM(RTRIM(CHD.FORENAMES)), ''),
                    Surname             = NULLIF(LTRIM(RTRIM(CHD.SURNAME)), ''),
                    Telephone_Number    = NULLIF(LTRIM(RTRIM(CHD.TEL_NO1)), ''),
                    Payroll_Number      = NULLIF(LTRIM(RTRIM(E.PAYROLL_NO)), ''),
                    Email               = NULLIF(LTRIM(RTRIM(CHD.EMAIL)), ''),
                    Ethnicity           = NULLIF(LTRIM(RTRIM(CEE.DESCRIPTION)), ''),
                    Religion            = CASE WHEN LTRIM(RTRIM(CER.DESCRIPTION)) = 'Not Declared' THEN NULL
                                               ELSE nullif(NULLIF(LTRIM(RTRIM(CER.DESCRIPTION)), ''), '<no selection>') END,
                    Job_Title           = NULLIF(LTRIM(RTRIM(CEJT.DESCRIPTION)), ''),
                    Salaried            = CASE WHEN LTRIM(RTRIM(JQ.DESCRIPTION)) = '<no selection>' THEN NULL
                                               ELSE NULLIF(LTRIM(RTRIM(JQ.DESCRIPTION)), '') END,
                    Payroll_Schedule    = NULLIF(LTRIM(RTRIM(E.INTERFACE)), ''),
                    Driver              = E.DRIVER,
                    First_Line_Address  = NULLIF(LTRIM(RTRIM(CHD.ADDRESS1)), ''),
                    Second_Line_Address = NULLIF(LTRIM(RTRIM(CHD.ADDRESS2)), ''),
                    Third_Line_Address  = NULLIF(LTRIM(RTRIM(CHD.ADDRESS3)), ''),
                    Fourth_Line_Address = NULLIF(LTRIM(RTRIM(CHD.ADDRESS4)), ''),
                    Postcode            = NULLIF(LTRIM(RTRIM(CHD.POSTCODE)), '')
                FROM dbo.EMPLOYEE E
                JOIN #Next n                 ON n.UUID           = E.EMP_REF
                LEFT JOIN dbo.CONTACT_DT CDT ON CDT.CNTA_DET_REF = E.CNTA_DET_REF
                LEFT JOIN dbo.CONTACT_HD CHD ON CHD.CONTACT_REF  = CDT.CONTACT_REF
                LEFT JOIN dbo.CHSYSDEC CEE   ON E.ETHNICITY      = CEE.DECODE_REF
                LEFT JOIN dbo.CHSYSDEC CER   ON E.RELORG_REF     = CER.DECODE_REF
                LEFT JOIN dbo.CHSYSDEC CEJT  ON E.JOBTITLE       = CEJT.DECODE_REF
                LEFT JOIN dbo.CHSYSDEC JQ    ON E.JOB_QUAL       = JQ.DECODE_REF
            )
            MERGE dbo.tbl_Employees AS tgt
            USING Base AS src
               ON tgt.UUID = src.UUID
            WHEN MATCHED THEN
                UPDATE SET
                    tgt.DOB                 = src.DOB,
                    tgt.Code                = src.Code,
                    tgt.Gender              = src.Gender,
                    tgt.Forenames           = src.Forenames,
                    tgt.Surname             = src.Surname,
                    tgt.Telephone_Number    = src.Telephone_Number,
                    tgt.Payroll_Number      = src.Payroll_Number,
                    tgt.Email               = src.Email,
                    tgt.Ethnicity           = src.Ethnicity,
                    tgt.Religion            = src.Religion,
                    tgt.Job_Title           = src.Job_Title,
                    tgt.Salaried            = src.Salaried,
                    tgt.Payroll_Schedule    = src.Payroll_Schedule,
                    tgt.Driver              = src.Driver,
                    tgt.First_Line_Address  = src.First_Line_Address,
                    tgt.Second_Line_Address = src.Second_Line_Address,
                    tgt.Third_Line_Address  = src.Third_Line_Address,
                    tgt.Fourth_Line_Address = src.Fourth_Line_Address,
                    tgt.Postcode            = src.Postcode,
                    tgt.UpdatedAtUTC        = @RunStartedAt
            WHEN NOT MATCHED BY TARGET THEN
                INSERT (
                    UUID, DOB, Code, Gender,
                    Forenames, Surname, Telephone_Number, Payroll_Number, Email,
                    Ethnicity, Religion, Job_Title, Salaried, Payroll_Schedule, Driver,
                    First_Line_Address, Second_Line_Address, Third_Line_Address, Fourth_Line_Address,
                    Postcode, CreatedAtUTC, UpdatedAtUTC
                )
                VALUES (
                    src.UUID, src.DOB, src.Code, src.Gender,
                    src.Forenames, src.Surname, src.Telephone_Number, src.Payroll_Number, src.Email,
                    src.Ethnicity, src.Religion, src.Job_Title, src.Salaried, src.Payroll_Schedule, src.Driver,
                    src.First_Line_Address, src.Second_Line_Address, src.Third_Line_Address, src.Fourth_Line_Address,
                    src.Postcode, @RunStartedAt, @RunStartedAt
                )
            OUTPUT $action INTO #ActLog(Action);

            DECLARE @i int = 0, @u int = 0;
            SELECT @i = SUM(CASE WHEN Action='INSERT' THEN 1 ELSE 0 END),
                   @u = SUM(CASE WHEN Action='UPDATE' THEN 1 ELSE 0 END)
            FROM #ActLog;

            SET @TotalInserted += ISNULL(@i,0);
            SET @TotalUpdated  += ISNULL(@u,0);

            IF @EmitInfo=1
                RAISERROR('Employees chunk: inserted=%d updated=%d (running %d/%d)', 0, 1, @i, @u, @TotalInserted, @TotalUpdated) WITH NOWAIT;

            DELETE c
            FROM #Changed c
            JOIN #Next n ON n.UUID = c.UUID;
        END

        /* 4) Apply deletes (EMPLOYEE deletes) */
        IF OBJECT_ID('tempdb..#DelLog') IS NOT NULL DROP TABLE #DelLog;
        CREATE TABLE #DelLog(UUID int NOT NULL);

        DELETE t
        OUTPUT DELETED.UUID INTO #DelLog(UUID)
        FROM dbo.tbl_Employees t
        JOIN (
            SELECT d.EMP_REF
            FROM CHANGETABLE(CHANGES dbo.EMPLOYEE, @LastSyncVersion) d
            WHERE d.SYS_CHANGE_OPERATION = 'D'
              AND d.SYS_CHANGE_VERSION   <= @ToVersion
        ) x ON t.UUID = x.EMP_REF;

        SET @TotalDeleted = (SELECT COUNT(*) FROM #DelLog);
        IF @EmitInfo=1 RAISERROR('Deleted from tbl_Employees due to source deletes: %d', 0, 1, @TotalDeleted) WITH NOWAIT;

        /* 5) Advance watermark + summary */
        UPDATE dbo.CT_Watermark
          SET LastSyncVersion=@ToVersion, LastSyncTime=SYSUTCDATETIME()
        WHERE ProcessName=@Process;

        SET @EndUTC = SYSUTCDATETIME();
        SET @EndIso = CONVERT(varchar(33), @EndUTC, 126);
        SET @DurationSec = DATEDIFF(SECOND, @RunStartedAt, @EndUTC);

        SET @Summary = CONCAT(
            N'Employees incremental started ', @StartIso, N' UTC; ended ', @EndIso,
            N' UTC; inserted ', CAST(@TotalInserted AS nvarchar(20)),
            N', updated ', CAST(@TotalUpdated AS nvarchar(20)),
            N', deleted ', CAST(@TotalDeleted AS nvarchar(20)),
            N'; advanced watermark to ', CAST(@ToVersion AS nvarchar(30)),
            N'; duration=', CAST(@DurationSec AS nvarchar(20)), N' sec.'
        );

        IF @EmitInfo=1 RAISERROR('Employees incremental sync complete.', 0, 1) WITH NOWAIT;
        IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;

        SET @ret = 0;

FinallyRelease:
        IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;
        RETURN @ret;
    END TRY
    BEGIN CATCH
        IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;
        DECLARE @msg nvarchar(4000)=ERROR_MESSAGE();
        DECLARE @num int=ERROR_NUMBER(), @sev int=ERROR_SEVERITY(), @st int=ERROR_STATE(), @lin int=ERROR_LINE(), @proc sysname=ERROR_PROCEDURE();
        DECLARE @procName sysname = ISNULL(@proc, N'<adhoc>');
        IF @EmitInfo=1 RAISERROR('usp_Sync_Employees_Incremental failed (%d, sev %d, state %d) at %s line %d: %s', 16, 1, @num, @sev, @st, @procName, @lin, @msg);
        SET @Summary = CONCAT(N'Employees incremental failed: ', @msg);
        IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
        RETURN -50001;
    END CATCH
END
