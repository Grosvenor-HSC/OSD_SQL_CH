USE [DOM_LIVE];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

/* =======================================================================
   EmployeesAbsences Baseline (seed watermark at start to capture in-flight changes)
   ======================================================================= */
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @Process       sysname      = N'EmployeesAbsences';
DECLARE @RunStartedAt  datetime2(3) = SYSUTCDATETIME();
DECLARE @BaselineFrom  bigint;   -- CT snapshot taken BEFORE we rebuild/load
DECLARE @LockResource  sysname    = N'DOM_LIVE:Sync:EmployeesAbsences';
DECLARE @LockOwner     sysname    = N'Session';
DECLARE @DbPrincipal   sysname    = N'dbo';
DECLARE @lockResult    int;
DECLARE @lockHeld      bit        = 0;

/* 0) Concurrency guard */
EXEC @lockResult = sys.sp_getapplock
    @Resource    = @LockResource,
    @LockMode    = 'Exclusive',
    @LockOwner   = @LockOwner,
    @DbPrincipal = @DbPrincipal,
    @LockTimeout = 600000;  -- 10 mins for baseline

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

    IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.INACTIVE_DY'))
        RAISERROR('Change Tracking is not enabled on dbo.INACTIVE_DY.', 16, 1);

    /* 2) Take CT snapshot AT START so anything after this is picked up by incremental */
    SET @BaselineFrom = CHANGE_TRACKING_CURRENT_VERSION();

    /* 3) Ensure watermark table exists and seed/refresh row to the START snapshot */
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

    RAISERROR('Seeded EmployeesAbsences watermark to START snapshot %I64d.', 0, 1, @BaselineFrom) WITH NOWAIT;

    /* 4) Recreate target table */
    IF OBJECT_ID('dbo.tbl_EmployeesAbsences', 'U') IS NOT NULL
        DROP TABLE dbo.tbl_EmployeesAbsences;

    CREATE TABLE dbo.tbl_EmployeesAbsences (
    BranchReference         NVARCHAR(50),
    EmployeeReference       NVARCHAR(50),
    AbsenceReason           NVARCHAR(255),
    AbsenceEndDate          DATETIME,
    AbsenceStartDate        DATETIME,
    UpdatedEndDate            DATETIME,
    AbsenceALStatus           NVARCHAR(50),
    UpdatedEndDateWeek        DATE,
    UpdatedStartDateWeek      DATE,
    UpdatedEndDateMonth       DATE,
    UpdatedStartDateMonth     DATE,
    UpdatedEndDateYear        DATE,
    UpdatedStartDateYear      DATE,
    InactivityReference       NVARCHAR(50) NOT NULL, 
    Duration                  INT,
    Comment                   NVARCHAR(MAX),
    CreatedAtUTC              datetime2(3) NOT NULL CONSTRAINT DF_tbl_EmployeesAbsences_CreatedAtUTC DEFAULT SYSUTCDATETIME(),
    UpdatedAtUTC              datetime2(3) NOT NULL CONSTRAINT DF_tbl_EmployeesAbsences_UpdatedAtUTC DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_tbl_EmployeesAbsences_InactivityReference PRIMARY KEY (InactivityReference)
);

    /* 5) Populate */
    SET DATEFIRST 1;  -- Monday

    INSERT INTO dbo.tbl_EmployeesAbsences (
        BranchReference,
        EmployeeReference,
        AbsenceReason,
        AbsenceEndDate,
        AbsenceStartDate,
        UpdatedEndDate,
        AbsenceALStatus,
        UpdatedEndDateWeek,
        UpdatedStartDateWeek,
        UpdatedEndDateMonth,
        UpdatedStartDateMonth,
        UpdatedEndDateYear,
        UpdatedStartDateYear,
        InactivityReference,
        Duration,
        Comment,
        CreatedAtUTC,
        UpdatedAtUTC
    )
    SELECT 
        E.BranchReference,
        CAST(IDY.EMP_REF AS NVARCHAR(50)) AS EmployeeReference,
        CR.DESCRIPTION AS AbsenceReason,
        IDY.END_DTM AS AbsenceEndDate,
        IDY.START_DTM AS AbsenceStartDate,

        CASE 
            WHEN IDY.END_DTM IS NULL AND ESLD.[GlobalStartDate] IS NULL THEN GETDATE()
            WHEN IDY.END_DTM IS NULL AND ESLD.[GlobalStartDate] IS NOT NULL THEN ESLD.[GlobalEndDate]
            ELSE IDY.END_DTM
        END AS UpdatedEndDate,

        CASE 
            WHEN IDY.ALEAVESTAT = ''  THEN 'Entered' 
            WHEN IDY.ALEAVESTAT = 'C' THEN 'Confirmed' 
            WHEN IDY.ALEAVESTAT = 'P' THEN 'Part-Paid' 
            WHEN IDY.ALEAVESTAT = 'F' THEN 'Fully-Paid' 
            ELSE 'Unknown'
        END AS AbsenceALStatus,

        DATEADD(DAY, 7 - DATEPART(WEEKDAY, CONVERT(DATE, 
            CASE 
                WHEN IDY.END_DTM IS NULL AND ESLD.[GlobalStartDate] IS NOT NULL THEN ESLD.[GlobalEndDate]
                WHEN IDY.END_DTM IS NULL THEN GETDATE()
                ELSE IDY.END_DTM
            END)), 
            CONVERT(DATE, 
            CASE 
                WHEN IDY.END_DTM IS NULL AND ESLD.[GlobalStartDate] IS NOT NULL THEN ESLD.[GlobalEndDate]
                WHEN IDY.END_DTM IS NULL THEN GETDATE()
                ELSE IDY.END_DTM
            END)
        ) AS UpdatedEndDateWeek,

        DATEADD(DAY, 7 - DATEPART(WEEKDAY, CONVERT(DATE, IDY.START_DTM)), CONVERT(DATE, IDY.START_DTM)) AS UpdatedStartDateWeek,

        EOMONTH(
            CASE 
                WHEN IDY.END_DTM IS NULL AND ESLD.[GlobalStartDate] IS NOT NULL THEN ESLD.[GlobalEndDate]
                WHEN IDY.END_DTM IS NULL THEN GETDATE()
                ELSE IDY.END_DTM
            END
        ) AS UpdatedEndDateMonth,

        EOMONTH(IDY.START_DTM) AS UpdatedStartDateMonth,

        CONVERT(DATE, DATEADD(YY, DATEDIFF(YY, 0, 
            CASE 
                WHEN IDY.END_DTM IS NULL AND ESLD.[GlobalStartDate] IS NOT NULL THEN ESLD.[GlobalEndDate]
                WHEN IDY.END_DTM IS NULL THEN GETDATE()
                ELSE IDY.END_DTM
            END
        ) + 1, -1)) AS UpdatedEndDateYear,

        CONVERT(DATE, DATEADD(YY, DATEDIFF(YY, 0, IDY.START_DTM) + 1, -1)) AS UpdatedStartDateYear,

        IDY.INACT_REF AS InactivityReference,

        CASE 
            WHEN IDY.END_DTM IS NULL AND ESLD.[GlobalStartDate] IS NOT NULL THEN DATEDIFF(DAY, IDY.START_DTM, ESLD.[GlobalEndDate])
            ELSE DATEDIFF(DAY, IDY.START_DTM, IDY.END_DTM)
        END AS Duration,

        IDY.COMMENT,

        @RunStartedAt, @RunStartedAt
    FROM dbo.INACTIVE_DY AS IDY WITH (NOLOCK)
    LEFT JOIN dbo.CHSYSDEC  AS CR   WITH (NOLOCK) ON CR.DECODE_REF = IDY.REASON
    LEFT JOIN dbo.tbl_Employees AS E WITH (NOLOCK) ON E.EmployeeReference = IDY.EMP_REF
    JOIN dbo.tbl_EmployeeStartLeaveDates AS ESLD ON ESLD.EmployeeReference = E.EmployeeReference
    -- Optional business filters you had commented out:
    WHERE IDY.EMP_REF <> 0 
    AND IDY.rectype = 'E'
    AND CR.DESCRIPTION NOT IN ('From Another Branch', 'Input Error', 'Resigned ', 'Do not use');

    DECLARE @rows int = @@ROWCOUNT;
    RAISERROR('tbl_EmployeesAbsences baseline complete. Inserted %d rows.', 0, 1, @rows) WITH NOWAIT;

    /* 6) Indexes after load */
    CREATE NONCLUSTERED INDEX IX_EmployeesAbsences_EmployeeReference
        ON dbo.tbl_EmployeesAbsences (EmployeeReference);
    CREATE NONCLUSTERED INDEX IX_EmployeesAbsences_UpdatedEndDate
        ON dbo.tbl_EmployeesAbsences (UpdatedEndDate);

    /* 7) Do NOT advance watermark here (incremental will pick up in-flight changes). */

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
        'EmployeesAbsences baseline failed (%d, sev %d, state %d) at %s line %d: %s',
        16, 1,
        @num, @sev, @st, @procName, @lin, @msg
    );

    RETURN;
END CATCH
GO
