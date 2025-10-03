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

    -- Concurrency (wide window for baseline)
    EXEC @lockResult = sys.sp_getapplock
        @Resource=@LockResource, @LockMode='Exclusive',
        @LockOwner='Session', @DbPrincipal='dbo', @LockTimeout=600000;
    IF @lockResult NOT IN (0,1)
    BEGIN
        SELECT 'Initial' AS Stage, CAST(N'EmployeeBranch initial failed: could not acquire applock.' AS nvarchar(4000)) AS Summary;
        RETURN -1;
    END;
    SET @lockHeld = 1;

    BEGIN TRY
        /* 1) Preconditions */
        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_databases WHERE database_id = DB_ID())
            RAISERROR('Change Tracking is not enabled at the database level.', 16, 1);
        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.DISTKEY'))
            RAISERROR('Change Tracking is not enabled on dbo.DISTKEY.', 16, 1);

        -- We reference tbl_Branch below; ensure it exists with required columns
        IF NOT (OBJECT_ID('dbo.tbl_Branch','U') IS NOT NULL
                AND COL_LENGTH('dbo.tbl_Branch','UUID')            IS NOT NULL
                AND COL_LENGTH('dbo.tbl_Branch','Old_Branch_UUID') IS NOT NULL
                AND COL_LENGTH('dbo.tbl_Branch','Branch_Name')     IS NOT NULL)
        BEGIN
            RAISERROR('dbo.tbl_Branch is missing or lacks required columns (UUID, Old_Branch_UUID, Branch_Name). Run Branch initial first.', 16, 1);
        END

        /* 2) Fence CT window */
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
        END;

        MERGE dbo.CT_Watermark AS t
        USING (SELECT @Process AS ProcessName) s
          ON t.ProcessName = s.ProcessName
        WHEN MATCHED THEN
            UPDATE SET LastSyncVersion=@BaselineFrom, LastSyncTime=SYSUTCDATETIME()
        WHEN NOT MATCHED THEN
            INSERT(ProcessName, LastSyncVersion, LastSyncTime)
            VALUES(@Process, @BaselineFrom, SYSUTCDATETIME());

        /* 4) Recreate target */
        IF OBJECT_ID('dbo.tbl_EmployeeBranch','U') IS NOT NULL
            DROP TABLE dbo.tbl_EmployeeBranch;

        CREATE TABLE dbo.tbl_EmployeeBranch
        (
            Employee_UUID   INT           NOT NULL,
            Branch_UUID     VARCHAR(55)   NULL,    -- FK to dbo.tbl_Branch.UUID
            Start_Date      DATETIME      NULL,
            End_Date        DATETIME      NULL,
            [Status]        NVARCHAR(255) NULL,
            [Group]         NVARCHAR(255) NULL,
            Left_Reason     NVARCHAR(255) NULL,
            [Location]      NVARCHAR(255) NULL,
            Main_Branch     CHAR(1)       NULL,    -- 'Y'/'N'
            Branch_Name     NVARCHAR(255) NULL,

            -- Persisted, explicitly-typed varchar(64) computed PK (SHA2_256 hex)
            UUID AS CONVERT(varchar(64),
                    LOWER(CONVERT(varchar(64),
                        HASHBYTES('SHA2_256',
                            CONCAT(
                                CONVERT(nvarchar(20), Employee_UUID),
                                N'|',
                                COALESCE(UPPER(LTRIM(RTRIM(Branch_UUID))), N'<NULL>')
                            )
                        ), 2
                    ))
                  ) PERSISTED,

            CreatedAtUTC    datetime2(3)  NOT NULL CONSTRAINT DF_tbl_EmployeeBranch_CreatedAtUTC DEFAULT SYSUTCDATETIME(),
            UpdatedAtUTC    datetime2(3)  NOT NULL CONSTRAINT DF_tbl_EmployeeBranch_UpdatedAtUTC DEFAULT SYSUTCDATETIME(),

            CONSTRAINT PK_tbl_EmployeeBranch PRIMARY KEY NONCLUSTERED (UUID)
        );

        /* 5) Optional visit aggregation (robust, column-name aware) */
        IF OBJECT_ID('tempdb..#VisitAgg') IS NOT NULL DROP TABLE #VisitAgg;
        CREATE TABLE #VisitAgg
        (
            Employee_UUID        INT         NOT NULL,
            Old_Branch_UUID      VARCHAR(20) NOT NULL,
            FirstVisitStartDate  DATETIME    NULL,
            LastVisitEndDate     DATETIME    NULL,
            PRIMARY KEY (Employee_UUID, Old_Branch_UUID)
        );

        DECLARE @hasVisits bit = 0;
        IF OBJECT_ID('dbo.tbl_Visits','U') IS NOT NULL
           AND COL_LENGTH('dbo.tbl_Visits','Employee_UUID')   IS NOT NULL
           AND COL_LENGTH('dbo.tbl_Visits','Branch_UUID')     IS NOT NULL
        BEGIN
            SET @hasVisits = 1;
        END

        IF @hasVisits = 1
        BEGIN
            DECLARE @StartCol sysname, @EndCol sysname;

            DECLARE @cols TABLE (name sysname NOT NULL);
            INSERT INTO @cols(name)
            SELECT c.name
            FROM sys.columns c
            WHERE c.object_id = OBJECT_ID(N'dbo.tbl_Visits');

            SELECT TOP (1) @StartCol = name
            FROM @cols
            WHERE name IN (N'VisitStartDate', N'Visit_Start_Date', N'StartDate', N'Start_Date', N'VisitStart', N'VisitStartTime', N'StartDateTime')
            ORDER BY CASE name
                       WHEN N'VisitStartDate'   THEN 1
                       WHEN N'Visit_Start_Date' THEN 2
                       WHEN N'StartDate'        THEN 3
                       WHEN N'Start_Date'       THEN 4
                       WHEN N'VisitStart'       THEN 5
                       WHEN N'VisitStartTime'   THEN 6
                       WHEN N'StartDateTime'    THEN 7
                       ELSE 99 END;

            SELECT TOP (1) @EndCol = name
            FROM @cols
            WHERE name IN (N'VisitEndDate', N'Visit_End_Date', N'EndDate', N'End_Date', N'VisitEnd', N'VisitEndTime', N'EndDateTime')
            ORDER BY CASE name
                       WHEN N'VisitEndDate'     THEN 1
                       WHEN N'Visit_End_Date'   THEN 2
                       WHEN N'EndDate'          THEN 3
                       WHEN N'End_Date'         THEN 4
                       WHEN N'VisitEnd'         THEN 5
                       WHEN N'VisitEndTime'     THEN 6
                       WHEN N'EndDateTime'      THEN 7
                       ELSE 99 END;

            IF @StartCol IS NOT NULL AND @EndCol IS NOT NULL
            BEGIN
                DECLARE @vsql nvarchar(max) =
                    N'INSERT INTO #VisitAgg (Employee_UUID, Old_Branch_UUID, FirstVisitStartDate, LastVisitEndDate)
                      SELECT
                          v.Employee_UUID,
                          b.Old_Branch_UUID,
                          MIN(v.' + QUOTENAME(@StartCol) + N'),
                          MAX(v.' + QUOTENAME(@EndCol)   + N')
                      FROM dbo.tbl_Visits AS v
                      JOIN dbo.tbl_Branch AS b
                        ON v.Branch_UUID = b.UUID
                      GROUP BY v.Employee_UUID, b.Old_Branch_UUID;';
                EXEC sys.sp_executesql @vsql;
            END
            -- else: skip aggregation silently if start/end not found
        END
        -- else: leave #VisitAgg empty; downstream LEFT JOINs are safe

        /* 6) Populate baseline */
        ;WITH cte_distinct_emp_branch AS
        (
            SELECT DISTINCT
                DK.INPRIKEY    AS Employee_UUID,     -- EMPLOYEE.EMP_REF
                DK.OUTPRIKEY   AS Old_Branch_UUID,   -- maps to tbl_Branch.Old_Branch_UUID
                DK.START_DATE  AS DK_Start_Date,
                DK.[DATE]      AS DK_End_Date,
                DK.LEFTREASON,
                DK.LOCATION_REF,
                DK.[STATUS]    AS StatusCode,
                DK.CARE_GRP_REF
            FROM dbo.DISTKEY AS DK
        ),
        Base AS
        (
            SELECT
                d.Employee_UUID,
                d.Old_Branch_UUID,
                d.DK_Start_Date,
                d.DK_End_Date,
                d.LEFTREASON,
                d.LOCATION_REF,
                d.StatusCode,
                d.CARE_GRP_REF,

                e.GS_REF,                                 -- employee’s legacy home branch
                el.DESCRIPTION   AS EmpLocationDesc,
                es.DESCRIPTION   AS StatusDesc,
                ecg.DESCRIPTION  AS CareGroupDesc,
                elr.DESCRIPTION  AS LeftReasonDesc,
                ebl.DESCRIPTION  AS EmpBranchLocDesc,

                va.FirstVisitStartDate,
                va.LastVisitEndDate
            FROM cte_distinct_emp_branch d
            JOIN dbo.EMPLOYEE e        ON e.EMP_REF      = d.Employee_UUID
            LEFT JOIN dbo.CHSYSDEC el  ON e.LOCATION_REF = el.DECODE_REF
            LEFT JOIN dbo.CHSYSDEC es  ON d.StatusCode   = es.DECODE_REF
            LEFT JOIN dbo.CHSYSDEC ecg ON d.CARE_GRP_REF = ecg.DECODE_REF
            LEFT JOIN dbo.CHSYSDEC elr ON d.LEFTREASON   = elr.DECODE_REF
            LEFT JOIN dbo.CHSYSDEC ebl ON d.LOCATION_REF = ebl.DECODE_REF
            LEFT JOIN #VisitAgg va     ON va.Employee_UUID   = d.Employee_UUID
                                      AND va.Old_Branch_UUID = d.Old_Branch_UUID
        ),
        Shaped AS
        (
            SELECT
                b.Employee_UUID,

                -- Map Old_Branch_UUID + location rule to a specific tbl_Branch.UUID
                Branch_UUID = CAST(pick.Branch_UUID AS varchar(55)),
                Branch_Name = pick.Branch_Name,

                -- Earliest of DK start vs first visit (if present)
                EffectiveStartDate =
                    CASE
                        WHEN b.DK_Start_Date IS NULL THEN b.FirstVisitStartDate
                        WHEN b.DK_Start_Date IS NOT NULL AND b.FirstVisitStartDate IS NOT NULL
                             AND b.FirstVisitStartDate < b.DK_Start_Date THEN b.FirstVisitStartDate
                        ELSE b.DK_Start_Date
                    END,
                -- Latest of DK end vs last visit (if present); open if any side open
                EffectiveEndDate =
                    CASE
                        WHEN b.DK_End_Date IS NULL THEN NULL
                        WHEN b.DK_End_Date IS NOT NULL AND b.LastVisitEndDate IS NOT NULL
                             AND b.LastVisitEndDate > b.DK_End_Date THEN b.LastVisitEndDate
                        ELSE b.DK_End_Date
                    END,

                [Status]     = CASE WHEN b.StatusDesc       = '<No Selection>' THEN N'' ELSE b.StatusDesc       END,
                [Group]      = CASE WHEN b.CareGroupDesc    = '<No Selection>' THEN N'' ELSE b.CareGroupDesc    END,
                Left_Reason  = CASE WHEN b.LeftReasonDesc   = '<No Selection>' THEN N'' ELSE b.LeftReasonDesc   END,
                [Location]   = CASE WHEN b.EmpBranchLocDesc = '<No Selection>' THEN N'' ELSE b.EmpBranchLocDesc END,

                Main_Branch  = CASE WHEN b.Old_Branch_UUID = b.GS_REF THEN 'Y' ELSE 'N' END
            FROM Base b
            OUTER APPLY
            (
                SELECT TOP (1)
                       tb.UUID        AS Branch_UUID,
                       tb.Branch_Name AS Branch_Name
                FROM dbo.tbl_Branch tb
                WHERE
                    -- special mapping for legacy '1970000043'
                    (b.Old_Branch_UUID = '1970000043' AND b.EmpLocationDesc = 'Southampton' AND tb.Branch_Name = 'Southampton')
                 OR (b.Old_Branch_UUID = '1970000043' AND (b.EmpLocationDesc IS NULL OR b.EmpLocationDesc <> 'Southampton') AND tb.Branch_Name = 'Portsmouth')
                 OR (b.Old_Branch_UUID <> '1970000043' AND tb.Old_Branch_UUID = b.Old_Branch_UUID)
            ) pick
        ),
        FinalAgg AS
        (
            SELECT
                s.Employee_UUID,
                s.Branch_UUID,
                MIN(s.EffectiveStartDate) AS Start_Date,
                CASE WHEN SUM(CASE WHEN s.EffectiveEndDate IS NULL THEN 1 ELSE 0 END) > 0
                     THEN NULL ELSE MAX(s.EffectiveEndDate) END AS End_Date,
                MAX(s.[Status])    AS [Status],
                MAX(NULLIF(s.[Group],       N'')) AS [Group],
                MAX(NULLIF(s.Left_Reason,   N'')) AS Left_Reason,
                MAX(NULLIF(s.[Location],    N'')) AS [Location],
                MAX(s.Main_Branch) AS Main_Branch,     -- 'Y' beats 'N'
                MAX(s.Branch_Name) AS Branch_Name
            FROM Shaped s
            WHERE s.Branch_UUID IS NOT NULL
              AND s.EffectiveStartDate IS NOT NULL
            GROUP BY s.Employee_UUID, s.Branch_UUID
        )
        INSERT INTO dbo.tbl_EmployeeBranch
        (
            Employee_UUID, Branch_UUID, Start_Date, End_Date,
            [Status], [Group], Left_Reason, [Location],
            Main_Branch, Branch_Name,
            CreatedAtUTC, UpdatedAtUTC
        )
        SELECT
            f.Employee_UUID, f.Branch_UUID, f.Start_Date, f.End_Date,
            f.[Status], f.[Group], f.Left_Reason, f.[Location],
            f.Main_Branch, f.Branch_Name,
            @RunStartedAt, @RunStartedAt
        FROM FinalAgg f;

        DECLARE @Inserted int = @@ROWCOUNT;

        /* 7) Indexes after load */
        CREATE CLUSTERED INDEX CX_tbl_EmployeeBranch
            ON dbo.tbl_EmployeeBranch (Employee_UUID, Branch_UUID, Start_Date);
        CREATE INDEX IX_tbl_EmployeeBranch_Employee  ON dbo.tbl_EmployeeBranch (Employee_UUID);
        CREATE INDEX IX_tbl_EmployeeBranch_Branch    ON dbo.tbl_EmployeeBranch (Branch_UUID);
        CREATE INDEX IX_tbl_EmployeeBranch_Start     ON dbo.tbl_EmployeeBranch (Start_Date);
        CREATE INDEX IX_tbl_EmployeeBranch_End       ON dbo.tbl_EmployeeBranch (End_Date);

        /* 8) (Optional) CT on target for auditing */
        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.tbl_EmployeeBranch'))
        BEGIN
            ALTER TABLE dbo.tbl_EmployeeBranch
                ENABLE CHANGE_TRACKING WITH (TRACK_COLUMNS_UPDATED = ON);
        END

        /* 9) Summary + optional incremental kick */
        DECLARE @EndInitialUTC datetime2(3) = SYSUTCDATETIME();
        DECLARE @EndInitialIso varchar(33)  = CONVERT(varchar(33), @EndInitialUTC, 126);

        DECLARE @InitialMsg nvarchar(4000) =
            CONCAT(N'EmployeeBranch initial started ', @StartIso,
                   N' UTC; ended ', @EndInitialIso,
                   N' UTC; baseline inserted ', @Inserted, N' rows.');

        DECLARE @IncrMsg nvarchar(4000) = N'EmployeeBranch incremental skipped (proc not found).';
        DECLARE @rc int;

        IF OBJECT_ID(N'dbo.usp_Sync_EmployeeBranch_Incremental', N'P') IS NOT NULL
        BEGIN
            BEGIN TRY
                SET @IncrMsg = N'';
                EXEC @rc = dbo.usp_Sync_EmployeeBranch_Incremental
                    @ChunkSize        = 100000,
                    @LockTimeoutMs    = 600000,
                    @UseAppLock       = 0,
                    @EmitInfo         = 0,
                    @Summary          = @IncrMsg OUTPUT,
                    @ReturnSummaryRow = 0;
                IF @IncrMsg = N'' SET @IncrMsg = CONCAT(N'EmployeeBranch incremental ran (rc=', @rc, N').');
            END TRY
            BEGIN CATCH
                DECLARE @em nvarchar(4000)=ERROR_MESSAGE();
                SET @IncrMsg = CONCAT(N'EmployeeBranch incremental failed to run: ', @em);
            END CATCH
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
        SELECT 'Initial' AS Stage, CAST(CONCAT(N'EmployeeBranch initial failed: ', @msg) AS nvarchar(4000)) AS Summary;
        RETURN -50001;
    END CATCH
END
GO
