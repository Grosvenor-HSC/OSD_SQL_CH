/*
Purpose:
    Incrementally load new or changed employee-to-branch relationships.

Source:
    Source employee branch assignment tables/views.

Target:
    Staging employee-branch relationship table.

Run type:
    Incremental.

Run frequency:
    Daily.

Safe to re-run:
    Usually YES.

Notes:
    - Must run AFTER employee incremental.
*/

/* ============================================================
   File: Employee_Branch_Incremental.sql
   Refactor: Branch keys moved from VARCHAR to INT
     - #Changed Old_Branch_UUID INT
     - Target Branch_UUID INT
     - Removes string comparisons for 1970000043
   ============================================================ */

/* ============================================================
   File: Employee_Branch_Incremental.sql
   Refactor: Branch keys moved from VARCHAR to INT
     - #Changed Old_Branch_UUID INT
     - Target Branch_UUID INT
     - Removes string comparisons for 1970000043
   ============================================================ */

USE [DOM_LIVE];
GO

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

ALTER PROCEDURE [dbo].[usp_Sync_EmployeeBranch_Incremental]
    @ChunkSize        int  = 100000,
    @LockTimeoutMs    int  = 60000,
    @UseAppLock       bit  = 1,
    @EmitInfo         bit  = 1,
    @Summary          nvarchar(4000) = NULL OUTPUT,
    @ReturnSummaryRow bit  = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET ANSI_WARNINGS ON;

    DECLARE @Process       sysname      = N'EmployeeBranch';
    DECLARE @RunStartedAt  datetime2(3) = SYSUTCDATETIME();
    DECLARE @StartIso      varchar(33)  = CONVERT(varchar(33), @RunStartedAt, 126);
    DECLARE @EndUTC        datetime2(3);
    DECLARE @EndIso        varchar(33);
    DECLARE @DurationSec   int;

    /* Concurrency guard */
    DECLARE @LockResource sysname = N'DOM_LIVE:Sync:EmployeeBranch';
    DECLARE @LockOwner   sysname = N'Session';
    DECLARE @DbPrincipal sysname = N'dbo';
    DECLARE @lockResult  int;
    DECLARE @lockHeld    bit = 0;

    IF @UseAppLock = 1
    BEGIN
        EXEC @lockResult = sys.sp_getapplock
            @Resource    = @LockResource,
            @LockMode    = 'Exclusive',
            @LockOwner   = @LockOwner,
            @DbPrincipal = @DbPrincipal,
            @LockTimeout = @LockTimeoutMs;

        IF @lockResult NOT IN (0,1)
        BEGIN
            IF @EmitInfo=1 RAISERROR('Could not acquire %s (sp_getapplock rc=%d).',16,1,@LockResource,@lockResult);
            SET @Summary = N'EmployeeBranch incremental failed: could not acquire applock.';
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            RETURN @lockResult;
        END
        SET @lockHeld = 1;
    END

    BEGIN TRY
        /* Preconditions */
        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_databases WHERE database_id = DB_ID())
        BEGIN
            IF @EmitInfo=1 RAISERROR('Change Tracking is not enabled at the database level.', 16, 1);
            SET @Summary = N'EmployeeBranch incremental failed: CT not enabled at DB level.';
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            GOTO FinallyRelease;
        END

        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.DISTKEY'))
        BEGIN
            IF @EmitInfo=1 RAISERROR('Change Tracking is not enabled on dbo.DISTKEY.',16,1);
            SET @Summary = N'EmployeeBranch incremental failed: CT not enabled on dbo.DISTKEY.';
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            GOTO FinallyRelease;
        END

        DECLARE @CT_EMPLOYEE bit =
            CASE WHEN EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.EMPLOYEE')) THEN 1 ELSE 0 END;

        DECLARE @CT_CHSYSDEC bit =
            CASE WHEN EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.CHSYSDEC')) THEN 1 ELSE 0 END;

        /* Watermark */
        IF OBJECT_ID('dbo.CT_Watermark','U') IS NULL
        BEGIN
            CREATE TABLE dbo.CT_Watermark
            (
              ProcessName     sysname      PRIMARY KEY,
              LastSyncVersion bigint       NOT NULL,
              LastSyncTime    datetime2(3) NOT NULL DEFAULT SYSUTCDATETIME()
            );
        END

        IF NOT EXISTS (SELECT 1 FROM dbo.CT_Watermark WITH (HOLDLOCK, UPDLOCK) WHERE ProcessName=@Process)
            INSERT INTO dbo.CT_Watermark(ProcessName, LastSyncVersion) VALUES (@Process, 0);

        DECLARE @LastSyncVersion bigint =
            (SELECT LastSyncVersion FROM dbo.CT_Watermark WITH (HOLDLOCK, UPDLOCK) WHERE ProcessName=@Process);

        /* Min valid across referenced CT tables */
        DECLARE @MinValid bigint =
        (
            SELECT MAX(CHANGE_TRACKING_MIN_VALID_VERSION(object_id))
            FROM sys.change_tracking_tables
            WHERE object_id IN (
                OBJECT_ID(N'dbo.DISTKEY'),
                CASE WHEN @CT_EMPLOYEE=1 THEN OBJECT_ID(N'dbo.EMPLOYEE') ELSE NULL END,
                CASE WHEN @CT_CHSYSDEC=1 THEN OBJECT_ID(N'dbo.CHSYSDEC') ELSE NULL END
            )
        );

        IF @MinValid IS NOT NULL AND @LastSyncVersion < @MinValid
        BEGIN
            IF @EmitInfo=1 RAISERROR('Watermark (%I64d) < CT min valid (%I64d). Re-baseline required.',16,1,@LastSyncVersion,@MinValid);
            SET @Summary = CONCAT(N'EmployeeBranch incremental failed: watermark ', @LastSyncVersion, N' < min valid ', @MinValid, N' (re-baseline).');
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            GOTO FinallyRelease;
        END

        DECLARE @ToVersion bigint = CHANGE_TRACKING_CURRENT_VERSION();

        IF @EmitInfo=1
        BEGIN
            RAISERROR('EmployeeBranch CT window:', 0, 1) WITH NOWAIT;
            RAISERROR('  From = %I64d', 0, 1, @LastSyncVersion) WITH NOWAIT;
            RAISERROR('  To   = %I64d', 0, 1, @ToVersion) WITH NOWAIT;
        END

        /* Build changed (Employee_UUID, Old_Branch_UUID) pairs */
        IF OBJECT_ID('tempdb..#Changed') IS NOT NULL DROP TABLE #Changed;
        CREATE TABLE #Changed
        (
            Employee_UUID      INT NOT NULL,
            Old_Branch_UUID    INT NOT NULL,
            PRIMARY KEY (Employee_UUID, Old_Branch_UUID)
        );

        /* From DISTKEY using dynamic PK join */
        DECLARE @join nvarchar(max);
        DECLARE @sql  nvarchar(max);

        DECLARE @pkcols TABLE (ord int, name sysname);
        INSERT INTO @pkcols(ord, name)
        SELECT ic.key_ordinal, c.name
        FROM sys.indexes i
        JOIN sys.index_columns ic ON i.object_id=ic.object_id AND i.index_id=ic.index_id
        JOIN sys.columns c        ON c.object_id=ic.object_id AND c.column_id=ic.column_id
        WHERE i.object_id = OBJECT_ID(N'dbo.DISTKEY')
          AND i.is_primary_key = 1
        ORDER BY ic.key_ordinal;

        IF NOT EXISTS (SELECT 1 FROM @pkcols)
        BEGIN
            IF @EmitInfo=1 RAISERROR('dbo.DISTKEY has no PK (required for CT).',16,1);
            SET @Summary = N'EmployeeBranch incremental failed: DISTKEY has no PK.';
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            GOTO FinallyRelease;
        END

        SELECT @join =
            STUFF((SELECT ' AND dk.' + QUOTENAME(name) + ' = ct.' + QUOTENAME(name)
                   FROM @pkcols ORDER BY ord FOR XML PATH(''), TYPE).value('.','nvarchar(max)'),1,5,'');

        SET @sql = N'
