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
    @EmitInfo          bit  = 1,                         -- verbose RAISERROR output
    @Summary           nvarchar(4000) = NULL OUTPUT,     -- one-line summary
    @ReturnSummaryRow  bit  = 1                          -- <— NEW: return Stage/Summary row
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

    -- 0) Concurrency
    DECLARE @LockResource sysname = N'DOM_LIVE:Sync:Clients';
    DECLARE @LockOwner   sysname = N'Session';
    DECLARE @DbPrincipal sysname = N'dbo';
    DECLARE @lockResult  int;
    DECLARE @lockHeld    bit = 0;

    IF @UseAppLock = 1
    BEGIN
        EXEC @lockResult = sys.sp_getapplock
            @Resource=@LockResource, @LockMode='Exclusive',
            @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal,
            @LockTimeout=@LockTimeoutMs;

        IF @lockResult NOT IN (0,1)
        BEGIN
            IF @EmitInfo=1 RAISERROR('Could not acquire %s (sp_getapplock rc=%d).',16,1,@LockResource,@lockResult);
            SET @Summary = N'Clients incremental failed: could not acquire applock.';
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            RETURN @lockResult;
        END
        SET @lockHeld = 1;
    END

    BEGIN TRY
        -- 1) Preconditions & watermark
        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_databases WHERE database_id = DB_ID())
        BEGIN
            IF @EmitInfo=1 RAISERROR('Change Tracking is not enabled at the database level.', 16, 1);
            SET @Summary = N'Clients incremental failed: CT not enabled at DB level.';
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;
            RETURN -100;
        END

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

        DECLARE @ToVersion bigint = CHANGE_TRACKING_CURRENT_VERSION();

        -- Min valid across referenced tables
        DECLARE @MinValid bigint =
        (
            SELECT MAX(CHANGE_TRACKING_MIN_VALID_VERSION(object_id))
            FROM sys.change_tracking_tables
            WHERE object_id IN (
                OBJECT_ID(N'dbo.CLIENT'),
                OBJECT_ID(N'dbo.CONTACT_DT'),
                OBJECT_ID(N'dbo.CONTACT_HD'),
                OBJECT_ID(N'dbo.CHSYSDEC')
            )
        );

        IF @MinValid IS NOT NULL AND @LastSyncVersion < @MinValid
        BEGIN
            IF @EmitInfo=1 RAISERROR('Watermark (%I64d) < CT min valid (%I64d). Re-baseline required.',16,1,@LastSyncVersion,@MinValid);
            SET @Summary = CONCAT(N'Clients incremental failed: watermark ', @LastSyncVersion, N' < min valid ', @MinValid, N' (re-baseline).');
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;
            RETURN -200;
        END

        IF @EmitInfo=1
        BEGIN
            RAISERROR('Clients CT incremental window:', 0, 1) WITH NOWAIT;
            RAISERROR('  From = %I64d', 0, 1, @LastSyncVersion) WITH NOWAIT;
            RAISERROR('  To   = %I64d', 0, 1, @ToVersion) WITH NOWAIT;
        END

        -- 2) Build changed set
        IF OBJECT_ID('tempdb..#Changed') IS NOT NULL DROP TABLE #Changed;
        CREATE TABLE #Changed (ClientRef varchar(50) NOT NULL PRIMARY KEY);

        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.CLIENT'))
        BEGIN
            IF @EmitInfo=1 RAISERROR('Change Tracking is not enabled on dbo.CLIENT. Cannot proceed.',16,1);
            SET @Summary = N'Clients incremental failed: CT not enabled on CLIENT.';
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;
            RETURN -210;
        END

        INSERT INTO #Changed(ClientRef)
        SELECT DISTINCT CAST(c.CLIENT_REF AS varchar(50))
        FROM CHANGETABLE(CHANGES dbo.CLIENT, @LastSyncVersion) ct
        JOIN dbo.CLIENT c ON c.CLIENT_REF = ct.CLIENT_REF
        WHERE ct.SYS_CHANGE_VERSION <= @ToVersion;

        IF EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.CONTACT_DT'))
        BEGIN
            INSERT INTO #Changed(ClientRef)
            SELECT DISTINCT CAST(c.CLIENT_REF AS varchar(50))
            FROM CHANGETABLE(CHANGES dbo.CONTACT_DT, @LastSyncVersion) x
            JOIN dbo.CLIENT c ON c.CNTA_DET_REF = x.CNTA_DET_REF
            WHERE x.SYS_CHANGE_VERSION <= @ToVersion
              AND NOT EXISTS (SELECT 1 FROM #Changed z WHERE z.ClientRef = CAST(c.CLIENT_REF AS varchar(50)));
        END

        IF EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.CONTACT_HD'))
        BEGIN
            INSERT INTO #Changed(ClientRef)
            SELECT DISTINCT CAST(c.CLIENT_REF AS varchar(50))
            FROM CHANGETABLE(CHANGES dbo.CONTACT_HD, @LastSyncVersion) h
            JOIN dbo.CONTACT_DT dt ON dt.CONTACT_REF = h.CONTACT_REF
            JOIN dbo.CLIENT    c  ON c.CNTA_DET_REF = dt.CNTA_DET_REF
            WHERE h.SYS_CHANGE_VERSION <= @ToVersion
              AND NOT EXISTS (SELECT 1 FROM #Changed z WHERE z.ClientRef = CAST(c.CLIENT_REF AS varchar(50)));
        END

        IF EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.CHSYSDEC'))
        BEGIN
            INSERT INTO #Changed(ClientRef)
            SELECT DISTINCT CAST(c.CLIENT_REF AS varchar(50))
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
              AND NOT EXISTS (SELECT 1 FROM #Changed z WHERE z.ClientRef = CAST(c.CLIENT_REF AS varchar(50)));

            INSERT INTO #Changed(ClientRef)
            SELECT DISTINCT CAST(c.CLIENT_REF AS varchar(50))
            FROM CHANGETABLE(CHANGES dbo.CHSYSDEC, @LastSyncVersion) d
            JOIN dbo.CONTACT_HD  h  ON h.TITLE        = d.DECODE_REF
            JOIN dbo.CONTACT_DT  dt ON dt.CONTACT_REF = h.CONTACT_REF
            JOIN dbo.CLIENT      c  ON c.CNTA_DET_REF = dt.CNTA_DET_REF
            WHERE d.SYS_CHANGE_VERSION <= @ToVersion
              AND NOT EXISTS (SELECT 1 FROM #Changed z WHERE z.ClientRef = CAST(c.CLIENT_REF AS varchar(50)));
        END

        DECLARE @ToProcess int = (SELECT COUNT(*) FROM #Changed);
        IF @EmitInfo=1 RAISERROR('Changed clients to process: %d', 0, 1, @ToProcess) WITH NOWAIT;

        IF @ToProcess = 0
        BEGIN
            UPDATE dbo.CT_Watermark
              SET LastSyncVersion = @ToVersion, LastSyncTime = SYSUTCDATETIME()
            WHERE ProcessName = @Process;

            SET @EndUTC = SYSUTCDATETIME();
            SET @EndIso = CONVERT(varchar(33), @EndUTC, 126);
            SET @DurationSec = DATEDIFF(SECOND, @RunStartedAt, @EndUTC);

            SET @Summary = CONCAT(
                N'Clients incremental started ', @StartIso, N' UTC; ended ', @EndIso,
                N' UTC; inserted 0, updated 0, deleted 0; advanced watermark to ',
                CAST(@ToVersion AS nvarchar(30)), N'; duration=', @DurationSec, N' sec.'
            );

            IF @EmitInfo=1 RAISERROR('No changes. Watermark advanced.', 0, 1) WITH NOWAIT;
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;

            IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;
            RETURN 0;
        END

        -- 3) Chunked upsert
        DECLARE @TotalInserted bigint = 0, @TotalUpdated bigint = 0;

        WHILE EXISTS (SELECT 1 FROM #Changed)
        BEGIN
            IF OBJECT_ID('tempdb..#Next') IS NOT NULL DROP TABLE #Next;
            CREATE TABLE #Next (ClientRef varchar(50) NOT NULL PRIMARY KEY);

            INSERT INTO #Next(ClientRef)
            SELECT TOP (@ChunkSize) ClientRef
            FROM #Changed
            ORDER BY ClientRef;

            IF OBJECT_ID('tempdb..#ActLog') IS NOT NULL DROP TABLE #ActLog;
            CREATE TABLE #ActLog(Action nvarchar(10) NOT NULL);

            ;WITH BaseClient AS
            (
              SELECT
                COALESCE(CAST(bname.BranchUID AS varchar(50)),
                         CAST(bold.BranchUID  AS varchar(50)))                  AS BranchReference,

                CAST(C.CLIENT_REF AS varchar(50))                               AS ClientReference,
                C.CASE_NO                                                       AS ClientCaseNo,
                C.DATEOFBIRTH                                                   AS ClientDateofBirth,

                LTRIM(RTRIM(CHD.ADDRESS1))                                      AS Address1,
                LTRIM(RTRIM(CHD.ADDRESS2))                                      AS Address2,
                LTRIM(RTRIM(CHD.ADDRESS3))                                      AS Address3,
                LTRIM(RTRIM(CHD.ADDRESS4))                                      AS Address4,

                CHD.POSTCODE                                                    AS ClientPostcode,
                CASE WHEN CHD.POSTCODE IS NULL
                     THEN NULL
                     ELSE LEFT(CHD.POSTCODE, CHARINDEX(' ', CHD.POSTCODE + ' ') - 1)
                END                                                             AS Outward_Code,

                CHD.FORENAMES                                                   AS ClientForenames,
                CHD.SURNAME                                                     AS ClientSurname,
                CHD.EMAIL,
                CHD.TEL_NO1,
                CHD.TEL_NO2,

                CTL.DESCRIPTION                                                 AS ClientTitle,
                CG.DESCRIPTION                                                  AS ClientGroup,
                C.CLIENT_CODE                                                   AS ClientCode,
                C.KEYSAFE                                                       AS KeySafeYN,
                C.KEYSAFENO                                                     AS KeySafe1,
                C.KEYSAFE2                                                      AS KeySafe2,
                C.KEYSAFE3                                                      AS KeySafe3,

                CASE WHEN C.SEX = 'M' THEN 'Male'
                     WHEN C.SEX = 'F' THEN 'Female'
                     ELSE 'Other'
                END                                                             AS ClientGender,

                C.START_DATE                                                    AS ClientStartDate,
                C.LEFT_DATE                                                     AS ClientLeaveDate,

                CSE.DESCRIPTION                                                 AS ClientStatus,
                CD1.DESCRIPTION                                                 AS ClientDisability,
                CD2.DESCRIPTION                                                 AS ClientDisability2,
                CD3.DESCRIPTION                                                 AS ClientDisability3,
                CE.DESCRIPTION                                                  AS ClientEthnicity,
                CLR.DESCRIPTION                                                 AS ClientLeftReason,
                CR.DESCRIPTION                                                  AS ClientReligion,
                CL.DESCRIPTION                                                  AS ClientLocation,
                CTY.DESCRIPTION                                                 AS ClientType,

                C.EXTCLREF                                                      AS ExternalReference,
                C.CNTA_DET_REF,
                LR.DESCRIPTION                                                  AS LeftReason
              FROM dbo.CLIENT AS C
              JOIN #Next n                                 ON n.ClientRef   = CAST(C.CLIENT_REF AS varchar(50))

              LEFT JOIN dbo.CONTACT_DT  AS CDT             ON CDT.CNTA_DET_REF = C.CNTA_DET_REF
              LEFT JOIN dbo.CONTACT_HD  AS CHD             ON CHD.CONTACT_REF  = CDT.CONTACT_REF

              LEFT JOIN dbo.CHSYSDEC AS CTL                ON CHD.TITLE      = CTL.DECODE_REF
              LEFT JOIN dbo.CHSYSDEC AS CG                 ON C.CARE_GRP_REF = CG.DECODE_REF
              LEFT JOIN dbo.CHSYSDEC AS CD1                ON C.DISAB_REF    = CD1.DECODE_REF
              LEFT JOIN dbo.CHSYSDEC AS CD2                ON C.DISAB_REF2   = CD2.DECODE_REF
              LEFT JOIN dbo.CHSYSDEC AS CD3                ON C.DISAB_REF3   = CD3.DECODE_REF
              LEFT JOIN dbo.CHSYSDEC AS CE                 ON C.ETHNICITY    = CE.DECODE_REF
              LEFT JOIN dbo.CHSYSDEC AS CLR                ON C.LEFTRES_REF  = CLR.DECODE_REF
              LEFT JOIN dbo.CHSYSDEC AS LR                 ON C.LEFTRES_REF  = LR.DECODE_REF
              LEFT JOIN dbo.CHSYSDEC AS CR                 ON C.RELORG_REF   = CR.DECODE_REF
              LEFT JOIN dbo.CHSYSDEC AS CTY                ON C.CLIENT_TYPE  = CTY.DECODE_REF
              LEFT JOIN dbo.CHSYSDEC AS CL                 ON C.LOCATION_REF = CL.DECODE_REF
              LEFT JOIN dbo.CHSYSDEC AS CSE                ON C.STATUS       = CSE.DECODE_REF

              OUTER APPLY (
                 SELECT CASE 
                          WHEN C.GS_REF = '1970000043' AND CL.DESCRIPTION = 'Southampton' THEN 'Southampton'
                          WHEN C.GS_REF = '1970000043' AND (CL.DESCRIPTION <> 'Southampton' OR CL.DESCRIPTION IS NULL) THEN 'Portsmouth'
                          ELSE NULL
                        END AS BranchName
              ) pick
              LEFT JOIN dbo.tbl_Branch AS bname           ON pick.BranchName IS NOT NULL AND bname.BranchName = pick.BranchName
              LEFT JOIN dbo.tbl_Branch AS bold            ON pick.BranchName IS NULL    AND CAST(bold.OldBranchUID AS varchar(50)) = CAST(C.GS_REF AS varchar(50))
            )
            MERGE dbo.tbl_Clients AS tgt
            USING (
                SELECT
                    BranchReference, ClientReference, ClientCaseNo, ClientDateofBirth,
                    Address1, Address2, Address3, Address4,
                    ClientPostcode, Outward_Code,
                    ClientForenames, ClientSurname, EMAIL, TEL_NO1, TEL_NO2,
                    ClientTitle, ClientGroup, ClientCode,
                    KeySafeYN, KeySafe1, KeySafe2, KeySafe3,
                    ClientGender, ClientStartDate, ClientLeaveDate, ClientStatus,
                    ClientDisability, ClientDisability2, ClientDisability3, ClientEthnicity,
                    ClientLeftReason, ClientReligion, ClientLocation, ClientType,
                    ExternalReference, CNTA_DET_REF, LeftReason
                FROM BaseClient
                WHERE BranchReference IS NOT NULL
            ) AS src
                ON tgt.ClientReference = src.ClientReference
            WHEN MATCHED THEN
                UPDATE SET
                    tgt.BranchReference      = src.BranchReference,
                    tgt.ClientCaseNo         = src.ClientCaseNo,
                    tgt.ClientDateofBirth    = src.ClientDateofBirth,
                    tgt.Address1             = src.Address1,
                    tgt.Address2             = src.Address2,
                    tgt.Address3             = src.Address3,
                    tgt.Address4             = src.Address4,
                    tgt.ClientPostcode       = src.ClientPostcode,
                    tgt.Outward_Code         = src.Outward_Code,
                    tgt.ClientForenames      = src.ClientForenames,
                    tgt.ClientSurname        = src.ClientSurname,
                    tgt.EMAIL                = src.EMAIL,
                    tgt.TEL_NO1              = src.TEL_NO1,
                    tgt.TEL_NO2              = src.TEL_NO2,
                    tgt.ClientTitle          = src.ClientTitle,
                    tgt.ClientGroup          = src.ClientGroup,
                    tgt.ClientCode           = src.ClientCode,
                    tgt.KeySafeYN            = src.KeySafeYN,
                    tgt.KeySafe1             = src.KeySafe1,
                    tgt.KeySafe2             = src.KeySafe2,
                    tgt.KeySafe3             = src.KeySafe3,
                    tgt.ClientGender         = src.ClientGender,
                    tgt.ClientStartDate      = src.ClientStartDate,
                    tgt.ClientLeaveDate      = src.ClientLeaveDate,
                    tgt.ClientStatus         = src.ClientStatus,
                    tgt.ClientDisability     = src.ClientDisability,
                    tgt.ClientDisability2    = src.ClientDisability2,
                    tgt.ClientDisability3    = src.ClientDisability3,
                    tgt.ClientEthnicity      = src.ClientEthnicity,
                    tgt.ClientLeftReason     = src.ClientLeftReason,
                    tgt.ClientReligion       = src.ClientReligion,
                    tgt.ClientLocation       = src.ClientLocation,
                    tgt.ClientType           = src.ClientType,
                    tgt.ExternalReference    = src.ExternalReference,
                    tgt.CNTA_DET_REF         = src.CNTA_DET_REF,
                    tgt.LeftReason           = src.LeftReason,
                    tgt.UpdatedAtUTC         = @RunStartedAt
            WHEN NOT MATCHED BY TARGET THEN
                INSERT (
                    BranchReference, ClientReference, ClientCaseNo, ClientDateofBirth,
                    Address1, Address2, Address3, Address4,
                    ClientPostcode, Outward_Code,
                    ClientForenames, ClientSurname, EMAIL, TEL_NO1, TEL_NO2,
                    ClientTitle, ClientGroup, ClientCode,
                    KeySafeYN, KeySafe1, KeySafe2, KeySafe3,
                    ClientGender, ClientStartDate, ClientLeaveDate, ClientStatus,
                    ClientDisability, ClientDisability2, ClientDisability3, ClientEthnicity,
                    ClientLeftReason, ClientReligion, ClientLocation, ClientType,
                    ExternalReference, CNTA_DET_REF, LeftReason,
                    CreatedAtUTC, UpdatedAtUTC
                )
                VALUES (
                    src.BranchReference, src.ClientReference, src.ClientCaseNo, src.ClientDateofBirth,
                    src.Address1, src.Address2, src.Address3, src.Address4,
                    src.ClientPostcode, src.Outward_Code,
                    src.ClientForenames, src.ClientSurname, src.EMAIL, src.TEL_NO1, src.TEL_NO2,
                    src.ClientTitle, src.ClientGroup, src.ClientCode,
                    src.KeySafeYN, src.KeySafe1, src.KeySafe2, src.KeySafe3,
                    src.ClientGender, src.ClientStartDate, src.ClientLeaveDate, src.ClientStatus,
                    src.ClientDisability, src.ClientDisability2, src.ClientDisability3, src.ClientEthnicity,
                    src.ClientLeftReason, src.ClientReligion, src.ClientLocation, src.ClientType,
                    src.ExternalReference, src.CNTA_DET_REF, src.LeftReason,
                    @RunStartedAt, @RunStartedAt
                )
            OUTPUT $action INTO #ActLog(Action);

            DECLARE @i int = 0, @u int = 0;
            SELECT @i = SUM(CASE WHEN Action='INSERT' THEN 1 ELSE 0 END),
                   @u = SUM(CASE WHEN Action='UPDATE' THEN 1 ELSE 0 END)
            FROM #ActLog;

            SET @TotalInserted += ISNULL(@i,0);
            SET @TotalUpdated  += ISNULL(@u,0);

            IF @EmitInfo=1
                RAISERROR('Clients chunk upserted: inserted=%d updated=%d (running %d / %d)', 0, 1, @i, @u, @TotalInserted, @TotalUpdated) WITH NOWAIT;

            DELETE c
            FROM #Changed c
            JOIN #Next n ON n.ClientRef = c.ClientRef;
        END

        -- 4) Deletes from CLIENT
        IF OBJECT_ID('tempdb..#DelLog') IS NOT NULL DROP TABLE #DelLog;
        CREATE TABLE #DelLog(ClientRef varchar(50) NOT NULL);

        DELETE t
        OUTPUT DELETED.ClientReference INTO #DelLog(ClientRef)
        FROM dbo.tbl_Clients t
        JOIN (
            SELECT d.CLIENT_REF
            FROM CHANGETABLE(CHANGES dbo.CLIENT, @LastSyncVersion) d
            WHERE d.SYS_CHANGE_OPERATION = 'D'
              AND d.SYS_CHANGE_VERSION   <= @ToVersion
        ) x ON t.ClientReference = CAST(x.CLIENT_REF AS varchar(50));

        DECLARE @TotalDeleted int = (SELECT COUNT(*) FROM #DelLog);
        IF @EmitInfo=1 RAISERROR('Deleted due to CLIENT deletes: %d', 0, 1, @TotalDeleted) WITH NOWAIT;

        -- 5) Advance watermark + summary
        UPDATE dbo.CT_Watermark
          SET LastSyncVersion=@ToVersion, LastSyncTime=SYSUTCDATETIME()
        WHERE ProcessName=@Process;

        SET @EndUTC = SYSUTCDATETIME();
        SET @EndIso = CONVERT(varchar(33), @EndUTC, 126);
        SET @DurationSec = DATEDIFF(SECOND, @RunStartedAt, @EndUTC);

        SET @Summary = CONCAT(
            N'Clients incremental started ', @StartIso, N' UTC; ended ', @EndIso,
            N' UTC; inserted ', CAST(@TotalInserted AS nvarchar(20)),
            N', updated ', CAST(@TotalUpdated AS nvarchar(20)),
            N', deleted ', CAST(@TotalDeleted AS nvarchar(20)),
            N'; advanced watermark to ', CAST(@ToVersion AS nvarchar(30)),
            N'; duration=', CAST(@DurationSec AS nvarchar(20)), N' sec.'
        );

        IF @EmitInfo=1
        BEGIN
            RAISERROR('Clients incremental sync complete.', 0, 1) WITH NOWAIT;
            RAISERROR('  Inserted = %d', 0, 1, @TotalInserted) WITH NOWAIT;
            RAISERROR('  Updated  = %d', 0, 1, @TotalUpdated) WITH NOWAIT;
            RAISERROR('  Deleted  = %d', 0, 1, @TotalDeleted) WITH NOWAIT;
        END

        IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;

        IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;
        DECLARE @msg nvarchar(4000)=ERROR_MESSAGE();
        DECLARE @num int=ERROR_NUMBER(), @sev int=ERROR_SEVERITY(), @st int=ERROR_STATE(), @lin int=ERROR_LINE(), @proc sysname=ERROR_PROCEDURE();
        DECLARE @procName sysname = ISNULL(@proc, N'<adhoc>');
        IF @EmitInfo=1 RAISERROR('usp_Sync_Clients_Incremental failed (%d, sev %d, state %d) at %s line %d: %s',16,1,@num,@sev,@st,@procName,@lin,@msg);
        SET @Summary = CONCAT(N'Clients incremental failed: ', @msg);
        IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
        RETURN -50001;
    END CATCH
END
GO
