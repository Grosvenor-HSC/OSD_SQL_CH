USE [DOM_LIVE];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

/* =======================================================================
   ClientAbsences Baseline (seed watermark + CreatedAtUTC/UpdatedAtUTC)
   ======================================================================= */
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @Process       sysname      = N'ClientAbsences';
DECLARE @RunStartedAt  datetime2(3) = SYSUTCDATETIME();
DECLARE @BaselineFrom  bigint;   -- CT snapshot taken BEFORE we rebuild/load
DECLARE @LockResource  sysname    = N'DOM_LIVE:Sync:ClientAbsences';
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

    /* 2) Take CT snapshot AT START */
    SET @BaselineFrom = CHANGE_TRACKING_CURRENT_VERSION();

    /* 3) Watermark seed/refresh */
    IF OBJECT_ID('dbo.CT_Watermark','U') IS NULL
    BEGIN
        CREATE TABLE dbo.CT_Watermark
        (
          ProcessName     sysname      PRIMARY KEY,
          LastSyncVersion bigint       NOT NULL,
          LastSyncTime    datetime2(3) NOT NULL DEFAULT SYSUTCDATETIME()
        );
    END

    IF EXISTS (SELECT 1 FROM dbo.CT_Watermark WITH (HOLDLOCK, UPDLOCK) WHERE ProcessName=@Process)
        UPDATE dbo.CT_Watermark
           SET LastSyncVersion = @BaselineFrom,
               LastSyncTime    = SYSUTCDATETIME()
         WHERE ProcessName = @Process;
    ELSE
        INSERT INTO dbo.CT_Watermark(ProcessName, LastSyncVersion, LastSyncTime)
        VALUES (@Process, @BaselineFrom, SYSUTCDATETIME());

    RAISERROR('Seeded ClientAbsences watermark to START snapshot %I64d.', 0, 1, @BaselineFrom) WITH NOWAIT;

    /* 4) Recreate target table + indexes */
    IF OBJECT_ID('[dbo].[tbl_ClientAbsences]', 'U') IS NOT NULL
        DROP TABLE [dbo].[tbl_ClientAbsences];

    CREATE TABLE [dbo].[tbl_ClientAbsences](
        InactiveReference      nvarchar(55),
        ClientReference        INT,
        AbsenceReason          NVARCHAR(255),
        AbsenceStartDate       DATE,
        AbsenceEndDate         DATE,
        UpdatedLeaveDate       DATE,
        AbsenceEndDate_Week    DATE,
        AbsenceStartDate_Week  DATE,
        AbsenceEndMonth        INT,
        AbsenceStartMonth      INT,
        AbsenceEndYear         INT,
        AbsenceStartYear       INT,
        DaysOnLeave            INT,
        CreatedAtUTC           datetime2(3)  NOT NULL CONSTRAINT DF_tbl_ClientAbsences_CreatedAtUTC DEFAULT SYSUTCDATETIME(),
        UpdatedAtUTC           datetime2(3)  NOT NULL CONSTRAINT DF_tbl_ClientAbsences_UpdatedAtUTC DEFAULT SYSUTCDATETIME()
    );

    /* 5) Populate (stamp Created/Updated with @RunStartedAt) */
    SET DATEFIRST 1;  -- Monday

    INSERT INTO [dbo].[tbl_ClientAbsences] (
        InactiveReference,
        ClientReference,
        AbsenceReason,
        AbsenceStartDate,
        AbsenceEndDate,
        UpdatedLeaveDate,
        AbsenceEndDate_Week,
        AbsenceStartDate_Week,
        AbsenceEndMonth,
        AbsenceStartMonth,
        AbsenceEndYear,
        AbsenceStartYear,
        DaysOnLeave,
        CreatedAtUTC,
        UpdatedAtUTC
    )
    SELECT 
        InactiveReference,
        ClientReference,
        AbsenceReason,
        AbsenceStartDate,
        AbsenceEndDate,
        UpdatedLeaveDate,
        DATEADD(day, 1 - DATEPART(weekday, UpdatedLeaveDate), UpdatedLeaveDate) AS AbsenceEndDate_Week,
        DATEADD(day, 1 - DATEPART(weekday, AbsenceStartDate), AbsenceStartDate) AS AbsenceStartDate_Week,
        MONTH(UpdatedLeaveDate) AS AbsenceEndMonth,
        MONTH(AbsenceStartDate) AS AbsenceStartMonth,
        YEAR(UpdatedLeaveDate) AS AbsenceEndYear,
        YEAR(AbsenceStartDate) AS AbsenceStartYear,
        DATEDIFF(day, AbsenceStartDate, UpdatedLeaveDate) AS DaysOnLeave,
        @RunStartedAt AS CreatedAtUTC,
        @RunStartedAt AS UpdatedAtUTC
    FROM (
        SELECT        
            idy.INACT_REF AS InactiveReference,
            IDY.CLIENT_REF AS ClientReference,
            CAST(IDY.START_DT AS date) AS AbsenceStartDate,
            CAST(IDY.END_DT   AS date) AS AbsenceEndDate,
            CR.DESCRIPTION   AS AbsenceReason,
            CAST(IDY.END_DT AS date) AS UpdatedLeaveDate
        FROM [dbo].INACTIVE_DY AS IDY WITH (NOLOCK)
        LEFT JOIN [dbo].CHSYSDEC AS CR WITH (NOLOCK) 
            ON CR.DECODE_REF = IDY.REASON
        WHERE IDY.rectype NOT IN ('S','R','E')
    ) AS SourceTable;

    DECLARE @rows int = @@ROWCOUNT;
    RAISERROR('tbl_ClientAbsences baseline complete. Inserted %d rows.', 0, 1, @rows) WITH NOWAIT;

    /* 6) Do NOT advance the watermark here (incremental will pick up in-flight changes). */

    /* 7) Indexes after load */
    CREATE INDEX IX_tbl_ClientAbsences_InactiveReference     ON [dbo].[tbl_ClientAbsences](InactiveReference);
    CREATE INDEX IX_tbl_ClientAbsences_ClientReference       ON [dbo].[tbl_ClientAbsences](ClientReference);
    CREATE INDEX IX_tbl_ClientAbsences_AbsenceStartDate      ON [dbo].[tbl_ClientAbsences](AbsenceStartDate);
    CREATE INDEX IX_tbl_ClientAbsences_AbsenceEndDate        ON [dbo].[tbl_ClientAbsences](AbsenceEndDate);
    -- Optional helper:
    -- CREATE INDEX IX_tbl_ClientAbsences_UpdatedAtUTC         ON [dbo].[tbl_ClientAbsences](UpdatedAtUTC);

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
        'ClientAbsences baseline failed (%d, sev %d, state %d) at %s line %d: %s',
        16, 1,
        @num, @sev, @st, @procName, @lin, @msg
    );

    RETURN;
END CATCH
GO
