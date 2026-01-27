/*
Purpose:
    Perform the initial full load of visit records into the staging visits table.
    This establishes the baseline dataset used by all downstream visit processing.

Source:
    Source visit tables/views (OSD / care system source).

Target:
    Staging visits table (e.g. dbo.tbl_Visits or equivalent).

Run type:
    Initial (full backfill).

Run frequency:
    One-time only (or controlled re-run in non-production environments).

Safe to re-run:
    NO.
    This script reloads the full visit history and may truncate or overwrite existing data.

Notes:
    - Must be run BEFORE any visit incremental scripts.
    - Downstream processes (distance calculation, reporting, QDS) depend on this data.
    - Re-running in production will invalidate historical reporting and should only be done
      with explicit approval and downtime.
*/

USE [DOM_LIVE]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

ALTER PROCEDURE dbo.usp_Sync_Visits_Initial
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET ANSI_WARNINGS ON;

    DECLARE @Process       sysname      = N'Visits';
    DECLARE @RunStartedAt  datetime2(3) = SYSUTCDATETIME();
    DECLARE @StartIso      varchar(33)  = CONVERT(varchar(33), @RunStartedAt, 126);
    DECLARE @BaselineFrom  bigint;
    DECLARE @LockResource  sysname      = N'DOM_LIVE:Sync:Visits';
    DECLARE @lockResult    int;
    DECLARE @lockHeld      bit          = 0;

    /* 0) Concurrency */
    EXEC @lockResult = sys.sp_getapplock
        @Resource=@LockResource, @LockMode='Exclusive',
        @LockOwner='Session', @DbPrincipal='dbo', @LockTimeout=600000;

    IF @lockResult NOT IN (0,1)
    BEGIN
        SELECT 'Initial' AS Stage, N'Visits initial failed: could not acquire applock.' AS Summary;
        RETURN -1;
    END
    SET @lockHeld = 1;

    BEGIN TRY
        /* Preconditions */
        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_databases WHERE database_id = DB_ID())
            THROW 50000, 'Change Tracking not enabled at DB level.', 1;

        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.ACTIVITY_HD'))
            THROW 50000, 'Change Tracking not enabled on dbo.ACTIVITY_HD.', 1;

        /* 1) Seed watermark */
        SET @BaselineFrom = CHANGE_TRACKING_CURRENT_VERSION();

        IF OBJECT_ID('dbo.CT_Watermark','U') IS NULL
        BEGIN
            CREATE TABLE dbo.CT_Watermark
            (
                ProcessName     sysname      PRIMARY KEY,
                LastSyncVersion bigint       NOT NULL,
                LastSyncTime    datetime2(3) NOT NULL DEFAULT SYSUTCDATETIME()
            );
        END

        MERGE dbo.CT_Watermark t
        USING (SELECT @Process AS ProcessName) s
        ON t.ProcessName = s.ProcessName
        WHEN MATCHED THEN
            UPDATE SET LastSyncVersion=@BaselineFrom, LastSyncTime=SYSUTCDATETIME()
        WHEN NOT MATCHED THEN
            INSERT (ProcessName, LastSyncVersion, LastSyncTime)
            VALUES (@Process, @BaselineFrom, SYSUTCDATETIME());

        /* 2) Rebuild target */
        IF OBJECT_ID('dbo.tbl_Visits','U') IS NOT NULL
            DROP TABLE dbo.tbl_Visits;

        CREATE TABLE dbo.tbl_Visits
        (
            UUID                          INT          NOT NULL PRIMARY KEY, -- ACT_REF
            Client_UUID                   INT          NULL,
            Employee_UUID                 INT          NULL,
            Planned_Employee_UUID         INT          NULL,
            Careplan_UUID                 INT          NULL,
            Care_Group                    INT          NULL,
            Branch_UUID                   INT          NULL,
            Contract_UUID                 INT          NULL,
            Linked_Visit_UUID             INT          NULL,
            Planned_Duration              INT          NULL,
            Planned_Visit_Start_Date_Time DATETIME2    NULL,
            Planned_Visit_End_Date_Time   DATETIME2    NULL,
            Actual_Duration               INT          NULL,
            Actual_Visit_Start_Date_Time  DATETIME2    NULL,
            Actual_Visit_End_Date_Time    DATETIME2    NULL,
            Visit_Code                    VARCHAR(50)  NULL,
            Visit_Origin                  VARCHAR(30)  NULL,
            Visit_Invoice_Status          INT          NULL,
            Visit_Pay_Status              INT          NULL,
            Cancel_Pay_Flag               NVARCHAR(4)  NULL,
            CreatedAtUTC                  DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
            UpdatedAtUTC                  DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME()
        );

        /* 3) Keyset */
        CREATE TABLE #Keys (ACT_REF INT PRIMARY KEY);

        INSERT INTO #Keys
        SELECT ACT_REF
        FROM dbo.ACTIVITY_HD
        WHERE [TYPE] <> 1
          AND START_DTM >= DATEADD(YEAR, -3, SYSUTCDATETIME());

        DECLARE @ChunkSize int = 1000000;
        DECLARE @InsertedTotal bigint = 0;

        WHILE EXISTS (SELECT 1 FROM #Keys)
        BEGIN
            CREATE TABLE #NextKeys (ACT_REF INT PRIMARY KEY);

            INSERT INTO #NextKeys
            SELECT TOP (@ChunkSize) ACT_REF
            FROM #Keys
            ORDER BY ACT_REF;

            BEGIN TRAN;

            ;WITH VisitsBase AS
            (
                SELECT
                    AHD.ACT_REF                         AS UUID,
                    AHD.CLIENT_REF                      AS Client_UUID,
                    NULLIF(AHD.EMP_REF,0)               AS Employee_UUID,
                    NULLIF(CPDT.EMP_REF,0)              AS Planned_Employee_UUID,
                    NULLIF(AHD.CPLAN_DET_REF,0)         AS Careplan_UUID,
                    NULLIF(AHD.GS_REF,0)                AS Care_Group,
                    C.Branch_UUID                       AS Branch_UUID,
                    CHD.CONTRACT_REF                    AS Contract_UUID,
                    NULLIF(AHD.MLINKREF,0)              AS Linked_Visit_UUID,
                    CAST(COALESCE(CPDT.QUANTITY,0)*60 AS INT) AS Planned_Duration,
                    AHD.ORIGSTDTM                       AS Planned_Visit_Start_Date_Time,
                    DATEADD(MINUTE, COALESCE(CPDT.QUANTITY,0), AHD.ORIGSTDTM)
                                                        AS Planned_Visit_End_Date_Time,
                    DATEDIFF(MINUTE, AHD.START_DTM, AHD.END_DTM) AS Actual_Duration,
                    AHD.START_DTM                       AS Actual_Visit_Start_Date_Time,
                    AHD.END_DTM                         AS Actual_Visit_End_Date_Time,
                    SHD.SERVICE_CODE                    AS Visit_Code,
                    CASE
                        WHEN AHD.CPLAN_DET_REF <> 0 THEN 'From Template Careplan'
                        WHEN AHD.RNB_VISIT = 'Y'    THEN 'From Booking'
                        ELSE 'Ad-Hoc Entry'
                    END                                 AS Visit_Origin,
                    AHD.INV_STATUS                      AS Visit_Invoice_Status,
                    AHD.PAY_STATUS                      AS Visit_Pay_Status,
                    NULLIF(AHD.CANC_PAY,'')             AS Cancel_Pay_Flag
                FROM dbo.ACTIVITY_HD AHD
                JOIN #NextKeys NK ON NK.ACT_REF = AHD.ACT_REF
                LEFT JOIN dbo.CAREPLAN_DT  CPDT ON AHD.CPLAN_DET_REF = CPDT.CPLAN_DET_REF
                LEFT JOIN dbo.CONTRACT_DT  CDT  ON AHD.CONT_DET_REF = CDT.CONT_DET_REF
                LEFT JOIN dbo.CONTRACT_HD  CHD  ON CDT.CONTRACT_REF = CHD.CONTRACT_REF
                LEFT JOIN dbo.SERVICE_HD   SHD  ON AHD.SERVICE_REF  = SHD.SERVICE_REF
                JOIN dbo.tbl_Clients C ON C.UUID = AHD.CLIENT_REF
            )
            INSERT dbo.tbl_Visits
            SELECT *, @RunStartedAt, @RunStartedAt
            FROM VisitsBase;

            SET @InsertedTotal += @@ROWCOUNT;

            COMMIT;

            DELETE k FROM #Keys k JOIN #NextKeys n ON n.ACT_REF = k.ACT_REF;
        END

        SELECT 'Initial' AS Stage,
               CONCAT('Visits initial completed. Inserted ', @InsertedTotal, ' rows.') AS Summary;

        EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner='Session', @DbPrincipal='dbo';
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner='Session', @DbPrincipal='dbo';
        THROW;
    END CATCH
END
GO
