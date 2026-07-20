USE [DOM_LIVE];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Sync_Employees_Initial
    @Summary nvarchar(4000) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Process       sysname      = N'Employees';
    DECLARE @RunStartedAt  datetime2(3) = SYSUTCDATETIME();
    DECLARE @StartIso      varchar(33)  = CONVERT(varchar(33), @RunStartedAt, 126);
    DECLARE @BaselineFrom  bigint;

    DECLARE @LockResource  sysname = N'DOM_LIVE:Sync:Employees';
    DECLARE @LockOwner     sysname = N'Session';
    DECLARE @DbPrincipal   sysname = N'dbo';
    DECLARE @lockResult    int;
    DECLARE @lockHeld      bit = 0;

    EXEC @lockResult = sys.sp_getapplock
        @Resource    = @LockResource,
        @LockMode    = 'Exclusive',
        @LockOwner   = @LockOwner,
        @DbPrincipal = @DbPrincipal,
        @LockTimeout = 600000;

    IF @lockResult NOT IN (0,1)
    BEGIN
        SET @Summary = N'Employees initial failed: could not acquire applock.';
        SELECT [Stage]=N'Initial', [Summary]=@Summary;
        RETURN -1;
    END;
    SET @lockHeld = 1;

    BEGIN TRY
        /* Preconditions */
        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_databases WHERE database_id = DB_ID())
            RAISERROR('Change Tracking is not enabled at the database level.', 16, 1);

        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.EMPLOYEE'))
            RAISERROR('Change Tracking is not enabled on dbo.EMPLOYEE.', 16, 1);

        /* Fence CT window */
        SET @BaselineFrom = CHANGE_TRACKING_CURRENT_VERSION();

        /* Watermark */
        IF OBJECT_ID(N'dbo.CT_Watermark', N'U') IS NULL
        BEGIN
            CREATE TABLE dbo.CT_Watermark
            (
              ProcessName     sysname      NOT NULL CONSTRAINT PK_CT_Watermark PRIMARY KEY,
              LastSyncVersion bigint       NOT NULL,
              LastSyncTime    datetime2(3) NOT NULL CONSTRAINT DF_CT_Watermark_LastSyncTime DEFAULT SYSUTCDATETIME()
            );
        END;

        MERGE dbo.CT_Watermark AS t
        USING (SELECT @Process AS ProcessName) s
           ON t.ProcessName = s.ProcessName
        WHEN MATCHED THEN
            UPDATE SET LastSyncVersion=@BaselineFrom, LastSyncTime=SYSUTCDATETIME()
        WHEN NOT MATCHED THEN
            INSERT(ProcessName, LastSyncVersion, LastSyncTime)
            VALUES(@Process, @BaselineFrom, SYSUTCDATETIME());

        /* Hard reset target (drop view/synonym/table) */
        DECLARE @ddl nvarchar(max) = N'
IF OBJECT_ID(N''dbo.tbl_Employees'', N''V'') IS NOT NULL
    DROP VIEW dbo.tbl_Employees;

IF EXISTS (SELECT 1 FROM sys.synonyms WHERE name = N''tbl_Employees'' AND schema_id = SCHEMA_ID(N''dbo''))
    DROP SYNONYM dbo.tbl_Employees;

IF OBJECT_ID(N''dbo.tbl_Employees'', N''U'') IS NOT NULL
    DROP TABLE dbo.tbl_Employees;

CREATE TABLE dbo.tbl_Employees
(
    UUID                int           NOT NULL,
    DOB                 date          NULL,
    Code                nvarchar(50)  NOT NULL,
    Gender              nvarchar(20)  NULL,
    Forenames           nvarchar(100) NULL,
    Surname             nvarchar(100) NULL,
    Telephone_Number    nvarchar(20)  NULL,
    Payroll_Number      nvarchar(50)  NULL,
    Email               nvarchar(100) NULL,
    Ethnicity           nvarchar(100) NULL,
    Religion            nvarchar(100) NULL,
    Job_Title           nvarchar(100) NULL,
    Salaried            nvarchar(20)  NULL,
    Payroll_Schedule    nvarchar(20)  NULL,
    Driver              nvarchar(20)  NULL,
    First_Line_Address  nvarchar(100) NULL,
    Second_Line_Address nvarchar(100) NULL,
    Third_Line_Address  nvarchar(100) NULL,
    Fourth_Line_Address nvarchar(100) NULL,
    Postcode            nvarchar(20)  NULL,
    CreatedAtUTC        datetime2(3)  NOT NULL CONSTRAINT DF_tbl_Employees_CreatedAtUTC DEFAULT SYSUTCDATETIME(),
    UpdatedAtUTC        datetime2(3)  NOT NULL CONSTRAINT DF_tbl_Employees_UpdatedAtUTC DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_tbl_Employees PRIMARY KEY CLUSTERED (UUID)
);
';
        EXEC sys.sp_executesql @ddl;

        /* Baseline load + capture inserted count */
        IF OBJECT_ID('tempdb..#Inserted', 'U') IS NOT NULL DROP TABLE #Inserted;
        CREATE TABLE #Inserted (Cnt int NOT NULL);

        DECLARE @ins nvarchar(max) = N'
