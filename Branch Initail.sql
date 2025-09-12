USE [DOM_LIVE];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Sync_Branch_Initial
    @Summary NVARCHAR(4000) = NULL OUTPUT   -- NEW: human-readable result
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Process       sysname      = N'Branch';
    DECLARE @RunStartedAt  datetime2(3) = SYSUTCDATETIME();
    DECLARE @RunStartedIso varchar(33)  = CONVERT(varchar(33), @RunStartedAt, 126);
    DECLARE @BaselineFrom  bigint;
    DECLARE @LockResource  sysname = N'DOM_LIVE:Sync:Branch';
    DECLARE @LockOwner     sysname = N'Session';
    DECLARE @DbPrincipal   sysname = N'dbo';
    DECLARE @lockResult    int;
    DECLARE @lockHeld      bit = 0;

    EXEC @lockResult = sys.sp_getapplock
        @Resource=@LockResource, @LockMode='Exclusive',
        @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal, @LockTimeout=600000;

    IF @lockResult NOT IN (0,1)
    BEGIN
        SET @Summary = N'Initial failed: could not acquire applock.';
        SELECT [Summary] = @Summary;
        RETURN -1;
    END;
    SET @lockHeld = 1;

    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_databases WHERE database_id = DB_ID())
            RAISERROR('Change Tracking is not enabled at the database level.', 16, 1);

        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.GLOB_SITE'))
            RAISERROR('Change Tracking is not enabled on dbo.GLOB_SITE.', 16, 1);

        SET @BaselineFrom = CHANGE_TRACKING_CURRENT_VERSION();

        IF OBJECT_ID('dbo.CT_Watermark','U') IS NULL
        BEGIN
            CREATE TABLE dbo.CT_Watermark
            (
              ProcessName     sysname      PRIMARY KEY,
              LastSyncVersion bigint       NOT NULL,
              LastSyncTime    datetime2(3) NOT NULL DEFAULT SYSUTCDATETIME()
            );
        END;

        IF EXISTS (SELECT 1 FROM dbo.CT_Watermark WITH (HOLDLOCK, UPDLOCK) WHERE ProcessName=@Process)
            UPDATE dbo.CT_Watermark
               SET LastSyncVersion = @BaselineFrom,
                   LastSyncTime    = SYSUTCDATETIME()
             WHERE ProcessName = @Process;
        ELSE
            INSERT INTO dbo.CT_Watermark(ProcessName, LastSyncVersion, LastSyncTime)
            VALUES (@Process, @BaselineFrom, SYSUTCDATETIME());

        IF OBJECT_ID('dbo.tbl_Branch','U') IS NOT NULL
            DROP TABLE dbo.tbl_Branch;

        CREATE TABLE dbo.tbl_Branch
        (
            BranchUID     VARCHAR(42)   NOT NULL,
            BranchName    NVARCHAR(100) NOT NULL,
            Brand         NVARCHAR(100) NULL,
            Active        NVARCHAR(20)  NULL,
            EarlyPayRate  DECIMAL(10,2) NULL,
            OldBranchUID  VARCHAR(20)   NULL,
            CreatedAtUTC  datetime2(3)  NOT NULL CONSTRAINT DF_tbl_Branch_CreatedAtUTC DEFAULT SYSUTCDATETIME(),
            UpdatedAtUTC  datetime2(3)  NOT NULL CONSTRAINT DF_tbl_Branch_UpdatedAtUTC DEFAULT SYSUTCDATETIME(),
            CONSTRAINT PK_tbl_Branch PRIMARY KEY CLUSTERED (BranchUID)
        );

        CREATE NONCLUSTERED INDEX IX_tbl_Branch_BranchName      ON dbo.tbl_Branch (BranchName);
        CREATE NONCLUSTERED INDEX IX_tbl_Branch_Brand           ON dbo.tbl_Branch (Brand);
        CREATE NONCLUSTERED INDEX IX_tbl_Branch_BranchNameBrand ON dbo.tbl_Branch (BranchName, Brand);
        CREATE NONCLUSTERED INDEX IX_tbl_Branch_OldBranchUID    ON dbo.tbl_Branch (OldBranchUID);

        ;WITH Expanded AS (
            SELECT GS.GS_REF, CAST(N'Portsmouth'      AS NVARCHAR(100)) AS BranchName FROM dbo.GLOB_SITE AS GS WHERE GS.GS_REF='1970000043'
            UNION ALL
            SELECT GS.GS_REF, CAST(N'Southampton'     AS NVARCHAR(100)) FROM dbo.GLOB_SITE AS GS WHERE GS.GS_REF='1970000043'
            UNION ALL
            SELECT GS.GS_REF, CAST(N'Old_Southampton' AS NVARCHAR(100)) FROM dbo.GLOB_SITE AS GS WHERE GS.GS_REF='1970000069'
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

        DECLARE @BaselineInserted int = @@ROWCOUNT;

        /* optional: post-baseline incremental (kept from your previous design) */
        DECLARE @rc int = 0;
        EXEC @rc = dbo.usp_Sync_Branch_Incremental
            @ChunkSize=50000, @LockTimeoutMs=600000, @UseAppLock=0;

        DECLARE @EndUTC datetime2(3) = SYSUTCDATETIME();
        DECLARE @EndIso varchar(33) = CONVERT(varchar(33), @EndUTC, 126);

        -- Build the human-readable summary you asked for:
        SET @Summary = CONCAT(
            N'Branch initial started ', @RunStartedIso, N' UTC; ended ', @EndIso,
            N' UTC; baseline inserted ', @BaselineInserted, N' rows.'
        );

        -- Also surface it as a result set for SSMS:
        SELECT [Summary] = @Summary;

        IF @lockHeld=1 EXEC sys.sp_releaseapplock
            @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;

        RETURN 0;
    END TRY
    BEGIN CATCH
        IF @lockHeld=1 EXEC sys.sp_releaseapplock
            @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;

        DECLARE @msg nvarchar(4000)=ERROR_MESSAGE();
        SET @Summary = CONCAT(N'Branch initial failed: ', @msg);
        SELECT [Summary] = @Summary;

        RETURN -50001;
    END CATCH;
END;
GO
