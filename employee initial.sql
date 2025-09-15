USE [DOM_LIVE];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Sync_Employees_Initial
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Process       sysname      = N'Employees';
    DECLARE @RunStartedAt  datetime2(3) = SYSUTCDATETIME();
    DECLARE @StartIso      varchar(33)  = CONVERT(varchar(33), @RunStartedAt, 126);
    DECLARE @BaselineFrom  bigint;
    DECLARE @LockResource  sysname      = N'DOM_LIVE:Sync:Employees';
    DECLARE @lockResult    int;
    DECLARE @lockHeld      bit          = 0;

    -- applock (wide window for baseline)
    EXEC @lockResult = sys.sp_getapplock
        @Resource=@LockResource, @LockMode='Exclusive',
        @LockOwner='Session', @DbPrincipal='dbo', @LockTimeout=600000;
    IF @lockResult NOT IN (0,1)
    BEGIN
        SELECT 'Initial' AS Stage, CAST(N'Employees initial failed: could not acquire applock.' AS nvarchar(4000)) AS Summary;
        RETURN -1;
    END
    SET @lockHeld = 1;

    BEGIN TRY
        /* Preconditions */
        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_databases WHERE database_id = DB_ID())
            RAISERROR('Change Tracking is not enabled at the database level.', 16, 1);
        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.EMPLOYEE'))
            RAISERROR('Change Tracking is not enabled on dbo.EMPLOYEE.', 16, 1);

        /* Fence CT window at START */
        SET @BaselineFrom = CHANGE_TRACKING_CURRENT_VERSION();

        /* Watermark seed/refresh */
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
            UPDATE SET LastSyncVersion=@BaselineFrom, LastSyncTime=SYSUTCDATETIME()
        WHEN NOT MATCHED THEN
            INSERT(ProcessName, LastSyncVersion, LastSyncTime) VALUES(@Process, @BaselineFrom, SYSUTCDATETIME());

        /* Recreate target */
        IF OBJECT_ID('dbo.tbl_Employees','U') IS NOT NULL
            DROP TABLE dbo.tbl_Employees;

        CREATE TABLE dbo.tbl_Employees
        (
            EmployeeReference INT NOT NULL PRIMARY KEY CLUSTERED,
            BranchReference   NVARCHAR(55) NOT NULL,
            EmployeeDateOfBirth DATE NULL,
            EmployeeAge      INT NULL,
            EmployeeCode     NVARCHAR(50) NOT NULL,
            EmployeeGender   NVARCHAR(20) NULL,
            EmployeeForenames NVARCHAR(100) NULL,
            EmployeeSurname  NVARCHAR(100) NULL,
            TelephoneNumber  NVARCHAR(20) NULL,
            PayrollNumber    NVARCHAR(50) NULL,
            Email            NVARCHAR(100) NULL,
            Ethnicity        NVARCHAR(100) NULL,
            Religion         NVARCHAR(100) NULL,
            JobTitle         NVARCHAR(100) NULL,
            Salaried         NVARCHAR(20)  NULL,
            Interface        NVARCHAR(20)  NULL,
            Driver           NVARCHAR(20)  NULL,
            FirstLineAddress NVARCHAR(100) NULL,
            SecondLineAddress NVARCHAR(100) NULL,
            ThirdLineAddress NVARCHAR(100) NULL,
            FourthLineAddress NVARCHAR(100) NULL,
            Postcode         NVARCHAR(20)  NULL,
            EmployeeSubLocation NVARCHAR(100) NULL,
            CreatedAtUTC     datetime2(3) NOT NULL CONSTRAINT DF_tbl_Employees_CreatedAtUTC DEFAULT SYSUTCDATETIME(),
            UpdatedAtUTC     datetime2(3) NOT NULL CONSTRAINT DF_tbl_Employees_UpdatedAtUTC DEFAULT SYSUTCDATETIME()
        );

        /* Baseline load */
        ;WITH EmpBase AS
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
            FROM dbo.EMPLOYEE      AS E
            LEFT JOIN dbo.CONTACT_DT AS CDT ON CDT.CNTA_DET_REF = E.CNTA_DET_REF
            LEFT JOIN dbo.CONTACT_HD AS CHD ON CHD.CONTACT_REF  = CDT.CONTACT_REF
            LEFT JOIN dbo.CHSYSDEC   AS CEE ON E.ETHNICITY      = CEE.DECODE_REF
            LEFT JOIN dbo.CHSYSDEC   AS CER ON E.RELORG_REF     = CER.DECODE_REF
            LEFT JOIN dbo.CHSYSDEC   AS CEJT ON E.JOBTITLE      = CEJT.DECODE_REF
            LEFT JOIN dbo.CHSYSDEC   AS CEL ON E.LOCATION_REF   = CEL.DECODE_REF
            LEFT JOIN dbo.CHSYSDEC   AS JQ  ON E.JOB_QUAL       = JQ.DECODE_REF
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
        WHERE w.BranchUID IS NOT NULL;

        DECLARE @Inserted int = @@ROWCOUNT;

        /* Indexes after load */
        CREATE NONCLUSTERED INDEX IX_tbl_Employees_BranchReference ON [dbo].[tbl_Employees] (BranchReference);
        CREATE NONCLUSTERED INDEX IX_tbl_Employees_EmployeeCode    ON [dbo].[tbl_Employees] (EmployeeCode);
        CREATE NONCLUSTERED INDEX IX_tbl_Employees_Salaried        ON [dbo].[tbl_Employees] (Salaried);
        CREATE NONCLUSTERED INDEX IX_tbl_Employees_Interface       ON [dbo].[tbl_Employees] (Interface);

        /* Baseline summary */
        DECLARE @EndInitialUTC datetime2(3) = SYSUTCDATETIME();
        DECLARE @EndInitialIso varchar(33)  = CONVERT(varchar(33), @EndInitialUTC, 126);
        DECLARE @InitialMsg nvarchar(4000) =
            CONCAT(N'Employees initial started ', @StartIso,
                   N' UTC; ended ', @EndInitialIso,
                   N' UTC; baseline inserted ', @Inserted, N' rows.');

        /* Quiet incremental sweep to top off */
        DECLARE @IncrMsg nvarchar(4000) = N'Incremental skipped.';
        IF OBJECT_ID('dbo.usp_Sync_Employees_Incremental','P') IS NOT NULL
        BEGIN
            DECLARE @rc int;
            EXEC @rc = dbo.usp_Sync_Employees_Incremental
                @ChunkSize=100000, @LockTimeoutMs=600000, @UseAppLock=0,
                @EmitInfo=0, @Summary=@IncrMsg OUTPUT, @ReturnSummaryRow=0;
            IF (@rc < 0)
                SET @IncrMsg = CONCAT(@IncrMsg, N' (rc=', @rc, N')');
        END

        -- Return two rows
        SELECT 'Initial' AS Stage,     @InitialMsg AS Summary
        UNION ALL
        SELECT 'Incremental',          @IncrMsg;

        IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner='Session', @DbPrincipal='dbo';
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner='Session', @DbPrincipal='dbo';
        DECLARE @msg nvarchar(4000)=ERROR_MESSAGE();
        SELECT 'Initial' AS Stage, CAST(CONCAT(N'Employees initial failed: ', @msg) AS nvarchar(4000)) AS Summary;
        RETURN -50001;
    END CATCH
END
GO
