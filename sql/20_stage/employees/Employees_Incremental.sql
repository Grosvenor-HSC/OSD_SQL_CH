USE [DOM_LIVE];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Sync_Employees_Incremental
    @ChunkSize        int            = 100000,
    @LockTimeoutMs    int            = 60000,
    @UseAppLock       bit            = 1,
    @EmitInfo         bit            = 1,
    @Summary          nvarchar(4000) = NULL OUTPUT,
    @ReturnSummaryRow bit            = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -------------------------------------------------------------------------
    -- Identity
    -------------------------------------------------------------------------
    DECLARE @Process       sysname      = N'Employees';
    DECLARE @RunStartedAt  datetime2(3) = SYSUTCDATETIME();
    DECLARE @StartIso      varchar(33)  = CONVERT(varchar(33), @RunStartedAt, 126);

    DECLARE @EndUTC        datetime2(3);
    DECLARE @EndIso        varchar(33);

    DECLARE @DurationMs    bigint;
    DECLARE @DurationSec   decimal(12,3);

    -------------------------------------------------------------------------
    -- Concurrency guard
    -------------------------------------------------------------------------
    DECLARE @LockResource sysname = N'DOM_LIVE:Sync:Employees';
    DECLARE @LockOwner    sysname = N'Session';
    DECLARE @DbPrincipal  sysname = N'dbo';
    DECLARE @lockResult   int;
    DECLARE @lockHeld     bit = 0;

    -------------------------------------------------------------------------
    -- Working totals
    -------------------------------------------------------------------------
    DECLARE @TotalInserted bigint = 0;
    DECLARE @TotalUpdated  bigint = 0;
    DECLARE @TotalDeleted  bigint = 0;

    -------------------------------------------------------------------------
    -- CT vars
    -------------------------------------------------------------------------
    DECLARE @LastSyncVersion bigint = NULL;
    DECLARE @ToVersion       bigint = NULL;

    -------------------------------------------------------------------------
    -- Capability flags
    -------------------------------------------------------------------------
    DECLARE @CT_CONTACT_DT bit;
    DECLARE @CT_CONTACT_HD bit;
    DECLARE @CT_CHSYSDEC   bit;

    BEGIN TRY
        ---------------------------------------------------------------------
        -- Validate inputs
        ---------------------------------------------------------------------
        IF @ChunkSize IS NULL OR @ChunkSize <= 0
            THROW 50000, 'Employees incremental: @ChunkSize must be > 0.', 1;

        IF @LockTimeoutMs IS NULL OR @LockTimeoutMs < 0
            THROW 50000, 'Employees incremental: @LockTimeoutMs must be >= 0.', 1;

        ---------------------------------------------------------------------
        -- Acquire applock (optional)
        ---------------------------------------------------------------------
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
                SET @Summary = N'Employees incremental failed: could not acquire applock.';
                IF @ReturnSummaryRow = 1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
                RETURN @lockResult;
            END

            SET @lockHeld = 1;
        END

        ---------------------------------------------------------------------
        -- Preconditions
        ---------------------------------------------------------------------
        IF OBJECT_ID(N'dbo.tbl_Employees', N'U') IS NULL
            THROW 50000, 'Employees incremental failed: target dbo.tbl_Employees missing (run initial).', 1;

        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_databases WHERE database_id = DB_ID())
            THROW 50000, 'Employees incremental failed: Change Tracking not enabled at DB level.', 1;

        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.EMPLOYEE'))
            THROW 50000, 'Employees incremental failed: CT not enabled on dbo.EMPLOYEE.', 1;

        SET @CT_CONTACT_DT = CASE WHEN EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.CONTACT_DT')) THEN 1 ELSE 0 END;
        SET @CT_CONTACT_HD = CASE WHEN EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.CONTACT_HD')) THEN 1 ELSE 0 END;
        SET @CT_CHSYSDEC   = CASE WHEN EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.CHSYSDEC'))   THEN 1 ELSE 0 END;

        ---------------------------------------------------------------------
        -- Watermark table (idempotent)
        ---------------------------------------------------------------------
        IF OBJECT_ID(N'dbo.CT_Watermark', N'U') IS NULL
        BEGIN
            CREATE TABLE dbo.CT_Watermark
            (
              ProcessName     sysname      NOT NULL CONSTRAINT PK_CT_Watermark PRIMARY KEY,
              LastSyncVersion bigint       NOT NULL,
              LastSyncTime    datetime2(3) NOT NULL CONSTRAINT DF_CT_Watermark_LastSyncTime DEFAULT SYSUTCDATETIME()
            );
        END

        IF NOT EXISTS (SELECT 1 FROM dbo.CT_Watermark WITH (HOLDLOCK, UPDLOCK) WHERE ProcessName = @Process)
            INSERT INTO dbo.CT_Watermark(ProcessName, LastSyncVersion) VALUES (@Process, 0);

        SELECT @LastSyncVersion = LastSyncVersion
        FROM dbo.CT_Watermark WITH (HOLDLOCK, UPDLOCK)
        WHERE ProcessName = @Process;

        ---------------------------------------------------------------------
        -- Validate min valid version across all contributing tables
        ---------------------------------------------------------------------
        DECLARE @MinValid bigint =
        (
            SELECT MAX(CHANGE_TRACKING_MIN_VALID_VERSION(object_id))
            FROM sys.change_tracking_tables
            WHERE object_id IN
            (
                OBJECT_ID(N'dbo.EMPLOYEE'),
                CASE WHEN @CT_CONTACT_DT = 1 THEN OBJECT_ID(N'dbo.CONTACT_DT') ELSE NULL END,
                CASE WHEN @CT_CONTACT_HD = 1 THEN OBJECT_ID(N'dbo.CONTACT_HD') ELSE NULL END,
                CASE WHEN @CT_CHSYSDEC   = 1 THEN OBJECT_ID(N'dbo.CHSYSDEC')   ELSE NULL END
            )
        );

        IF @MinValid IS NOT NULL AND @LastSyncVersion < @MinValid
        BEGIN
            SET @Summary = CONCAT(N'Employees incremental failed: watermark ', @LastSyncVersion,
                                 N' < min valid ', @MinValid, N' (re-baseline required).');
            IF @ReturnSummaryRow = 1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            IF @lockHeld = 1
                EXEC sys.sp_releaseapplock @Resource = @LockResource, @LockOwner = @LockOwner, @DbPrincipal = @DbPrincipal;
            RETURN -200;
        END

        SET @ToVersion = CHANGE_TRACKING_CURRENT_VERSION();

        IF @EmitInfo = 1
        BEGIN
            RAISERROR('Employees CT incremental window:', 0, 1) WITH NOWAIT;
            RAISERROR('  From = %I64d', 0, 1, @LastSyncVersion) WITH NOWAIT;
            RAISERROR('  To   = %I64d', 0, 1, @ToVersion) WITH NOWAIT;
        END

        ---------------------------------------------------------------------
        -- Temp tables: create once, reuse (avoids repeated tempdb metadata churn)
        ---------------------------------------------------------------------
        IF OBJECT_ID('tempdb..#Changed') IS NOT NULL DROP TABLE #Changed;
        CREATE TABLE #Changed (UUID int NOT NULL PRIMARY KEY);

        IF OBJECT_ID('tempdb..#Next') IS NOT NULL DROP TABLE #Next;
        CREATE TABLE #Next (UUID int NOT NULL PRIMARY KEY);

        IF OBJECT_ID('tempdb..#ActLog') IS NOT NULL DROP TABLE #ActLog;
        CREATE TABLE #ActLog (Action nvarchar(10) NOT NULL);

        IF OBJECT_ID('tempdb..#DelLog') IS NOT NULL DROP TABLE #DelLog;
        CREATE TABLE #DelLog (UUID int NOT NULL);

        ---------------------------------------------------------------------
        -- Build changed key set
        ---------------------------------------------------------------------
        INSERT INTO #Changed(UUID)
        SELECT DISTINCT ct.EMP_REF
        FROM CHANGETABLE(CHANGES dbo.EMPLOYEE, @LastSyncVersion) ct
        WHERE ct.SYS_CHANGE_VERSION <= @ToVersion;

        IF @CT_CONTACT_DT = 1
        BEGIN
            INSERT INTO #Changed(UUID)
            SELECT DISTINCT e.EMP_REF
            FROM CHANGETABLE(CHANGES dbo.CONTACT_DT, @LastSyncVersion) x
            JOIN dbo.EMPLOYEE e ON e.CNTA_DET_REF = x.CNTA_DET_REF
            WHERE x.SYS_CHANGE_VERSION <= @ToVersion
              AND NOT EXISTS (SELECT 1 FROM #Changed z WHERE z.UUID = e.EMP_REF);
        END
        ELSE IF @EmitInfo = 1
            RAISERROR('Note: CT not enabled on CONTACT_DT; contact changes not captured.', 0, 1) WITH NOWAIT;

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
        ELSE IF @EmitInfo = 1
            RAISERROR('Note: CT not enabled on CONTACT_HD; header changes not captured.', 0, 1) WITH NOWAIT;

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
        ELSE IF @EmitInfo = 1
            RAISERROR('Note: CT not enabled on CHSYSDEC; decoded text changes not captured.', 0, 1) WITH NOWAIT;

        DECLARE @ToProcess int = (SELECT COUNT(*) FROM #Changed);
        IF @EmitInfo = 1 RAISERROR('Employees to process: %d', 0, 1, @ToProcess) WITH NOWAIT;

        ---------------------------------------------------------------------
        -- No changes: advance watermark and exit
        ---------------------------------------------------------------------
        IF @ToProcess = 0
        BEGIN
            UPDATE dbo.CT_Watermark
              SET LastSyncVersion = @ToVersion,
                  LastSyncTime    = SYSUTCDATETIME()
            WHERE ProcessName = @Process;

            SET @EndUTC = SYSUTCDATETIME();
            SET @EndIso = CONVERT(varchar(33), @EndUTC, 126);
            SET @DurationMs  = DATEDIFF(MILLISECOND, @RunStartedAt, @EndUTC);
            SET @DurationSec = CAST(@DurationMs / 1000.0 AS decimal(12,3));

            SET @Summary = CONCAT(
                N'Employees incremental started ', @StartIso, N' UTC; ended ', @EndIso,
                N' UTC; inserted 0, updated 0, deleted 0; advanced watermark to ',
                CAST(@ToVersion AS nvarchar(30)),
                N'; duration_ms=', @DurationMs,
                N' sec=', @DurationSec, N'.'
            );

            IF @EmitInfo = 1 RAISERROR('No changes. Watermark advanced.', 0, 1) WITH NOWAIT;
            IF @ReturnSummaryRow = 1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            IF @lockHeld = 1
                EXEC sys.sp_releaseapplock @Resource = @LockResource, @LockOwner = @LockOwner, @DbPrincipal = @DbPrincipal;
            RETURN 0;
        END

        ---------------------------------------------------------------------
        -- Chunked upsert
        ---------------------------------------------------------------------
        WHILE EXISTS (SELECT 1 FROM #Changed)
        BEGIN
            TRUNCATE TABLE #Next;
            TRUNCATE TABLE #ActLog;

            INSERT INTO #Next(UUID)
            SELECT TOP (@ChunkSize) UUID
            FROM #Changed
            ORDER BY UUID;

            ;WITH EmpBase AS
            (
                SELECT
                    UUID = E.EMP_REF,
                    DOB  = TRY_CONVERT(date, E.BIRTH_DATE),
                    Code = LTRIM(RTRIM(E.EMP_CODE)),
                    Gender =
                        CASE E.SEX
                            WHEN 'M' THEN 'Male'
                            WHEN 'F' THEN 'Female'
                            WHEN 'N' THEN 'Not Applicable'
                            ELSE 'Unknown'
                        END,
                    Forenames        = NULLIF(LTRIM(RTRIM(CHD.FORENAMES)), ''),
                    Surname          = NULLIF(LTRIM(RTRIM(CHD.SURNAME)),   ''),
                    Telephone_Number = NULLIF(LTRIM(RTRIM(CHD.TEL_NO1)),   ''),
                    Payroll_Number   = NULLIF(LTRIM(RTRIM(E.PAYROLL_NO)),  ''),
                    Email            = NULLIF(LTRIM(RTRIM(CHD.EMAIL)),     ''),
                    Ethnicity        = NULLIF(LTRIM(RTRIM(CEE.DESCRIPTION)), ''),
                    Religion         = CASE WHEN LTRIM(RTRIM(CER.DESCRIPTION)) = 'Not Declared'
                                            THEN NULL
                                            ELSE NULLIF(LTRIM(RTRIM(CER.DESCRIPTION)), '')
                                       END,
                    Job_Title        = NULLIF(LTRIM(RTRIM(CEJT.DESCRIPTION)), ''),
                    Salaried         = CASE WHEN LTRIM(RTRIM(JQ.DESCRIPTION)) = '<no selection>'
                                            THEN NULL
                                            ELSE NULLIF(LTRIM(RTRIM(JQ.DESCRIPTION)), '')
                                       END,
                    Payroll_Schedule = NULLIF(LTRIM(RTRIM(E.INTERFACE)), ''),
                    Driver           = NULLIF(LTRIM(RTRIM(E.DRIVER)), ''),
                    First_Line_Address  = NULLIF(LTRIM(RTRIM(CHD.ADDRESS1)), ''),
                    Second_Line_Address = NULLIF(LTRIM(RTRIM(CHD.ADDRESS2)), ''),
                    Third_Line_Address  = NULLIF(LTRIM(RTRIM(CHD.ADDRESS3)), ''),
                    Fourth_Line_Address = NULLIF(LTRIM(RTRIM(CHD.ADDRESS4)), ''),
                    Postcode            = NULLIF(LTRIM(RTRIM(CHD.POSTCODE)), '')
                FROM dbo.EMPLOYEE AS E
                JOIN #Next n                 ON n.UUID           = E.EMP_REF
                LEFT JOIN dbo.CONTACT_DT CDT ON CDT.CNTA_DET_REF = E.CNTA_DET_REF
                LEFT JOIN dbo.CONTACT_HD CHD ON CHD.CONTACT_REF  = CDT.CONTACT_REF
                LEFT JOIN dbo.CHSYSDEC   AS CEE  ON E.ETHNICITY  = CEE.DECODE_REF
                LEFT JOIN dbo.CHSYSDEC   AS CER  ON E.RELORG_REF = CER.DECODE_REF
                LEFT JOIN dbo.CHSYSDEC   AS CEJT ON E.JOBTITLE   = CEJT.DECODE_REF
                LEFT JOIN dbo.CHSYSDEC   AS JQ   ON E.JOB_QUAL   = JQ.DECODE_REF
                WHERE E.EMP_REF IS NOT NULL
            )
            MERGE dbo.tbl_Employees AS tgt
            USING EmpBase AS src
               ON tgt.UUID = src.UUID
            WHEN MATCHED AND
            (
                ISNULL(tgt.DOB,'19000101') <> ISNULL(src.DOB,'19000101')
                OR ISNULL(tgt.Code,'') <> ISNULL(src.Code,'')
                OR ISNULL(tgt.Gender,'') <> ISNULL(src.Gender,'')
                OR ISNULL(tgt.Forenames,'') <> ISNULL(src.Forenames,'')
                OR ISNULL(tgt.Surname,'') <> ISNULL(src.Surname,'')
                OR ISNULL(tgt.Telephone_Number,'') <> ISNULL(src.Telephone_Number,'')
                OR ISNULL(tgt.Payroll_Number,'') <> ISNULL(src.Payroll_Number,'')
                OR ISNULL(tgt.Email,'') <> ISNULL(src.Email,'')
                OR ISNULL(tgt.Ethnicity,'') <> ISNULL(src.Ethnicity,'')
                OR ISNULL(tgt.Religion,'') <> ISNULL(src.Religion,'')
                OR ISNULL(tgt.Job_Title,'') <> ISNULL(src.Job_Title,'')
                OR ISNULL(tgt.Salaried,'') <> ISNULL(src.Salaried,'')
                OR ISNULL(tgt.Payroll_Schedule,'') <> ISNULL(src.Payroll_Schedule,'')
                OR ISNULL(tgt.Driver,'') <> ISNULL(src.Driver,'')
                OR ISNULL(tgt.First_Line_Address,'') <> ISNULL(src.First_Line_Address,'')
                OR ISNULL(tgt.Second_Line_Address,'') <> ISNULL(src.Second_Line_Address,'')
                OR ISNULL(tgt.Third_Line_Address,'') <> ISNULL(src.Third_Line_Address,'')
                OR ISNULL(tgt.Fourth_Line_Address,'') <> ISNULL(src.Fourth_Line_Address,'')
                OR ISNULL(tgt.Postcode,'') <> ISNULL(src.Postcode,'')
            )
            THEN
                UPDATE SET
                    DOB                 = src.DOB,
                    Code                = src.Code,
                    Gender              = src.Gender,
                    Forenames           = src.Forenames,
                    Surname             = src.Surname,
                    Telephone_Number    = src.Telephone_Number,
                    Payroll_Number      = src.Payroll_Number,
                    Email               = src.Email,
                    Ethnicity           = src.Ethnicity,
                    Religion            = src.Religion,
                    Job_Title           = src.Job_Title,
                    Salaried            = src.Salaried,
                    Payroll_Schedule    = src.Payroll_Schedule,
                    Driver              = src.Driver,
                    First_Line_Address  = src.First_Line_Address,
                    Second_Line_Address = src.Second_Line_Address,
                    Third_Line_Address  = src.Third_Line_Address,
                    Fourth_Line_Address = src.Fourth_Line_Address,
                    Postcode            = src.Postcode,
                    UpdatedAtUTC        = @RunStartedAt
            WHEN NOT MATCHED BY TARGET THEN
                INSERT
                (
                    UUID, DOB, Code, Gender, Forenames, Surname, Telephone_Number, Payroll_Number, Email,
                    Ethnicity, Religion, Job_Title, Salaried, Payroll_Schedule, Driver,
                    First_Line_Address, Second_Line_Address, Third_Line_Address, Fourth_Line_Address,
                    Postcode, CreatedAtUTC, UpdatedAtUTC
                )
                VALUES
                (
                    src.UUID, src.DOB, src.Code, src.Gender, src.Forenames, src.Surname, src.Telephone_Number, src.Payroll_Number, src.Email,
                    src.Ethnicity, src.Religion, src.Job_Title, src.Salaried, src.Payroll_Schedule, src.Driver,
                    src.First_Line_Address, src.Second_Line_Address, src.Third_Line_Address, src.Fourth_Line_Address,
                    src.Postcode, @RunStartedAt, @RunStartedAt
                )
            OUTPUT $action INTO #ActLog(Action);

            DECLARE @i2 int = 0, @u2 int = 0;

            /* SUM() over 0 rows returns NULL -> COALESCE to prevent "(null)" logging */
            SELECT
                @i2 = COALESCE(SUM(CASE WHEN Action = 'INSERT' THEN 1 ELSE 0 END), 0),
                @u2 = COALESCE(SUM(CASE WHEN Action = 'UPDATE' THEN 1 ELSE 0 END), 0)
            FROM #ActLog;

            SET @TotalInserted += @i2;
            SET @TotalUpdated  += @u2;

            IF @EmitInfo = 1
                RAISERROR('Employees chunk: inserted=%d updated=%d (running ins=%I64d upd=%I64d)',
                          0, 1, @i2, @u2, @TotalInserted, @TotalUpdated) WITH NOWAIT;

            DELETE c
            FROM #Changed c
            JOIN #Next n ON n.UUID = c.UUID;
        END

        ---------------------------------------------------------------------
        -- Hard deletes from EMPLOYEE CT
        ---------------------------------------------------------------------
        TRUNCATE TABLE #DelLog;

        DELETE t
        OUTPUT DELETED.UUID INTO #DelLog(UUID)
        FROM dbo.tbl_Employees t
        JOIN
        (
            SELECT d.EMP_REF
            FROM CHANGETABLE(CHANGES dbo.EMPLOYEE, @LastSyncVersion) d
            WHERE d.SYS_CHANGE_OPERATION = 'D'
              AND d.SYS_CHANGE_VERSION   <= @ToVersion
        ) x
          ON x.EMP_REF = t.UUID;

        SET @TotalDeleted = (SELECT COUNT_BIG(*) FROM #DelLog);

        ---------------------------------------------------------------------
        -- Advance watermark + summary
        ---------------------------------------------------------------------
        UPDATE dbo.CT_Watermark
          SET LastSyncVersion = @ToVersion,
              LastSyncTime    = SYSUTCDATETIME()
        WHERE ProcessName = @Process;

        SET @EndUTC = SYSUTCDATETIME();
        SET @EndIso = CONVERT(varchar(33), @EndUTC, 126);

        SET @DurationMs  = DATEDIFF(MILLISECOND, @RunStartedAt, @EndUTC);
        SET @DurationSec = CAST(@DurationMs / 1000.0 AS decimal(12,3));

        SET @Summary = CONCAT(
            N'Employees incremental started ', @StartIso, N' UTC; ended ', @EndIso,
            N' UTC; inserted ', CAST(@TotalInserted AS nvarchar(20)),
            N', updated ', CAST(@TotalUpdated AS nvarchar(20)),
            N', deleted ', CAST(@TotalDeleted AS nvarchar(20)),
            N'; advanced watermark to ', CAST(@ToVersion AS nvarchar(30)),
            N'; duration_ms=', CAST(@DurationMs AS nvarchar(20)),
            N' sec=', CAST(@DurationSec AS nvarchar(20)), N'.'
        );

        IF @EmitInfo = 1 RAISERROR('Employees incremental sync complete.', 0, 1) WITH NOWAIT;
        IF @ReturnSummaryRow = 1 SELECT 'Incremental' AS Stage, @Summary AS Summary;

        IF @lockHeld = 1
            EXEC sys.sp_releaseapplock @Resource = @LockResource, @LockOwner = @LockOwner, @DbPrincipal = @DbPrincipal;

        RETURN 0;
    END TRY
    BEGIN CATCH
        DECLARE @msg nvarchar(4000) = ERROR_MESSAGE();
        DECLARE @num int = ERROR_NUMBER(), @sev int = ERROR_SEVERITY(), @st int = ERROR_STATE(),
                @lin int = ERROR_LINE(), @proc sysname = ERROR_PROCEDURE();
        DECLARE @procName sysname = ISNULL(@proc, N'<adhoc>');

        SET @Summary = CONCAT(N'Employees incremental failed: ', @msg);

        IF @EmitInfo = 1
            RAISERROR('usp_Sync_Employees_Incremental failed (%d, sev %d, state %d) at %s line %d: %s',
                      16, 1, @num, @sev, @st, @procName, @lin, @msg);

        IF @ReturnSummaryRow = 1 SELECT 'Incremental' AS Stage, @Summary AS Summary;

        IF @lockHeld = 1
            EXEC sys.sp_releaseapplock @Resource = @LockResource, @LockOwner = @LockOwner, @DbPrincipal = @DbPrincipal;

        RETURN -50001;
    END CATCH

END
GO
