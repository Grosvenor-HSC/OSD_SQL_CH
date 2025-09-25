USE [DOM_LIVE];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Sync_EmployeeStartLeaveDates_Initial
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Process       sysname      = N'EmployeeStartLeaveDates';
    DECLARE @RunStartedAt  datetime2(3) = SYSUTCDATETIME();
    DECLARE @StartIso      varchar(33)  = CONVERT(varchar(33), @RunStartedAt, 126);
    DECLARE @BaselineFrom  bigint;
    DECLARE @LockResource  sysname      = N'DOM_LIVE:Sync:EmployeeStartLeaveDates';
    DECLARE @lockResult    int;
    DECLARE @lockHeld      bit          = 0;

    -- applock
    EXEC @lockResult = sys.sp_getapplock
        @Resource=@LockResource, @LockMode='Exclusive',
        @LockOwner='Session', @DbPrincipal='dbo', @LockTimeout=600000;
    IF @lockResult NOT IN (0,1)
    BEGIN
        SELECT 'Initial' AS Stage, CAST(N'EmployeeStartLeaveDates initial failed: could not acquire applock.' AS nvarchar(4000)) AS Summary;
        RETURN -1;
    END
    SET @lockHeld = 1;

    BEGIN TRY
        /* 1) Preconditions: CT at DB + on tbl_EmployeeBranch (driver) */
        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_databases WHERE database_id = DB_ID())
            RAISERROR('Change Tracking is not enabled at the database level.', 16, 1);
        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.tbl_EmployeeBranch'))
            RAISERROR('Change Tracking is not enabled on dbo.tbl_EmployeeBranch.', 16, 1);

        /* 2) Fence CT window at START so incremental can top-off */
        SET @BaselineFrom = CHANGE_TRACKING_CURRENT_VERSION();

        /* 3) Seed/refresh watermark to START snapshot */
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
            UPDATE SET LastSyncVersion=@BaselineFrom, LastSyncTime=SYSUTCDATETIME()
        WHEN NOT MATCHED THEN
            INSERT(ProcessName, LastSyncVersion, LastSyncTime) VALUES(@Process, @BaselineFrom, SYSUTCDATETIME());

        /* 4) Recreate target with Created/Updated + PK */
        IF OBJECT_ID('dbo.tbl_EmployeeStartLeaveDates','U') IS NOT NULL
            DROP TABLE dbo.tbl_EmployeeStartLeaveDates;

        CREATE TABLE dbo.tbl_EmployeeStartLeaveDates (
            [Start_Date]     date         NULL,
            [End_Date]       date         NULL,
            [Status]         varchar(50)  NULL,
            [Employee_UUID]  varchar(50)  NOT NULL,
            CreatedAtUTC     datetime2(3) NOT NULL CONSTRAINT DF_tbl_EmpSLD_CreatedAtUTC DEFAULT SYSUTCDATETIME(),
            UpdatedAtUTC     datetime2(3) NOT NULL CONSTRAINT DF_tbl_EmpSLD_UpdatedAtUTC DEFAULT SYSUTCDATETIME(),
            CONSTRAINT PK_tbl_EmployeeStartLeaveDates PRIMARY KEY CLUSTERED (Employee_UUID)
        );

        /* 5) Baseline load (aggregate over tbl_EmployeeBranch) */
        ;WITH base AS
        (
            SELECT
                eb.Employee_UUID,
                MIN(CAST(eb.Start_Date AS date)) AS MinStartDate,
                MAX(CAST(eb.End_Date   AS date)) AS MaxEndDate,
                SUM(CASE WHEN eb.End_Date IS NULL THEN 1 ELSE 0 END) AS OpenRows,
                -- rank “Active” highest, then “Temporarily Inactive”, else 0
                MAX(CASE WHEN eb.[Status] = 'Active' THEN 2
                         WHEN eb.[Status] = 'Temporarily Inactive' THEN 1
                         ELSE 0 END) AS StatusRank,
                COUNT(DISTINCT eb.Branch_UUID) AS BranchCount
            FROM dbo.tbl_EmployeeBranch eb
            GROUP BY eb.Employee_UUID
        ),
        Final AS
        (
            SELECT
                [Start_Date]    = ISNULL(MinStartDate, CAST('1998-01-01' AS date)),
                [End_Date]      = CASE WHEN OpenRows > 0 THEN NULL ELSE MaxEndDate END,
                [Status]        = CASE 
                                    WHEN OpenRows > 0 THEN 
                                        CASE WHEN StatusRank = 2 THEN 'Active'
                                             WHEN StatusRank = 1 THEN 'Temporarily Inactive'
                                             ELSE 'Unknown'
                                        END
                                    ELSE 'Permanently Inactive'
                                  END,
                [Employee_UUID] = CAST(b.Employee_UUID AS varchar(50))
            FROM base b
        )
        INSERT dbo.tbl_EmployeeStartLeaveDates
        (
            [Start_Date], [End_Date], [Status],
            [Employee_UUID], CreatedAtUTC, UpdatedAtUTC
        )
        SELECT
            f.[Start_Date], f.[End_Date], f.[Status],
            f.[Employee_UUID], @RunStartedAt, @RunStartedAt
        FROM Final f;

        DECLARE @Inserted int = @@ROWCOUNT;

        /* 6) Helpful indexes */
        CREATE NONCLUSTERED INDEX IX_EmpSLD_Status     ON dbo.tbl_EmployeeStartLeaveDates ([Status]);
        CREATE NONCLUSTERED INDEX IX_EmpSLD_StartDate  ON dbo.tbl_EmployeeStartLeaveDates ([Start_Date]);
        CREATE NONCLUSTERED INDEX IX_EmpSLD_EndDate    ON dbo.tbl_EmployeeStartLeaveDates ([End_Date]);

        /* 7) Summaries + quiet incremental sweep */
        DECLARE @EndInitialUTC datetime2(3) = SYSUTCDATETIME();
        DECLARE @EndInitialIso varchar(33)  = CONVERT(varchar(33), @EndInitialUTC, 126);
        DECLARE @InitialMsg nvarchar(4000) =
            CONCAT(N'EmployeeStartLeaveDates initial started ', @StartIso,
                   N' UTC; ended ', @EndInitialIso,
                   N' UTC; baseline inserted ', @Inserted, N' rows.');

        DECLARE @IncrMsg nvarchar(4000) = N'Incremental skipped.';
        IF OBJECT_ID('dbo.usp_Sync_EmployeeStartLeaveDates_Incremental','P') IS NOT NULL
        BEGIN
            DECLARE @rc int;
            EXEC @rc = dbo.usp_Sync_EmployeeStartLeaveDates_Incremental
                @ChunkSize=100000, @LockTimeoutMs=600000, @UseAppLock=0,
                @EmitInfo=0, @Summary=@IncrMsg OUTPUT, @ReturnSummaryRow=0;
            IF (@rc < 0)
                SET @IncrMsg = CONCAT(@IncrMsg, N' (rc=', @rc, N')');
        END

        SELECT 'Initial' AS Stage,     @InitialMsg AS Summary
        UNION ALL
        SELECT 'Incremental',          @IncrMsg;

        IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner='Session', @DbPrincipal='dbo';
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner='Session', @DbPrincipal='dbo';
        DECLARE @msg nvarchar(4000)=ERROR_MESSAGE();
        SELECT 'Initial' AS Stage, CAST(CONCAT(N'EmployeeStartLeaveDates initial failed: ', @msg) AS nvarchar(4000)) AS Summary;
        RETURN -50001;
    END CATCH
END
GO
