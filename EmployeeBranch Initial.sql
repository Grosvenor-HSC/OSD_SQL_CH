USE [DOM_LIVE];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Sync_EmployeeBranch_Initial
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Process       sysname      = N'EmployeeBranch';
    DECLARE @RunStartedAt  datetime2(3) = SYSUTCDATETIME();
    DECLARE @StartIso      varchar(33)  = CONVERT(varchar(33), @RunStartedAt, 126);
    DECLARE @BaselineFrom  bigint;
    DECLARE @LockResource  sysname      = N'DOM_LIVE:Sync:EmployeeBranch';
    DECLARE @lockResult    int;
    DECLARE @lockHeld      bit          = 0;

    -- Applock (wide window for baseline)
    EXEC @lockResult = sys.sp_getapplock
        @Resource=@LockResource, @LockMode='Exclusive',
        @LockOwner='Session', @DbPrincipal='dbo', @LockTimeout=600000;
    IF @lockResult NOT IN (0,1)
    BEGIN
        SELECT 'Initial' AS Stage, CAST(N'EmployeeBranch initial failed: could not acquire applock.' AS nvarchar(4000)) AS Summary;
        RETURN -1;
    END
    SET @lockHeld = 1;

    BEGIN TRY
        /* 1) Preconditions */
        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_databases WHERE database_id = DB_ID())
            RAISERROR('Change Tracking is not enabled at the database level.', 16, 1);
        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.DISTKEY'))
            RAISERROR('Change Tracking is not enabled on dbo.DISTKEY.', 16, 1);

        /* 2) Fence CT window at START so incremental can top-off */
        SET @BaselineFrom = CHANGE_TRACKING_CURRENT_VERSION();

        /* 3) Seed watermark */
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

        /* 4) Recreate target with CreatedAtUTC/UpdatedAtUTC */
        IF OBJECT_ID('dbo.tbl_EmployeeBranch','U') IS NOT NULL
            DROP TABLE dbo.tbl_EmployeeBranch;

        CREATE TABLE dbo.tbl_EmployeeBranch (
            EmployeeReference         INT           NOT NULL,
            BranchReference           NVARCHAR(55)  NULL,
            StartDate                 DATETIME      NULL,
            EndDate                   DATETIME      NULL,
            [Status]                  NVARCHAR(255) NULL,
            CareGroup                 NVARCHAR(255) NULL,
            LeftReason                NVARCHAR(255) NULL,
            EmployeeBranchLocation    NVARCHAR(255) NULL,
            BranchEmployeeMainBranch  CHAR(1)       NULL,
            BranchName                NVARCHAR(255) NULL,
            EmpBranchHash AS HASHBYTES(
                              'SHA2_256',
                              CONCAT(
                                  CONVERT(nvarchar(20), EmployeeReference),
                                  N'|',
                                  COALESCE(UPPER(LTRIM(RTRIM(BranchReference))), N'<NULL>')
                              )
                           ) PERSISTED,
            CreatedAtUTC              datetime2(3)  NOT NULL CONSTRAINT DF_tbl_EmployeeBranch_CreatedAtUTC DEFAULT SYSUTCDATETIME(),
            UpdatedAtUTC              datetime2(3)  NOT NULL CONSTRAINT DF_tbl_EmployeeBranch_UpdatedAtUTC DEFAULT SYSUTCDATETIME(),
            CONSTRAINT PK_tbl_EmployeeBranch PRIMARY KEY NONCLUSTERED (EmpBranchHash)
        );

        /* 5) Populate baseline */
        ;WITH cte_distinct_emp_branch AS (
            SELECT DISTINCT
                DK.INPRIKEY      AS EmployeeReference,
                DK.OUTPRIKEY     AS DISTBranchReference,
                DK.START_DATE    AS StartDate,
                DK.[DATE]        AS EndDate,
                DK.LEFTREASON,
                DK.LOCATION_REF,
                DK.[STATUS],
                DK.CARE_GRP_REF
            FROM dbo.DISTKEY AS DK
        ),
        FirstEmployeeVisits AS (
            SELECT
                V.EmployeeReference,
                B.OldBranchUID,
                MIN(V.VisitStartDate) AS FirstVisitStartDate,
                MAX(V.VisitEndDate)   AS LastVisitEndDate
            FROM dbo.tbl_Visits V
            JOIN dbo.tbl_Branch B ON V.BranchReference = B.BranchUID
            GROUP BY V.EmployeeReference, B.OldBranchUID
        ),
        Base AS (
            SELECT
                DK.EmployeeReference,
                DK.DISTBranchReference,
                DK.StartDate        AS DK_StartDate,
                DK.EndDate          AS DK_EndDate,
                DK.LEFTREASON,
                DK.LOCATION_REF,
                DK.[STATUS]         AS DK_STATUS,
                DK.CARE_GRP_REF,
                E.EMP_REF,
                E.GS_REF,
                EL.DESCRIPTION      AS EmpLocationDesc,
                ES.DESCRIPTION      AS StatusDesc,
                ECG.DESCRIPTION     AS CareGroupDesc,
                ELR.DESCRIPTION     AS LeftReasonDesc,
                EBL.DESCRIPTION     AS EmpBranchLocDesc,
                V.FirstVisitStartDate,
                V.LastVisitEndDate
            FROM cte_distinct_emp_branch DK
            JOIN dbo.EMPLOYEE E             ON DK.EmployeeReference = E.EMP_REF
            LEFT JOIN dbo.CHSYSDEC EL       ON E.LOCATION_REF = EL.DECODE_REF
            LEFT JOIN dbo.CHSYSDEC ES       ON DK.[STATUS]    = ES.DECODE_REF
            LEFT JOIN dbo.CHSYSDEC ECG      ON DK.CARE_GRP_REF = ECG.DECODE_REF
            LEFT JOIN dbo.CHSYSDEC ELR      ON DK.LEFTREASON   = ELR.DECODE_REF
            LEFT JOIN dbo.CHSYSDEC EBL      ON DK.LOCATION_REF = EBL.DECODE_REF
            LEFT JOIN FirstEmployeeVisits V
                   ON V.EmployeeReference = DK.EmployeeReference
                  AND V.OldBranchUID      = DK.DISTBranchReference
        ),
        Shaped AS (
            SELECT
                EmployeeReference = b.EmployeeReference,
                BranchReference   = CAST(bpick.BranchUID AS nvarchar(55)),
                BranchName        = bpick.BranchName,
                EffectiveStartDate =
                    CASE
                        WHEN b.DK_StartDate IS NULL THEN b.FirstVisitStartDate
                        WHEN b.DK_StartDate IS NOT NULL AND b.FirstVisitStartDate IS NOT NULL
                             AND b.FirstVisitStartDate < b.DK_StartDate THEN b.FirstVisitStartDate
                        ELSE b.DK_StartDate
                    END,
                EffectiveEndDate =
                    CASE
                        WHEN b.DK_EndDate IS NULL THEN NULL
                        WHEN b.DK_EndDate IS NOT NULL AND b.LastVisitEndDate IS NOT NULL
                             AND b.LastVisitEndDate > b.DK_EndDate THEN b.LastVisitEndDate
                        ELSE b.DK_EndDate
                    END,
                [Status]               = CASE WHEN b.StatusDesc      = '<No Selection>' THEN '' ELSE b.StatusDesc      END,
                CareGroup              = CASE WHEN b.CareGroupDesc   = '<No Selection>' THEN '' ELSE b.CareGroupDesc   END,
                LeftReason             = CASE WHEN b.LeftReasonDesc  = '<No Selection>' THEN '' ELSE b.LeftReasonDesc  END,
                EmployeeBranchLocation = CASE WHEN b.EmpBranchLocDesc= '<No Selection>' THEN '' ELSE b.EmpBranchLocDesc END,
                BranchEmployeeMainBranch = CASE WHEN b.DISTBranchReference = b.GS_REF THEN 'Y' ELSE 'N' END
            FROM Base b
            OUTER APPLY (
                SELECT TOP (1) BranchUID, BranchName
                FROM dbo.tbl_Branch tb
                WHERE
                    (b.DISTBranchReference = '1970000043' AND b.EmpLocationDesc = 'Southampton' AND tb.BranchName = 'Southampton')
                    OR
                    (b.DISTBranchReference = '1970000043' AND (b.EmpLocationDesc IS NULL OR b.EmpLocationDesc <> 'Southampton') AND tb.BranchName = 'Portsmouth')
                    OR
                    (b.DISTBranchReference <> '1970000043' AND tb.OldBranchUID = b.DISTBranchReference)
            ) bpick
        ),
        FinalAgg AS (
            SELECT
                s.EmployeeReference,
                s.BranchReference,
                MIN(s.EffectiveStartDate) AS EffectiveStartDate,
                CASE WHEN SUM(CASE WHEN s.EffectiveEndDate IS NULL THEN 1 ELSE 0 END) > 0
                     THEN NULL ELSE MAX(s.EffectiveEndDate) END AS EffectiveEndDate,
                MAX(s.[Status])                 AS [Status],
                MAX(s.CareGroup)                AS CareGroup,
                MAX(s.LeftReason)               AS LeftReason,
                MAX(s.EmployeeBranchLocation)   AS EmployeeBranchLocation,
                MAX(s.BranchEmployeeMainBranch) AS BranchEmployeeMainBranch,
                MAX(s.BranchName)               AS BranchName
            FROM Shaped s
            WHERE s.BranchReference IS NOT NULL
              AND s.EffectiveStartDate IS NOT NULL
            GROUP BY s.EmployeeReference, s.BranchReference
        )
        INSERT INTO dbo.tbl_EmployeeBranch (
            EmployeeReference, BranchReference, StartDate, EndDate,
            [Status], CareGroup, LeftReason, EmployeeBranchLocation,
            BranchEmployeeMainBranch, BranchName, CreatedAtUTC, UpdatedAtUTC
        )
        SELECT
            f.EmployeeReference, f.BranchReference, f.EffectiveStartDate, f.EffectiveEndDate,
            f.[Status], f.CareGroup, f.LeftReason, f.EmployeeBranchLocation,
            f.BranchEmployeeMainBranch, f.BranchName, @RunStartedAt, @RunStartedAt
        FROM FinalAgg f;

        DECLARE @Inserted int = @@ROWCOUNT;

        /* 6) Indexes after load */
        CREATE CLUSTERED INDEX CX_EmployeeBranch
          ON dbo.tbl_EmployeeBranch (EmployeeReference, BranchReference, StartDate);
        CREATE INDEX IX_EmployeeBranch_EmployeeRef        ON dbo.tbl_EmployeeBranch (EmployeeReference);
        CREATE INDEX IX_EmployeeBranch_BranchRef          ON dbo.tbl_EmployeeBranch (BranchReference);
        CREATE INDEX IX_EmployeeBranch_StartDate          ON dbo.tbl_EmployeeBranch (StartDate);
        CREATE INDEX IX_EmployeeBranch_EndDate            ON dbo.tbl_EmployeeBranch (EndDate);
        CREATE INDEX IX_EmployeeBranch_EmpBranchStartDate ON dbo.tbl_EmployeeBranch (EmployeeReference, BranchReference, StartDate);

        /* 7) Enable CT on target (optional for auditing; not required by incremental) */
        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.tbl_EmployeeBranch'))
        BEGIN
            ALTER TABLE dbo.tbl_EmployeeBranch
            ENABLE CHANGE_TRACKING
            WITH (TRACK_COLUMNS_UPDATED = ON);
        END

        /* 8) Compose baseline summary + call incremental QUIETLY and capture summary */
        DECLARE @EndInitialUTC datetime2(3) = SYSUTCDATETIME();
        DECLARE @EndInitialIso varchar(33)  = CONVERT(varchar(33), @EndInitialUTC, 126);

        DECLARE @InitialMsg nvarchar(4000) =
            CONCAT(N'EmployeeBranch initial started ', @StartIso,
                   N' UTC; ended ', @EndInitialIso,
                   N' UTC; baseline inserted ', @Inserted, N' rows.');

        DECLARE @IncrMsg nvarchar(4000) = N'EmployeeBranch incremental completed.';
        DECLARE @rc int;

        IF OBJECT_ID('dbo.usp_Sync_EmployeeBranch_Incremental','P') IS NOT NULL
           AND EXISTS (SELECT 1 FROM sys.parameters WHERE object_id = OBJECT_ID(N'dbo.usp_Sync_EmployeeBranch_Incremental') AND name=N'@Summary')
        BEGIN
            -- New signature: fill @IncrMsg via OUTPUT, suppress row return
            EXEC @rc = dbo.usp_Sync_EmployeeBranch_Incremental
                @ChunkSize=100000, @LockTimeoutMs=600000, @UseAppLock=0,
                @EmitInfo=0, @Summary=@IncrMsg OUTPUT, @ReturnSummaryRow=0;
        END
        ELSE IF OBJECT_ID('dbo.usp_Sync_EmployeeBranch_Incremental','P') IS NOT NULL
        BEGIN
            -- Old signature fallback
            EXEC @rc = dbo.usp_Sync_EmployeeBranch_Incremental
                @ChunkSize=100000, @LockTimeoutMs=600000, @UseAppLock=0;
            SET @IncrMsg = CONCAT(@IncrMsg, N' (rc=', @rc, N').');
        END
        ELSE
        BEGIN
            SET @rc = -1;
            SET @IncrMsg = N'EmployeeBranch incremental skipped (proc not found).';
        END

        -- Return exactly TWO rows
        SELECT 'Initial'     AS Stage, @InitialMsg AS Summary
        UNION ALL
        SELECT 'Incremental' AS Stage, @IncrMsg    AS Summary;

        IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner='Session', @DbPrincipal='dbo';
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner='Session', @DbPrincipal='dbo';
        DECLARE @msg nvarchar(4000)=ERROR_MESSAGE();
        SELECT 'Initial' AS Stage, CAST(CONCAT(N'EmployeeBranch initial failed: ', @msg) AS nvarchar(4000)) AS Summary;
        RETURN -50001;
    END CATCH
END
GO
