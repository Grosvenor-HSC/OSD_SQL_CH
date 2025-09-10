USE [DOM_LIVE];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

/* =======================================================================
   Branch Baseline (seed watermark at start to capture in-flight changes)
   ======================================================================= */
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @Process       sysname      = N'Branch';
DECLARE @RunStartedAt  datetime2(3) = SYSUTCDATETIME();
DECLARE @BaselineFrom  bigint;   -- CT snapshot taken BEFORE we rebuild/load
DECLARE @LockResource  sysname = N'DOM_LIVE:Sync:Branch';
DECLARE @LockOwner     sysname = N'Session';
DECLARE @DbPrincipal   sysname = N'dbo';
DECLARE @lockResult    int;
DECLARE @lockHeld      bit = 0;

/* 0) Concurrency guard: use same applock as incremental */
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

    IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.GLOB_SITE'))
        RAISERROR('Change Tracking is not enabled on dbo.GLOB_SITE.', 16, 1);

    /* 2) Take CT snapshot AT START so anything after this is picked up by incremental */
    SET @BaselineFrom = CHANGE_TRACKING_CURRENT_VERSION();

    /* 3) Ensure watermark table exists and seed/refresh Branch row to the START snapshot */
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

    RAISERROR('Seeded Branch watermark to START snapshot %I64d.', 0, 1, @BaselineFrom) WITH NOWAIT;

    /* 4) Recreate target table + indexes */
    IF OBJECT_ID('dbo.tbl_Branch','U') IS NOT NULL
        DROP TABLE dbo.tbl_Branch;

    CREATE TABLE dbo.tbl_Branch
    (
        BranchUID     VARCHAR(42)   NOT NULL,               -- SHA1 hex of BranchName
        BranchName    NVARCHAR(100) NOT NULL,
        Brand         NVARCHAR(100) NULL,                   -- from GLOB_SITE.VATREG
        Active        NVARCHAR(20)  NULL,                   -- from GLOB_SITE.NHS_DEPT
        EarlyPayRate  DECIMAL(10,2) NULL,                   -- from tbl_EarlyPayInitialRatesTable
        OldBranchUID  VARCHAR(20)   NULL,                   -- source GS_REF
        CreatedAtUTC  datetime2(3)  NOT NULL CONSTRAINT DF_tbl_Branch_CreatedAtUTC DEFAULT SYSUTCDATETIME(),
        UpdatedAtUTC  datetime2(3)  NOT NULL CONSTRAINT DF_tbl_Branch_UpdatedAtUTC DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_tbl_Branch PRIMARY KEY CLUSTERED (BranchUID)
    );

    CREATE NONCLUSTERED INDEX IX_tbl_Branch_BranchName      ON dbo.tbl_Branch (BranchName);
    CREATE NONCLUSTERED INDEX IX_tbl_Branch_Brand           ON dbo.tbl_Branch (Brand);
    CREATE NONCLUSTERED INDEX IX_tbl_Branch_BranchNameBrand ON dbo.tbl_Branch (BranchName, Brand);
    CREATE NONCLUSTERED INDEX IX_tbl_Branch_OldBranchUID    ON dbo.tbl_Branch (OldBranchUID);

    /* 5) Populate in a single pass (special cases) */
    ;WITH Expanded AS (
        SELECT GS.GS_REF, CAST(N'Portsmouth'      AS NVARCHAR(100)) AS BranchName FROM dbo.GLOB_SITE AS GS WHERE GS.GS_REF = '1970000043'
        UNION ALL
        SELECT GS.GS_REF, CAST(N'Southampton'     AS NVARCHAR(100)) FROM dbo.GLOB_SITE AS GS WHERE GS.GS_REF = '1970000043'
        UNION ALL
        SELECT GS.GS_REF, CAST(N'Old_Southampton' AS NVARCHAR(100)) FROM dbo.GLOB_SITE AS GS WHERE GS.GS_REF = '1970000069'
        UNION ALL
        SELECT GS.GS_REF, CAST(GS.NAME            AS NVARCHAR(100)) FROM dbo.GLOB_SITE AS GS WHERE GS.GS_REF NOT IN ('1970000043','1970000069')
    ),
    Base AS (
        SELECT
            BranchUID    = CAST(LOWER(master.dbo.fn_varbintohexstr(HASHBYTES('SHA1', e.BranchName))) AS VARCHAR(42)),
            BranchName   = e.BranchName,
            Brand        = CAST(gs.VATREG AS NVARCHAR(100)),
            Active       = CAST(gs.NHS_DEPT AS NVARCHAR(20)),
            EarlyPayRate = CAST(ep.LowestBasicRate AS DECIMAL(10,2)),
            OldBranchUID = CAST(gs.GS_REF AS VARCHAR(20))
        FROM Expanded e
        JOIN dbo.GLOB_SITE gs ON gs.GS_REF = e.GS_REF
        LEFT JOIN dbo.tbl_EarlyPayInitialRatesTable ep ON ep.Branch = e.BranchName
    )
    INSERT INTO dbo.tbl_Branch (BranchUID, BranchName, Brand, Active, EarlyPayRate, OldBranchUID)
    SELECT BranchUID, BranchName, Brand, Active, EarlyPayRate, OldBranchUID
    FROM Base;

    DECLARE @rows int = @@ROWCOUNT;
    RAISERROR('tbl_Branch baseline complete. Inserted %d rows.', 0, 1, @rows) WITH NOWAIT;

    /* 6) IMPORTANT: Do NOT advance watermark here.
           Leaving it at @BaselineFrom ensures any changes made DURING the baseline
           (i.e., versions > @BaselineFrom) will be processed by the next incremental. */

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
            @st int  = ERROR_STATE(),
            @lin int = ERROR_LINE(),
            @proc sysname = ERROR_PROCEDURE();

    -- fix: assign COALESCE result into a variable first
    DECLARE @procName sysname = ISNULL(@proc, N'<adhoc>');

    RAISERROR(
        'Branch baseline failed (%d, sev %d, state %d) at %s line %d: %s',
        16, 1,
        @num, @sev, @st, @procName, @lin, @msg
    );

    RETURN;
END CATCH

