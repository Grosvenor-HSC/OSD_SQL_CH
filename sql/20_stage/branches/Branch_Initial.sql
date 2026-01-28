USE [DOM_LIVE];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

ALTER PROCEDURE [dbo].[usp_Sync_Branch_Initial]
    @Summary NVARCHAR(4000) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Process       sysname      = N'Branch';
    DECLARE @RunStartedAt  datetime2(3) = SYSUTCDATETIME();
    DECLARE @StartIso      varchar(33)  = CONVERT(varchar(33), @RunStartedAt, 126);
    DECLARE @BaselineFrom  bigint;

    /* Concurrency */
    DECLARE @LockResource  sysname = N'DOM_LIVE:Sync:Branch';
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
        SET @Summary = N'Branch initial failed: could not acquire applock.';
        SELECT [Summary] = @Summary;
        RETURN -1;
    END;
    SET @lockHeld = 1;

    BEGIN TRY
        /* Preconditions */
        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_databases WHERE database_id = DB_ID())
            RAISERROR('Change Tracking is not enabled at the database level.', 16, 1);

        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.GLOB_SITE'))
            RAISERROR('Change Tracking is not enabled on dbo.GLOB_SITE.', 16, 1);

        /* Fence CT window */
        SET @BaselineFrom = CHANGE_TRACKING_CURRENT_VERSION();

        /* Watermark */
        IF OBJECT_ID(N'dbo.CT_Watermark', N'U') IS NULL
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
            INSERT(ProcessName, LastSyncVersion, LastSyncTime)
            VALUES(@Process, @BaselineFrom, SYSUTCDATETIME());

        /* ------------------------------------------------------------
           DROP + CREATE via dynamic SQL (avoids stale metadata binding)
           ------------------------------------------------------------ */
        DECLARE @ddl nvarchar(max) = N'
IF OBJECT_ID(N''dbo.tbl_Branch'', N''V'') IS NOT NULL
    DROP VIEW dbo.tbl_Branch;

IF EXISTS (SELECT 1 FROM sys.synonyms WHERE name = N''tbl_Branch'' AND schema_id = SCHEMA_ID(N''dbo''))
    DROP SYNONYM dbo.tbl_Branch;

IF OBJECT_ID(N''dbo.tbl_Branch'', N''U'') IS NOT NULL
    DROP TABLE dbo.tbl_Branch;

CREATE TABLE dbo.tbl_Branch
(
    UUID            INT IDENTITY(1,1) NOT NULL,
    Old_Branch_UUID INT               NOT NULL,   -- GS_REF
    Branch_Name     NVARCHAR(100)     NOT NULL,
    Brand           NVARCHAR(100)     NULL,
    Active          NVARCHAR(20)      NULL,
    Early_Pay_Rate  DECIMAL(10,2)     NULL,

    CreatedAtUTC    datetime2(3)      NOT NULL CONSTRAINT DF_tbl_Branch_CreatedAtUTC DEFAULT SYSUTCDATETIME(),
    UpdatedAtUTC    datetime2(3)      NOT NULL CONSTRAINT DF_tbl_Branch_UpdatedAtUTC DEFAULT SYSUTCDATETIME(),

    CONSTRAINT PK_tbl_Branch PRIMARY KEY CLUSTERED (UUID),
    CONSTRAINT UQ_tbl_Branch_GSRef_Name UNIQUE (Old_Branch_UUID, Branch_Name)
);

CREATE INDEX IX_tbl_Branch_OldBranchUUID ON dbo.tbl_Branch (Old_Branch_UUID);
CREATE INDEX IX_tbl_Branch_BranchName   ON dbo.tbl_Branch (Branch_Name);
CREATE INDEX IX_tbl_Branch_Brand        ON dbo.tbl_Branch (Brand);
';
        EXEC sys.sp_executesql @ddl;

        /* ------------------------------------------------------------
           Baseline insert via dynamic SQL (critical fix)
           ------------------------------------------------------------ */
        DECLARE @ins nvarchar(max) = N'
