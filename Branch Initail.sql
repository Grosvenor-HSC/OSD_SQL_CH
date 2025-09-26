USE [DOM_LIVE];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Sync_Branch_Initial
    @Summary NVARCHAR(4000) = NULL OUTPUT
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

    -- Concurrency
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
        -- Preconditions
        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_databases WHERE database_id = DB_ID())
            RAISERROR('Change Tracking is not enabled at the database level.', 16, 1);
        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.GLOB_SITE'))
            RAISERROR('Change Tracking is not enabled on dbo.GLOB_SITE.', 16, 1);

        -- Fence CT window
        SET @BaselineFrom = CHANGE_TRACKING_CURRENT_VERSION();

        -- Watermark table/row
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

        -- Recreate target with the schema your incremental expects
        IF OBJECT_ID('dbo.tbl_Branch','U') IS NOT NULL
            DROP TABLE dbo.tbl_Branch;

        CREATE TABLE dbo.tbl_Branch
        (
            UUID               VARCHAR(42)    NOT NULL,
            Branch_Name        NVARCHAR(100)  NOT NULL,
            Brand              NVARCHAR(100)  NULL,
            Active             NVARCHAR(20)   NULL,
            Early_Pay_Rate     DECIMAL(10,2)  NULL,
            Old_Branch_UUID    VARCHAR(20)    NULL,
            CreatedAtUTC       datetime2(3)   NOT NULL CONSTRAINT DF_tbl_Branch_CreatedAtUTC DEFAULT SYSUTCDATETIME(),
            UpdatedAtUTC       datetime2(3)   NOT NULL CONSTRAINT DF_tbl_Branch_UpdatedAtUTC DEFAULT SYSUTCDATETIME(),
            CONSTRAINT PK_tbl_Branch PRIMARY KEY CLUSTERED (UUID)
        );

        CREATE NONCLUSTERED INDEX IX_tbl_Branch_BranchName         ON dbo.tbl_Branch (Branch_Name);
        CREATE NONCLUSTERED INDEX IX_tbl_Branch_Brand              ON dbo.tbl_Branch (Brand);
        CREATE NONCLUSTERED INDEX IX_tbl_Branch_BranchName_Brand   ON dbo.tbl_Branch (Branch_Name, Brand);
        CREATE NONCLUSTERED INDEX IX_tbl_Branch_OldBranchUID       ON dbo.tbl_Branch (Old_Branch_UUID);

        /* =========
           Baseline insert via dynamic SQL to avoid compile-time binding to any pre-existing table shape
           ========= */
        DECLARE @sql nvarchar(max) = N'
;WITH Base AS
(
    SELECT
        Branch_Name = CASE
                          WHEN gs.GS_REF=''1970000043'' THEN N''Southampton''
                          WHEN gs.GS_REF=''1970000069'' THEN N''Old_Southampton''
                          ELSE LTRIM(RTRIM(gs.NAME))
                      END,
        Brand           = CAST(LTRIM(RTRIM(gs.VATREG)) AS NVARCHAR(100)),
        Active          = CAST(LTRIM(RTRIM(gs.NHS_DEPT)) AS NVARCHAR(20)),
        Early_Pay_Rate  = CAST(LTRIM(RTRIM(ep.LowestBasicRate)) AS DECIMAL(10,2)),
        Old_Branch_UUID = CAST(LTRIM(RTRIM(gs.GS_REF)) AS VARCHAR(20)),
        UUID = CAST(LOWER(master.dbo.fn_varbintohexstr(
                    HASHBYTES(''SHA1'',
                        CASE
                            WHEN gs.GS_REF=''1970000043'' THEN N''Southampton''
                            WHEN gs.GS_REF=''1970000069'' THEN N''Old_Southampton''
                            ELSE gs.NAME
                        END))) AS VARCHAR(42))
    FROM dbo.GLOB_SITE gs
    LEFT JOIN dbo.tbl_EarlyPayInitialRatesTable ep
           ON ep.Branch = CASE
                              WHEN gs.GS_REF=''1970000043'' THEN N''Southampton''
                              WHEN gs.GS_REF=''1970000069'' THEN N''Old_Southampton''
                              ELSE gs.NAME
                          END
)
INSERT INTO dbo.tbl_Branch
(
    UUID, Branch_Name, Brand, Active, Early_Pay_Rate, Old_Branch_UUID, CreatedAtUTC, UpdatedAtUTC
)
SELECT
    UUID, Branch_Name, Brand, Active, Early_Pay_Rate, Old_Branch_UUID, @RunStartedAt, @RunStartedAt
FROM Base;
';
        DECLARE @params nvarchar(200) = N'@RunStartedAt datetime2(3)';
        EXEC sp_executesql @sql, @params, @RunStartedAt=@RunStartedAt;

        DECLARE @BaselineInserted int = @@ROWCOUNT;

        -- Optionally trigger incremental quietly
        IF OBJECT_ID(N'dbo.usp_Sync_Branch_Incremental', N'P') IS NOT NULL
        BEGIN
            DECLARE @rc int = 0;
            EXEC @rc = dbo.usp_Sync_Branch_Incremental
                @ChunkSize=50000, @LockTimeoutMs=600000, @UseAppLock=0;
        END

        DECLARE @EndUTC datetime2(3) = SYSUTCDATETIME();
        DECLARE @EndIso varchar(33)  = CONVERT(varchar(33), @EndUTC, 126);

        SET @Summary = CONCAT(
            N'Branch initial started ', @RunStartedIso,
            N' UTC; ended ', @EndIso,
            N' UTC; baseline inserted ', @BaselineInserted, N' rows.'
        );
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
