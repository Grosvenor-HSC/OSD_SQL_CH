USE [DOM_LIVE];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Sync_EmployeesDiary_Initial
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Process       sysname      = N'EmployeesDiary';
    DECLARE @RunStartedAt  datetime2(3) = SYSUTCDATETIME();
    DECLARE @StartIso      varchar(33)  = CONVERT(varchar(33), @RunStartedAt, 126);
    DECLARE @BaselineFrom  bigint;
    DECLARE @LockResource  sysname      = N'DOM_LIVE:Sync:EmployeesDiary';
    DECLARE @lockResult    int;
    DECLARE @lockHeld      bit          = 0;

    -- Applock (wide window for baseline)
    EXEC @lockResult = sys.sp_getapplock
        @Resource=@LockResource, @LockMode='Exclusive',
        @LockOwner='Session', @DbPrincipal='dbo', @LockTimeout=600000;
    IF @lockResult NOT IN (0,1)
    BEGIN
        SELECT 'Initial' AS Stage, CAST(N'EmployeesDiary initial failed: could not acquire applock.' AS nvarchar(4000)) AS Summary;
        RETURN -1;
    END
    SET @lockHeld = 1;

    BEGIN TRY
        /* Preconditions */
        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_databases WHERE database_id = DB_ID())
            RAISERROR('Change Tracking is not enabled at the database level.', 16, 1);
        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.EMPLOYEE_DY'))
            RAISERROR('Change Tracking is not enabled on dbo.EMPLOYEE_DY.', 16, 1);

        /* Fence CT window at START */
        SET @BaselineFrom = CHANGE_TRACKING_CURRENT_VERSION();

        /* Watermark seed/refresh */
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

        /* Recreate target with Created/Updated + PK */
        IF OBJECT_ID('dbo.tbl_EmployeesDiary','U') IS NOT NULL
            DROP TABLE dbo.tbl_EmployeesDiary;

        CREATE TABLE dbo.tbl_EmployeesDiary
        (
            EmployeeReference           NVARCHAR(50)  NOT NULL,
            EmployeeDiaryReference      INT           NOT NULL,
            EmployeeDiaryEntryDate      DATETIME      NULL,
            EmployeeDiaryReminded       NVARCHAR(1)   NULL,
            EmployeeDiaryReviewDate     DATETIME      NULL,
            EmployeeDiaryEntryType      NVARCHAR(255) NULL,
            EmployeeDiaryAction         NVARCHAR(MAX) NULL,
            EmployeeDiaryActionDate     DATETIME      NULL,
            EmployeeDiaryReviewDoneDate DATETIME      NULL,
            EmployeeDiaryBranchID       NVARCHAR(55)  NULL,   -- matches tbl_Employees.BranchReference
            CreatedAtUTC                datetime2(3)  NOT NULL CONSTRAINT DF_tbl_EmployeesDiary_CreatedAtUTC DEFAULT SYSUTCDATETIME(),
            UpdatedAtUTC                datetime2(3)  NOT NULL CONSTRAINT DF_tbl_EmployeesDiary_UpdatedAtUTC DEFAULT SYSUTCDATETIME(),
            CONSTRAINT PK_tbl_EmployeesDiary PRIMARY KEY CLUSTERED (EmployeeReference, EmployeeDiaryReference)
        );

        /* Baseline load */
        INSERT INTO dbo.tbl_EmployeesDiary
        (
            EmployeeReference, EmployeeDiaryReference,
            EmployeeDiaryEntryDate, EmployeeDiaryReminded, EmployeeDiaryReviewDate,
            EmployeeDiaryEntryType, EmployeeDiaryAction, EmployeeDiaryActionDate,
            EmployeeDiaryReviewDoneDate, EmployeeDiaryBranchID,
            CreatedAtUTC, UpdatedAtUTC
        )
        SELECT
            CAST(EDY.EMP_REF AS nvarchar(50))        AS EmployeeReference,
            EDY.EMP_DY_REF                           AS EmployeeDiaryReference,
            EDY.ENTRY_DATE,
            EDY.REMINDED,
            EDY.REVIEW_DATE,
            CET.DESCRIPTION                          AS EmployeeDiaryEntryType,
            EDY.ACTION,
            EDY.ACTIONDT,
            EDY.REVDONE_DT,
            E.BranchReference                        AS EmployeeDiaryBranchID,
            @RunStartedAt,
            @RunStartedAt
        FROM dbo.EMPLOYEE_DY AS EDY WITH (NOLOCK)
        LEFT JOIN dbo.tbl_Employees AS E WITH (NOLOCK)
               ON E.EmployeeReference = EDY.EMP_REF
        LEFT JOIN dbo.CHSYSDEC AS CET WITH (NOLOCK)
               ON CET.DECODE_REF = EDY.ENTRY_TYPE;

        DECLARE @Inserted int = @@ROWCOUNT;

        /* Indexes (post-load) */
        CREATE NONCLUSTERED INDEX ix_tbl_EmployeesDiary_EmployeeDiaryEntryDate
            ON dbo.tbl_EmployeesDiary (EmployeeDiaryEntryDate);
        CREATE NONCLUSTERED INDEX ix_tbl_EmployeesDiary_EmployeeDiaryReviewDate
            ON dbo.tbl_EmployeesDiary (EmployeeDiaryReviewDate);
        CREATE NONCLUSTERED INDEX ix_tbl_EmployeesDiary_EmployeeDiaryActionDate
            ON dbo.tbl_EmployeesDiary (EmployeeDiaryActionDate);
        CREATE NONCLUSTERED INDEX ix_tbl_EmployeesDiary_EmployeeDiaryBranchID
            ON dbo.tbl_EmployeesDiary (EmployeeDiaryBranchID);

        /* Compose baseline summary */
        DECLARE @EndInitialUTC datetime2(3) = SYSUTCDATETIME();
        DECLARE @EndInitialIso varchar(33)  = CONVERT(varchar(33), @EndInitialUTC, 126);
        DECLARE @InitialMsg nvarchar(4000) =
            CONCAT(N'EmployeesDiary initial started ', @StartIso,
                   N' UTC; ended ', @EndInitialIso,
                   N' UTC; baseline inserted ', @Inserted, N' rows.');

        /* Quiet incremental sweep to top-off */
        DECLARE @IncrMsg nvarchar(4000) = N'Incremental skipped.';
        IF OBJECT_ID('dbo.usp_Sync_EmployeesDiary_Incremental','P') IS NOT NULL
        BEGIN
            DECLARE @rc int;
            EXEC @rc = dbo.usp_Sync_EmployeesDiary_Incremental
                @ChunkSize=100000, @LockTimeoutMs=600000, @UseAppLock=0,
                @EmitInfo=0, @Summary=@IncrMsg OUTPUT, @ReturnSummaryRow=0;
            IF (@rc < 0) SET @IncrMsg = CONCAT(@IncrMsg, N' (rc=', @rc, N')');
        END

        /* Return two rows */
        SELECT 'Initial'     AS Stage, @InitialMsg AS Summary
        UNION ALL
        SELECT 'Incremental' AS Stage, @IncrMsg    AS Summary;

        IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner='Session', @DbPrincipal='dbo';
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner='Session', @DbPrincipal='dbo';
        DECLARE @msg nvarchar(4000)=ERROR_MESSAGE();
        SELECT 'Initial' AS Stage, CAST(CONCAT(N'EmployeesDiary initial failed: ', @msg) AS nvarchar(4000)) AS Summary;
        RETURN -50001;
    END CATCH
END
GO
