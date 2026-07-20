/*
Purpose:
    Incrementally load employee-to-branch relationships into dbo.tbl_EmployeeBranch
    using SQL Server Change Tracking.

Source:
    dbo.DISTKEY (+ dbo.EMPLOYEE + dbo.CHSYSDEC + optional dbo.tbl_Visits + dbo.tbl_Branch)

Target:
    dbo.tbl_EmployeeBranch

Key strategy:
    - Branch UUID is INT (dbo.tbl_Branch.UUID)
    - Old_Branch_UUID is INT (source/native, mapping only)
    - Deterministic relationship rows keyed by computed SHA2_256(Employee_UUID|Branch_UUID) string

Design:
    - Fences CT window: From watermark -> ToVersion
    - Chunked processing
    - For each changed (Employee_UUID, Old_Branch_UUID) pair:
        * recompute the target Branch_UUID mapping
        * rebuild the corresponding row(s) in tbl_EmployeeBranch deterministically
    - Handles deletes (DISTKEY delete rows) by purging corresponding mappings

Requires:
    - CT enabled at DB level and on dbo.DISTKEY
    - dbo.tbl_Branch + dbo.tbl_Employees exist (initial dependencies)
    - dbo.tbl_EmployeeBranch exists and matches Initial schema
*/

USE [DOM_LIVE];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Sync_EmployeeBranch_Incremental
    @ChunkSize         int  = 100000,
    @LockTimeoutMs     int  = 60000,
    @UseAppLock        bit  = 1,
    @EmitInfo          bit  = 0,
    @Summary           nvarchar(4000) = NULL OUTPUT,
    @ReturnSummaryRow  bit  = 1
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

    /* Concurrency */
    DECLARE @LockResource sysname = N'DOM_LIVE:Sync:EmployeeBranch';
    DECLARE @LockOwner    sysname = N'Session';
    DECLARE @DbPrincipal  sysname = N'dbo';
    DECLARE @lockResult   int;
    DECLARE @lockHeld     bit = 0;

    DECLARE @rc int = 0;

    IF @UseAppLock = 1
    BEGIN
        EXEC @lockResult = sys.sp_getapplock
            @Resource=@LockResource,
            @LockMode='Exclusive',
            @LockOwner=@LockOwner,
            @DbPrincipal=@DbPrincipal,
            @LockTimeout=@LockTimeoutMs;

        IF @lockResult NOT IN (0,1)
        BEGIN
            SET @Summary = N'EmployeeBranch incremental failed: could not acquire applock.';
            IF @ReturnSummaryRow=1 SELECT N'Incremental' AS Stage, @Summary AS Summary;
            RETURN @lockResult;
        END
        SET @lockHeld = 1;
    END

    BEGIN TRY
        /* ------------------------------------------------------------
           1) Preconditions
           ------------------------------------------------------------ */
        IF OBJECT_ID(N'dbo.DISTKEY', N'U') IS NULL
        BEGIN
            SET @Summary = N'EmployeeBranch incremental failed: source dbo.DISTKEY missing.';
            IF @ReturnSummaryRow=1 SELECT N'Incremental' AS Stage, @Summary AS Summary;
            SET @rc = -301;
            GOTO Finally;
        END

        IF OBJECT_ID(N'dbo.tbl_Branch', N'U') IS NULL
        BEGIN
            SET @Summary = N'EmployeeBranch incremental failed: dbo.tbl_Branch missing (run Branch initial first).';
            IF @ReturnSummaryRow=1 SELECT N'Incremental' AS Stage, @Summary AS Summary;
            SET @rc = -302;
            GOTO Finally;
        END

        IF OBJECT_ID(N'dbo.tbl_Employees', N'U') IS NULL
        BEGIN
            SET @Summary = N'EmployeeBranch incremental failed: dbo.tbl_Employees missing (run Employees initial first).';
            IF @ReturnSummaryRow=1 SELECT N'Incremental' AS Stage, @Summary AS Summary;
            SET @rc = -303;
            GOTO Finally;
        END

        IF OBJECT_ID(N'dbo.tbl_EmployeeBranch', N'U') IS NULL
        BEGIN
            SET @Summary = N'EmployeeBranch incremental failed: dbo.tbl_EmployeeBranch missing (run EmployeeBranch initial first).';
            IF @ReturnSummaryRow=1 SELECT N'Incremental' AS Stage, @Summary AS Summary;
            SET @rc = -304;
            GOTO Finally;
        END

        /* Target schema contract (match Initial) */
        IF COL_LENGTH(N'dbo.tbl_EmployeeBranch', N'Employee_UUID') IS NULL
           OR COL_LENGTH(N'dbo.tbl_EmployeeBranch', N'Branch_UUID') IS NULL
           OR COL_LENGTH(N'dbo.tbl_EmployeeBranch', N'Start_Date') IS NULL
           OR COL_LENGTH(N'dbo.tbl_EmployeeBranch', N'End_Date') IS NULL
           OR COL_LENGTH(N'dbo.tbl_EmployeeBranch', N'Status') IS NULL
           OR COL_LENGTH(N'dbo.tbl_EmployeeBranch', N'Group') IS NULL
           OR COL_LENGTH(N'dbo.tbl_EmployeeBranch', N'Left_Reason') IS NULL
           OR COL_LENGTH(N'dbo.tbl_EmployeeBranch', N'Location') IS NULL
           OR COL_LENGTH(N'dbo.tbl_EmployeeBranch', N'Main_Branch') IS NULL
           OR COL_LENGTH(N'dbo.tbl_EmployeeBranch', N'Branch_Name') IS NULL
           OR COL_LENGTH(N'dbo.tbl_EmployeeBranch', N'UUID') IS NULL
           OR COL_LENGTH(N'dbo.tbl_EmployeeBranch', N'CreatedAtUTC') IS NULL
           OR COL_LENGTH(N'dbo.tbl_EmployeeBranch', N'UpdatedAtUTC') IS NULL
        BEGIN
            SET @Summary = N'EmployeeBranch incremental failed: dbo.tbl_EmployeeBranch schema mismatch (does not match Initial contract).';
            IF @ReturnSummaryRow=1 SELECT N'Incremental' AS Stage, @Summary AS Summary;
            SET @rc = -310;
            GOTO Finally;
        END

        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_databases WHERE database_id = DB_ID())
        BEGIN
            SET @Summary = N'EmployeeBranch incremental failed: CT not enabled at DB level.';
            IF @ReturnSummaryRow=1 SELECT N'Incremental' AS Stage, @Summary AS Summary;
            SET @rc = -100;
            GOTO Finally;
        END

        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.DISTKEY'))
        BEGIN
            SET @Summary = N'EmployeeBranch incremental failed: CT not enabled on dbo.DISTKEY.';
            IF @ReturnSummaryRow=1 SELECT N'Incremental' AS Stage, @Summary AS Summary;
            SET @rc = -210;
            GOTO Finally;
        END

        DECLARE @CT_EMPLOYEE bit = CASE WHEN EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.EMPLOYEE')) THEN 1 ELSE 0 END;
        DECLARE @CT_DEC      bit = CASE WHEN EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.CHSYSDEC')) THEN 1 ELSE 0 END;

        /* Watermark */
        IF OBJECT_ID(N'dbo.CT_Watermark', N'U') IS NULL
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

        DECLARE @ToVersion bigint = CHANGE_TRACKING_CURRENT_VERSION();

        /* CT retention safety */
        DECLARE @MinValid bigint =
        (
            SELECT MAX(CHANGE_TRACKING_MIN_VALID_VERSION(object_id))
            FROM sys.change_tracking_tables
            WHERE object_id IN
            (
                OBJECT_ID(N'dbo.DISTKEY'),
                CASE WHEN @CT_EMPLOYEE=1 THEN OBJECT_ID(N'dbo.EMPLOYEE') ELSE NULL END,
                CASE WHEN @CT_DEC=1      THEN OBJECT_ID(N'dbo.CHSYSDEC') ELSE NULL END
            )
        );

        IF @MinValid IS NOT NULL AND @LastSyncVersion < @MinValid
        BEGIN
            SET @Summary = CONCAT(
                N'EmployeeBranch incremental failed: watermark ', @LastSyncVersion,
                N' < CT min valid ', @MinValid, N' (re-baseline required).'
            );
            IF @ReturnSummaryRow=1 SELECT N'Incremental' AS Stage, @Summary AS Summary;
            SET @rc = -200;
            GOTO Finally;
        END

        IF @EmitInfo=1
            RAISERROR('EmployeeBranch CT window: From=%I64d To=%I64d', 0, 1, @LastSyncVersion, @ToVersion) WITH NOWAIT;

        /* ------------------------------------------------------------
           2) Build changed set of pairs + deleted pairs
           ------------------------------------------------------------ */
        IF OBJECT_ID('tempdb..#Changed') IS NOT NULL DROP TABLE #Changed;
        CREATE TABLE #Changed
        (
            Employee_UUID   int NOT NULL,
            Old_Branch_UUID int NOT NULL,
            CONSTRAINT PK_Changed PRIMARY KEY (Employee_UUID, Old_Branch_UUID)
        );

        IF OBJECT_ID('tempdb..#DeletedPairs') IS NOT NULL DROP TABLE #DeletedPairs;
        CREATE TABLE #DeletedPairs
        (
            Employee_UUID   int NOT NULL,
            Old_Branch_UUID int NOT NULL,
            CONSTRAINT PK_DeletedPairs PRIMARY KEY (Employee_UUID, Old_Branch_UUID)
        );

        /* Build dynamic join to DISTKEY PK for CHANGETABLE join */
        DECLARE @JoinPK nvarchar(max);

        ;WITH pk AS
        (
            SELECT c.name AS colname, ic.key_ordinal
            FROM sys.indexes i
            JOIN sys.index_columns ic ON i.object_id=ic.object_id AND i.index_id=ic.index_id
            JOIN sys.columns c ON c.object_id=ic.object_id AND c.column_id=ic.column_id
            WHERE i.object_id = OBJECT_ID(N'dbo.DISTKEY')
              AND i.is_primary_key = 1
        )
        SELECT @JoinPK =
            STUFF((
                SELECT ' AND dk.' + QUOTENAME(colname) + ' = ct.' + QUOTENAME(colname)
                FROM pk
                ORDER BY key_ordinal
                FOR XML PATH(''), TYPE
            ).value('.','nvarchar(max)'), 1, 5, '');

        IF @JoinPK IS NULL OR LEN(@JoinPK)=0
        BEGIN
            SET @Summary = N'EmployeeBranch incremental failed: dbo.DISTKEY has no PK (required for CT join).';
            IF @ReturnSummaryRow=1 SELECT N'Incremental' AS Stage, @Summary AS Summary;
            SET @rc = -211;
            GOTO Finally;
        END

        DECLARE @sql nvarchar(max) = N'
