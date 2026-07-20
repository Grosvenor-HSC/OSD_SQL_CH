/* ============================================================
   File: Clients_Incremental.sql
   Proc: dbo.usp_Sync_Clients_Incremental

   FULL REFACTOR:
     - Mirrors Initial mapping exactly (branch pick logic + joins)
     - CT window fenced at START (ToVersion fixed)
     - Changed-set driven by CT on related tables when available
     - Chunked MERGE with action logging (no $action parsing issues)
     - Delete pass from CLIENT CT deletes
     - Strong typing: Old_Branch_UUID join uses TRY_CONVERT(int, C.GS_REF)
     - Clean applock handling + summary row option

   IMPORTANT:
     Run this script as a normal T-SQL batch (SQLCMD mode OFF).
   ============================================================ */

USE [DOM_LIVE];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Sync_Clients_Incremental
    @ChunkSize         int  = 100000,
    @LockTimeoutMs     int  = 60000,
    @UseAppLock        bit  = 1,
    @EmitInfo          bit  = 0,  -- 0=quiet, 1=NOWAIT progress
    @AutoInitial       bit  = 0,  -- 0=fail if baseline missing/stale, 1=run Initial
    @Summary           nvarchar(4000) = NULL OUTPUT,
    @ReturnSummaryRow  bit  = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Process       sysname      = N'Clients';
    DECLARE @RunStartedAt  datetime2(3) = SYSUTCDATETIME();
    DECLARE @StartIso      varchar(33)  = CONVERT(varchar(33), @RunStartedAt, 126);
    DECLARE @EndUTC        datetime2(3);
    DECLARE @EndIso        varchar(33);
    DECLARE @DurationSec   int;

    /* Concurrency */
    DECLARE @LockResource sysname = N'DOM_LIVE:Sync:Clients';
    DECLARE @LockOwner    sysname = N'Session';
    DECLARE @DbPrincipal  sysname = N'dbo';
    DECLARE @LockResult   int;
    DECLARE @LockHeld     bit = 0;

    IF @UseAppLock = 1
    BEGIN
        EXEC @LockResult = sys.sp_getapplock
            @Resource    = @LockResource,
            @LockMode    = 'Exclusive',
            @LockOwner   = @LockOwner,
            @DbPrincipal = @DbPrincipal,
            @LockTimeout = @LockTimeoutMs;

        IF @LockResult NOT IN (0,1)
        BEGIN
            SET @Summary = N'Clients incremental failed: could not acquire applock.';
            IF @ReturnSummaryRow=1 SELECT N'Incremental' AS Stage, @Summary AS Summary;
            RETURN -1;
        END;

        SET @LockHeld = 1;
    END

    BEGIN TRY
        /* Preconditions */
        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_databases WHERE database_id = DB_ID())
            RAISERROR('Change Tracking is not enabled at the database level.', 16, 1);

        IF OBJECT_ID(N'dbo.tbl_Branch', N'U') IS NULL
            RAISERROR('Missing dependency dbo.tbl_Branch. Run Branch initial first.', 16, 1);

        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.CLIENT'))
            RAISERROR('Change Tracking is not enabled on dbo.CLIENT.', 16, 1);

        DECLARE @CT_CONTACT_DT bit = CASE WHEN EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.CONTACT_DT')) THEN 1 ELSE 0 END;
        DECLARE @CT_CONTACT_HD bit = CASE WHEN EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.CONTACT_HD')) THEN 1 ELSE 0 END;
        DECLARE @CT_CHSYSDEC   bit = CASE WHEN EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.CHSYSDEC'))   THEN 1 ELSE 0 END;

        /* Baseline existence */
        DECLARE @NeedInitial bit = 0;

        IF OBJECT_ID(N'dbo.tbl_Clients', N'U') IS NULL
            SET @NeedInitial = 1;

        IF @NeedInitial = 0
        BEGIN
            IF OBJECT_ID(N'dbo.CT_Watermark', N'U') IS NULL
                SET @NeedInitial = 1;
            ELSE IF NOT EXISTS (SELECT 1 FROM dbo.CT_Watermark WHERE ProcessName=@Process)
                SET @NeedInitial = 1;
        END

        IF @NeedInitial = 1
        BEGIN
            IF @AutoInitial=1 AND OBJECT_ID(N'dbo.usp_Sync_Clients_Initial', N'P') IS NOT NULL
            BEGIN
                IF @EmitInfo=1 RAISERROR('Auto-running Clients initial (baseline missing).',10,1) WITH NOWAIT;
                EXEC dbo.usp_Sync_Clients_Initial;
            END
            ELSE
                RAISERROR('Clients baseline missing. Run dbo.usp_Sync_Clients_Initial first (or set @AutoInitial=1).',16,1);
        END

        /* Watermark */
        IF OBJECT_ID(N'dbo.CT_Watermark', N'U') IS NULL
        BEGIN
            CREATE TABLE dbo.CT_Watermark
            (
                ProcessName     sysname      NOT NULL CONSTRAINT PK_CT_Watermark PRIMARY KEY,
                LastSyncVersion bigint       NOT NULL,
                LastSyncTime    datetime2(3) NOT NULL CONSTRAINT DF_CT_Watermark_LastSyncTime DEFAULT SYSUTCDATETIME()
            );
        END;

        IF NOT EXISTS (SELECT 1 FROM dbo.CT_Watermark WITH (HOLDLOCK, UPDLOCK) WHERE ProcessName=@Process)
            INSERT INTO dbo.CT_Watermark(ProcessName, LastSyncVersion) VALUES (@Process, 0);

        DECLARE @LastSyncVersion bigint;
        SELECT @LastSyncVersion = LastSyncVersion
        FROM dbo.CT_Watermark WITH (HOLDLOCK, UPDLOCK)
        WHERE ProcessName=@Process;

        /* Fence CT window at START */
        DECLARE @ToVersion bigint = CHANGE_TRACKING_CURRENT_VERSION();

        /* CT retention check (only for CT-enabled tables we actually use) */
        DECLARE @MinValid bigint =
        (
            SELECT MAX(CHANGE_TRACKING_MIN_VALID_VERSION(object_id))
            FROM sys.change_tracking_tables
            WHERE object_id IN
            (
                OBJECT_ID(N'dbo.CLIENT'),
                CASE WHEN @CT_CONTACT_DT=1 THEN OBJECT_ID(N'dbo.CONTACT_DT') ELSE NULL END,
                CASE WHEN @CT_CONTACT_HD=1 THEN OBJECT_ID(N'dbo.CONTACT_HD') ELSE NULL END,
                CASE WHEN @CT_CHSYSDEC=1   THEN OBJECT_ID(N'dbo.CHSYSDEC')   ELSE NULL END
            )
        );

        IF @MinValid IS NOT NULL AND @LastSyncVersion < @MinValid
        BEGIN
            IF @AutoInitial=1 AND OBJECT_ID(N'dbo.usp_Sync_Clients_Initial', N'P') IS NOT NULL
            BEGIN
                IF @EmitInfo=1 RAISERROR('Auto-running Clients initial (watermark stale).',10,1) WITH NOWAIT;
                EXEC dbo.usp_Sync_Clients_Initial;

                SELECT @LastSyncVersion = LastSyncVersion
                FROM dbo.CT_Watermark WITH (HOLDLOCK, UPDLOCK)
                WHERE ProcessName=@Process;

                SET @ToVersion = CHANGE_TRACKING_CURRENT_VERSION();
            END
            ELSE
                RAISERROR('Clients watermark (%I64d) < CT min valid (%I64d). Re-baseline required.',16,1,@LastSyncVersion,@MinValid);
        END

        IF @EmitInfo=1
            RAISERROR('Clients CT window: From=%I64d To=%I64d',10,1,@LastSyncVersion,@ToVersion) WITH NOWAIT;

        /* Build changed set */
        IF OBJECT_ID(N'tempdb..#Changed') IS NOT NULL DROP TABLE #Changed;
        CREATE TABLE #Changed (ClientRef int NOT NULL PRIMARY KEY);

        INSERT INTO #Changed(ClientRef)
        SELECT DISTINCT ct.CLIENT_REF
        FROM CHANGETABLE(CHANGES dbo.CLIENT, @LastSyncVersion) ct
        WHERE ct.SYS_CHANGE_VERSION <= @ToVersion;

        IF @CT_CONTACT_DT=1
        BEGIN
            INSERT INTO #Changed(ClientRef)
            SELECT DISTINCT c.CLIENT_REF
            FROM CHANGETABLE(CHANGES dbo.CONTACT_DT, @LastSyncVersion) x
            JOIN dbo.CLIENT c
              ON c.CNTA_DET_REF = x.CNTA_DET_REF
            WHERE x.SYS_CHANGE_VERSION <= @ToVersion
              AND NOT EXISTS (SELECT 1 FROM #Changed z WHERE z.ClientRef = c.CLIENT_REF);
        END

        IF @CT_CONTACT_HD=1 AND @CT_CONTACT_DT=1
        BEGIN
            INSERT INTO #Changed(ClientRef)
            SELECT DISTINCT c.CLIENT_REF
            FROM CHANGETABLE(CHANGES dbo.CONTACT_HD, @LastSyncVersion) h
            JOIN dbo.CONTACT_DT dt
              ON dt.CONTACT_REF = h.CONTACT_REF
            JOIN dbo.CLIENT c
              ON c.CNTA_DET_REF = dt.CNTA_DET_REF
            WHERE h.SYS_CHANGE_VERSION <= @ToVersion
              AND NOT EXISTS (SELECT 1 FROM #Changed z WHERE z.ClientRef = c.CLIENT_REF);
        END

        IF @CT_CHSYSDEC=1
        BEGIN
            INSERT INTO #Changed(ClientRef)
            SELECT DISTINCT c.CLIENT_REF
            FROM CHANGETABLE(CHANGES dbo.CHSYSDEC, @LastSyncVersion) d
            JOIN dbo.CLIENT c
              ON c.CARE_GRP_REF = d.DECODE_REF
              OR c.DISAB_REF    = d.DECODE_REF
              OR c.DISAB_REF2   = d.DECODE_REF
              OR c.DISAB_REF3   = d.DECODE_REF
              OR c.ETHNICITY    = d.DECODE_REF
              OR c.LEFTRES_REF  = d.DECODE_REF
              OR c.RELORG_REF   = d.DECODE_REF
              OR c.CLIENT_TYPE  = d.DECODE_REF
              OR c.LOCATION_REF = d.DECODE_REF
              OR c.STATUS       = d.DECODE_REF
            WHERE d.SYS_CHANGE_VERSION <= @ToVersion
              AND NOT EXISTS (SELECT 1 FROM #Changed z WHERE z.ClientRef = c.CLIENT_REF);

            IF @CT_CONTACT_HD=1 AND @CT_CONTACT_DT=1
            BEGIN
                INSERT INTO #Changed(ClientRef)
                SELECT DISTINCT c.CLIENT_REF
                FROM CHANGETABLE(CHANGES dbo.CHSYSDEC, @LastSyncVersion) d
                JOIN dbo.CONTACT_HD h
                  ON h.TITLE = d.DECODE_REF
                JOIN dbo.CONTACT_DT dt
                  ON dt.CONTACT_REF = h.CONTACT_REF
                JOIN dbo.CLIENT c
                  ON c.CNTA_DET_REF = dt.CNTA_DET_REF
                WHERE d.SYS_CHANGE_VERSION <= @ToVersion
                  AND NOT EXISTS (SELECT 1 FROM #Changed z WHERE z.ClientRef = c.CLIENT_REF);
            END
        END

        DECLARE @ToProcess int = (SELECT COUNT(*) FROM #Changed);
        IF @EmitInfo=1 RAISERROR('Changed clients to process: %d',10,1,@ToProcess) WITH NOWAIT;

        IF @ToProcess = 0
        BEGIN
            UPDATE dbo.CT_Watermark
              SET LastSyncVersion=@ToVersion, LastSyncTime=SYSUTCDATETIME()
            WHERE ProcessName=@Process;

            SET @EndUTC      = SYSUTCDATETIME();
            SET @EndIso      = CONVERT(varchar(33), @EndUTC, 126);
            SET @DurationSec = DATEDIFF(SECOND, @RunStartedAt, @EndUTC);

            SET @Summary = CONCAT(
                N'Clients incremental started ', @StartIso, N' UTC; ended ', @EndIso,
                N' UTC; inserted 0, updated 0, deleted 0; advanced watermark to ',
                CAST(@ToVersion AS nvarchar(30)), N'; duration=', @DurationSec, N' sec.'
            );

            IF @ReturnSummaryRow=1 SELECT N'Incremental' AS Stage, @Summary AS Summary;
            IF @LockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource,@LockOwner=@LockOwner,@DbPrincipal=@DbPrincipal;
            RETURN 0;
        END

        /* Chunked upsert */
        DECLARE @TotalInserted bigint = 0, @TotalUpdated bigint = 0;

        WHILE EXISTS (SELECT 1 FROM #Changed)
        BEGIN
            IF OBJECT_ID(N'tempdb..#Next') IS NOT NULL DROP TABLE #Next;
            CREATE TABLE #Next (ClientRef int NOT NULL PRIMARY KEY);

            INSERT INTO #Next(ClientRef)
            SELECT TOP (@ChunkSize) ClientRef
            FROM #Changed
            ORDER BY ClientRef;

            IF OBJECT_ID(N'tempdb..#ActLog') IS NOT NULL DROP TABLE #ActLog;
            CREATE TABLE #ActLog (MergeAction nvarchar(10) NOT NULL);

            ;WITH BaseClient AS
            (
                SELECT
                    Branch_UUID = COALESCE(b_by_name.UUID, b_by_old.UUID),
                    UUID        = C.CLIENT_REF,

                    Case_No              = NULLIF(LTRIM(RTRIM(C.CASE_NO)), ''),
                    DOB                  = TRY_CONVERT(date, C.DATEOFBIRTH),

                    First_Line_Address   = NULLIF(LTRIM(RTRIM(CHD.ADDRESS1)), ''),
                    Second_Line_Address  = NULLIF(LTRIM(RTRIM(CHD.ADDRESS2)), ''),
                    Third_Line_Address   = NULLIF(LTRIM(RTRIM(CHD.ADDRESS3)), ''),
                    Fourth_Line_Address  = NULLIF(LTRIM(RTRIM(CHD.ADDRESS4)), ''),
                    Postcode             = NULLIF(LTRIM(RTRIM(CHD.POSTCODE)), ''),

                    Forenames            = NULLIF(LTRIM(RTRIM(CHD.FORENAMES)), ''),
                    Surname              = NULLIF(LTRIM(RTRIM(CHD.SURNAME)), ''),
                    Email                = NULLIF(LTRIM(RTRIM(CHD.EMAIL)), ''),
                    Telephone_1          = NULLIF(LTRIM(RTRIM(CHD.TEL_NO1)), ''),
                    Telephone_2          = NULLIF(LTRIM(RTRIM(CHD.TEL_NO2)), ''),

                    Title                = NULLIF(LTRIM(RTRIM(CTL.DESCRIPTION)), ''),
                    Care_Group           = NULLIF(LTRIM(RTRIM(CG.DESCRIPTION)), ''),
                    CH_Code              = NULLIF(LTRIM(RTRIM(C.CLIENT_CODE)), ''),

                    Gender               = CASE WHEN C.SEX='M' THEN 'Male'
                                                WHEN C.SEX='F' THEN 'Female'
                                                ELSE 'Other' END,

                    StartDate            = TRY_CONVERT(date, C.START_DATE),
                    LeaveDate            = TRY_CONVERT(date, C.LEFT_DATE),

                    Status               = NULLIF(LTRIM(RTRIM(CSE.DESCRIPTION)), ''),

                    Disability_1         = CASE WHEN LTRIM(RTRIM(CD1.DESCRIPTION)) = '<no selection>' THEN NULL
                                                ELSE NULLIF(LTRIM(RTRIM(CD1.DESCRIPTION)), '') END,
                    Disability_2         = CASE WHEN LTRIM(RTRIM(CD2.DESCRIPTION)) = '<no selection>' THEN NULL
                                                ELSE NULLIF(LTRIM(RTRIM(CD2.DESCRIPTION)), '') END,
                    Disability_3         = CASE WHEN LTRIM(RTRIM(CD3.DESCRIPTION)) = '<no selection>' THEN NULL
                                                ELSE NULLIF(LTRIM(RTRIM(CD3.DESCRIPTION)), '') END,

                    Ethnicity            = NULLIF(LTRIM(RTRIM(CE.DESCRIPTION)), ''),
                    LeftReason           = CASE WHEN LTRIM(RTRIM(CLR.DESCRIPTION)) = '<no selection>' THEN NULL
                                                ELSE NULLIF(LTRIM(RTRIM(CLR.DESCRIPTION)), '') END,
                    Religion             = CASE WHEN LTRIM(RTRIM(CR.DESCRIPTION))  = 'Not Declared' THEN NULL
                                                ELSE NULLIF(LTRIM(RTRIM(CR.DESCRIPTION)), '') END,
                    Location             = CASE WHEN LTRIM(RTRIM(CL.DESCRIPTION))  = '<no selection>' THEN NULL
                                                ELSE NULLIF(LTRIM(RTRIM(CL.DESCRIPTION)), '') END,
                    Type                 = NULLIF(LTRIM(RTRIM(CTY.DESCRIPTION)), ''),

                    External_Reference   = NULLIF(LTRIM(RTRIM(C.EXTCLREF)), '')
                FROM dbo.CLIENT C
                JOIN #Next n
                  ON n.ClientRef = C.CLIENT_REF

                LEFT JOIN dbo.CONTACT_DT CDT
                  ON CDT.CNTA_DET_REF = C.CNTA_DET_REF
                LEFT JOIN dbo.CONTACT_HD CHD
                  ON CHD.CONTACT_REF = CDT.CONTACT_REF

                LEFT JOIN dbo.CHSYSDEC CTL
                  ON CHD.TITLE = CTL.DECODE_REF
                LEFT JOIN dbo.CHSYSDEC CG
                  ON C.CARE_GRP_REF = CG.DECODE_REF
                LEFT JOIN dbo.CHSYSDEC CD1
                  ON C.DISAB_REF = CD1.DECODE_REF
                LEFT JOIN dbo.CHSYSDEC CD2
                  ON C.DISAB_REF2 = CD2.DECODE_REF
                LEFT JOIN dbo.CHSYSDEC CD3
                  ON C.DISAB_REF3 = CD3.DECODE_REF
                LEFT JOIN dbo.CHSYSDEC CE
                  ON C.ETHNICITY = CE.DECODE_REF
                LEFT JOIN dbo.CHSYSDEC CLR
                  ON C.LEFTRES_REF = CLR.DECODE_REF
                LEFT JOIN dbo.CHSYSDEC CR
                  ON C.RELORG_REF = CR.DECODE_REF
                LEFT JOIN dbo.CHSYSDEC CTY
                  ON C.CLIENT_TYPE = CTY.DECODE_REF
                LEFT JOIN dbo.CHSYSDEC CL
                  ON C.LOCATION_REF = CL.DECODE_REF
                LEFT JOIN dbo.CHSYSDEC CSE
                  ON C.STATUS = CSE.DECODE_REF

                OUTER APPLY
                (
                    SELECT CASE
                             WHEN TRY_CONVERT(int, C.GS_REF) = 1970000043 AND CL.DESCRIPTION = 'Southampton' THEN N'Southampton'
                             WHEN TRY_CONVERT(int, C.GS_REF) = 1970000043 AND (CL.DESCRIPTION <> 'Southampton' OR CL.DESCRIPTION IS NULL) THEN N'Portsmouth'
                             ELSE NULL
                           END AS BranchName
                ) pick

                LEFT JOIN dbo.tbl_Branch b_by_name
                  ON pick.BranchName IS NOT NULL
                 AND b_by_name.Branch_Name = pick.BranchName

                LEFT JOIN dbo.tbl_Branch b_by_old
                  ON pick.BranchName IS NULL
                 AND b_by_old.Old_Branch_UUID = TRY_CONVERT(int, C.GS_REF)
            )
            MERGE dbo.tbl_Clients AS tgt
            USING (SELECT * FROM BaseClient WHERE Branch_UUID IS NOT NULL) AS src
              ON tgt.UUID = src.UUID
            WHEN MATCHED THEN
                UPDATE SET
                    tgt.Branch_UUID         = src.Branch_UUID,
                    tgt.Case_No             = src.Case_No,
                    tgt.DOB                 = src.DOB,
                    tgt.First_Line_Address  = src.First_Line_Address,
                    tgt.Second_Line_Address = src.Second_Line_Address,
                    tgt.Third_Line_Address  = src.Third_Line_Address,
                    tgt.Fourth_Line_Address = src.Fourth_Line_Address,
                    tgt.Postcode            = src.Postcode,
                    tgt.Forenames           = src.Forenames,
                    tgt.Surname             = src.Surname,
                    tgt.Email               = src.Email,
                    tgt.Telephone_1         = src.Telephone_1,
                    tgt.Telephone_2         = src.Telephone_2,
                    tgt.Title               = src.Title,
                    tgt.Care_Group          = src.Care_Group,
                    tgt.CH_Code             = src.CH_Code,
                    tgt.Gender              = src.Gender,
                    tgt.StartDate           = src.StartDate,
                    tgt.LeaveDate           = src.LeaveDate,
                    tgt.Status              = src.Status,
                    tgt.Disability_1        = src.Disability_1,
                    tgt.Disability_2        = src.Disability_2,
                    tgt.Disability_3        = src.Disability_3,
                    tgt.Ethnicity           = src.Ethnicity,
                    tgt.LeftReason          = src.LeftReason,
                    tgt.Religion            = src.Religion,
                    tgt.Location            = src.Location,
                    tgt.Type                = src.Type,
                    tgt.External_Reference  = src.External_Reference,
                    tgt.UpdatedAtUTC        = @RunStartedAt
            WHEN NOT MATCHED BY TARGET THEN
                INSERT
                (
                    Branch_UUID, UUID, Case_No, DOB,
                    First_Line_Address, Second_Line_Address, Third_Line_Address, Fourth_Line_Address,
                    Postcode, Forenames, Surname, Email, Telephone_1, Telephone_2,
                    Title, Care_Group, CH_Code, Gender, StartDate, LeaveDate, Status,
                    Disability_1, Disability_2, Disability_3, Ethnicity,
                    LeftReason, Religion, Location, Type,
                    External_Reference, CreatedAtUTC, UpdatedAtUTC
                )
                VALUES
                (
                    src.Branch_UUID, src.UUID, src.Case_No, src.DOB,
                    src.First_Line_Address, src.Second_Line_Address, src.Third_Line_Address, src.Fourth_Line_Address,
                    src.Postcode, src.Forenames, src.Surname, src.Email, src.Telephone_1, src.Telephone_2,
                    src.Title, src.Care_Group, src.CH_Code, src.Gender, src.StartDate, src.LeaveDate, src.Status,
                    src.Disability_1, src.Disability_2, src.Disability_3, src.Ethnicity,
                    src.LeftReason, src.Religion, src.Location, src.Type,
                    src.External_Reference, @RunStartedAt, @RunStartedAt
                )
            OUTPUT $action AS MergeAction INTO #ActLog(MergeAction)
            ;

            DECLARE @ChunkIns int = 0, @ChunkUpd int = 0;
            SELECT
                @ChunkIns = SUM(CASE WHEN MergeAction='INSERT' THEN 1 ELSE 0 END),
                @ChunkUpd = SUM(CASE WHEN MergeAction='UPDATE' THEN 1 ELSE 0 END)
            FROM #ActLog;

            SET @TotalInserted += ISNULL(@ChunkIns,0);
            SET @TotalUpdated  += ISNULL(@ChunkUpd,0);

            IF @EmitInfo=1
                RAISERROR('Clients chunk: inserted=%d updated=%d (running %I64d/%I64d)',10,1,@ChunkIns,@ChunkUpd,@TotalInserted,@TotalUpdated) WITH NOWAIT;

            DELETE c
            FROM #Changed c
            JOIN #Next n ON n.ClientRef = c.ClientRef;
        END

        /* Deletes from CLIENT CT deletes */
        IF OBJECT_ID(N'tempdb..#DelLog') IS NOT NULL DROP TABLE #DelLog;
        CREATE TABLE #DelLog (UUID int NOT NULL);

        DELETE t
        OUTPUT DELETED.UUID INTO #DelLog(UUID)
        FROM dbo.tbl_Clients t
        JOIN
        (
            SELECT d.CLIENT_REF
            FROM CHANGETABLE(CHANGES dbo.CLIENT, @LastSyncVersion) d
            WHERE d.SYS_CHANGE_OPERATION='D'
              AND d.SYS_CHANGE_VERSION <= @ToVersion
        ) x
          ON t.UUID = x.CLIENT_REF;

        DECLARE @TotalDeleted int = (SELECT COUNT(*) FROM #DelLog);
        IF @EmitInfo=1 RAISERROR('Clients deletes applied: %d',10,1,@TotalDeleted) WITH NOWAIT;

        /* Advance watermark */
        UPDATE dbo.CT_Watermark
          SET LastSyncVersion=@ToVersion, LastSyncTime=SYSUTCDATETIME()
        WHERE ProcessName=@Process;

        SET @EndUTC      = SYSUTCDATETIME();
        SET @EndIso      = CONVERT(varchar(33), @EndUTC, 126);
        SET @DurationSec = DATEDIFF(SECOND, @RunStartedAt, @EndUTC);

        SET @Summary = CONCAT(
            N'Clients incremental started ', @StartIso, N' UTC; ended ', @EndIso,
            N' UTC; inserted ', CAST(@TotalInserted AS nvarchar(20)),
            N', updated ', CAST(@TotalUpdated AS nvarchar(20)),
            N', deleted ', CAST(@TotalDeleted AS nvarchar(20)),
            N'; advanced watermark to ', CAST(@ToVersion AS nvarchar(30)),
            N'; duration=', CAST(@DurationSec AS nvarchar(20)), N' sec.'
        );

        IF @ReturnSummaryRow=1
            SELECT N'Incremental' AS Stage, @Summary AS Summary;

        IF @LockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource,@LockOwner=@LockOwner,@DbPrincipal=@DbPrincipal;
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF @LockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource,@LockOwner=@LockOwner,@DbPrincipal=@DbPrincipal;

        DECLARE @ErrMsg nvarchar(4000) = ERROR_MESSAGE();
        SET @Summary = CONCAT(N'Clients incremental failed: ', @ErrMsg);

        IF @ReturnSummaryRow=1
            SELECT N'Incremental' AS Stage, @Summary AS Summary;

        RETURN -50001;
    END CATCH
END;
GO
