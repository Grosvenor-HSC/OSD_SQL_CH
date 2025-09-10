USE [DOM_LIVE];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

/* =======================================================================
   Employees Baseline (seed watermark at start to capture in-flight changes)
   ======================================================================= */
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @Process       sysname      = N'Employees';
DECLARE @RunStartedAt  datetime2(3) = SYSUTCDATETIME();
DECLARE @BaselineFrom  bigint;   -- CT snapshot taken BEFORE we rebuild/load
DECLARE @LockResource  sysname    = N'DOM_LIVE:Sync:Employees';
DECLARE @LockOwner     sysname    = N'Session';
DECLARE @DbPrincipal   sysname    = N'dbo';
DECLARE @lockResult    int;
DECLARE @lockHeld      bit        = 0;

/* 0) Concurrency guard (same key family as the incremental) */
EXEC @lockResult = sys.sp_getapplock
    @Resource    = @LockResource,
    @LockMode    = 'Exclusive',
    @LockOwner   = @LockOwner,
    @DbPrincipal = @DbPrincipal,
    @LockTimeout = 600000;  -- up to 10 mins for baseline

IF @lockResult NOT IN (0,1)
BEGIN
    RAISERROR('Could not acquire %s (rc=%d).',16,1,@LockResource,@lockResult);
    RETURN;
END
SET @lockHeld = 1;