/* Inserts + Updates -> #Changed */
INSERT INTO #Changed(Employee_UUID, Old_Branch_UUID)
SELECT DISTINCT
    TRY_CONVERT(int, dk.INPRIKEY),
    TRY_CONVERT(int, dk.OUTPRIKEY)
FROM CHANGETABLE(CHANGES dbo.DISTKEY, @fromV) AS ct
JOIN dbo.DISTKEY AS dk
  ON ' + @JoinPK + N'
WHERE ct.SYS_CHANGE_VERSION <= @toV
  AND ct.SYS_CHANGE_OPERATION IN (''I'',''U'')
  AND TRY_CONVERT(int, dk.INPRIKEY)  IS NOT NULL
  AND TRY_CONVERT(int, dk.OUTPRIKEY) IS NOT NULL;

/* Deletes -> #DeletedPairs (cannot join to dk, so use ct values)
   Note: assumes PK columns include INPRIKEY/OUTPRIKEY. If not, re-baseline design needed. */
INSERT INTO #DeletedPairs(Employee_UUID, Old_Branch_UUID)
SELECT DISTINCT
    TRY_CONVERT(int, ct.INPRIKEY),
    TRY_CONVERT(int, ct.OUTPRIKEY)
FROM CHANGETABLE(CHANGES dbo.DISTKEY, @fromV) AS ct
WHERE ct.SYS_CHANGE_VERSION <= @toV
  AND ct.SYS_CHANGE_OPERATION = ''D''
  AND TRY_CONVERT(int, ct.INPRIKEY)  IS NOT NULL
  AND TRY_CONVERT(int, ct.OUTPRIKEY) IS NOT NULL;