;WITH EmpBase AS
(
    SELECT
        UUID = E.EMP_REF,
        DOB  = TRY_CONVERT(date, E.BIRTH_DATE),
        Code = LTRIM(RTRIM(E.EMP_CODE)),
        Gender =
            CASE E.SEX
                WHEN ''M'' THEN ''Male''
                WHEN ''F'' THEN ''Female''
                WHEN ''N'' THEN ''Not Applicable''
                ELSE ''Unknown''
            END,
        Forenames        = NULLIF(LTRIM(RTRIM(CHD.FORENAMES)), ''''),
        Surname          = NULLIF(LTRIM(RTRIM(CHD.SURNAME)),   ''''),
        Telephone_Number = NULLIF(LTRIM(RTRIM(CHD.TEL_NO1)),   ''''),
        Payroll_Number   = NULLIF(LTRIM(RTRIM(E.PAYROLL_NO)),  ''''),
        Email            = NULLIF(LTRIM(RTRIM(CHD.EMAIL)),     ''''),
        Ethnicity        = NULLIF(LTRIM(RTRIM(CEE.DESCRIPTION)), ''''),
        Religion         = CASE WHEN LTRIM(RTRIM(CER.DESCRIPTION)) = ''Not Declared'' THEN NULL ELSE NULLIF(LTRIM(RTRIM(CER.DESCRIPTION)), '''') END,
        Job_Title        = NULLIF(LTRIM(RTRIM(CEJT.DESCRIPTION)), ''''),
        Salaried         = CASE WHEN LTRIM(RTRIM(JQ.DESCRIPTION)) = ''<no selection>'' THEN NULL ELSE NULLIF(LTRIM(RTRIM(JQ.DESCRIPTION)), '''') END,
        Payroll_Schedule = NULLIF(LTRIM(RTRIM(E.INTERFACE)), ''''),
        Driver           = NULLIF(LTRIM(RTRIM(E.DRIVER)),    ''''),
        First_Line_Address  = NULLIF(LTRIM(RTRIM(CHD.ADDRESS1)), ''''),
        Second_Line_Address = NULLIF(LTRIM(RTRIM(CHD.ADDRESS2)), ''''),
        Third_Line_Address  = NULLIF(LTRIM(RTRIM(CHD.ADDRESS3)), ''''),
        Fourth_Line_Address = NULLIF(LTRIM(RTRIM(CHD.ADDRESS4)), ''''),
        Postcode            = NULLIF(LTRIM(RTRIM(CHD.POSTCODE)), '''')
    FROM dbo.EMPLOYEE AS E
    LEFT JOIN dbo.CONTACT_DT AS CDT ON CDT.CNTA_DET_REF = E.CNTA_DET_REF
    LEFT JOIN dbo.CONTACT_HD AS CHD ON CHD.CONTACT_REF  = CDT.CONTACT_REF
    LEFT JOIN dbo.CHSYSDEC   AS CEE ON E.ETHNICITY      = CEE.DECODE_REF
    LEFT JOIN dbo.CHSYSDEC   AS CER ON E.RELORG_REF     = CER.DECODE_REF
    LEFT JOIN dbo.CHSYSDEC   AS CEJT ON E.JOBTITLE      = CEJT.DECODE_REF
    LEFT JOIN dbo.CHSYSDEC   AS JQ  ON E.JOB_QUAL       = JQ.DECODE_REF
    WHERE E.EMP_REF IS NOT NULL
)
INSERT INTO dbo.tbl_Employees
(
    UUID, DOB, Code, Gender, Forenames, Surname, Telephone_Number, Payroll_Number, Email,
    Ethnicity, Religion, Job_Title, Salaried, Payroll_Schedule, Driver,
    First_Line_Address, Second_Line_Address, Third_Line_Address, Fourth_Line_Address,
    Postcode, CreatedAtUTC, UpdatedAtUTC
)
SELECT
    e.UUID, e.DOB, e.Code, e.Gender, e.Forenames, e.Surname, e.Telephone_Number, e.Payroll_Number, e.Email,
    e.Ethnicity, e.Religion, e.Job_Title, e.Salaried, e.Payroll_Schedule, e.Driver,
    e.First_Line_Address, e.Second_Line_Address, e.Third_Line_Address, e.Fourth_Line_Address,
    e.Postcode, @RunStartedAt, @RunStartedAt
FROM EmpBase e;

INSERT INTO #Inserted(Cnt) VALUES (@@ROWCOUNT);
';

        EXEC sys.sp_executesql
            @ins,
            N'@RunStartedAt datetime2(3)',
            @RunStartedAt = @RunStartedAt;

        DECLARE @Inserted int = (SELECT TOP (1) Cnt FROM #Inserted);

        /* Indexes (idempotent: drop stats or indexes with same name) */
        DECLARE @post nvarchar(max) = N'
IF EXISTS (SELECT 1 FROM sys.stats   WHERE object_id = OBJECT_ID(N''dbo.tbl_Employees'') AND name = N''IX_tbl_Employees_Code'')
    DROP STATISTICS dbo.tbl_Employees.IX_tbl_Employees_Code;
IF EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N''dbo.tbl_Employees'') AND name = N''IX_tbl_Employees_Code'')
    DROP INDEX IX_tbl_Employees_Code ON dbo.tbl_Employees;
CREATE NONCLUSTERED INDEX IX_tbl_Employees_Code ON dbo.tbl_Employees (Code);

IF EXISTS (SELECT 1 FROM sys.stats   WHERE object_id = OBJECT_ID(N''dbo.tbl_Employees'') AND name = N''IX_tbl_Employees_Salaried'')
    DROP STATISTICS dbo.tbl_Employees.IX_tbl_Employees_Salaried;
IF EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N''dbo.tbl_Employees'') AND name = N''IX_tbl_Employees_Salaried'')
    DROP INDEX IX_tbl_Employees_Salaried ON dbo.tbl_Employees;
CREATE NONCLUSTERED INDEX IX_tbl_Employees_Salaried ON dbo.tbl_Employees (Salaried);

IF EXISTS (SELECT 1 FROM sys.stats   WHERE object_id = OBJECT_ID(N''dbo.tbl_Employees'') AND name = N''IX_tbl_Employees_PayrollSchedule'')
    DROP STATISTICS dbo.tbl_Employees.IX_tbl_Employees_PayrollSchedule;
IF EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N''dbo.tbl_Employees'') AND name = N''IX_tbl_Employees_PayrollSchedule'')
    DROP INDEX IX_tbl_Employees_PayrollSchedule ON dbo.tbl_Employees;
CREATE NONCLUSTERED INDEX IX_tbl_Employees_PayrollSchedule ON dbo.tbl_Employees (Payroll_Schedule);
';
        EXEC sys.sp_executesql @post;

        /* Optional: enable CT on target */
        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.tbl_Employees'))
        BEGIN
            ALTER TABLE dbo.tbl_Employees
                ENABLE CHANGE_TRACKING WITH (TRACK_COLUMNS_UPDATED = ON);
        END

        DECLARE @EndUTC datetime2(3) = SYSUTCDATETIME();
        DECLARE @EndIso varchar(33)  = CONVERT(varchar(33), @EndUTC, 126);

        SET @Summary = CONCAT(
            N'Employees initial started ', @StartIso,
            N' UTC; ended ', @EndIso,
            N' UTC; baseline inserted ', @Inserted, N' rows; watermark set to ',
            CAST(@BaselineFrom AS nvarchar(30)), N'.'
        );

        SELECT [Stage]=N'Initial', [Summary]=@Summary;

        IF @lockHeld=1
            EXEC sys.sp_releaseapplock @Resource=@LockResource,@LockOwner=@LockOwner,@DbPrincipal=@DbPrincipal;

        RETURN 0;
    END TRY
    BEGIN CATCH
        IF @lockHeld=1
            EXEC sys.sp_releaseapplock @Resource=@LockResource,@LockOwner=@LockOwner,@DbPrincipal=@DbPrincipal;

        DECLARE @msg nvarchar(4000)=ERROR_MESSAGE();
        SET @Summary = CONCAT(N'Employees initial failed: ', @msg);
        SELECT [Stage]=N'Initial', [Summary]=@Summary;

        RAISERROR('usp_Sync_Employees_Initial failed: %s',16,1,@msg);
        RETURN -50001;
    END CATCH
END;
GO