;WITH Base AS
(
    SELECT
        Old_Branch_UUID = TRY_CONVERT(int, gs.GS_REF),

        Branch_Name =
            CASE
                WHEN TRY_CONVERT(int, gs.GS_REF) = 1970000043 THEN N''Southampton''
                WHEN TRY_CONVERT(int, gs.GS_REF) = 1970000069 THEN N''Old_Southampton''
                ELSE LTRIM(RTRIM(gs.NAME))
            END,

        Brand  = NULLIF(CAST(LTRIM(RTRIM(gs.VATREG))   AS NVARCHAR(100)), N''''),
        Active = NULLIF(CAST(LTRIM(RTRIM(gs.NHS_DEPT)) AS NVARCHAR(20)),  N''''),

        Early_Pay_Rate = NULLIF(TRY_CONVERT(DECIMAL(10,2), ep.LowestBasicRate), 0)
    FROM dbo.GLOB_SITE gs
    LEFT JOIN dbo.tbl_EarlyPayInitialRatesTable ep
      ON ep.Branch =
            CASE
                WHEN TRY_CONVERT(int, gs.GS_REF) = 1970000043 THEN N''Southampton''
                WHEN TRY_CONVERT(int, gs.GS_REF) = 1970000069 THEN N''Old_Southampton''
                ELSE gs.NAME
            END
),
Expanded AS
(
    SELECT * FROM Base

    UNION ALL
    SELECT
        Old_Branch_UUID = 1970000043,
        Branch_Name     = N''Portsmouth'',
        Brand           = (SELECT TOP (1) Brand          FROM Base WHERE Old_Branch_UUID = 1970000043),
        Active          = (SELECT TOP (1) Active         FROM Base WHERE Old_Branch_UUID = 1970000043),
        Early_Pay_Rate  = (SELECT TOP (1) Early_Pay_Rate FROM Base WHERE Old_Branch_UUID = 1970000043)
    WHERE EXISTS (SELECT 1 FROM Base WHERE Old_Branch_UUID = 1970000043)
)
INSERT INTO dbo.tbl_Branch
(
    Old_Branch_UUID,
    Branch_Name,
    Brand,
    Active,
    Early_Pay_Rate,
    CreatedAtUTC,
    UpdatedAtUTC
)
SELECT
    e.Old_Branch_UUID,
    e.Branch_Name,
    e.Brand,
    e.Active,
    e.Early_Pay_Rate,
    @RunStartedAt,
    @RunStartedAt
FROM Expanded e
WHERE e.Old_Branch_UUID IS NOT NULL
  AND e.Branch_Name IS NOT NULL;
';
        EXEC sys.sp_executesql
            @ins,
            N'@RunStartedAt datetime2(3)',
            @RunStartedAt = @RunStartedAt;

        DECLARE @BaselineInserted int;
        SELECT @BaselineInserted = COUNT(*) FROM dbo.tbl_Branch;

        /* Optional: enable CT on target */
        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.tbl_Branch'))
        BEGIN
            ALTER TABLE dbo.tbl_Branch
                ENABLE CHANGE_TRACKING WITH (TRACK_COLUMNS_UPDATED = ON);
        END

        DECLARE @EndUTC datetime2(3) = SYSUTCDATETIME();
        DECLARE @EndIso varchar(33)  = CONVERT(varchar(33), @EndUTC, 126);

        SET @Summary = CONCAT(
            N'Branch initial started ', @StartIso,
            N' UTC; ended ', @EndIso,
            N' UTC; baseline rows in tbl_Branch = ', @BaselineInserted, N'.'
        );

        SELECT [Summary] = @Summary;

        IF @lockHeld=1
            EXEC sys.sp_releaseapplock
                @Resource    = @LockResource,
                @LockOwner   = @LockOwner,
                @DbPrincipal = @DbPrincipal;

        RETURN 0;
    END TRY
    BEGIN CATCH
        IF @lockHeld=1
            EXEC sys.sp_releaseapplock
                @Resource    = @LockResource,
                @LockOwner   = @LockOwner,
                @DbPrincipal = @DbPrincipal;

        DECLARE @msg nvarchar(4000) = ERROR_MESSAGE();
        SET @Summary = CONCAT(N'Branch initial failed: ', @msg);
        SELECT [Summary] = @Summary;
        RETURN -50001;
    END CATCH
END;
GO