';

        EXEC sys.sp_executesql @sql,
            N'@fromV bigint, @toV bigint',
            @fromV=@LastSyncVersion, @toV=@ToVersion;

        /* Optional: EMPLOYEE changes can affect mapping (GS_REF, LOCATION_REF) */
        IF @CT_EMPLOYEE = 1
        BEGIN
            INSERT INTO #Changed(Employee_UUID, Old_Branch_UUID)
            SELECT DISTINCT
                e.EMP_REF,
                TRY_CONVERT(int, dk.OUTPRIKEY)
            FROM CHANGETABLE(CHANGES dbo.EMPLOYEE, @LastSyncVersion) ce
            JOIN dbo.EMPLOYEE e ON e.EMP_REF = ce.EMP_REF
            JOIN dbo.DISTKEY dk ON TRY_CONVERT(int, dk.INPRIKEY) = e.EMP_REF
            WHERE ce.SYS_CHANGE_VERSION <= @ToVersion
              AND TRY_CONVERT(int, dk.OUTPRIKEY) IS NOT NULL
              AND NOT EXISTS (SELECT 1 FROM #Changed z WHERE z.Employee_UUID=e.EMP_REF AND z.Old_Branch_UUID=TRY_CONVERT(int, dk.OUTPRIKEY));
        END

        /* Optional: decode changes can affect text columns */
        IF @CT_DEC = 1
        BEGIN
            INSERT INTO #Changed(Employee_UUID, Old_Branch_UUID)
            SELECT DISTINCT
                TRY_CONVERT(int, dk.INPRIKEY),
                TRY_CONVERT(int, dk.OUTPRIKEY)
            FROM CHANGETABLE(CHANGES dbo.CHSYSDEC, @LastSyncVersion) cd
            JOIN dbo.DISTKEY dk
              ON dk.[STATUS]     = cd.DECODE_REF
              OR dk.CARE_GRP_REF = cd.DECODE_REF
              OR dk.LEFTREASON   = cd.DECODE_REF
              OR dk.LOCATION_REF = cd.DECODE_REF
            WHERE cd.SYS_CHANGE_VERSION <= @ToVersion
              AND TRY_CONVERT(int, dk.INPRIKEY)  IS NOT NULL
              AND TRY_CONVERT(int, dk.OUTPRIKEY) IS NOT NULL
              AND NOT EXISTS
                  (SELECT 1 FROM #Changed z
                   WHERE z.Employee_UUID=TRY_CONVERT(int, dk.INPRIKEY)
                     AND z.Old_Branch_UUID=TRY_CONVERT(int, dk.OUTPRIKEY));

            INSERT INTO #Changed(Employee_UUID, Old_Branch_UUID)
            SELECT DISTINCT
                e.EMP_REF,
                TRY_CONVERT(int, dk.OUTPRIKEY)
            FROM CHANGETABLE(CHANGES dbo.CHSYSDEC, @LastSyncVersion) cd
            JOIN dbo.EMPLOYEE e ON e.LOCATION_REF = cd.DECODE_REF
            JOIN dbo.DISTKEY dk ON TRY_CONVERT(int, dk.INPRIKEY) = e.EMP_REF
            WHERE cd.SYS_CHANGE_VERSION <= @ToVersion
              AND TRY_CONVERT(int, dk.OUTPRIKEY) IS NOT NULL
              AND NOT EXISTS (SELECT 1 FROM #Changed z WHERE z.Employee_UUID=e.EMP_REF AND z.Old_Branch_UUID=TRY_CONVERT(int, dk.OUTPRIKEY));
        END

        DECLARE @ToProcess int = (SELECT COUNT(*) FROM #Changed);
        DECLARE @ToDelete  int = (SELECT COUNT(*) FROM #DeletedPairs);

        IF @EmitInfo=1
            RAISERROR('EmployeeBranch pairs: changed=%d deleted=%d', 0, 1, @ToProcess, @ToDelete) WITH NOWAIT;

        IF @ToProcess = 0 AND @ToDelete = 0
        BEGIN
            UPDATE dbo.CT_Watermark
              SET LastSyncVersion=@ToVersion,
                  LastSyncTime=SYSUTCDATETIME()
            WHERE ProcessName=@Process;

            SET @EndUTC = SYSUTCDATETIME();
            SET @EndIso = CONVERT(varchar(33), @EndUTC, 126);
            SET @DurationSec = DATEDIFF(SECOND, @RunStartedAt, @EndUTC);

            SET @Summary = CONCAT(
                N'EmployeeBranch incremental started ', @StartIso, N' UTC; ended ', @EndIso,
                N' UTC; inserted 0, updated 0, deleted 0; advanced watermark to ',
                CAST(@ToVersion AS nvarchar(30)), N'; duration=', @DurationSec, N' sec.'
            );

            IF @ReturnSummaryRow=1 SELECT N'Incremental' AS Stage, @Summary AS Summary;
            SET @rc = 0;
            GOTO Finally;
        END

        /* ------------------------------------------------------------
           3) Apply deletes for removed pairs
           ------------------------------------------------------------ */
        DECLARE @TotalDeleted int = 0;

        IF EXISTS (SELECT 1 FROM #DeletedPairs)
        BEGIN
            /* Compute which Branch_UUID those old branch ids map to, then delete */
            IF OBJECT_ID('tempdb..#DelTargets') IS NOT NULL DROP TABLE #DelTargets;
            CREATE TABLE #DelTargets
            (
                Employee_UUID int NOT NULL,
                Branch_UUID   int NOT NULL,
                CONSTRAINT PK_DelTargets PRIMARY KEY (Employee_UUID, Branch_UUID)
            );

            INSERT INTO #DelTargets(Employee_UUID, Branch_UUID)
            SELECT
                d.Employee_UUID,
                pick.Branch_UUID
            FROM #DeletedPairs d
            JOIN dbo.EMPLOYEE e ON e.EMP_REF = d.Employee_UUID
            LEFT JOIN dbo.CHSYSDEC el ON e.LOCATION_REF = el.DECODE_REF
            OUTER APPLY
            (
                SELECT TOP (1) tb.UUID AS Branch_UUID
                FROM dbo.tbl_Branch tb
                WHERE
                    (d.Old_Branch_UUID = 1970000043 AND el.DESCRIPTION = 'Southampton' AND tb.Branch_Name = 'Southampton')
                 OR (d.Old_Branch_UUID = 1970000043 AND (el.DESCRIPTION IS NULL OR el.DESCRIPTION <> 'Southampton') AND tb.Branch_Name = 'Portsmouth')
                 OR (d.Old_Branch_UUID <> 1970000043 AND tb.Old_Branch_UUID = d.Old_Branch_UUID)
                ORDER BY tb.UUID
            ) pick
            WHERE pick.Branch_UUID IS NOT NULL;

            DELETE tgt
            FROM dbo.tbl_EmployeeBranch tgt
            JOIN #DelTargets x
              ON x.Employee_UUID = tgt.Employee_UUID
             AND x.Branch_UUID   = tgt.Branch_UUID;

            SET @TotalDeleted += @@ROWCOUNT;
        END

        /* ------------------------------------------------------------
           4) Chunked rebuild for changed pairs (deterministic)
           ------------------------------------------------------------ */
        DECLARE @TotalInserted bigint = 0;
        DECLARE @TotalUpdated  bigint = 0;

        /* Visit aggregation, aligned with Initial */
        DECLARE @HasVisits bit =
            CASE WHEN OBJECT_ID(N'dbo.tbl_Visits', N'U') IS NOT NULL
               AND COL_LENGTH(N'dbo.tbl_Visits', N'Employee_UUID') IS NOT NULL
               AND COL_LENGTH(N'dbo.tbl_Visits', N'Branch_UUID')   IS NOT NULL
               AND COL_LENGTH(N'dbo.tbl_Visits', N'Actual_Visit_Start_Date_Time') IS NOT NULL
               AND COL_LENGTH(N'dbo.tbl_Visits', N'Actual_Visit_End_Date_Time')   IS NOT NULL
            THEN 1 ELSE 0 END;

        WHILE EXISTS (SELECT 1 FROM #Changed)
        BEGIN
            IF OBJECT_ID('tempdb..#Next') IS NOT NULL DROP TABLE #Next;
            CREATE TABLE #Next
            (
                Employee_UUID   int NOT NULL,
                Old_Branch_UUID int NOT NULL,
                CONSTRAINT PK_Next PRIMARY KEY (Employee_UUID, Old_Branch_UUID)
            );

            INSERT INTO #Next(Employee_UUID, Old_Branch_UUID)
            SELECT TOP (@ChunkSize) Employee_UUID, Old_Branch_UUID
            FROM #Changed
            ORDER BY Employee_UUID, Old_Branch_UUID;

            IF OBJECT_ID('tempdb..#VisitAgg') IS NOT NULL DROP TABLE #VisitAgg;
            CREATE TABLE #VisitAgg
            (
                Employee_UUID       int NOT NULL,
                Old_Branch_UUID     int NOT NULL,
                FirstVisitStartDate datetime NULL,
                LastVisitEndDate    datetime NULL,
                CONSTRAINT PK_VisitAgg2 PRIMARY KEY (Employee_UUID, Old_Branch_UUID)
            );

            IF @HasVisits = 1
            BEGIN
                INSERT INTO #VisitAgg(Employee_UUID, Old_Branch_UUID, FirstVisitStartDate, LastVisitEndDate)
                SELECT
                    v.Employee_UUID,
                    b.Old_Branch_UUID,
                    MIN(v.Actual_Visit_Start_Date_Time),
                    MAX(v.Actual_Visit_End_Date_Time)
                FROM dbo.tbl_Visits v
                JOIN dbo.tbl_Branch b ON b.UUID = v.Branch_UUID
                WHERE EXISTS
                (
                    SELECT 1
                    FROM #Next n
                    WHERE n.Employee_UUID   = v.Employee_UUID
                      AND n.Old_Branch_UUID = b.Old_Branch_UUID
                )
                GROUP BY v.Employee_UUID, b.Old_Branch_UUID;
            END

            /* Build the NEW desired rows for this chunk exactly like Initial */
            IF OBJECT_ID('tempdb..#NewRows') IS NOT NULL DROP TABLE #NewRows;
            CREATE TABLE #NewRows
            (
                Employee_UUID int NOT NULL,
                Branch_UUID   int NOT NULL,
                Start_Date    datetime NULL,
                End_Date      datetime NULL,
                [Status]      nvarchar(255) NULL,
                [Group]       nvarchar(255) NULL,
                Left_Reason   nvarchar(255) NULL,
                [Location]    nvarchar(255) NULL,
                Main_Branch   char(1) NULL,
                Branch_Name   nvarchar(255) NULL,
                CONSTRAINT PK_NewRows PRIMARY KEY (Employee_UUID, Branch_UUID)
            );

            ;WITH DistinctPairs AS
            (
                SELECT DISTINCT
                    Employee_UUID   = TRY_CONVERT(int, dk.INPRIKEY),
                    Old_Branch_UUID = TRY_CONVERT(int, dk.OUTPRIKEY),
                    DK_Start_Date   = dk.START_DATE,
                    DK_End_Date     = dk.[DATE],
                    DK_LEFTREASON   = dk.LEFTREASON,
                    DK_LOCATION_REF = dk.LOCATION_REF,
                    DK_STATUS       = dk.[STATUS],
                    DK_CARE_GRP_REF = dk.CARE_GRP_REF
                FROM dbo.DISTKEY dk
                JOIN #Next n
                  ON n.Employee_UUID   = TRY_CONVERT(int, dk.INPRIKEY)
                 AND n.Old_Branch_UUID = TRY_CONVERT(int, dk.OUTPRIKEY)
                WHERE TRY_CONVERT(int, dk.INPRIKEY) IS NOT NULL
                  AND TRY_CONVERT(int, dk.OUTPRIKEY) IS NOT NULL
            ),
            Base AS
            (
                SELECT
                    d.Employee_UUID,
                    d.Old_Branch_UUID,
                    d.DK_Start_Date,
                    d.DK_End_Date,
                    d.DK_LEFTREASON,
                    d.DK_LOCATION_REF,
                    d.DK_STATUS,
                    d.DK_CARE_GRP_REF,

                    e.GS_REF,
                    el.DESCRIPTION   AS EmpLocationDesc,
                    es.DESCRIPTION   AS StatusDesc,
                    ecg.DESCRIPTION  AS CareGroupDesc,
                    elr.DESCRIPTION  AS LeftReasonDesc,
                    ebl.DESCRIPTION  AS EmpBranchLocDesc,

                    va.FirstVisitStartDate,
                    va.LastVisitEndDate
                FROM DistinctPairs d
                JOIN dbo.EMPLOYEE e        ON e.EMP_REF      = d.Employee_UUID
                LEFT JOIN dbo.CHSYSDEC el  ON e.LOCATION_REF = el.DECODE_REF
                LEFT JOIN dbo.CHSYSDEC es  ON d.DK_STATUS    = es.DECODE_REF
                LEFT JOIN dbo.CHSYSDEC ecg ON d.DK_CARE_GRP_REF = ecg.DECODE_REF
                LEFT JOIN dbo.CHSYSDEC elr ON d.DK_LEFTREASON   = elr.DECODE_REF
                LEFT JOIN dbo.CHSYSDEC ebl ON d.DK_LOCATION_REF = ebl.DECODE_REF
                LEFT JOIN #VisitAgg va     ON va.Employee_UUID    = d.Employee_UUID
                                          AND va.Old_Branch_UUID = d.Old_Branch_UUID
            ),
            Shaped AS
            (
                SELECT
                    b.Employee_UUID,
                    pick.Branch_UUID,
                    pick.Branch_Name,

                    EffectiveStartDate =
                        CASE
                            WHEN b.DK_Start_Date IS NULL THEN b.FirstVisitStartDate
                            WHEN b.DK_Start_Date IS NOT NULL AND b.FirstVisitStartDate IS NOT NULL
                                 AND b.FirstVisitStartDate < b.DK_Start_Date THEN b.FirstVisitStartDate
                            ELSE b.DK_Start_Date
                        END,

                    EffectiveEndDate =
                        CASE
                            WHEN b.DK_End_Date IS NULL THEN NULL
                            WHEN b.DK_End_Date IS NOT NULL AND b.LastVisitEndDate IS NOT NULL
                                 AND b.LastVisitEndDate > b.DK_End_Date THEN b.LastVisitEndDate
                            ELSE b.DK_End_Date
                        END,

                    [Status]     = NULLIF(CASE WHEN b.StatusDesc       = '<No Selection>' THEN N'' ELSE b.StatusDesc       END, N''),
                    [Group]      = NULLIF(CASE WHEN b.CareGroupDesc    = '<No Selection>' THEN N'' ELSE b.CareGroupDesc    END, N''),
                    Left_Reason  = NULLIF(CASE WHEN b.LeftReasonDesc   = '<No Selection>' THEN N'' ELSE b.LeftReasonDesc   END, N''),
                    [Location]   = NULLIF(CASE WHEN b.EmpBranchLocDesc = '<No Selection>' THEN N'' ELSE b.EmpBranchLocDesc END, N''),

                    Main_Branch  = CASE WHEN TRY_CONVERT(int, b.Old_Branch_UUID) = TRY_CONVERT(int, b.GS_REF) THEN 'Y' ELSE 'N' END
                FROM Base b
                OUTER APPLY
                (
                    SELECT TOP (1)
                        tb.UUID        AS Branch_UUID,
                        tb.Branch_Name AS Branch_Name
                    FROM dbo.tbl_Branch tb
                    WHERE
                        (b.Old_Branch_UUID = 1970000043 AND b.EmpLocationDesc = 'Southampton' AND tb.Branch_Name = 'Southampton')
                     OR (b.Old_Branch_UUID = 1970000043 AND (b.EmpLocationDesc IS NULL OR b.EmpLocationDesc <> 'Southampton') AND tb.Branch_Name = 'Portsmouth')
                     OR (b.Old_Branch_UUID <> 1970000043 AND tb.Old_Branch_UUID = b.Old_Branch_UUID)
                    ORDER BY tb.UUID
                ) pick
            ),
            FinalAgg AS
            (
                SELECT
                    s.Employee_UUID,
                    s.Branch_UUID,
                    Start_Date = MIN(s.EffectiveStartDate),
                    End_Date   = CASE WHEN SUM(CASE WHEN s.EffectiveEndDate IS NULL THEN 1 ELSE 0 END) > 0
                                      THEN NULL ELSE MAX(s.EffectiveEndDate) END,
                    [Status]    = MAX(s.[Status]),
                    [Group]     = MAX(s.[Group]),
                    Left_Reason = MAX(s.Left_Reason),
                    [Location]  = MAX(s.[Location]),
                    Main_Branch = MAX(s.Main_Branch),
                    Branch_Name = MAX(s.Branch_Name)
                FROM Shaped s
                WHERE s.Branch_UUID IS NOT NULL
                  AND s.Employee_UUID IS NOT NULL
                  AND s.EffectiveStartDate IS NOT NULL
                GROUP BY s.Employee_UUID, s.Branch_UUID
            )
            INSERT INTO #NewRows(Employee_UUID, Branch_UUID, Start_Date, End_Date, [Status], [Group], Left_Reason, [Location], Main_Branch, Branch_Name)
            SELECT
                f.Employee_UUID, f.Branch_UUID, f.Start_Date, f.End_Date,
                f.[Status], f.[Group], f.Left_Reason, f.[Location],
                f.Main_Branch, f.Branch_Name
            FROM FinalAgg f;

            /* Deterministic rebuild:
               - Delete existing rows for these employees that match the Branch_UUIDs we’re about to write
               - Then insert fresh rows
            */
            DELETE tgt
            FROM dbo.tbl_EmployeeBranch tgt
            JOIN #NewRows n
              ON n.Employee_UUID = tgt.Employee_UUID
             AND n.Branch_UUID   = tgt.Branch_UUID;

            DECLARE @deletedThis int = @@ROWCOUNT;

            INSERT INTO dbo.tbl_EmployeeBranch
            (
                Employee_UUID, Branch_UUID, Start_Date, End_Date,
                [Status], [Group], Left_Reason, [Location],
                Main_Branch, Branch_Name,
                CreatedAtUTC, UpdatedAtUTC
            )
            SELECT
                n.Employee_UUID, n.Branch_UUID, n.Start_Date, n.End_Date,
                n.[Status], n.[Group], n.Left_Reason, n.[Location],
                n.Main_Branch, n.Branch_Name,
                @RunStartedAt, @RunStartedAt
            FROM #NewRows n;

            DECLARE @insertedThis int = @@ROWCOUNT;

            SET @TotalDeleted += @deletedThis;
            SET @TotalInserted += @insertedThis;

            IF @EmitInfo=1
                RAISERROR('EmployeeBranch chunk rebuilt: deleted=%d inserted=%d (running del=%d ins=%d)',
                          0,1,@deletedThis,@insertedThis,@TotalDeleted,@TotalInserted) WITH NOWAIT;

            DELETE c
            FROM #Changed c
            JOIN #Next n
              ON n.Employee_UUID   = c.Employee_UUID
             AND n.Old_Branch_UUID = c.Old_Branch_UUID;
        END

        /* ------------------------------------------------------------
           5) Advance watermark + summary
           ------------------------------------------------------------ */
        UPDATE dbo.CT_Watermark
          SET LastSyncVersion=@ToVersion,
              LastSyncTime=SYSUTCDATETIME()
        WHERE ProcessName=@Process;

        SET @EndUTC = SYSUTCDATETIME();
        SET @EndIso = CONVERT(varchar(33), @EndUTC, 126);
        SET @DurationSec = DATEDIFF(SECOND, @RunStartedAt, @EndUTC);

        SET @Summary = CONCAT(
            N'EmployeeBranch incremental started ', @StartIso, N' UTC; ended ', @EndIso,
            N' UTC; inserted ', CAST(@TotalInserted AS nvarchar(20)),
            N', deleted ', CAST(@TotalDeleted AS nvarchar(20)),
            N'; advanced watermark to ', CAST(@ToVersion AS nvarchar(30)),
            N'; duration=', CAST(@DurationSec AS nvarchar(20)), N' sec.'
        );

        IF @ReturnSummaryRow=1 SELECT N'Incremental' AS Stage, @Summary AS Summary;

        SET @rc = 0;

Finally:
        IF @lockHeld=1
            EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;

        RETURN @rc;
    END TRY
    BEGIN CATCH
        IF @lockHeld=1
            EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;

        DECLARE @err nvarchar(4000)=ERROR_MESSAGE();
        DECLARE @num int=ERROR_NUMBER(), @sev int=ERROR_SEVERITY(), @st int=ERROR_STATE(),
                @lin int=ERROR_LINE(), @proc sysname=ERROR_PROCEDURE();
        DECLARE @procName sysname = ISNULL(@proc, N'<adhoc>');

        IF @EmitInfo=1
            RAISERROR('usp_Sync_EmployeeBranch_Incremental failed (%d, sev %d, state %d) at %s line %d: %s',
                      16,1,@num,@sev,@st,@procName,@lin,@err);

        SET @Summary = CONCAT(N'EmployeeBranch incremental failed: ', @err);
        IF @ReturnSummaryRow=1 SELECT N'Incremental' AS Stage, @Summary AS Summary;

        RETURN -50001;
    END CATCH
END;
GO