BEGIN TRY
    /* 1) Preconditions */
    IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_databases WHERE database_id = DB_ID())
        RAISERROR('Change Tracking is not enabled at the database level.', 16, 1);

    -- Driver for incrementals: EMPLOYEE
    IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.EMPLOYEE'))
        RAISERROR('Change Tracking is not enabled on dbo.EMPLOYEE.', 16, 1);

    /* 2) Take CT snapshot AT START so anything after this is picked up by incremental */
    SET @BaselineFrom = CHANGE_TRACKING_CURRENT_VERSION();

    /* 3) Ensure watermark table exists and seed/refresh Employees row to the START snapshot */
    IF OBJECT_ID('dbo.CT_Watermark','U') IS NULL
    BEGIN
        CREATE TABLE dbo.CT_Watermark
        (
          ProcessName     sysname      PRIMARY KEY,
          LastSyncVersion bigint       NOT NULL,
          LastSyncTime    datetime2(3) NOT NULL DEFAULT SYSUTCDATETIME()
        );
    END

    MERGE dbo.CT_Watermark AS t
    USING (SELECT @Process AS ProcessName) s
      ON t.ProcessName = s.ProcessName
    WHEN MATCHED THEN
      UPDATE SET LastSyncVersion = @BaselineFrom, LastSyncTime = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN
      INSERT (ProcessName, LastSyncVersion) VALUES (@Process, @BaselineFrom);

    RAISERROR('Seeded Employees watermark to START snapshot %I64d.', 0, 1, @BaselineFrom) WITH NOWAIT;

    /* 4) Recreate target table */
    IF OBJECT_ID('dbo.tbl_Employees', 'U') IS NOT NULL
        DROP TABLE dbo.tbl_Employees;

    CREATE TABLE [dbo].[tbl_Employees] (
        EmployeeReference INT NOT NULL PRIMARY KEY CLUSTERED,
        BranchReference NVARCHAR(55) NOT NULL,
        EmployeeDateOfBirth DATE NULL,
        EmployeeAge INT NULL,
        EmployeeCode NVARCHAR(50) NOT NULL,
        EmployeeGender NVARCHAR(20) NULL,
        EmployeeForenames NVARCHAR(100) NULL,
        EmployeeSurname NVARCHAR(100) NULL,
        TelephoneNumber NVARCHAR(20) NULL,
        PayrollNumber NVARCHAR(50) NULL,
        Email NVARCHAR(100) NULL,
        Ethnicity NVARCHAR(100) NULL,
        Religion NVARCHAR(100) NULL,
        JobTitle NVARCHAR(100) NULL,
        Salaried NVARCHAR(20) NULL,
        Interface NVARCHAR(20) NULL,
        Driver NVARCHAR(20) NULL,
        FirstLineAddress NVARCHAR(100) NULL,
        SecondLineAddress NVARCHAR(100) NULL,
        ThirdLineAddress NVARCHAR(100) NULL,
        FourthLineAddress NVARCHAR(100) NULL,
        Postcode NVARCHAR(20) NULL,
        EmployeeSubLocation NVARCHAR(100) NULL,
        CreatedAtUTC  datetime2(3) NOT NULL CONSTRAINT DF_tbl_Employees_CreatedAtUTC DEFAULT SYSUTCDATETIME(),
        UpdatedAtUTC  datetime2(3) NOT NULL CONSTRAINT DF_tbl_Employees_UpdatedAtUTC DEFAULT SYSUTCDATETIME()
    );

    /* 5) Populate (maps GS_REF -> tbl_Branch.BranchUID with Portsmouth/Southampton split) */
    ;WITH EmpBase AS
    (
        SELECT
            E.EMP_REF                                        AS EmployeeReference,
            E.GS_REF                                         AS OldBranchUID,
            CAST(E.BIRTH_DATE AS DATE)                       AS EmployeeDateOfBirth,
            -- Age as of today, adjust if birthday not yet occurred this year
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
        FROM dbo.EMPLOYEE      AS E   WITH (NOLOCK)
        LEFT JOIN dbo.CONTACT_DT AS CDT WITH (NOLOCK) ON CDT.CNTA_DET_REF = E.CNTA_DET_REF
        LEFT JOIN dbo.CONTACT_HD AS CHD WITH (NOLOCK) ON CHD.CONTACT_REF  = CDT.CONTACT_REF
        LEFT JOIN dbo.CHSYSDEC   AS CEE WITH (NOLOCK) ON E.ETHNICITY      = CEE.DECODE_REF
        LEFT JOIN dbo.CHSYSDEC   AS CER WITH (NOLOCK) ON E.RELORG_REF     = CER.DECODE_REF
        LEFT JOIN dbo.CHSYSDEC   AS CEJT WITH (NOLOCK) ON E.JOBTITLE      = CEJT.DECODE_REF
        LEFT JOIN dbo.CHSYSDEC   AS CEL WITH (NOLOCK) ON E.LOCATION_REF   = CEL.DECODE_REF
        LEFT JOIN dbo.CHSYSDEC   AS JQ  WITH (NOLOCK) ON E.JOB_QUAL       = JQ.DECODE_REF
        WHERE E.EMP_REF IS NOT NULL
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
        FROM EmpBase b
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
    INSERT INTO dbo.tbl_Employees
    (
        EmployeeReference, BranchReference,
        EmployeeDateOfBirth, EmployeeAge, EmployeeCode, EmployeeGender,
        EmployeeForenames, EmployeeSurname, TelephoneNumber, PayrollNumber, Email,
        Ethnicity, Religion, JobTitle, Salaried, Interface, Driver,
        FirstLineAddress, SecondLineAddress, ThirdLineAddress, FourthLineAddress,
        Postcode, EmployeeSubLocation,
        CreatedAtUTC, UpdatedAtUTC
    )
    SELECT
        w.EmployeeReference,
        CAST(w.BranchUID AS nvarchar(55))              AS BranchReference,
        w.EmployeeDateOfBirth, w.EmployeeAge, w.EmployeeCode, w.EmployeeGender,
        w.EmployeeForenames, w.EmployeeSurname, w.TelephoneNumber, w.PayrollNumber, w.Email,
        w.Ethnicity, w.Religion, w.JobTitle, w.Salaried, w.Interface, w.Driver,
        w.FirstLineAddress, w.SecondLineAddress, w.ThirdLineAddress, w.FourthLineAddress,
        w.Postcode, w.EmployeeSubLocation,
        @RunStartedAt, @RunStartedAt
    FROM WithBranch w
    WHERE w.BranchUID IS NOT NULL;  -- honor NOT NULL BranchReference

    DECLARE @rows int = @@ROWCOUNT;
    RAISERROR('tbl_Employees baseline complete. Inserted %d rows.', 0, 1, @rows) WITH NOWAIT;

    /* 6) Indexes (post-load) */
    CREATE NONCLUSTERED INDEX IX_tbl_Employees_BranchReference ON [dbo].[tbl_Employees] (BranchReference);
    CREATE NONCLUSTERED INDEX IX_tbl_Employees_EmployeeCode    ON [dbo].[tbl_Employees] (EmployeeCode);
    CREATE NONCLUSTERED INDEX IX_tbl_Employees_Salaried        ON [dbo].[tbl_Employees] (Salaried);
    CREATE NONCLUSTERED INDEX IX_tbl_Employees_Interface       ON [dbo].[tbl_Employees] (Interface);

    /* 7) Do NOT advance the watermark here.
          We want the incremental to pick up anything that changed DURING the baseline. */

    IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;
END TRY
BEGIN CATCH
    IF @lockHeld=1 
        EXEC sys.sp_releaseapplock 
            @Resource=@LockResource, 
            @LockOwner=@LockOwner, 
            @DbPrincipal=@DbPrincipal;

    DECLARE @msg nvarchar(4000) = ERROR_MESSAGE();
    DECLARE @num int = ERROR_NUMBER(),
            @sev int = ERROR_SEVERITY(),
            @st  int = ERROR_STATE(),
            @lin int = ERROR_LINE(),
            @proc sysname = ERROR_PROCEDURE();
    DECLARE @procName sysname = ISNULL(@proc, N'<adhoc>');

    RAISERROR(
        'Employees baseline failed (%d, sev %d, state %d) at %s line %d: %s',
        16, 1,
        @num, @sev, @st, @procName, @lin, @msg
    );

    RETURN;
END CATCH
GO
