/*
Purpose:
    Perform the initial full load of employee-to-branch relationships.

Key strategy:
    - Branch UUID is INT (identity) in dbo.tbl_Branch.UUID
    - All FK references to Branch use INT (Branch_UUID INT)
    - Old_Branch_UUID is INT (source/native), used for mapping only

Design goals:
    - Destructive + deterministic
    - Safe to re-run in non-prod
    - Immune to leftover objects (table/view/synonym)
    - No implicit casts of hash UUIDs to INT

Notes:
    - Must run AFTER Branch initial and Employees initial.
*/

USE [DOM_LIVE];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Sync_EmployeeBranch_Initial
    @Summary nvarchar(4000) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Process      sysname      = N'EmployeeBranch';
    DECLARE @RunStartedAt datetime2(3) = SYSUTCDATETIME();
    DECLARE @StartIso     varchar(33)  = CONVERT(varchar(33), @RunStartedAt, 126);
    DECLARE @BaselineFrom bigint;

    DECLARE @LockResource sysname = N'DOM_LIVE:Sync:EmployeeBranch';
    DECLARE @LockOwner    sysname = N'Session';
    DECLARE @DbPrincipal  sysname = N'dbo';
    DECLARE @lockResult   int;
    DECLARE @lockHeld     bit = 0;

    BEGIN TRY
        /* Acquire applock */
        EXEC @lockResult = sys.sp_getapplock
            @Resource    = @LockResource,
            @LockMode    = 'Exclusive',
            @LockOwner   = @LockOwner,
            @DbPrincipal = @DbPrincipal,
            @LockTimeout = 600000;

        IF @lockResult NOT IN (0,1)
            THROW 50000, 'EmployeeBranch initial failed: could not acquire applock.', 1;

        SET @lockHeld = 1;

        /* Preconditions */
        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_databases WHERE database_id = DB_ID())
            THROW 50000, 'Change Tracking is not enabled at the database level.', 1;

        IF OBJECT_ID(N'dbo.DISTKEY', N'U') IS NULL
            THROW 50000, 'Source table dbo.DISTKEY not found.', 1;

        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.DISTKEY'))
            THROW 50000, 'Change Tracking is not enabled on dbo.DISTKEY.', 1;

        IF OBJECT_ID(N'dbo.tbl_Employees', N'U') IS NULL
            THROW 50000, 'dbo.tbl_Employees missing. Run Employees initial first.', 1;

        IF OBJECT_ID(N'dbo.tbl_Branch', N'U') IS NULL
            THROW 50000, 'dbo.tbl_Branch missing. Run Branch initial first.', 1;

        IF COL_LENGTH(N'dbo.tbl_Branch', N'UUID') IS NULL
           OR COL_LENGTH(N'dbo.tbl_Branch', N'Old_Branch_UUID') IS NULL
           OR COL_LENGTH(N'dbo.tbl_Branch', N'Branch_Name') IS NULL
            THROW 50000, 'dbo.tbl_Branch invalid schema (expected UUID, Old_Branch_UUID, Branch_Name).', 1;

        /* Fence CT window */
        SET @BaselineFrom = CHANGE_TRACKING_CURRENT_VERSION();

        /* Ensure watermark table exists + upsert */
        IF OBJECT_ID(N'dbo.CT_Watermark', N'U') IS NULL
        BEGIN
            CREATE TABLE dbo.CT_Watermark
            (
              ProcessName     sysname      NOT NULL CONSTRAINT PK_CT_Watermark PRIMARY KEY,
              LastSyncVersion bigint       NOT NULL,
              LastSyncTime    datetime2(3) NOT NULL CONSTRAINT DF_CT_Watermark_LastSyncTime DEFAULT SYSUTCDATETIME()
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

        BEGIN TRAN;

        /* -----------------------------------------------------------------
           Hard reset target safely:
             - Drop SYNONYM if exists
             - Drop VIEW if exists
             - Drop TABLE if exists (ONLY if it's a table)
           ----------------------------------------------------------------- */

        IF EXISTS (
            SELECT 1
            FROM sys.synonyms
            WHERE schema_id = SCHEMA_ID(N'dbo')
              AND name = N'tbl_EmployeeBranch'
        )
        BEGIN
            EXEC sys.sp_executesql N'DROP SYNONYM dbo.tbl_EmployeeBranch;';
        END;

        IF EXISTS (
            SELECT 1
            FROM sys.views
            WHERE object_id = OBJECT_ID(N'dbo.tbl_EmployeeBranch')
        )
        BEGIN
            EXEC sys.sp_executesql N'DROP VIEW dbo.tbl_EmployeeBranch;';
        END;

        IF OBJECT_ID(N'dbo.tbl_EmployeeBranch', N'U') IS NOT NULL
        BEGIN
            /* Drop foreign keys referencing this table (defensive) */
            DECLARE @dropFks nvarchar(max) = N'';

            SELECT @dropFks = @dropFks +
                N'ALTER TABLE ' + QUOTENAME(SCHEMA_NAME(pt.schema_id)) + N'.' + QUOTENAME(pt.name) +
                N' DROP CONSTRAINT ' + QUOTENAME(fk.name) + N';' + CHAR(10)
            FROM sys.foreign_keys fk
            JOIN sys.tables pt
              ON pt.object_id = fk.parent_object_id
            WHERE fk.referenced_object_id = OBJECT_ID(N'dbo.tbl_EmployeeBranch');

            IF @dropFks <> N''
                EXEC sys.sp_executesql @dropFks;

            DROP TABLE dbo.tbl_EmployeeBranch;
        END;

        /* Recreate table cleanly */
        CREATE TABLE dbo.tbl_EmployeeBranch
        (
            Employee_UUID   int           NOT NULL,
            Branch_UUID     int           NOT NULL,
            Start_Date      datetime      NULL,
            End_Date        datetime      NULL,
            [Status]        nvarchar(255) NULL,
            [Group]         nvarchar(255) NULL,
            Left_Reason     nvarchar(255) NULL,
            [Location]      nvarchar(255) NULL,
            Main_Branch     char(1)       NULL,
            Branch_Name     nvarchar(255) NULL,

            /* Stable deterministic row key (string hash), NOT used as Branch UUID */
            UUID AS CONVERT(varchar(64),
                    LOWER(CONVERT(varchar(64),
                        HASHBYTES('SHA2_256',
                            CONCAT(
                                CONVERT(nvarchar(20), Employee_UUID),
                                N'|',
                                CONVERT(nvarchar(20), Branch_UUID)
                            )
                        ), 2
                    ))) PERSISTED,

            CreatedAtUTC    datetime2(3)  NOT NULL CONSTRAINT DF_tbl_EmployeeBranch_CreatedAtUTC DEFAULT SYSUTCDATETIME(),
            UpdatedAtUTC    datetime2(3)  NOT NULL CONSTRAINT DF_tbl_EmployeeBranch_UpdatedAtUTC DEFAULT SYSUTCDATETIME(),

            CONSTRAINT PK_tbl_EmployeeBranch PRIMARY KEY NONCLUSTERED (UUID)
        );

        /* Optional visit aggregation (defensive, no dependency) */
        IF OBJECT_ID('tempdb..#VisitAgg') IS NOT NULL DROP TABLE #VisitAgg;
        CREATE TABLE #VisitAgg
        (
            Employee_UUID        int      NOT NULL,
            Old_Branch_UUID      int      NOT NULL,
            FirstVisitStartDate  datetime NULL,
            LastVisitEndDate     datetime NULL,
            CONSTRAINT PK_VisitAgg PRIMARY KEY (Employee_UUID, Old_Branch_UUID)
        );

        IF OBJECT_ID(N'dbo.tbl_Visits', N'U') IS NOT NULL
           AND COL_LENGTH(N'dbo.tbl_Visits', N'Employee_UUID') IS NOT NULL
           AND COL_LENGTH(N'dbo.tbl_Visits', N'Branch_UUID')   IS NOT NULL
           AND COL_LENGTH(N'dbo.tbl_Visits', N'Actual_Visit_Start_Date_Time') IS NOT NULL
           AND COL_LENGTH(N'dbo.tbl_Visits', N'Actual_Visit_End_Date_Time')   IS NOT NULL
        BEGIN
            INSERT INTO #VisitAgg (Employee_UUID, Old_Branch_UUID, FirstVisitStartDate, LastVisitEndDate)
            SELECT
                v.Employee_UUID,
                b.Old_Branch_UUID,
                MIN(v.Actual_Visit_Start_Date_Time),
                MAX(v.Actual_Visit_End_Date_Time)
            FROM dbo.tbl_Visits AS v
            JOIN dbo.tbl_Branch AS b
              ON v.Branch_UUID = b.UUID
            WHERE v.Employee_UUID IS NOT NULL
              AND b.Old_Branch_UUID IS NOT NULL
            GROUP BY v.Employee_UUID, b.Old_Branch_UUID;
        END;

        /* Populate baseline (NO implicit casting of hashes -> INT) */
        ;WITH DistinctPairs AS
        (
            SELECT DISTINCT
                Employee_UUID   = TRY_CONVERT(int, DK.INPRIKEY),
                Old_Branch_UUID = TRY_CONVERT(int, DK.OUTPRIKEY),
                DK_Start_Date   = DK.START_DATE,
                DK_End_Date     = DK.[DATE],
                DK_LEFTREASON   = DK.LEFTREASON,
                DK_LOCATION_REF = DK.LOCATION_REF,
                DK_STATUS       = DK.[STATUS],
                DK_CARE_GRP_REF = DK.CARE_GRP_REF
            FROM dbo.DISTKEY AS DK
            WHERE TRY_CONVERT(int, DK.INPRIKEY) IS NOT NULL
              AND TRY_CONVERT(int, DK.OUTPRIKEY) IS NOT NULL
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

        /* Indexes (table was recreated; create once) */
        CREATE CLUSTERED INDEX CX_tbl_EmployeeBranch
            ON dbo.tbl_EmployeeBranch (Employee_UUID, Branch_UUID, Start_Date);

        CREATE INDEX IX_tbl_EmployeeBranch_Employee
            ON dbo.tbl_EmployeeBranch (Employee_UUID);

        CREATE INDEX IX_tbl_EmployeeBranch_Branch
            ON dbo.tbl_EmployeeBranch (Branch_UUID);

        CREATE INDEX IX_tbl_EmployeeBranch_Start
            ON dbo.tbl_EmployeeBranch (Start_Date);

        CREATE INDEX IX_tbl_EmployeeBranch_End
            ON dbo.tbl_EmployeeBranch (End_Date);

        /* Enable CT on target (optional but consistent with pattern) */
        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.tbl_EmployeeBranch'))
        BEGIN
            ALTER TABLE dbo.tbl_EmployeeBranch
                ENABLE CHANGE_TRACKING WITH (TRACK_COLUMNS_UPDATED = ON);
        END;

        COMMIT;

        DECLARE @EndUTC datetime2(3) = SYSUTCDATETIME();
        DECLARE @EndIso varchar(33)  = CONVERT(varchar(33), @EndUTC, 126);

        SET @Summary =
            CONCAT(N'EmployeeBranch initial started ', @StartIso,
                   N' UTC; ended ', @EndIso,
                   N' UTC; inserted ', @Inserted, N' rows; watermark set to ',
                   CAST(@BaselineFrom AS nvarchar(30)), N'.');

        SELECT [Stage]=N'Initial', [Summary]=@Summary;

        IF @lockHeld=1
            EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;

        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK;

        IF @lockHeld=1
            EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;

        DECLARE @msg nvarchar(4000) = ERROR_MESSAGE();
        SET @Summary = CONCAT(N'EmployeeBranch initial failed: ', @msg);
        SELECT [Stage]=N'Initial', [Summary]=@Summary;

        THROW;
    END CATCH
END;
GO
