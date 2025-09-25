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
    END;
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
        END;

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
            UUID                INT           NOT NULL PRIMARY KEY CLUSTERED,
            DOB                 DATE          NULL,
            Code                NVARCHAR(50)  NOT NULL,
            Gender              NVARCHAR(20)  NULL,
            Forenames           NVARCHAR(100) NULL,
            Surname             NVARCHAR(100) NULL,
            Telephone_Number    NVARCHAR(20)  NULL,
            Payroll_Number      NVARCHAR(50)  NULL,
            Email               NVARCHAR(100) NULL,
            Ethnicity           NVARCHAR(100) NULL,
            Religion            NVARCHAR(100) NULL,
            Job_Title           NVARCHAR(100) NULL,
            Salaried            NVARCHAR(20)  NULL,
            Payroll_Schedule    NVARCHAR(20)  NULL,   -- <— keep this name consistently
            Driver              NVARCHAR(20)  NULL,
            First_Line_Address  NVARCHAR(100) NULL,
            Second_Line_Address NVARCHAR(100) NULL,
            Third_Line_Address  NVARCHAR(100) NULL,
            Fourth_Line_Address NVARCHAR(100) NULL,
            Postcode            NVARCHAR(20)  NULL,
            CreatedAtUTC        datetime2(3)  NOT NULL CONSTRAINT DF_tbl_Employees_CreatedAtUTC DEFAULT SYSUTCDATETIME(),
            UpdatedAtUTC        datetime2(3)  NOT NULL CONSTRAINT DF_tbl_Employees_UpdatedAtUTC DEFAULT SYSUTCDATETIME()
        );

        /* Baseline load */
        ;WITH EmpBase AS
        (
            SELECT
                E.EMP_REF                                        AS UUID,
                CAST(E.BIRTH_DATE AS DATE)                       AS DOB,
                E.EMP_CODE                                       AS Code,
                CASE E.SEX WHEN 'M' THEN 'Male'
                           WHEN 'F' THEN 'Female'
                           WHEN 'N' THEN 'Not Applicable'
                           ELSE 'Unknown' END                    AS Gender,
                CHD.FORENAMES                                    AS Forenames,
                CHD.SURNAME                                      AS Surname,
                CHD.TEL_NO1                                      AS Telephone_Number,
                E.PAYROLL_NO                                     AS Payroll_Number,
                CHD.EMAIL                                        AS Email,
                CEE.DESCRIPTION                                  AS Ethnicity,
                CER.DESCRIPTION                                  AS Religion,
                CEJT.DESCRIPTION                                 AS Job_Title,
                JQ.DESCRIPTION                                   AS Salaried,
                E.INTERFACE                                      AS Payroll_Schedule,   -- <— alias matches table column
                E.DRIVER                                         AS Driver,
                CHD.ADDRESS1                                     AS First_Line_Address,
                CHD.ADDRESS2                                     AS Second_Line_Address,
                CHD.ADDRESS3                                     AS Third_Line_Address,
                CHD.ADDRESS4                                     AS Fourth_Line_Address,
                CHD.POSTCODE                                     AS Postcode
            FROM dbo.EMPLOYEE      AS E
            LEFT JOIN dbo.CONTACT_DT AS CDT ON CDT.CNTA_DET_REF = E.CNTA_DET_REF
            LEFT JOIN dbo.CONTACT_HD AS CHD ON CHD.CONTACT_REF  = CDT.CONTACT_REF
            LEFT JOIN dbo.CHSYSDEC   AS CEE ON E.ETHNICITY      = CEE.DECODE_REF
            LEFT JOIN dbo.CHSYSDEC   AS CER ON E.RELORG_REF     = CER.DECODE_REF
            LEFT JOIN dbo.CHSYSDEC   AS CEJT ON E.JOBTITLE      = CEJT.DECODE_REF
            LEFT JOIN dbo.CHSYSDEC   AS CEL ON E.LOCATION_REF   = CEL.DECODE_REF
            LEFT JOIN dbo.CHSYSDEC   AS JQ  ON E.JOB_QUAL       = JQ.DECODE_REF
            WHERE E.EMP_REF IS NOT NULL
        )
        INSERT INTO dbo.tbl_Employees
        (
            UUID,
            DOB, Code, Gender,
            Forenames, Surname, Telephone_Number, Payroll_Number, Email,
            Ethnicity, Religion, Job_Title, Salaried, Payroll_Schedule, Driver,
            First_Line_Address, Second_Line_Address, Third_Line_Address, Fourth_Line_Address,
            Postcode,
            CreatedAtUTC, UpdatedAtUTC
        )
        SELECT
            w.UUID,
            w.DOB, w.Code, w.Gender,
            w.Forenames, w.Surname, w.Telephone_Number, w.Payroll_Number, w.Email,
            w.Ethnicity, w.Religion, w.Job_Title, w.Salaried, w.Payroll_Schedule, w.Driver,  -- <— use Payroll_Schedule
            w.First_Line_Address, w.Second_Line_Address, w.Third_Line_Address, w.Fourth_Line_Address,
            w.Postcode,
            @RunStartedAt, @RunStartedAt
        FROM EmpBase w;

        DECLARE @Inserted int = @@ROWCOUNT;

        /* Indexes */
        CREATE NONCLUSTERED INDEX IX_tbl_Employees_Code             ON dbo.tbl_Employees (Code);
        CREATE NONCLUSTERED INDEX IX_tbl_Employees_Salaried         ON dbo.tbl_Employees (Salaried);
        CREATE NONCLUSTERED INDEX IX_tbl_Employees_PayrollSchedule  ON dbo.tbl_Employees (Payroll_Schedule);  -- <— fixed

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
