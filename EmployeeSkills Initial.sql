CREATE OR ALTER PROCEDURE dbo.usp_Sync_EmployeeSkills_Initial
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

    -- Concurrency (wide window for baseline)
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
        /* 1) Preconditions: CT on DB + on SKILL_REQD (driver for incremental) */
        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_databases WHERE database_id = DB_ID())
            RAISERROR('Change Tracking is not enabled at the database level.', 16, 1);
        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.SKILL_REQD'))
            RAISERROR('Change Tracking is not enabled on dbo.SKILL_REQD.', 16, 1);

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

        /* 4) Recreate target with Created/Updated columns */
        IF OBJECT_ID('dbo.tbl_EmployeeSkills','U') IS NOT NULL
            DROP TABLE dbo.tbl_EmployeeSkills;

        CREATE TABLE dbo.tbl_EmployeeSkills (
            EmployeeReference                  VARCHAR(20)   NOT NULL,
            EmployeeKeySkillDescription        VARCHAR(255)  NOT NULL,
            EmployeeSkillReference             INT           NOT NULL,     -- SKILLREQ_REF
            EmployeeKeySkillValidFromDate      DATETIME2     NULL,
            EmployeeKeySkillValidToDate        DATETIME2     NULL,
            EmployeeKeySkillNotes              NVARCHAR(MAX) NULL,
            EmployeeKeySkillRefField           VARCHAR(50)   NULL,
            UpdatedEmployeeKeySkillValidToDate DATETIME2     NULL,
            EmployeeKeySkillCategory           VARCHAR(255)  NULL,
            BranchReference                    NVARCHAR(50)  NULL,
            CreatedAtUTC                       datetime2(3)  NOT NULL CONSTRAINT DF_tbl_EmployeeSkills_CreatedAtUTC DEFAULT SYSUTCDATETIME(),
            UpdatedAtUTC                       datetime2(3)  NOT NULL CONSTRAINT DF_tbl_EmployeeSkills_UpdatedAtUTC DEFAULT SYSUTCDATETIME(),
            CONSTRAINT PK_tbl_EmployeeSkills PRIMARY KEY CLUSTERED (EmployeeSkillReference)
        );

        /* 5) Baseline load (single latest row per SKILLREQ_REF) */
        ;WITH SR AS (
          SELECT
              sr.SKILLREQ_REF,
              TRY_CONVERT(int, sr.[REFERENCE]) AS EMP_REF,
              sr.SKILL_REF,
              TRY_CONVERT(datetime2, sr.VAL_START_DTM) AS StartDT,
              TRY_CONVERT(datetime2, sr.VAL_END_DTM)   AS EndDT,
              CAST(sr.NOTES AS NVARCHAR(MAX))          AS Notes,
              sr.REFFIELD
          FROM dbo.SKILL_REQD sr
          WHERE sr.REF_TYPE = 2
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
              cat.DESC_TXT AS Cat,
              b.BranchUID,
              ROW_NUMBER() OVER (PARTITION BY sr.SKILLREQ_REF ORDER BY sr.StartDT DESC, sr.SKILLREQ_REF) AS rn
          FROM SR sr
          JOIN dbo.EMPLOYEE   e ON e.EMP_REF = sr.EMP_REF
          JOIN dbo.tbl_Branch b ON b.OldBranchUID = e.GS_REF
          CROSS APPLY (
              SELECT TOP 1 LTRIM(RTRIM(d.DESCRIPTION)) AS DESCRIPTION, d.VALUE1
              FROM dbo.CHSYSDEC d
              WHERE d.DECODE_REF = sr.SKILL_REF AND d.GROUP1 = 2 AND d.CODE = 'SKIL'
              ORDER BY d.DECODE_REF
          ) d
          OUTER APPLY (
              SELECT TOP 1 sc.DESC_TXT
              FROM dbo.SKILL_CATS sc
              WHERE sc.SKILL_REF = d.VALUE1
              ORDER BY sc.DESC_TXT
          ) cat
        )
        INSERT dbo.tbl_EmployeeSkills (
            EmployeeReference,
            EmployeeKeySkillDescription,
            EmployeeSkillReference,
            EmployeeKeySkillValidFromDate,
            EmployeeKeySkillValidToDate,
            EmployeeKeySkillNotes,
            EmployeeKeySkillRefField,
            UpdatedEmployeeKeySkillValidToDate,
            EmployeeKeySkillCategory,
            BranchReference,
            CreatedAtUTC,
            UpdatedAtUTC
        )
        SELECT
            CAST(J.EMP_REF AS varchar(20)),
            J.DESCRIPTION,
            J.SKILLREQ_REF,
            J.StartDT,
            J.EndDT,
            J.Notes,
            J.REFFIELD,
            COALESCE(J.EndDT, SYSUTCDATETIME()),
            J.Cat,
            CAST(J.BranchUID AS nvarchar(50)),
            @RunStartedAt, @RunStartedAt
        FROM J
        WHERE J.rn = 1;

        DECLARE @Inserted int = @@ROWCOUNT;

        /* 6) Helpful indexes */
        CREATE NONCLUSTERED INDEX IX_tbl_EmployeeSkills_EmployeeReference
          ON dbo.tbl_EmployeeSkills (EmployeeReference)
          INCLUDE (EmployeeKeySkillDescription, EmployeeKeySkillValidFromDate, EmployeeKeySkillValidToDate);

        CREATE NONCLUSTERED INDEX IX_tbl_EmployeeSkills_BranchReference
          ON dbo.tbl_EmployeeSkills (BranchReference);

        CREATE NONCLUSTERED INDEX IX_tbl_EmployeeSkills_EmployeeKeySkillDescription
          ON dbo.tbl_EmployeeSkills (EmployeeKeySkillDescription)
          INCLUDE (EmployeeReference, EmployeeKeySkillValidFromDate, EmployeeKeySkillValidToDate);

        /* 7) Summaries + quiet incremental top-off */
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
        SELECT 'Initial' AS Stage, CAST(CONCAT(N'EmployeeSkills initial failed: ', @msg) AS nvarchar(4000)) AS Summary;
        RETURN -50001;
    END CATCH
END
GO
