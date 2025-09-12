USE [DOM_LIVE];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Sync_ClientStartLeaveDates_Initial
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Process       sysname      = N'ClientStartLeaveDates';
    DECLARE @RunStartedAt  datetime2(3) = SYSUTCDATETIME();
    DECLARE @StartIso      varchar(33)  = CONVERT(varchar(33), @RunStartedAt, 126);
    DECLARE @BaselineFrom  bigint;
    DECLARE @LockResource  sysname      = N'DOM_LIVE:Sync:ClientStartLeaveDates';
    DECLARE @lockResult    int;
    DECLARE @lockHeld      bit          = 0;

    -- applock
    EXEC @lockResult = sys.sp_getapplock
        @Resource=@LockResource, @LockMode='Exclusive',
        @LockOwner='Session', @DbPrincipal='dbo', @LockTimeout=600000;
    IF @lockResult NOT IN (0,1)
    BEGIN
        SELECT 'Initial' AS Stage, CAST(N'ClientStartLeaveDates initial failed: could not acquire applock.' AS nvarchar(4000)) AS Summary;
        RETURN -1;
    END
    SET @lockHeld = 1;

    BEGIN TRY
        /* 1) Preconditions */
        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_databases WHERE database_id = DB_ID())
            RAISERROR('Change Tracking is not enabled at the database level.', 16, 1);

        /* 2) Snapshot at START */
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

        MERGE dbo.CT_Watermark AS t
        USING (SELECT @Process AS ProcessName) AS s
          ON t.ProcessName = s.ProcessName
        WHEN MATCHED THEN
          UPDATE SET LastSyncVersion=@BaselineFrom, LastSyncTime=SYSUTCDATETIME()
        WHEN NOT MATCHED THEN
          INSERT(ProcessName, LastSyncVersion, LastSyncTime) VALUES(@Process, @BaselineFrom, SYSUTCDATETIME());

        /* 4) Recreate target */
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
            GLOBAL_STATUS         VARCHAR(50) NOT NULL,
            CreatedAtUTC          datetime2(3) NOT NULL CONSTRAINT DF_tbl_ClientStartLeaveDates_CreatedAtUTC DEFAULT SYSUTCDATETIME(),
            UpdatedAtUTC          datetime2(3) NOT NULL CONSTRAINT DF_tbl_ClientStartLeaveDates_UpdatedAtUTC DEFAULT SYSUTCDATETIME(),
            CONSTRAINT PK_tbl_ClientStartLeaveDates_ClientReference PRIMARY KEY CLUSTERED (ClientReference)
        );

        /* 5) Populate */
        SET DATEFIRST 1;  -- Monday
        ;WITH Agg AS (
            SELECT
                C.ClientReference,
                C.BranchReference,
                MIN(C.ClientStartDate) AS MinClientStartDate,
                MAX(C.ClientLeaveDate) AS MaxClientLeaveDate,
                MIN(V.VisitStartDate)  AS MinVisitStartDate,
                MAX(C.ClientStatus)    AS ClientStatus
            FROM dbo.tbl_Clients AS C
            LEFT JOIN dbo.tbl_Visits  AS V
                   ON V.ClientReference = C.ClientReference
            GROUP BY C.ClientReference, C.BranchReference, C.ClientStatus
        ),
        Final AS (
            SELECT
                ClientReference,
                BranchReference,
                CASE 
                    WHEN MinClientStartDate IS NULL AND MinVisitStartDate IS NOT NULL THEN MinVisitStartDate
                    WHEN MinClientStartDate IS NOT NULL AND MinVisitStartDate IS NULL THEN MinClientStartDate
                    WHEN MinClientStartDate >= MinVisitStartDate THEN MinVisitStartDate
                    ELSE MinClientStartDate
                END AS GLOBAL_START_DATE,
                MaxClientLeaveDate AS GLOBAL_END_DATE,
                ClientStatus       AS GLOBAL_STATUS
            FROM Agg
        )
        INSERT INTO dbo.tbl_ClientStartLeaveDates (
            ClientReference, BranchReference,
            GLOBAL_START_DATE, GLOBAL_WEEK_START, GLOBAL_START_MONTH, GLOBAL_START_YEAR,
            GLOBAL_END_DATE,   GLOBAL_WEEK_END,   GLOBAL_END_MONTH,   GLOBAL_END_YEAR,
            UPDATED_LEAVE_DATES, GLOBAL_STATUS,
            CreatedAtUTC, UpdatedAtUTC
        )
        SELECT
            f.ClientReference,
            f.BranchReference,
            f.GLOBAL_START_DATE,
            CASE 
                WHEN f.GLOBAL_START_DATE IS NOT NULL
                THEN DATEADD(DAY, 1 - DATEPART(WEEKDAY, f.GLOBAL_START_DATE), f.GLOBAL_START_DATE)
                ELSE NULL
            END AS GLOBAL_WEEK_START,
            MONTH(f.GLOBAL_START_DATE),
            YEAR(f.GLOBAL_START_DATE),
            f.GLOBAL_END_DATE,
            CASE 
                WHEN f.GLOBAL_END_DATE IS NOT NULL
                THEN DATEADD(DAY, 1 - DATEPART(WEEKDAY, f.GLOBAL_END_DATE), f.GLOBAL_END_DATE)
                ELSE NULL
            END AS GLOBAL_WEEK_END,
            MONTH(f.GLOBAL_END_DATE),
            YEAR(f.GLOBAL_END_DATE),
            ISNULL(CONVERT(DATE, f.GLOBAL_END_DATE), CONVERT(DATE, GETDATE())),
            f.GLOBAL_STATUS,
            @RunStartedAt, @RunStartedAt
        FROM Final AS f;

        DECLARE @Inserted int = @@ROWCOUNT;

        /* 6) Indexes */
        CREATE NONCLUSTERED INDEX IX_ClientStartLeave_WeekStart ON dbo.tbl_ClientStartLeaveDates (GLOBAL_WEEK_START);
        CREATE NONCLUSTERED INDEX IX_ClientStartLeave_WeekEnd   ON dbo.tbl_ClientStartLeaveDates (GLOBAL_WEEK_END);
        CREATE NONCLUSTERED INDEX IX_ClientStartLeave_Status    ON dbo.tbl_ClientStartLeaveDates (GLOBAL_STATUS);

        /* 7) Compose initial summary and quietly run incremental for a second row */
        DECLARE @EndInitialUTC datetime2(3) = SYSUTCDATETIME();
        DECLARE @EndInitialIso varchar(33)  = CONVERT(varchar(33), @EndInitialUTC, 126);

        DECLARE @InitialMsg nvarchar(4000) =
            CONCAT(N'ClientStartLeaveDates initial started ', @StartIso,
                   N' UTC; ended ', @EndInitialIso,
                   N' UTC; baseline inserted ', @Inserted, N' rows.');

        DECLARE @IncrMsg nvarchar(4000) = N'Incremental skipped.';
        IF OBJECT_ID('dbo.usp_Sync_ClientStartLeaveDates_Incremental','P') IS NOT NULL
        BEGIN
            DECLARE @rc int;
            EXEC @rc = dbo.usp_Sync_ClientStartLeaveDates_Incremental
                @ChunkSize=100000,
                @LockTimeoutMs=600000,
                @UseAppLock=0,
                @EmitInfo=0,                 -- quiet
                @Summary=@IncrMsg OUTPUT;    -- << capture one-line summary
            IF (@rc < 0)
                SET @IncrMsg = CONCAT(@IncrMsg, N' (rc=', @rc, N')');
        END

        -- Return two rows: Initial + Incremental
        SELECT 'Initial' AS Stage,     @InitialMsg AS Summary
        UNION ALL
        SELECT 'Incremental',          @IncrMsg;

        IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner='Session', @DbPrincipal='dbo';
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner='Session', @DbPrincipal='dbo';
        DECLARE @msg nvarchar(4000)=ERROR_MESSAGE();
        SELECT 'Initial' AS Stage, CAST(CONCAT(N'ClientStartLeaveDates initial failed: ', @msg) AS nvarchar(4000)) AS Summary;
        RETURN -50001;
    END CATCH
END
GO
