/*
Purpose:
    Perform the initial full load of employee diary records into the staging diary table.

Source:
    Source employee diary tables/views (OSD / care system source).

Target:
    Staging employee diary table.

Run type:
    Initial (full backfill).

Run frequency:
    One-time only.

Safe to re-run:
    NO.
    Reloads the full employee diary history.

Notes:
    - Must be run AFTER employees initial load.
    - Must be run BEFORE employee diary incremental scripts.
*/

/* ============================================================
   File: Employees_Diary_Initial.sql
   Refactor: Ensure Employee_UUID + UUID are INT (EMP_REF / EMP_DY_REF)
   Notes:
     - Drops/recreates dbo.tbl_EmployeesDiary
     - Watermark seeded to CT snapshot at start
     - Baseline load uses ints (no varchar casts)
   ============================================================ */

USE [DOM_LIVE];
GO

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

ALTER PROCEDURE [dbo].[usp_Sync_EmployeesDiary_Initial]
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

    /* Concurrency (wide window for baseline) */
    EXEC @lockResult = sys.sp_getapplock
        @Resource=@LockResource, @LockMode='Exclusive',
        @LockOwner='Session', @DbPrincipal='dbo', @LockTimeout=600000;

    IF @lockResult NOT IN (0,1)
    BEGIN
        SELECT 'Initial' AS Stage,
               CAST(N'EmployeesDiary initial failed: could not acquire applock.' AS nvarchar(4000)) AS Summary;
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

        /* Watermark seed/refresh (to START snapshot) */
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
            INSERT(ProcessName, LastSyncVersion, LastSyncTime)
            VALUES(@Process, @BaselineFrom, SYSUTCDATETIME());

        /* Recreate target */
        IF OBJECT_ID('dbo.tbl_EmployeesDiary','U') IS NOT NULL
            DROP TABLE dbo.tbl_EmployeesDiary;

        CREATE TABLE dbo.tbl_EmployeesDiary
        (
            Employee_UUID  INT           NOT NULL,  -- EMPLOYEE_DY.EMP_REF
            UUID           INT           NOT NULL,  -- EMPLOYEE_DY.EMP_DY_REF
            Entry_Date     DATETIME      NULL,
            Review_Date    DATETIME      NULL,
            Entry_Type     NVARCHAR(255) NULL,
            CreatedAtUTC   datetime2(3)  NOT NULL CONSTRAINT DF_tbl_EmployeesDiary_CreatedAtUTC DEFAULT SYSUTCDATETIME(),
            UpdatedAtUTC   datetime2(3)  NOT NULL CONSTRAINT DF_tbl_EmployeesDiary_UpdatedAtUTC DEFAULT SYSUTCDATETIME(),
            CONSTRAINT PK_tbl_EmployeesDiary PRIMARY KEY CLUSTERED (Employee_UUID, UUID)
        );

        /* Baseline load (dynamic SQL to avoid compile-time binding issues) */
        DECLARE @sql nvarchar(max) = N'
INSERT INTO dbo.tbl_EmployeesDiary
(
    Employee_UUID, UUID,
    Entry_Date, Review_Date, Entry_Type,
    CreatedAtUTC, UpdatedAtUTC
)
SELECT
    EDY.EMP_REF      AS Employee_UUID,
    EDY.EMP_DY_REF   AS UUID,
    EDY.ENTRY_DATE   AS Entry_Date,
    EDY.REVIEW_DATE  AS Review_Date,
    CET.DESCRIPTION  AS Entry_Type,
    @RunStartedAt    AS CreatedAtUTC,
    @RunStartedAt    AS UpdatedAtUTC
FROM dbo.EMPLOYEE_DY AS EDY WITH (NOLOCK)
LEFT JOIN dbo.CHSYSDEC AS CET WITH (NOLOCK)
       ON CET.DECODE_REF = EDY.ENTRY_TYPE
WHERE EDY.EMP_REF <> 0;
';

        EXEC sp_executesql @sql, N'@RunStartedAt datetime2(3)', @RunStartedAt=@RunStartedAt;

        DECLARE @Inserted int = @@ROWCOUNT;

        /* Indexes after load */
        CREATE NONCLUSTERED INDEX IX_tbl_EmployeesDiary_EntryDate
            ON dbo.tbl_EmployeesDiary (Entry_Date);

        CREATE NONCLUSTERED INDEX IX_tbl_EmployeesDiary_ReviewDate
            ON dbo.tbl_EmployeesDiary (Review_Date);

        /* Summary */
        DECLARE @EndInitialUTC datetime2(3) = SYSUTCDATETIME();
        DECLARE @EndInitialIso varchar(33)  = CONVERT(varchar(33), @EndInitialUTC, 126);

        DECLARE @InitialMsg nvarchar(4000) =
            CONCAT(N'EmployeesDiary initial started ', @StartIso,
                   N' UTC; ended ', @EndInitialIso,
                   N' UTC; baseline inserted ', @Inserted, N' rows.');

        /* Quiet incremental top-off (robust to old/new signatures) */
        DECLARE @IncrMsg nvarchar(4000) = N'Incremental skipped (proc not found).';
        DECLARE @rc int;

        IF OBJECT_ID(N'dbo.usp_Sync_EmployeesDiary_Incremental', N'P') IS NOT NULL
        BEGIN
            BEGIN TRY
                SET @IncrMsg = N'';
                EXEC @rc = dbo.usp_Sync_EmployeesDiary_Incremental
                    @ChunkSize        = 100000,
                    @LockTimeoutMs    = 600000,
                    @UseAppLock       = 0,
                    @EmitInfo         = 0,
                    @Summary          = @IncrMsg OUTPUT,
                    @ReturnSummaryRow = 0;

                IF @IncrMsg = N'' SET @IncrMsg = CONCAT(N'EmployeesDiary incremental ran (rc=', @rc, N').');
            END TRY
            BEGIN CATCH
                -- Fallback to legacy signature
                SET @IncrMsg = N'EmployeesDiary incremental ran (legacy signature).';
                BEGIN TRY
                    SET @rc = 0;
                    EXEC @rc = dbo.usp_Sync_EmployeesDiary_Incremental
                        @ChunkSize     = 100000,
                        @LockTimeoutMs = 600000,
                        @UseAppLock    = 0,
                        @EmitInfo      = 0;
                    SET @IncrMsg = CONCAT(@IncrMsg, N' (rc=', @rc, N').');
                END TRY
                BEGIN CATCH
                    SET @IncrMsg = CONCAT(N'EmployeesDiary incremental failed to run: ', ERROR_MESSAGE());
                END CATCH
            END CATCH
        END

        SELECT 'Initial' AS Stage, @InitialMsg AS Summary
        UNION ALL
        SELECT 'Incremental', @IncrMsg;

        IF @lockHeld=1
            EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner='Session', @DbPrincipal='dbo';

        RETURN 0;
    END TRY
    BEGIN CATCH
        IF @lockHeld=1
            EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner='Session', @DbPrincipal='dbo';

        DECLARE @msg nvarchar(4000)=ERROR_MESSAGE();
        SELECT 'Initial' AS Stage,
               CAST(CONCAT(N'EmployeesDiary initial failed: ', @msg) AS nvarchar(4000)) AS Summary;
        RETURN -50001;
    END CATCH
END;
GO