INSERT INTO #Changed(Employee_UUID, Old_Branch_UUID)
SELECT DISTINCT dk.INPRIKEY, dk.OUTPRIKEY
FROM CHANGETABLE(CHANGES dbo.DISTKEY, @LastSyncVersion) ct
JOIN dbo.DISTKEY dk ON ' + @join + N'
WHERE ct.SYS_CHANGE_VERSION <= @ToVersion
  AND ct.SYS_CHANGE_OPERATION IN (''I'',''U'');';

        EXEC sp_executesql @sql,
            N'@LastSyncVersion bigint, @ToVersion bigint',
            @LastSyncVersion=@LastSyncVersion, @ToVersion=@ToVersion;

        /* EMPLOYEE changes (optional) */
        IF @CT_EMPLOYEE = 1
        BEGIN
            INSERT INTO #Changed(Employee_UUID, Old_Branch_UUID)
            SELECT DISTINCT dk.INPRIKEY, dk.OUTPRIKEY
            FROM CHANGETABLE(CHANGES dbo.EMPLOYEE, @LastSyncVersion) ce
            JOIN dbo.EMPLOYEE e ON e.EMP_REF = ce.EMP_REF
            JOIN dbo.DISTKEY dk ON dk.INPRIKEY = e.EMP_REF
            WHERE ce.SYS_CHANGE_VERSION <= @ToVersion
              AND NOT EXISTS (SELECT 1 FROM #Changed z WHERE z.Employee_UUID = dk.INPRIKEY AND z.Old_Branch_UUID = dk.OUTPRIKEY);
        END
        ELSE IF @EmitInfo=1
            RAISERROR('Note: CT not enabled on EMPLOYEE; location-driven changes may be delayed.', 0, 1) WITH NOWAIT;

        /* CHSYSDEC changes (optional) */
        IF @CT_CHSYSDEC = 1
        BEGIN
            INSERT INTO #Changed(Employee_UUID, Old_Branch_UUID)
            SELECT DISTINCT dk.INPRIKEY, dk.OUTPRIKEY
            FROM CHANGETABLE(CHANGES dbo.CHSYSDEC, @LastSyncVersion) cd
            JOIN dbo.DISTKEY dk
              ON dk.[STATUS]      = cd.DECODE_REF
              OR dk.CARE_GRP_REF  = cd.DECODE_REF
              OR dk.LEFTREASON    = cd.DECODE_REF
              OR dk.LOCATION_REF  = cd.DECODE_REF
            WHERE cd.SYS_CHANGE_VERSION <= @ToVersion
              AND NOT EXISTS (SELECT 1 FROM #Changed z WHERE z.Employee_UUID = dk.INPRIKEY AND z.Old_Branch_UUID = dk.OUTPRIKEY);

            INSERT INTO #Changed(Employee_UUID, Old_Branch_UUID)
            SELECT DISTINCT dk.INPRIKEY, dk.OUTPRIKEY
            FROM CHANGETABLE(CHANGES dbo.CHSYSDEC, @LastSyncVersion) cd
            JOIN dbo.EMPLOYEE e ON e.LOCATION_REF = cd.DECODE_REF
            JOIN dbo.DISTKEY dk ON dk.INPRIKEY = e.EMP_REF
            WHERE cd.SYS_CHANGE_VERSION <= @ToVersion
              AND NOT EXISTS (SELECT 1 FROM #Changed z WHERE z.Employee_UUID = dk.INPRIKEY AND z.Old_Branch_UUID = dk.OUTPRIKEY);
        END
        ELSE IF @EmitInfo=1
            RAISERROR('Note: CT not enabled on CHSYSDEC; description changes may be delayed.', 0, 1) WITH NOWAIT;

        DECLARE @ToProcess int = (SELECT COUNT(*) FROM #Changed);
        IF @EmitInfo=1 RAISERROR('Employee/OldBranch pairs to process: %d', 0, 1, @ToProcess) WITH NOWAIT;

        IF @ToProcess = 0
        BEGIN
            UPDATE dbo.CT_Watermark
              SET LastSyncVersion = @ToVersion, LastSyncTime = SYSUTCDATETIME()
            WHERE ProcessName = @Process;

            SET @EndUTC = SYSUTCDATETIME();
            SET @EndIso = CONVERT(varchar(33), @EndUTC, 126);
            SET @DurationSec = DATEDIFF(SECOND, @RunStartedAt, @EndUTC);

            SET @Summary = CONCAT(
                N'EmployeeBranch incremental started ', @StartIso, N' UTC; ended ', @EndIso,
                N' UTC; inserted 0, updated 0; advanced watermark to ',
                CAST(@ToVersion AS nvarchar(30)), N'; duration=', @DurationSec, N' sec.'
            );

            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            GOTO FinallyRelease;
        END

        /* Optional visit enrichment */
        IF OBJECT_ID('tempdb..#VisitsAgg') IS NOT NULL DROP TABLE #VisitsAgg;
        CREATE TABLE #VisitsAgg
        (
            Employee_UUID        INT      NOT NULL,
            Old_Branch_UUID      INT      NOT NULL,
            FirstVisitStartDate  DATETIME NULL,
            LastVisitEndDate     DATETIME NULL,
            PRIMARY KEY (Employee_UUID, Old_Branch_UUID)
        );

        IF OBJECT_ID('dbo.tbl_Visits','U') IS NOT NULL
           AND COL_LENGTH('dbo.tbl_Visits','Employee_UUID')   IS NOT NULL
           AND COL_LENGTH('dbo.tbl_Visits','Branch_UUID')     IS NOT NULL
           AND COL_LENGTH('dbo.tbl_Visits','VisitStartDate')  IS NOT NULL
           AND COL_LENGTH('dbo.tbl_Visits','VisitEndDate')    IS NOT NULL
        BEGIN
            DECLARE @vsql nvarchar(max) = N'
INSERT INTO #VisitsAgg (Employee_UUID, Old_Branch_UUID, FirstVisitStartDate, LastVisitEndDate)
SELECT
    v.Employee_UUID,
    b.Old_Branch_UUID,
    MIN(v.VisitStartDate),
    MAX(v.VisitEndDate)
FROM dbo.tbl_Visits v
JOIN dbo.tbl_Branch b ON v.Branch_UUID = b.UUID
WHERE EXISTS (
    SELECT 1
    FROM #Changed c
    WHERE c.Employee_UUID = v.Employee_UUID
      AND c.Old_Branch_UUID = b.Old_Branch_UUID
)
GROUP BY v.Employee_UUID, b.Old_Branch_UUID;';
            EXEC sys.sp_executesql @vsql;
        END

        /* Chunked UPSERT */
        DECLARE @TotalInserted bigint = 0, @TotalUpdated bigint = 0;

        WHILE EXISTS (SELECT 1 FROM #Changed)
        BEGIN
            IF OBJECT_ID('tempdb..#Next') IS NOT NULL DROP TABLE #Next;
            CREATE TABLE #Next
            (
                Employee_UUID    INT NOT NULL,
                Old_Branch_UUID  INT NOT NULL,
                PRIMARY KEY (Employee_UUID, Old_Branch_UUID)
            );

            INSERT INTO #Next(Employee_UUID, Old_Branch_UUID)
            SELECT TOP (@ChunkSize) Employee_UUID, Old_Branch_UUID
            FROM #Changed
            ORDER BY Employee_UUID, Old_Branch_UUID;

            IF OBJECT_ID('tempdb..#ActLog') IS NOT NULL DROP TABLE #ActLog;
            CREATE TABLE #ActLog(Action nvarchar(10) NOT NULL);

            ;WITH DKRows AS
            (
                SELECT DISTINCT
                    dk.INPRIKEY    AS Employee_UUID,
                    dk.OUTPRIKEY   AS Old_Branch_UUID,
                    dk.START_DATE  AS DK_Start_Date,
                    dk.[DATE]      AS DK_End_Date,
                    dk.LEFTREASON,
                    dk.LOCATION_REF,
                    dk.[STATUS]    AS DK_STATUS,
                    dk.CARE_GRP_REF
                FROM dbo.DISTKEY dk
                JOIN #Next n
                  ON n.Employee_UUID   = dk.INPRIKEY
                 AND n.Old_Branch_UUID = dk.OUTPRIKEY
            ),
            Emp AS
            (
                SELECT e.EMP_REF, e.GS_REF, e.LOCATION_REF AS EMP_LOC_REF
                FROM dbo.EMPLOYEE e
                WHERE EXISTS (SELECT 1 FROM #Next n WHERE n.Employee_UUID = e.EMP_REF)
            ),
            Lookups AS
            (
                SELECT d.DECODE_REF, d.DESCRIPTION FROM dbo.CHSYSDEC d
            ),
            Base AS
            (
                SELECT
                    dk.Employee_UUID,
                    dk.Old_Branch_UUID,
                    dk.DK_Start_Date,
                    dk.DK_End_Date,
                    dk.LEFTREASON,
                    dk.LOCATION_REF,
                    dk.DK_STATUS,
                    dk.CARE_GRP_REF,
                    e.GS_REF,
                    EL.DESCRIPTION  AS EmpLocationDesc,
                    ES.DESCRIPTION  AS StatusDesc,
                    ECG.DESCRIPTION AS CareGroupDesc,
                    ELR.DESCRIPTION AS LeftReasonDesc,
                    EBL.DESCRIPTION AS EmpBranchLocDesc,
                    va.FirstVisitStartDate,
                    va.LastVisitEndDate
                FROM DKRows dk
                LEFT JOIN Emp e         ON e.EMP_REF      = dk.Employee_UUID
                LEFT JOIN Lookups EL    ON EL.DECODE_REF  = e.EMP_LOC_REF
                LEFT JOIN Lookups ES    ON ES.DECODE_REF  = dk.DK_STATUS
                LEFT JOIN Lookups ECG   ON ECG.DECODE_REF = dk.CARE_GRP_REF
                LEFT JOIN Lookups ELR   ON ELR.DECODE_REF = dk.LEFTREASON
                LEFT JOIN Lookups EBL   ON EBL.DECODE_REF = dk.LOCATION_REF
                LEFT JOIN #VisitsAgg va ON va.Employee_UUID   = dk.Employee_UUID
                                       AND va.Old_Branch_UUID = dk.Old_Branch_UUID
            ),
            Shaped AS
            (
                SELECT
                    b.Employee_UUID,
                    Branch_UUID = pick.Branch_UUID,
                    Branch_Name = pick.Branch_Name,

                    Start_Date =
                        CASE
                            WHEN b.DK_Start_Date IS NULL THEN b.FirstVisitStartDate
                            WHEN b.DK_Start_Date IS NOT NULL AND b.FirstVisitStartDate IS NOT NULL
                                 AND b.FirstVisitStartDate < b.DK_Start_Date THEN b.FirstVisitStartDate
                            ELSE b.DK_Start_Date
                        END,
                    End_Date =
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
                    SELECT TOP (1) tb.UUID AS Branch_UUID, tb.Branch_Name
                    FROM dbo.tbl_Branch tb
                    WHERE
                        (b.Old_Branch_UUID = 1970000043 AND b.EmpLocationDesc = 'Southampton' AND tb.Branch_Name = 'Southampton')
                     OR (b.Old_Branch_UUID = 1970000043 AND (b.EmpLocationDesc IS NULL OR b.EmpLocationDesc <> 'Southampton') AND tb.Branch_Name = 'Portsmouth')
                     OR (b.Old_Branch_UUID <> 1970000043 AND tb.Old_Branch_UUID = b.Old_Branch_UUID)
                ) pick
            ),
            FinalAgg AS
            (
                SELECT
                    s.Employee_UUID,
                    s.Branch_UUID,
                    MIN(s.Start_Date) AS Start_Date,
                    CASE WHEN SUM(CASE WHEN s.End_Date IS NULL THEN 1 ELSE 0 END) > 0
                         THEN NULL ELSE MAX(s.End_Date) END AS End_Date,
                    MAX(COALESCE(s.[Status],    N'')) AS [Status],
                    MAX(NULLIF(COALESCE(s.[Group], N''), N'')) AS [Group],
                    MAX(NULLIF(COALESCE(s.Left_Reason, N''), N'')) AS Left_Reason,
                    MAX(NULLIF(COALESCE(s.[Location],   N''), N'')) AS [Location],
                    MAX(COALESCE(s.Main_Branch, 'N')) AS Main_Branch,
                    MAX(COALESCE(s.Branch_Name, N'')) AS Branch_Name
                FROM Shaped s
                WHERE s.Branch_UUID IS NOT NULL
                  AND s.Start_Date  IS NOT NULL
                GROUP BY s.Employee_UUID, s.Branch_UUID
            )
            MERGE dbo.tbl_EmployeeBranch AS tgt
            USING FinalAgg AS src
               ON tgt.Employee_UUID = src.Employee_UUID
              AND tgt.Branch_UUID   = src.Branch_UUID
            WHEN MATCHED THEN
                UPDATE SET
                    tgt.Start_Date   = src.Start_Date,
                    tgt.End_Date     = src.End_Date,
                    tgt.[Status]     = src.[Status],
                    tgt.[Group]      = src.[Group],
                    tgt.Left_Reason  = src.Left_Reason,
                    tgt.[Location]   = src.[Location],
                    tgt.Main_Branch  = src.Main_Branch,
                    tgt.Branch_Name  = src.Branch_Name,
                    tgt.UpdatedAtUTC = @RunStartedAt
            WHEN NOT MATCHED BY TARGET THEN
                INSERT (
                    Employee_UUID, Branch_UUID, Start_Date, End_Date,
                    [Status], [Group], Left_Reason, [Location],
                    Main_Branch, Branch_Name,
                    CreatedAtUTC, UpdatedAtUTC
                )
                VALUES (
                    src.Employee_UUID, src.Branch_UUID, src.Start_Date, src.End_Date,
                    src.[Status], src.[Group], src.Left_Reason, src.[Location],
                    src.Main_Branch, src.Branch_Name,
                    @RunStartedAt, @RunStartedAt
                )
            OUTPUT $action INTO #ActLog(Action);

            DECLARE @i int=0, @u int=0;
            SELECT
                @i = SUM(CASE WHEN Action='INSERT' THEN 1 ELSE 0 END),
                @u = SUM(CASE WHEN Action='UPDATE' THEN 1 ELSE 0 END)
            FROM #ActLog;

            SET @TotalInserted += ISNULL(@i,0);
            SET @TotalUpdated  += ISNULL(@u,0);

            IF @EmitInfo=1
                RAISERROR('EmployeeBranch chunk upserted: inserted=%d updated=%d (running %d/%d)',
                          0,1,@i,@u,@TotalInserted,@TotalUpdated) WITH NOWAIT;

            DELETE c
            FROM #Changed c
            JOIN #Next n
              ON n.Employee_UUID   = c.Employee_UUID
             AND n.Old_Branch_UUID = c.Old_Branch_UUID;
        END

        /* Advance watermark + summary */
        UPDATE dbo.CT_Watermark
          SET LastSyncVersion = @ToVersion,
              LastSyncTime    = SYSUTCDATETIME()
        WHERE ProcessName = @Process;

        SET @EndUTC = SYSUTCDATETIME();
        SET @EndIso = CONVERT(varchar(33), @EndUTC, 126);
        SET @DurationSec = DATEDIFF(SECOND, @RunStartedAt, @EndUTC);

        SET @Summary = CONCAT(
            N'EmployeeBranch incremental started ', @StartIso, N' UTC; ended ', @EndIso,
            N' UTC; inserted ', CAST(@TotalInserted AS nvarchar(20)),
            N', updated ', CAST(@TotalUpdated AS nvarchar(20)),
            N'; advanced watermark to ', CAST(@ToVersion AS nvarchar(30)),
            N'; duration=', CAST(@DurationSec AS nvarchar(20)), N' sec.'
        );

        IF @EmitInfo=1 RAISERROR('EmployeeBranch incremental sync complete.', 0, 1) WITH NOWAIT;
        IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;

FinallyRelease:
        IF @lockHeld=1
            EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;

        RETURN 0;
    END TRY
    BEGIN CATCH
        IF @lockHeld=1
            EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;

        DECLARE @msg nvarchar(4000)=ERROR_MESSAGE();
        DECLARE @num int=ERROR_NUMBER(), @sev int=ERROR_SEVERITY(), @st int=ERROR_STATE(), @lin int=ERROR_LINE(), @proc sysname=ERROR_PROCEDURE();
        DECLARE @procName sysname = ISNULL(@proc, N'<adhoc>');

        IF @EmitInfo=1
            RAISERROR('usp_Sync_EmployeeBranch_Incremental failed (%d, sev %d, state %d) at %s line %d: %s',
                      16,1,@num,@sev,@st,@procName,@lin,@msg);

        SET @Summary = CONCAT(N'EmployeeBranch incremental failed: ', @msg);
        IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
        RETURN -50001;
    END CATCH
END;
GO
