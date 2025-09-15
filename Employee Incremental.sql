USE [DOM_LIVE];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Sync_Employees_Incremental
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
    DECLARE @ret           int = 0;      -- final return code

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
            IF @EmitInfo=1 RAISERROR('Could not acquire %s (sp_getapplock rc=%d).',16,1,@LockResource,@lockResult);
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
            IF @EmitInfo=1 RAISERROR('Change Tracking is not enabled at the database level.', 16, 1);
            SET @Summary = N'Employees incremental failed: CT not enabled at DB level.';
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            SET @ret = -100; GOTO FinallyRelease;
        END

        -- FIX: removed extra closing parenthesis here ↓
        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.EMPLOYEE'))
        BEGIN
            IF @EmitInfo=1 RAISERROR('Change Tracking is not enabled on dbo.EMPLOYEE.',16,1);
            SET @Summary = N'Employees incremental failed: CT not enabled on dbo.EMPLOYEE.';
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            SET @ret = -210; GOTO FinallyRelease;
        END

        -- Optional CT sources
        DECLARE @CT_CONTACT_DT bit = CASE WHEN EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.CONTACT_DT')) THEN 1 ELSE 0 END;
        DECLARE @CT_CONTACT_HD bit = CASE WHEN EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.CONTACT_HD')) THEN 1 ELSE 0 END;
        DECLARE @CT_CHSYSDEC   bit = CASE WHEN EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.CHSYSDEC'))   THEN 1 ELSE 0 END;

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

        -- Min valid across the tables queried via CHANGETABLE
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
            IF @EmitInfo=1 RAISERROR('Watermark (%I64d) is older than CT min valid version (%I64d). Re-baseline required.',16,1,@LastSyncVersion,@MinValid);
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

        /* 2) Build changed EmployeeReference set */
        IF OBJECT_ID('tempdb..#Changed') IS NOT NULL DROP TABLE #Changed;
        CREATE TABLE #Changed (EmployeeReference int NOT NULL PRIMARY KEY);

        -- EMPLOYEE (I/U)
        INSERT INTO #Changed(EmployeeReference)
        SELECT DISTINCT e.EMP_REF
        FROM CHANGETABLE(CHANGES dbo.EMPLOYEE, @LastSyncVersion) ct
        JOIN dbo.EMPLOYEE e ON e.EMP_REF = ct.EMP_REF
        WHERE ct.SYS_CHANGE_VERSION <= @ToVersion
          AND ct.SYS_CHANGE_OPERATION IN ('I','U');

        -- CONTACT_DT (optional)
        IF @CT_CONTACT_DT = 1
        BEGIN
            INSERT INTO #Changed(EmployeeReference)
            SELECT DISTINCT e.EMP_REF
            FROM CHANGETABLE(CHANGES dbo.CONTACT_DT, @LastSyncVersion) x
            JOIN dbo.EMPLOYEE e ON e.CNTA_DET_REF = x.CNTA_DET_REF
            WHERE x.SYS_CHANGE_VERSION <= @ToVersion
              AND NOT EXISTS (SELECT 1 FROM #Changed z WHERE z.EmployeeReference = e.EMP_REF);
        END
        ELSE IF @EmitInfo=1
            RAISERROR('Note: CT not enabled on CONTACT_DT; contact changes not captured.', 0, 1) WITH NOWAIT;

        -- CONTACT_HD (optional)
        IF @CT_CONTACT_HD = 1
        BEGIN
            INSERT INTO #Changed(EmployeeReference)
            SELECT DISTINCT e.EMP_REF
            FROM CHANGETABLE(CHANGES dbo.CONTACT_HD, @LastSyncVersion) h
            JOIN dbo.CONTACT_DT dt ON dt.CONTACT_REF = h.CONTACT_REF
            JOIN dbo.EMPLOYEE  e  ON e.CNTA_DET_REF  = dt.CNTA_DET_REF
            WHERE h.SYS_CHANGE_VERSION <= @ToVersion
              AND NOT EXISTS (SELECT 1 FROM #Changed z WHERE z.EmployeeReference = e.EMP_REF);
        END
        ELSE IF @EmitInfo=1
            RAISERROR('Note: CT not enabled on CONTACT_HD; header changes not captured.', 0, 1) WITH NOWAIT;

        -- CHSYSDEC (optional)
        IF @CT_CHSYSDEC = 1
        BEGIN
            INSERT INTO #Changed(EmployeeReference)
            SELECT DISTINCT e.EMP_REF
            FROM CHANGETABLE(CHANGES dbo.CHSYSDEC, @LastSyncVersion) d
            JOIN dbo.EMPLOYEE e
              ON e.ETHNICITY    = d.DECODE_REF
              OR e.RELORG_REF   = d.DECODE_REF
              OR e.JOBTITLE     = d.DECODE_REF
              OR e.LOCATION_REF = d.DECODE_REF
              OR e.JOB_QUAL     = d.DECODE_REF
            WHERE d.SYS_CHANGE_VERSION <= @ToVersion
              AND NOT EXISTS (SELECT 1 FROM #Changed z WHERE z.EmployeeReference = e.EMP_REF);
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

        /* 3) Chunked MERGE into dbo.tbl_Employees */
        DECLARE @TotalInserted bigint = 0, @TotalUpdated bigint = 0, @TotalDeleted int = 0;

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

            ;WITH Base AS
            (
                SELECT
                    E.EMP_REF                                        AS EmployeeReference,
                    E.GS_REF                                         AS OldBranchUID,
                    CAST(E.BIRTH_DATE AS DATE)                       AS EmployeeDateOfBirth,
                    DATEDIFF(year, CAST(E.BIRTH_DATE AS DATE), GETDATE())
                      - CASE WHEN DATEADD(year, DATEDIFF(year, E.BIRTH_DATE, GETDATE()), E.BIRTH_DATE) > GETDATE() THEN 1 ELSE 0 END
                                                                AS EmployeeAge,
                    E.EMP_CODE                                       AS EmployeeCode,
                    CASE E.SEX WHEN 'M' THEN 'Male'
                               WHEN 'F' THEN 'Female'
                               WHEN 'N' THEN 'Not Applicable'
                               ELSE 'Unknown' END                    AS EmployeeGender,
                    CHD.FORENAMES                                    AS EmployeeForenames,
                    CHD.SURNAME                                      AS EmployeeSurname,
                    CHD.TEL_NO1                                      AS TelephoneNumber,
                    E.PAYROLL_NO                                     AS PayrollNumber,
                    CHD.EMAIL                                        AS Email,
                    CEE.DESCRIPTION                                  AS Ethnicity,
                    CER.DESCRIPTION                                  AS Religion,
                    CEJT.DESCRIPTION                                 AS JobTitle,
                    JQ.DESCRIPTION                                   AS Salaried,
                    E.INTERFACE                                      AS Interface,
                    E.DRIVER                                         AS Driver,
                    CHD.ADDRESS1                                     AS FirstLineAddress,
                    CHD.ADDRESS2                                     AS SecondLineAddress,
                    CHD.ADDRESS3                                     AS ThirdLineAddress,
                    CHD.ADDRESS4                                     AS FourthLineAddress,
                    CHD.POSTCODE                                     AS Postcode,
                    CEL.DESCRIPTION                                  AS EmployeeSubLocation
                FROM dbo.EMPLOYEE E
                JOIN #Next n                 ON n.EmployeeReference = E.EMP_REF
                LEFT JOIN dbo.CONTACT_DT CDT ON CDT.CNTA_DET_REF    = E.CNTA_DET_REF
                LEFT JOIN dbo.CONTACT_HD CHD ON CHD.CONTACT_REF     = CDT.CONTACT_REF
                LEFT JOIN dbo.CHSYSDEC CEE   ON E.ETHNICITY         = CEE.DECODE_REF
                LEFT JOIN dbo.CHSYSDEC CER   ON E.RELORG_REF        = CER.DECODE_REF
                LEFT JOIN dbo.CHSYSDEC CEJT  ON E.JOBTITLE          = CEJT.DECODE_REF
                LEFT JOIN dbo.CHSYSDEC CEL   ON E.LOCATION_REF      = CEL.DECODE_REF
                LEFT JOIN dbo.CHSYSDEC JQ    ON E.JOB_QUAL          = JQ.DECODE_REF
            ),
            WithBranch AS
            (
                SELECT
                    b.EmployeeReference,
                    BranchUID = COALESCE(bname.BranchUID, bold.BranchUID),
                    b.EmployeeDateOfBirth, b.EmployeeAge, b.EmployeeCode, b.EmployeeGender,
                    b.EmployeeForenames, b.EmployeeSurname, b.TelephoneNumber, b.PayrollNumber,
                    b.Email, b.Ethnicity, b.Religion, b.JobTitle, b.Salaried, b.Interface, b.Driver,
                    b.FirstLineAddress, b.SecondLineAddress, b.ThirdLineAddress, b.FourthLineAddress,
                    b.Postcode, b.EmployeeSubLocation
                FROM Base b
                OUTER APPLY (
                    SELECT CASE
                             WHEN b.OldBranchUID = '1970000043' AND b.EmployeeSubLocation = 'Southampton' THEN 'Southampton'
                             WHEN b.OldBranchUID = '1970000043' AND (b.EmployeeSubLocation <> 'Southampton' OR b.EmployeeSubLocation IS NULL) THEN 'Portsmouth'
                             ELSE NULL
                           END AS BranchName
                ) pick
                LEFT JOIN dbo.tbl_Branch AS bname  ON pick.BranchName IS NOT NULL AND bname.BranchName = pick.BranchName
                LEFT JOIN dbo.tbl_Branch AS bold   ON pick.BranchName IS NULL    AND bold.OldBranchUID = b.OldBranchUID
            )
            MERGE dbo.tbl_Employees AS tgt
            USING (
                SELECT
                    w.EmployeeReference,
                    BranchReference = CAST(w.BranchUID AS nvarchar(55)),
                    w.EmployeeDateOfBirth, w.EmployeeAge, w.EmployeeCode, w.EmployeeGender,
                    w.EmployeeForenames, w.EmployeeSurname, w.TelephoneNumber, w.PayrollNumber, w.Email,
                    w.Ethnicity, w.Religion, w.JobTitle, w.Salaried, w.Interface, w.Driver,
                    w.FirstLineAddress, w.SecondLineAddress, w.ThirdLineAddress, w.FourthLineAddress,
                    w.Postcode, w.EmployeeSubLocation
                FROM WithBranch w
                WHERE w.BranchUID IS NOT NULL
            ) AS src
               ON tgt.EmployeeReference = src.EmployeeReference
            WHEN MATCHED THEN
                UPDATE SET
                    tgt.BranchReference     = src.BranchReference,
                    tgt.EmployeeDateOfBirth = src.EmployeeDateOfBirth,
                    tgt.EmployeeAge         = src.EmployeeAge,
                    tgt.EmployeeCode        = src.EmployeeCode,
                    tgt.EmployeeGender      = src.EmployeeGender,
                    tgt.EmployeeForenames   = src.EmployeeForenames,
                    tgt.EmployeeSurname     = src.EmployeeSurname,
                    tgt.TelephoneNumber     = src.TelephoneNumber,
                    tgt.PayrollNumber       = src.PayrollNumber,
                    tgt.Email               = src.Email,
                    tgt.Ethnicity           = src.Ethnicity,
                    tgt.Religion            = src.Religion,
                    tgt.JobTitle            = src.JobTitle,
                    tgt.Salaried            = src.Salaried,
                    tgt.Interface           = src.Interface,
                    tgt.Driver              = src.Driver,
                    tgt.FirstLineAddress    = src.FirstLineAddress,
                    tgt.SecondLineAddress   = src.SecondLineAddress,
                    tgt.ThirdLineAddress    = src.ThirdLineAddress,
                    tgt.FourthLineAddress   = src.FourthLineAddress,
                    tgt.Postcode            = src.Postcode,
                    tgt.EmployeeSubLocation = src.EmployeeSubLocation,
                    tgt.UpdatedAtUTC        = @RunStartedAt
            WHEN NOT MATCHED BY TARGET THEN
                INSERT (
                    EmployeeReference, BranchReference,
                    EmployeeDateOfBirth, EmployeeAge, EmployeeCode, EmployeeGender,
                    EmployeeForenames, EmployeeSurname, TelephoneNumber, PayrollNumber, Email,
                    Ethnicity, Religion, JobTitle, Salaried, Interface, Driver,
                    FirstLineAddress, SecondLineAddress, ThirdLineAddress, FourthLineAddress,
                    Postcode, EmployeeSubLocation,
                    CreatedAtUTC, UpdatedAtUTC
                )
                VALUES (
                    src.EmployeeReference, src.BranchReference,
                    src.EmployeeDateOfBirth, src.EmployeeAge, src.EmployeeCode, src.EmployeeGender,
                    src.EmployeeForenames, src.EmployeeSurname, src.TelephoneNumber, src.PayrollNumber, src.Email,
                    src.Ethnicity, src.Religion, src.JobTitle, src.Salaried, src.Interface, src.Driver,
                    src.FirstLineAddress, src.SecondLineAddress, src.ThirdLineAddress, src.FourthLineAddress,
                    src.Postcode, src.EmployeeSubLocation,
                    @RunStartedAt, @RunStartedAt
                )
            OUTPUT $action INTO #ActLog(Action);

            DECLARE @i int = 0, @u int = 0;
            SELECT @i = SUM(CASE WHEN Action='INSERT' THEN 1 ELSE 0 END),
                   @u = SUM(CASE WHEN Action='UPDATE' THEN 1 ELSE 0 END)
            FROM #ActLog;

            SET @TotalInserted += ISNULL(@i,0);
            SET @TotalUpdated  += ISNULL(@u,0);

            IF @EmitInfo=1
                RAISERROR('Employees chunk: inserted=%d updated=%d (running %d/%d)', 0,1,@i,@u,@TotalInserted,@TotalUpdated) WITH NOWAIT;

            DELETE c
            FROM #Changed c
            JOIN #Next n ON n.EmployeeReference = c.EmployeeReference;
        END

        /* 4) Apply deletes (EMPLOYEE deletes) */
        IF OBJECT_ID('tempdb..#DelLog') IS NOT NULL DROP TABLE #DelLog;
        CREATE TABLE #DelLog(EmployeeReference int NOT NULL);

        DELETE t
        OUTPUT DELETED.EmployeeReference INTO #DelLog(EmployeeReference)
        FROM dbo.tbl_Employees t
        JOIN (
            SELECT d.EMP_REF
            FROM CHANGETABLE(CHANGES dbo.EMPLOYEE, @LastSyncVersion) d
            WHERE d.SYS_CHANGE_OPERATION = 'D'
              AND d.SYS_CHANGE_VERSION   <= @ToVersion
        ) x ON t.EmployeeReference = x.EMP_REF;

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
        IF @EmitInfo=1 RAISERROR('usp_Sync_Employees_Incremental failed (%d, sev %d, state %d) at %s line %d: %s',16,1,@num,@sev,@st,@procName,@lin,@msg);
        SET @Summary = CONCAT(N'Employees incremental failed: ', @msg);
        IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
        RETURN -50001;
    END CATCH
END
GO
