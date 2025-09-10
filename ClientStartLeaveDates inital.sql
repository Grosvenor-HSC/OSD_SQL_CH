USE [DOM_LIVE];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

/* =======================================================================
   ClientStartLeaveDates Baseline (seed watermark at start to capture in-flight changes)
   ======================================================================= */
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @Process       sysname      = N'ClientStartLeaveDates';
DECLARE @RunStartedAt  datetime2(3) = SYSUTCDATETIME();
DECLARE @BaselineFrom  bigint;   -- CT snapshot taken BEFORE we rebuild/load
DECLARE @LockResource  sysname    = N'DOM_LIVE:Sync:ClientStartLeaveDates';
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
    /* 1) Preconditions (DB-level CT only; table-level CT is not required for baseline) */
    IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_databases WHERE database_id = DB_ID())
        RAISERROR('Change Tracking is not enabled at the database level.', 16, 1);

    /* 2) Take CT snapshot AT START so anything after this is picked up by incremental */
    SET @BaselineFrom = CHANGE_TRACKING_CURRENT_VERSION();

    /* 3) Ensure watermark table exists and seed/refresh the row to the START snapshot */
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

    RAISERROR('Seeded ClientStartLeaveDates watermark to START snapshot %I64d.', 0, 1, @BaselineFrom) WITH NOWAIT;

    /* 4) Recreate target table */
    IF OBJECT_ID('dbo.tbl_ClientStartLeaveDates', 'U') IS NOT NULL
        DROP TABLE dbo.tbl_ClientStartLeaveDates;

    CREATE TABLE dbo.tbl_ClientStartLeaveDates (
        ClientReference       VARCHAR(50) NOT NULL,
        BranchReference       VARCHAR(50) NOT NULL,
        GLOBAL_START_DATE     DATE NULL,
        GLOBAL_WEEK_START     DATE NULL,
        GLOBAL_START_MONTH    TINYINT NULL,
        GLOBAL_START_YEAR     SMALLINT NULL,
        GLOBAL_END_DATE       DATE NULL,
        GLOBAL_WEEK_END       DATE NULL,
        GLOBAL_END_MONTH      TINYINT NULL,
        GLOBAL_END_YEAR       SMALLINT NULL,
        UPDATED_LEAVE_DATES   DATE NULL,
        GLOBAL_STATUS         VARCHAR(50) NOT NULL
    );

    /* 5) Populate (pre-aggregate per client, then compute globals) */
    SET DATEFIRST 1;  -- Monday

    ;WITH Agg AS (
        SELECT
            C.ClientReference,
            C.BranchReference,
            MIN(C.ClientStartDate)       AS MinClientStartDate,
            MAX(C.ClientLeaveDate)       AS MaxClientLeaveDate,
            MIN(V.VisitStartDate)        AS MinVisitStartDate,
            MAX(C.ClientStatus)          AS ClientStatus   -- ClientStatus is grouped below, MAX used just to select a value
        FROM dbo.tbl_Clients AS C
        LEFT JOIN dbo.tbl_Visits  AS V
               ON V.ClientReference = C.ClientReference
        GROUP BY
            C.ClientReference,
            C.BranchReference,
            C.ClientStatus
    ),
    Final AS (
        SELECT
            ClientReference,
            BranchReference,

            /* Choose global start between client start and first visit start */
            CASE 
                WHEN MinClientStartDate IS NULL AND MinVisitStartDate IS NOT NULL THEN MinVisitStartDate
                WHEN MinClientStartDate IS NOT NULL AND MinVisitStartDate IS NULL THEN MinClientStartDate
                WHEN MinClientStartDate >= MinVisitStartDate THEN MinVisitStartDate
                ELSE MinClientStartDate
            END AS GLOBAL_START_DATE,

            MaxClientLeaveDate AS GLOBAL_END_DATE,

            ClientStatus AS GLOBAL_STATUS
        FROM Agg
    )
    INSERT INTO dbo.tbl_ClientStartLeaveDates (
        ClientReference,
        BranchReference,
        GLOBAL_START_DATE,
        GLOBAL_WEEK_START,
        GLOBAL_START_MONTH,
        GLOBAL_START_YEAR,
        GLOBAL_END_DATE,
        GLOBAL_WEEK_END,
        GLOBAL_END_MONTH,
        GLOBAL_END_YEAR,
        UPDATED_LEAVE_DATES,
        GLOBAL_STATUS
    )
    SELECT
        f.ClientReference,
        f.BranchReference,
        f.GLOBAL_START_DATE,
        /* Week start (Mon) from start date */
        CASE 
            WHEN f.GLOBAL_START_DATE IS NOT NULL
            THEN DATEADD(DAY, 1 - DATEPART(WEEKDAY, f.GLOBAL_START_DATE), f.GLOBAL_START_DATE)
            ELSE NULL
        END AS GLOBAL_WEEK_START,
        MONTH(f.GLOBAL_START_DATE)  AS GLOBAL_START_MONTH,
        YEAR(f.GLOBAL_START_DATE)   AS GLOBAL_START_YEAR,

        f.GLOBAL_END_DATE,
        /* Week start (Mon) of end date (often used as "week end bucket") */
        CASE 
            WHEN f.GLOBAL_END_DATE IS NOT NULL
            THEN DATEADD(DAY, 1 - DATEPART(WEEKDAY, f.GLOBAL_END_DATE), f.GLOBAL_END_DATE)
            ELSE NULL
        END AS GLOBAL_WEEK_END,
        MONTH(f.GLOBAL_END_DATE) AS GLOBAL_END_MONTH,
        YEAR(f.GLOBAL_END_DATE)  AS GLOBAL_END_YEAR,

        ISNULL(CONVERT(DATE, f.GLOBAL_END_DATE), CONVERT(DATE, GETDATE())) AS UPDATED_LEAVE_DATES,

        f.GLOBAL_STATUS
    FROM Final AS f;

    DECLARE @rows int = @@ROWCOUNT;
    RAISERROR('tbl_ClientStartLeaveDates baseline complete. Inserted %d rows.', 0, 1, @rows) WITH NOWAIT;

    /* 6) Do NOT advance the watermark here. We want the next incremental to pick up
          any changes that happened DURING this baseline (versions > @BaselineFrom). */

    /* 7) Keys & indexes */
    ALTER TABLE dbo.tbl_ClientStartLeaveDates
        ADD CONSTRAINT PK_ClientStartLeaveDates PRIMARY KEY CLUSTERED (ClientReference);

    CREATE NONCLUSTERED INDEX IX_ClientStartLeave_WeekStart
        ON dbo.tbl_ClientStartLeaveDates (GLOBAL_WEEK_START);

    CREATE NONCLUSTERED INDEX IX_ClientStartLeave_WeekEnd
        ON dbo.tbl_ClientStartLeaveDates (GLOBAL_WEEK_END);

    CREATE NONCLUSTERED INDEX IX_ClientStartLeave_Status
        ON dbo.tbl_ClientStartLeaveDates (GLOBAL_STATUS);

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
        'ClientStartLeaveDates baseline failed (%d, sev %d, state %d) at %s line %d: %s',
        16, 1,
        @num, @sev, @st, @procName, @lin, @msg
    );

    RETURN;
END CATCH
GO
