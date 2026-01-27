USE [DOM_LIVE];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE [dbo].[usp_Sync_Clients_Incremental]
    @ChunkSize         int  = 100000,
    @LockTimeoutMs     int  = 60000,
    @UseAppLock        bit  = 1,
    @EmitInfo          bit  = 1,
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

    -- Concurrency
    DECLARE @LockResource sysname = N'DOM_LIVE:Sync:Clients';
    DECLARE @LockOwner    sysname = N'Session';
    DECLARE @DbPrincipal  sysname = N'dbo';
    DECLARE @lockResult   int;
    DECLARE @lockHeld     bit = 0;

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
            IF @EmitInfo = 1
                RAISERROR('Could not acquire %s (rc=%d).', 16, 1, @LockResource, @lockResult);

            SET @Summary = N'Clients incremental failed: could not acquire applock.';
            IF @ReturnSummaryRow = 1
                SELECT N'Incremental' AS Stage, @Summary AS Summary;

            RETURN @lockResult;
        END;

        SET @lockHeld = 1;
    END;

    BEGIN TRY
        -- Preconditions & watermark
        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_databases WHERE database_id = DB_ID())
        BEGIN
            IF @EmitInfo = 1
                RAISERROR('CT not enabled at DB level.', 16, 1);

            SET @Summary = N'Clients incremental failed: CT not enabled at DB level.';
            IF @ReturnSummaryRow = 1
                SELECT N'Incremental' AS Stage, @Summary AS Summary;

            IF @lockHeld = 1
                EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;

            RETURN -100;
        END;

        IF OBJECT_ID(N'dbo.CT_Watermark', N'U') IS NULL
        BEGIN
            CREATE TABLE dbo.CT_Watermark
            (
                ProcessName     sysname      NOT NULL CONSTRAINT PK_CT_Watermark PRIMARY KEY,
                LastSyncVersion bigint       NOT NULL,
                LastSyncTime    datetime2(3) NOT NULL CONSTRAINT DF_CT_Watermark_LastSyncTime DEFAULT SYSUTCDATETIME()
            );
        END;

        IF NOT EXISTS (SELECT 1 FROM dbo.CT_Watermark WITH (HOLDLOCK, UPDLOCK) WHERE ProcessName = @Process)
        BEGIN
            INSERT INTO dbo.CT_Watermark(ProcessName, LastSyncVersion)
            VALUES (@Process, 0);
        END;

        DECLARE @LastSyncVersion bigint =
        (
            SELECT LastSyncVersion
            FROM dbo.CT_Watermark WITH (HOLDLOCK, UPDLOCK)
            WHERE ProcessName = @Process
        );

        DECLARE @ToVersion bigint = CHANGE_TRACKING_CURRENT_VERSION();

        -- Min valid across referenced tables
        DECLARE @MinValid bigint =
        (
            SELECT MAX(CHANGE_TRACKING_MIN_VALID_VERSION(object_id))
            FROM sys.change_tracking_tables
            WHERE object_id IN
            (
                OBJECT_ID(N'dbo.CLIENT'),
                OBJECT_ID(N'dbo.CONTACT_DT'),
                OBJECT_ID(N'dbo.CONTACT_HD'),
                OBJECT_ID(N'dbo.CHSYSDEC')
            )
        );

        IF @MinValid IS NOT NULL AND @LastSyncVersion < @MinValid
        BEGIN
            IF @EmitInfo = 1
                RAISERROR('Watermark (%I64d) < CT min valid (%I64d). Re-baseline required.', 16, 1, @LastSyncVersion, @MinValid);

            SET @Summary = CONCAT(N'Clients incremental failed: watermark ', @LastSyncVersion, N' < min valid ', @MinValid, N'.');
            IF @ReturnSummaryRow = 1
                SELECT N'Incremental' AS Stage, @Summary AS Summary;

            IF @lockHeld = 1
                EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;

            RETURN -200;
        END;

        IF @EmitInfo = 1
            RAISERROR('Clients CT window: From=%I64d To=%I64d', 0, 1, @LastSyncVersion, @ToVersion) WITH NOWAIT;

        -- Build changed set (INT keys end-to-end)
        IF OBJECT_ID(N'tempdb..#Changed') IS NOT NULL DROP TABLE #Changed;
        CREATE TABLE #Changed
        (
            ClientRef int NOT NULL CONSTRAINT PK_Changed PRIMARY KEY
        );

        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.CLIENT'))
        BEGIN
            IF @EmitInfo = 1
                RAISERROR('CT not enabled on dbo.CLIENT.', 16, 1);

            SET @Summary = N'Clients incremental failed: CT not enabled on CLIENT.';
            IF @ReturnSummaryRow = 1
                SELECT N'Incremental' AS Stage, @Summary AS Summary;

            IF @lockHeld = 1
                EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;

            RETURN -210;
        END;

        INSERT INTO #Changed (ClientRef)
        SELECT DISTINCT ct.CLIENT_REF
        FROM CHANGETABLE(CHANGES dbo.CLIENT, @LastSyncVersion) AS ct
        WHERE ct.SYS_CHANGE_VERSION <= @ToVersion;

        IF EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.CONTACT_DT'))
        BEGIN
            INSERT INTO #Changed (ClientRef)
            SELECT DISTINCT c.CLIENT_REF
            FROM CHANGETABLE(CHANGES dbo.CONTACT_DT, @LastSyncVersion) AS x
            JOIN dbo.CLIENT AS c
              ON c.CNTA_DET_REF = x.CNTA_DET_REF
            WHERE x.SYS_CHANGE_VERSION <= @ToVersion
              AND NOT EXISTS (SELECT 1 FROM #Changed AS z WHERE z.ClientRef = c.CLIENT_REF);
        END;

        IF EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.CONTACT_HD'))
        BEGIN
            INSERT INTO #Changed (ClientRef)
            SELECT DISTINCT c.CLIENT_REF
            FROM CHANGETABLE(CHANGES dbo.CONTACT_HD, @LastSyncVersion) AS h
            JOIN dbo.CONTACT_DT AS dt
              ON dt.CONTACT_REF = h.CONTACT_REF
            JOIN dbo.CLIENT AS c
              ON c.CNTA_DET_REF = dt.CNTA_DET_REF
            WHERE h.SYS_CHANGE_VERSION <= @ToVersion
              AND NOT EXISTS (SELECT 1 FROM #Changed AS z WHERE z.ClientRef = c.CLIENT_REF);
        END;

        IF EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.CHSYSDEC'))
        BEGIN
            INSERT INTO #Changed (ClientRef)
            SELECT DISTINCT c.CLIENT_REF
            FROM CHANGETABLE(CHANGES dbo.CHSYSDEC, @LastSyncVersion) AS d
            JOIN dbo.CLIENT AS c
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
              AND NOT EXISTS (SELECT 1 FROM #Changed AS z WHERE z.ClientRef = c.CLIENT_REF);

            INSERT INTO #Changed (ClientRef)
            SELECT DISTINCT c.CLIENT_REF
            FROM CHANGETABLE(CHANGES dbo.CHSYSDEC, @LastSyncVersion) AS d
            JOIN dbo.CONTACT_HD AS h
              ON h.TITLE = d.DECODE_REF
            JOIN dbo.CONTACT_DT AS dt
              ON dt.CONTACT_REF = h.CONTACT_REF
            JOIN dbo.CLIENT AS c
              ON c.CNTA_DET_REF = dt.CNTA_DET_REF
            WHERE d.SYS_CHANGE_VERSION <= @ToVersion
              AND NOT EXISTS (SELECT 1 FROM #Changed AS z WHERE z.ClientRef = c.CLIENT_REF);
        END;

        DECLARE @ToProcess int = (SELECT COUNT(*) FROM #Changed);

        IF @EmitInfo = 1
            RAISERROR('Changed clients to process: %d', 0, 1, @ToProcess) WITH NOWAIT;

        IF @ToProcess = 0
        BEGIN
            UPDATE dbo.CT_Watermark
              SET LastSyncVersion = @ToVersion,
                  LastSyncTime    = SYSUTCDATETIME()
            WHERE ProcessName = @Process;

            SET @EndUTC      = SYSUTCDATETIME();
            SET @EndIso      = CONVERT(varchar(33), @EndUTC, 126);
            SET @DurationSec = DATEDIFF(SECOND, @RunStartedAt, @EndUTC);

            SET @Summary = CONCAT(
                N'Clients incremental started ', @StartIso, N' UTC; ended ', @EndIso,
                N' UTC; inserted 0, updated 0, deleted 0; advanced watermark to ',
                CAST(@ToVersion AS nvarchar(30)), N'; duration=', @DurationSec, N' sec.'
            );

            IF @ReturnSummaryRow = 1
                SELECT N'Incremental' AS Stage, @Summary AS Summary;

            IF @lockHeld = 1
                EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;

            RETURN 0;
        END;

        DECLARE @TotalInserted bigint = 0;
        DECLARE @TotalUpdated  bigint = 0;

        WHILE EXISTS (SELECT 1 FROM #Changed)
        BEGIN
            IF OBJECT_ID(N'tempdb..#Next') IS NOT NULL DROP TABLE #Next;
            CREATE TABLE #Next
            (
                ClientRef int NOT NULL CONSTRAINT PK_Next PRIMARY KEY
            );

            INSERT INTO #Next (ClientRef)
            SELECT TOP (@ChunkSize) ClientRef
            FROM #Changed
            ORDER BY ClientRef;

            IF OBJECT_ID(N'tempdb..#ActLog') IS NOT NULL DROP TABLE #ActLog;
            CREATE TABLE #ActLog
            (
                Action nvarchar(10) NOT NULL
            );

            ;WITH BaseClient AS
            (
                SELECT
                    Branch_UUID = COALESCE(b_by_name.UUID, b_by_old.UUID),

                    UUID        = C.CLIENT_REF,
                    Case_No     = NULLIF(LTRIM(RTRIM(C.CASE_NO)), ''),
                    DOB         = TRY_CONVERT(date, C.DATEOFBIRTH),

                    First_Line_Address  = NULLIF(LTRIM(RTRIM(CHD.ADDRESS1)), ''),
                    Second_Line_Address = NULLIF(LTRIM(RTRIM(CHD.ADDRESS2)), ''),
                    Third_Line_Address  = NULLIF(LTRIM(RTRIM(CHD.ADDRESS3)), ''),
                    Fourth_Line_Address = NULLIF(LTRIM(RTRIM(CHD.ADDRESS4)), ''),

                    Postcode    = NULLIF(LTRIM(RTRIM(CHD.POSTCODE)), ''),
                    Forenames   = NULLIF(LTRIM(RTRIM(CHD.FORENAMES)), ''),
                    Surname     = NULLIF(LTRIM(RTRIM(CHD.SURNAME)), ''),
                    Email       = NULLIF(LTRIM(RTRIM(CHD.EMAIL)), ''),
                    Telephone_1 = NULLIF(LTRIM(RTRIM(CHD.TEL_NO1)), ''),
                    Telephone_2 = NULLIF(LTRIM(RTRIM(CHD.TEL_NO2)), ''),

                    Title       = NULLIF(LTRIM(RTRIM(CTL.DESCRIPTION)), ''),
                    Care_Group  = NULLIF(LTRIM(RTRIM(CG.DESCRIPTION)), ''),
                    CH_Code     = NULLIF(LTRIM(RTRIM(C.CLIENT_CODE)), ''),

                    Gender      = CASE WHEN C.SEX = 'M' THEN 'Male'
                                       WHEN C.SEX = 'F' THEN 'Female'
                                       ELSE 'Other' END,

                    StartDate   = TRY_CONVERT(date, C.START_DATE),
                    LeaveDate   = TRY_CONVERT(date, C.LEFT_DATE),

                    Status        = NULLIF(LTRIM(RTRIM(CSE.DESCRIPTION)), ''),
                    Disability_1  = CASE WHEN LTRIM(RTRIM(CD1.DESCRIPTION)) = '<no selection>' THEN NULL ELSE NULLIF(LTRIM(RTRIM(CD1.DESCRIPTION)), '') END,
                    Disability_2  = CASE WHEN LTRIM(RTRIM(CD2.DESCRIPTION)) = '<no selection>' THEN NULL ELSE NULLIF(LTRIM(RTRIM(CD2.DESCRIPTION)), '') END,
                    Disability_3  = CASE WHEN LTRIM(RTRIM(CD3.DESCRIPTION)) = '<no selection>' THEN NULL ELSE NULLIF(LTRIM(RTRIM(CD3.DESCRIPTION)), '') END,
                    Ethnicity     = NULLIF(LTRIM(RTRIM(CE.DESCRIPTION)), ''),
                    LeftReason    = CASE WHEN LTRIM(RTRIM(CLR.DESCRIPTION)) = '<no selection>' THEN NULL ELSE NULLIF(LTRIM(RTRIM(CLR.DESCRIPTION)), '') END,
                    Religion      = CASE WHEN LTRIM(RTRIM(CR.DESCRIPTION))  = 'Not Declared'   THEN NULL ELSE NULLIF(LTRIM(RTRIM(CR.DESCRIPTION)), '') END,
                    Location      = CASE WHEN LTRIM(RTRIM(CL.DESCRIPTION))  = '<no selection>' THEN NULL ELSE NULLIF(LTRIM(RTRIM(CL.DESCRIPTION)), '') END,
                    Type          = NULLIF(LTRIM(RTRIM(CTY.DESCRIPTION)), ''),

                    External_Reference = NULLIF(LTRIM(RTRIM(C.EXTCLREF)), '')
                FROM dbo.CLIENT AS C
                JOIN #Next AS n
                  ON n.ClientRef = C.CLIENT_REF

                LEFT JOIN dbo.CONTACT_DT AS CDT
                  ON CDT.CNTA_DET_REF = C.CNTA_DET_REF
                LEFT JOIN dbo.CONTACT_HD AS CHD
                  ON CHD.CONTACT_REF = CDT.CONTACT_REF

                LEFT JOIN dbo.CHSYSDEC AS CTL
                  ON CHD.TITLE = CTL.DECODE_REF
                LEFT JOIN dbo.CHSYSDEC AS CG
                  ON C.CARE_GRP_REF = CG.DECODE_REF
                LEFT JOIN dbo.CHSYSDEC AS CD1
                  ON C.DISAB_REF = CD1.DECODE_REF
                LEFT JOIN dbo.CHSYSDEC AS CD2
                  ON C.DISAB_REF2 = CD2.DECODE_REF
                LEFT JOIN dbo.CHSYSDEC AS CD3
                  ON C.DISAB_REF3 = CD3.DECODE_REF
                LEFT JOIN dbo.CHSYSDEC AS CE
                  ON C.ETHNICITY = CE.DECODE_REF
                LEFT JOIN dbo.CHSYSDEC AS CLR
                  ON C.LEFTRES_REF = CLR.DECODE_REF
                LEFT JOIN dbo.CHSYSDEC AS CR
                  ON C.RELORG_REF = CR.DECODE_REF
                LEFT JOIN dbo.CHSYSDEC AS CTY
                  ON C.CLIENT_TYPE = CTY.DECODE_REF
                LEFT JOIN dbo.CHSYSDEC AS CL
                  ON C.LOCATION_REF = CL.DECODE_REF
                LEFT JOIN dbo.CHSYSDEC AS CSE
                  ON C.STATUS = CSE.DECODE_REF

                OUTER APPLY
                (
                    SELECT CASE
                             WHEN C.GS_REF = 1970000043 AND CL.DESCRIPTION = 'Southampton' THEN N'Southampton'
                             WHEN C.GS_REF = 1970000043 AND (CL.DESCRIPTION <> 'Southampton' OR CL.DESCRIPTION IS NULL) THEN N'Portsmouth'
                             ELSE NULL
                           END AS BranchName
                ) AS pick

                LEFT JOIN dbo.tbl_Branch AS b_by_name
                  ON pick.BranchName IS NOT NULL
                 AND b_by_name.Branch_Name = pick.BranchName

                LEFT JOIN dbo.tbl_Branch AS b_by_old
                  ON pick.BranchName IS NULL
                 AND b_by_old.Old_Branch_UUID = CONVERT(varchar(20), C.GS_REF)
            )
            MERGE dbo.tbl_Clients AS tgt
            USING
            (
                SELECT *
                FROM BaseClient
                WHERE Branch_UUID IS NOT NULL
            ) AS src
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
            OUTPUT $action INTO #ActLog(Action);

            DECLARE @i int = 0;
            DECLARE @u int = 0;

            SELECT
                @i = SUM(CASE WHEN Action = N'INSERT' THEN 1 ELSE 0 END),
                @u = SUM(CASE WHEN Action = N'UPDATE' THEN 1 ELSE 0 END)
            FROM #ActLog;

            SET @TotalInserted += ISNULL(@i, 0);
            SET @TotalUpdated  += ISNULL(@u, 0);

            IF @EmitInfo = 1
                RAISERROR('Clients chunk: inserted=%d updated=%d (running %d/%d)', 0, 1, @i, @u, @TotalInserted, @TotalUpdated) WITH NOWAIT;

            DELETE c
            FROM #Changed AS c
            JOIN #Next    AS n
              ON n.ClientRef = c.ClientRef;
        END;

        -- Deletes from CLIENT (INT keys end-to-end)
        IF OBJECT_ID(N'tempdb..#DelLog') IS NOT NULL DROP TABLE #DelLog;
        CREATE TABLE #DelLog
        (
            UUID int NOT NULL
        );

        DELETE t
        OUTPUT DELETED.UUID INTO #DelLog(UUID)
        FROM dbo.tbl_Clients AS t
        JOIN
        (
            SELECT d.CLIENT_REF
            FROM CHANGETABLE(CHANGES dbo.CLIENT, @LastSyncVersion) AS d
            WHERE d.SYS_CHANGE_OPERATION = 'D'
              AND d.SYS_CHANGE_VERSION  <= @ToVersion
        ) AS x
          ON t.UUID = x.CLIENT_REF;

        DECLARE @TotalDeleted int = (SELECT COUNT(*) FROM #DelLog);

        IF @EmitInfo = 1
            RAISERROR('Deleted due to CLIENT deletes: %d', 0, 1, @TotalDeleted) WITH NOWAIT;

        -- Advance watermark + summary
        UPDATE dbo.CT_Watermark
          SET LastSyncVersion = @ToVersion,
              LastSyncTime    = SYSUTCDATETIME()
        WHERE ProcessName = @Process;

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

        IF @EmitInfo = 1
        BEGIN
            RAISERROR('Clients incremental sync complete.', 0, 1) WITH NOWAIT;
            RAISERROR('  Inserted = %d', 0, 1, @TotalInserted) WITH NOWAIT;
            RAISERROR('  Updated  = %d', 0, 1, @TotalUpdated) WITH NOWAIT;
            RAISERROR('  Deleted  = %d', 0, 1, @TotalDeleted) WITH NOWAIT;
        END;

        IF @ReturnSummaryRow = 1
            SELECT N'Incremental' AS Stage, @Summary AS Summary;

        IF @lockHeld = 1
            EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;

        RETURN 0;
    END TRY
    BEGIN CATCH
        IF @lockHeld = 1
            EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;

        DECLARE @msg nvarchar(4000) = ERROR_MESSAGE();

        IF @EmitInfo = 1
            RAISERROR('usp_Sync_Clients_Incremental failed: %s', 16, 1, @msg);

        SET @Summary = CONCAT(N'Clients incremental failed: ', @msg);

        IF @ReturnSummaryRow = 1
            SELECT N'Incremental' AS Stage, @Summary AS Summary;

        RETURN -50001;
    END CATCH;
END;
GO
