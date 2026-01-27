/*
Purpose:
    Perform the initial full load of employee absence records into the staging absences table.
    This establishes the baseline employee absence dataset.

Source:
    Source employee absence tables/views (OSD / care system source).

Target:
    Staging employee absences table.

Run type:
    Initial (full backfill).

Run frequency:
    One-time only.

Safe to re-run:
    NO.
    Reloads the full employee absence history.

Notes:
    - Must be run AFTER employees initial load.
    - Must be run BEFORE employee absence incremental scripts.
*/

/* ============================================================
   File: Employees_Absences_Initial.sql
   Refactor: UUID (INACT_REF) changed from NVARCHAR(50) to INT
   ============================================================ */

USE [DOM_LIVE];
GO

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

ALTER PROCEDURE [dbo].[usp_Sync_EmployeesAbsences_Initial]
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Process       sysname      = N'EmployeesAbsences';
    DECLARE @RunStartedAt  datetime2(3) = SYSUTCDATETIME();
    DECLARE @StartIso      varchar(33)  = CONVERT(varchar(33), @RunStartedAt, 126);
    DECLARE @BaselineFrom  bigint;
    DECLARE @LockResource  sysname      = N'DOM_LIVE:Sync:EmployeesAbsences';
    DECLARE @LockOwner     sysname      = N'Session';
    DECLARE @DbPrincipal   sysname      = N'dbo';
    DECLARE @lockResult    int;
    DECLARE @lockHeld      bit          = 0;

    /* 0) Concurrency guard */
    EXEC @lockResult = sys.sp_getapplock
        @Resource    = @LockResource,
        @LockMode    = 'Exclusive',
        @LockOwner   = @LockOwner,
        @DbPrincipal = @DbPrincipal,
        @LockTimeout = 600000;

    IF @lockResult NOT IN (0,1)
    BEGIN
        SELECT 'Initial' AS Stage,
               CAST(N'EmployeesAbsences initial failed: could not acquire applock.' AS nvarchar(4000)) AS Summary;
        RETURN -1;
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

        /* 3) Watermark seed/refresh to START snapshot */
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
          UPDATE SET LastSyncVersion = @BaselineFrom, LastSyncTime = SYSUTCDATETIME()
        WHEN NOT MATCHED THEN
          INSERT (ProcessName, LastSyncVersion, LastSyncTime)
          VALUES (@Process, @BaselineFrom, SYSUTCDATETIME());

        /* 4) Recreate target table */
        IF OBJECT_ID('dbo.tbl_EmployeesAbsences', 'U') IS NOT NULL
            DROP TABLE dbo.tbl_EmployeesAbsences;

        CREATE TABLE dbo.tbl_EmployeesAbsences
        (
            Employee_UUID   INT             NOT NULL,   -- EMP_REF
            Reason          NVARCHAR(255)   NULL,
            [End_Date]      DATETIME        NULL,
            [Start_Date]    DATETIME        NULL,
            [Status]        NVARCHAR(50)    NULL,
            UUID            INT             NOT NULL,   -- INACT_REF (INT)
            Comment         NVARCHAR(MAX)   NULL,
            CreatedAtUTC    datetime2(3)    NOT NULL CONSTRAINT DF_tbl_EmployeesAbsences_CreatedAtUTC DEFAULT SYSUTCDATETIME(),
            UpdatedAtUTC    datetime2(3)    NOT NULL CONSTRAINT DF_tbl_EmployeesAbsences_UpdatedAtUTC DEFAULT SYSUTCDATETIME(),
            CONSTRAINT PK_tbl_EmployeesAbsences PRIMARY KEY (UUID)
        );

        /* 5) Baseline load */
        SET DATEFIRST 1;  -- Monday

        INSERT INTO dbo.tbl_EmployeesAbsences
        (
            Employee_UUID, Reason, [End_Date], [Start_Date], [Status], UUID, Comment,
            CreatedAtUTC, UpdatedAtUTC
        )
        SELECT
            CAST(IDY.EMP_REF AS INT)               AS Employee_UUID,
            CR.DESCRIPTION                         AS Reason,
            IDY.END_DTM                            AS [End_Date],
            IDY.START_DTM                          AS [Start_Date],
            CASE IDY.ALEAVESTAT
                 WHEN ''  THEN 'Entered'
                 WHEN 'C' THEN 'Confirmed'
                 WHEN 'P' THEN 'Part-Paid'
                 WHEN 'F' THEN 'Fully-Paid'
                 ELSE 'Unknown'
            END                                    AS [Status],
            IDY.INACT_REF                          AS UUID,        -- INT now
            IDY.COMMENT                            AS Comment,
            @RunStartedAt, @RunStartedAt
        FROM dbo.INACTIVE_DY AS IDY WITH (NOLOCK)
        LEFT JOIN dbo.CHSYSDEC AS CR WITH (NOLOCK)
               ON CR.DECODE_REF = IDY.REASON
        LEFT JOIN dbo.tbl_Employees AS E WITH (NOLOCK)
               ON E.UUID = IDY.EMP_REF
        WHERE IDY.EMP_REF <> 0
          AND IDY.rectype = 'E'
          AND (CR.DESCRIPTION IS NULL OR CR.DESCRIPTION NOT IN ('From Another Branch','Input Error','Resigned ','Do not use'));

        DECLARE @Inserted int = @@ROWCOUNT;
        RAISERROR('tbl_EmployeesAbsences baseline complete. Inserted %d rows.', 0, 1, @Inserted) WITH NOWAIT;

        /* 6) Indexes after load */
        CREATE NONCLUSTERED INDEX IX_EmployeesAbsences_Employee
            ON dbo.tbl_EmployeesAbsences (Employee_UUID);

        CREATE NONCLUSTERED INDEX IX_EmployeesAbsences_Start
            ON dbo.tbl_EmployeesAbsences ([Start_Date]);

        /* 7) Compose summary and (optionally) kick incremental */
        DECLARE @EndInitialUTC datetime2(3) = SYSUTCDATETIME();
        DECLARE @EndInitialIso varchar(33)  = CONVERT(varchar(33), @EndInitialUTC, 126);

        DECLARE @InitialMsg nvarchar(4000) =
            CONCAT(N'EmployeesAbsences initial started ', @StartIso,
                   N' UTC; ended ', @EndInitialIso,
                   N' UTC; baseline inserted ', @Inserted, N' rows.');

        DECLARE @IncrMsg nvarchar(4000) = N'EmployeesAbsences incremental skipped (proc not found).';
        DECLARE @rc int;

        IF OBJECT_ID(N'dbo.usp_Sync_EmployeesAbsences_Incremental', N'P') IS NOT NULL
        BEGIN
            BEGIN TRY
                SET @IncrMsg = N'';
                EXEC @rc = dbo.usp_Sync_EmployeesAbsences_Incremental
                    @ChunkSize        = 100000,
                    @LockTimeoutMs    = 600000,
                    @UseAppLock       = 0,
                    @EmitInfo         = 0,
                    @Summary          = @IncrMsg OUTPUT,
                    @ReturnSummaryRow = 0;

                IF @IncrMsg = N'' SET @IncrMsg = CONCAT(N'EmployeesAbsences incremental ran (rc=', @rc, N').');
            END TRY
            BEGIN CATCH
                -- fallback legacy signature
                BEGIN TRY
                    SET @rc = 0;
                    EXEC @rc = dbo.usp_Sync_EmployeesAbsences_Incremental
                        @ChunkSize     = 100000,
                        @LockTimeoutMs = 600000,
                        @UseAppLock    = 0,
                        @EmitInfo      = 0;
                    SET @IncrMsg = CONCAT(N'EmployeesAbsences incremental ran (legacy signature, rc=', @rc, N').');
                END TRY
                BEGIN CATCH
                    SET @IncrMsg = CONCAT(N'EmployeesAbsences incremental failed to run: ', ERROR_MESSAGE());
                END CATCH
            END CATCH
        END

        SELECT 'Initial' AS Stage,     @InitialMsg AS Summary
        UNION ALL
        SELECT 'Incremental',          @IncrMsg;

        IF @lockHeld=1
            EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;

        RETURN 0;

    END TRY
    BEGIN CATCH
        IF @lockHeld=1
            EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;

        DECLARE @msg nvarchar(4000)=ERROR_MESSAGE();
        SELECT 'Initial' AS Stage, CAST(CONCAT(N'EmployeesAbsences initial failed: ', @msg) AS nvarchar(4000)) AS Summary;
        RETURN -50001;
    END CATCH
END;
GO
