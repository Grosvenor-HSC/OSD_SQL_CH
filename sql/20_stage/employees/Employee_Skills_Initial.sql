/*
Purpose:
    Perform the initial full load of employee skill records.

Source:
    Source employee skills tables/views.

Target:
    Staging employee skills table.

Run type:
    Initial (full backfill).

Run frequency:
    One-time only.

Safe to re-run:
    NO.

Notes:
    - Must be run AFTER employees initial load.
*/

USE [DOM_LIVE]
GO
/****** Object:  StoredProcedure [dbo].[usp_Sync_EmployeeSkills_Initial]    Script Date: 26/01/2026 20:49:34 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
ALTER   PROCEDURE [dbo].[usp_Sync_EmployeeSkills_Initial]
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Process       sysname      = N'EmployeeSkills';
    DECLARE @RunStartedAt  datetime2(3) = SYSUTCDATETIME();
    DECLARE @StartIso      varchar(33)  = CONVERT(varchar(33), @RunStartedAt, 126);
    DECLARE @BaselineFrom  bigint;
    DECLARE @LockResource  sysname      = N'DOM_LIVE:Sync:EmployeeSkills';
    DECLARE @lockResult    int;
    DECLARE @lockHeld      bit          = 0;

    -- Applock
    EXEC @lockResult = sys.sp_getapplock
        @Resource=@LockResource, @LockMode='Exclusive',
        @LockOwner='Session', @DbPrincipal='dbo', @LockTimeout=600000;
    IF @lockResult NOT IN (0,1)
    BEGIN
        SELECT 'Initial' AS Stage, CAST(N'EmployeeSkills initial failed: could not acquire applock.' AS nvarchar(4000)) AS Summary;
        RETURN -1;
    END
    SET @lockHeld = 1;

    BEGIN TRY
        -- Preconditions
        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_databases WHERE database_id = DB_ID())
            RAISERROR('Change Tracking is not enabled at the database level.', 16, 1);
        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.SKILL_REQD'))
            RAISERROR('Change Tracking is not enabled on dbo.SKILL_REQD.', 16, 1);

        -- Fence CT window
        SET @BaselineFrom = CHANGE_TRACKING_CURRENT_VERSION();

        -- Watermark
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

        -- Recreate target
        IF OBJECT_ID('dbo.tbl_EmployeeSkills','U') IS NOT NULL
            DROP TABLE dbo.tbl_EmployeeSkills;

        CREATE TABLE dbo.tbl_EmployeeSkills (
            Employee_UUID      varchar(20)   NOT NULL,
            Skill_Description  varchar(255)  NOT NULL,
            UUID               int           NOT NULL,     -- SKILLREQ_REF
            Valid_From_Date    datetime2     NULL,
            Valid_To_Date      datetime2     NULL,
            Notes              nvarchar(max) NULL,
            Skill_Category     varchar(255)  NULL,
            CreatedAtUTC       datetime2(3)  NOT NULL CONSTRAINT DF_tbl_EmployeeSkills_CreatedAtUTC DEFAULT SYSUTCDATETIME(),
            UpdatedAtUTC       datetime2(3)  NOT NULL CONSTRAINT DF_tbl_EmployeeSkills_UpdatedAtUTC DEFAULT SYSUTCDATETIME(),
            CONSTRAINT PK_tbl_EmployeeSkills PRIMARY KEY CLUSTERED (UUID)
        );

        ;WITH SR AS (
            SELECT
                sr.SKILLREQ_REF,
                TRY_CONVERT(int, sr.[REFERENCE])                 AS EMP_REF,
                sr.SKILL_REF,
                TRY_CONVERT(datetime2, sr.VAL_START_DTM)         AS StartDT,
                TRY_CONVERT(datetime2, sr.VAL_END_DTM)           AS EndDT,
                CAST(sr.NOTES AS nvarchar(max))                  AS Notes,
                sr.REFFIELD
            FROM dbo.SKILL_REQD sr
            WHERE TRY_CONVERT(int, sr.REF_TYPE) = 2  -- employee
        ),
        D AS (  -- decode once
            SELECT d.DECODE_REF, LTRIM(RTRIM(d.DESCRIPTION)) AS DESCRIPTION, d.VALUE1
            FROM dbo.CHSYSDEC d
            WHERE d.GROUP1 = 2 AND d.CODE = 'SKIL'
        ),
        J AS (
            SELECT
                sr.SKILLREQ_REF,
                sr.EMP_REF,
                d.DESCRIPTION,
                sr.StartDT,
                sr.EndDT,
                sr.Notes,
                sr.REFFIELD,
                sc.DESC_TXT AS Cat,
                ROW_NUMBER() OVER (PARTITION BY sr.SKILLREQ_REF
                                   ORDER BY sr.StartDT DESC, sr.SKILLREQ_REF) AS rn
            FROM SR sr
            LEFT JOIN D              d  ON d.DECODE_REF = sr.SKILL_REF
            LEFT JOIN dbo.SKILL_CATS sc ON sc.SKILL_REF = d.VALUE1
        )
        INSERT dbo.tbl_EmployeeSkills (
            Employee_UUID, Skill_Description, UUID,
            Valid_From_Date, Valid_To_Date, Notes, Skill_Category,
            CreatedAtUTC, UpdatedAtUTC
        )
        SELECT
            CAST(J.EMP_REF AS varchar(20))      AS Employee_UUID,
            J.DESCRIPTION                       AS Skill_Description,
            J.SKILLREQ_REF                      AS UUID,
            J.StartDT                           AS Valid_From_Date,
            J.EndDT                             AS Valid_To_Date,
            J.Notes,
            J.Cat                               AS Skill_Category,
            @RunStartedAt, @RunStartedAt
        FROM J
        WHERE J.rn = 1;

        DECLARE @Inserted int = @@ROWCOUNT;

        -- Indexes
        CREATE NONCLUSTERED INDEX IX_tbl_EmployeeSkills_Employee_UUID
          ON dbo.tbl_EmployeeSkills (Employee_UUID)
          INCLUDE (Skill_Description, Valid_From_Date, Valid_To_Date);

        CREATE NONCLUSTERED INDEX IX_tbl_EmployeeSkills_Skill_Description
          ON dbo.tbl_EmployeeSkills (Skill_Description)
          INCLUDE (Employee_UUID, Valid_From_Date, Valid_To_Date);

        -- Summary + optional incremental
        DECLARE @EndInitialUTC datetime2(3) = SYSUTCDATETIME();
        DECLARE @EndInitialIso varchar(33)  = CONVERT(varchar(33), @EndInitialUTC, 126);

        DECLARE @InitialMsg nvarchar(4000) =
            CONCAT(N'EmployeeSkills initial started ', @StartIso,
                   N' UTC; ended ', @EndInitialIso,
                   N' UTC; baseline inserted ', @Inserted, N' rows.');

        DECLARE @IncrMsg nvarchar(4000) = N'Incremental skipped.';
        IF OBJECT_ID('dbo.usp_Sync_EmployeeSkills_Incremental','P') IS NOT NULL
        BEGIN
            DECLARE @rc int;
            EXEC @rc = dbo.usp_Sync_EmployeeSkills_Incremental
                @ChunkSize=100000, @LockTimeoutMs=600000, @UseAppLock=0,
                @EmitInfo=0, @Summary=@IncrMsg OUTPUT, @ReturnSummaryRow=0;
            IF (@rc < 0) SET @IncrMsg = CONCAT(@IncrMsg, N' (rc=', @rc, N')');
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
        SELECT 'Initial' AS Stage, CAST(CONCAT(N'EmployeeSkills initial failed: ', @msg) AS nvarchar(4000)) AS Summary;
        RETURN -50001;
    END CATCH
END
