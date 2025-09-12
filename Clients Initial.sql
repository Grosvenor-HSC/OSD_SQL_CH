USE [DOM_LIVE];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Sync_Clients_Initial
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Process       sysname      = N'Clients';
    DECLARE @RunStartedAt  datetime2(3) = SYSUTCDATETIME();
    DECLARE @StartIso      varchar(33)  = CONVERT(varchar(33), @RunStartedAt, 126);
    DECLARE @BaselineFrom  bigint;
    DECLARE @LockResource  sysname      = N'DOM_LIVE:Sync:Clients';
    DECLARE @lockResult    int;
    DECLARE @lockHeld      bit          = 0;

    -- applock
    EXEC @lockResult = sys.sp_getapplock
        @Resource=@LockResource, @LockMode='Exclusive',
        @LockOwner='Session', @DbPrincipal='dbo', @LockTimeout=600000;
    IF @lockResult NOT IN (0,1)
    BEGIN
        SELECT 'Initial' AS Stage, CAST(N'Clients initial failed: could not acquire applock.' AS nvarchar(4000)) AS Summary;
        RETURN -1;
    END
    SET @lockHeld = 1;

    BEGIN TRY
        -- Preconditions: CT at DB + on CLIENT (incremental depends on it)
        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_databases WHERE database_id = DB_ID())
            RAISERROR('Change Tracking is not enabled at the database level.', 16, 1);
        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.CLIENT'))
            RAISERROR('Change Tracking is not enabled on dbo.CLIENT.', 16, 1);

        -- Snapshot at START
        SET @BaselineFrom = CHANGE_TRACKING_CURRENT_VERSION();

        -- Watermark seed/refresh
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
        IF OBJECT_ID('dbo.tbl_Clients','U') IS NOT NULL
            DROP TABLE dbo.tbl_Clients;

        CREATE TABLE dbo.tbl_Clients (
            BranchReference      VARCHAR(50) NOT NULL,
            ClientReference      VARCHAR(50) NOT NULL,
            ClientCaseNo         VARCHAR(50) NULL,
            ClientDateofBirth    DATE NULL,
            Address1             VARCHAR(255) NULL,
            Address2             VARCHAR(255) NULL,
            Address3             VARCHAR(255) NULL,
            Address4             VARCHAR(255) NULL,
            ClientPostcode       VARCHAR(20) NULL,
            Outward_Code         VARCHAR(10) NULL,
            ClientForenames      VARCHAR(100) NULL,
            ClientSurname        VARCHAR(100) NULL,
            EMAIL                VARCHAR(255) NULL,
            TEL_NO1              VARCHAR(50) NULL,
            TEL_NO2              VARCHAR(50) NULL,
            ClientTitle          VARCHAR(50) NULL,
            ClientGroup          VARCHAR(50) NULL,
            ClientCode           VARCHAR(50) NULL,
            KeySafeYN            VARCHAR(5) NULL,
            KeySafe1             VARCHAR(50) NULL,
            KeySafe2             VARCHAR(50) NULL,
            KeySafe3             VARCHAR(50) NULL,
            ClientGender         VARCHAR(20) NULL,
            ClientStartDate      DATE NULL,
            ClientLeaveDate      DATE NULL,
            ClientStatus         VARCHAR(20) NULL,
            ClientDisability     VARCHAR(100) NULL,
            ClientDisability2    VARCHAR(100) NULL,
            ClientDisability3    VARCHAR(100) NULL,
            ClientEthnicity      VARCHAR(100) NULL,
            ClientLeftReason     VARCHAR(100) NULL,
            ClientReligion       VARCHAR(100) NULL,
            ClientLocation       VARCHAR(100) NULL,
            ClientType           VARCHAR(100) NULL,
            ExternalReference    VARCHAR(100) NULL,
            CNTA_DET_REF         INT NULL,
            LeftReason           VARCHAR(100) NULL,
            CreatedAtUTC         datetime2(3) NOT NULL CONSTRAINT DF_tbl_Clients_CreatedAtUTC DEFAULT SYSUTCDATETIME(),
            UpdatedAtUTC         datetime2(3) NOT NULL CONSTRAINT DF_tbl_Clients_UpdatedAtUTC DEFAULT SYSUTCDATETIME(),
            CONSTRAINT PK_tbl_Clients_ClientReference PRIMARY KEY CLUSTERED (ClientReference)
        );

        -- Baseline load
        ;WITH BaseClient AS (
            SELECT
                -- Branch mapping: 1970000043 => Southampton/Portsmouth by location; else by OldBranchUID
                COALESCE(CAST(bname.BranchUID AS varchar(50)),
                         CAST(bold.BranchUID  AS varchar(50)))                                   AS BranchReference,

                CAST(C.CLIENT_REF AS varchar(50))                                              AS ClientReference,
                C.CASE_NO                                                                         AS ClientCaseNo,
                C.DATEOFBIRTH                                                                     AS ClientDateofBirth,

                LTRIM(RTRIM(CHD.ADDRESS1))                                                       AS Address1,
                LTRIM(RTRIM(CHD.ADDRESS2))                                                       AS Address2,
                LTRIM(RTRIM(CHD.ADDRESS3))                                                       AS Address3,
                LTRIM(RTRIM(CHD.ADDRESS4))                                                       AS Address4,

                CHD.POSTCODE                                                                      AS ClientPostcode,
                CASE WHEN CHD.POSTCODE IS NULL
                     THEN NULL
                     ELSE LEFT(CHD.POSTCODE, CHARINDEX(' ', CHD.POSTCODE + ' ') - 1)
                END                                                                               AS Outward_Code,

                CHD.FORENAMES                                                                     AS ClientForenames,
                CHD.SURNAME                                                                       AS ClientSurname,
                CHD.EMAIL,
                CHD.TEL_NO1,
                CHD.TEL_NO2,

                CTL.DESCRIPTION                                                                   AS ClientTitle,
                CG.DESCRIPTION                                                                    AS ClientGroup,
                C.CLIENT_CODE                                                                     AS ClientCode,
                C.KEYSAFE                                                                         AS KeySafeYN,
                C.KEYSAFENO                                                                       AS KeySafe1,
                C.KEYSAFE2                                                                        AS KeySafe2,
                C.KEYSAFE3                                                                        AS KeySafe3,

                CASE WHEN C.SEX = 'M' THEN 'Male'
                     WHEN C.SEX = 'F' THEN 'Female'
                     ELSE 'Other' END                                                             AS ClientGender,

                C.START_DATE                                                                      AS ClientStartDate,
                C.LEFT_DATE                                                                       AS ClientLeaveDate,

                CSE.DESCRIPTION                                                                   AS ClientStatus,
                CD1.DESCRIPTION                                                                   AS ClientDisability,
                CD2.DESCRIPTION                                                                   AS ClientDisability2,
                CD3.DESCRIPTION                                                                   AS ClientDisability3,
                CE.DESCRIPTION                                                                    AS ClientEthnicity,
                CLR.DESCRIPTION                                                                   AS ClientLeftReason,
                CR.DESCRIPTION                                                                    AS ClientReligion,
                CL.DESCRIPTION                                                                    AS ClientLocation,
                CTY.DESCRIPTION                                                                   AS ClientType,

                C.EXTCLREF                                                                        AS ExternalReference,
                C.CNTA_DET_REF,
                LR.DESCRIPTION                                                                     AS LeftReason
            FROM dbo.CLIENT AS C
            LEFT JOIN dbo.CONTACT_DT  AS CDT ON CDT.CNTA_DET_REF = C.CNTA_DET_REF
            LEFT JOIN dbo.CONTACT_HD  AS CHD ON CHD.CONTACT_REF  = CDT.CONTACT_REF

            LEFT JOIN dbo.CHSYSDEC AS CTL  ON CHD.TITLE      = CTL.DECODE_REF
            LEFT JOIN dbo.CHSYSDEC AS CG   ON C.CARE_GRP_REF = CG.DECODE_REF
            LEFT JOIN dbo.CHSYSDEC AS CD1  ON C.DISAB_REF    = CD1.DECODE_REF
            LEFT JOIN dbo.CHSYSDEC AS CD2  ON C.DISAB_REF2   = CD2.DECODE_REF
            LEFT JOIN dbo.CHSYSDEC AS CD3  ON C.DISAB_REF3   = CD3.DECODE_REF
            LEFT JOIN dbo.CHSYSDEC AS CE   ON C.ETHNICITY    = CE.DECODE_REF
            LEFT JOIN dbo.CHSYSDEC AS CLR  ON C.LEFTRES_REF  = CLR.DECODE_REF
            LEFT JOIN dbo.CHSYSDEC AS LR   ON C.LEFTRES_REF  = LR.DECODE_REF
            LEFT JOIN dbo.CHSYSDEC AS CR   ON C.RELORG_REF   = CR.DECODE_REF
            LEFT JOIN dbo.CHSYSDEC AS CTY  ON C.CLIENT_TYPE  = CTY.DECODE_REF
            LEFT JOIN dbo.CHSYSDEC AS CL   ON C.LOCATION_REF = CL.DECODE_REF
            LEFT JOIN dbo.CHSYSDEC AS CSE  ON C.STATUS       = CSE.DECODE_REF

            OUTER APPLY (
                SELECT CASE 
                         WHEN C.GS_REF = '1970000043' AND CL.DESCRIPTION = 'Southampton' THEN 'Southampton'
                         WHEN C.GS_REF = '1970000043' AND (CL.DESCRIPTION <> 'Southampton' OR CL.DESCRIPTION IS NULL) THEN 'Portsmouth'
                         ELSE NULL
                       END AS BranchName
            ) pick
            LEFT JOIN dbo.tbl_Branch AS bname ON pick.BranchName IS NOT NULL AND bname.BranchName = pick.BranchName
            LEFT JOIN dbo.tbl_Branch AS bold  ON pick.BranchName IS NULL AND CAST(bold.OldBranchUID AS varchar(50)) = CAST(C.GS_REF AS varchar(50))
        )
        INSERT INTO dbo.tbl_Clients (
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
            ExternalReference, CNTA_DET_REF, LeftReason,
            @RunStartedAt, @RunStartedAt
        FROM BaseClient
        WHERE BranchReference IS NOT NULL;

        DECLARE @Inserted int = @@ROWCOUNT;

        -- Indexes after load
        CREATE NONCLUSTERED INDEX IX_tbl_Clients_BranchReference ON dbo.tbl_Clients (BranchReference);
        CREATE NONCLUSTERED INDEX IX_tbl_Clients_StartLeave      ON dbo.tbl_Clients (ClientStartDate, ClientLeaveDate);

        -- Initial summary
        DECLARE @EndInitialUTC datetime2(3) = SYSUTCDATETIME();
        DECLARE @EndInitialIso varchar(33)  = CONVERT(varchar(33), @EndInitialUTC, 126);
        DECLARE @InitialMsg nvarchar(4000) =
            CONCAT(N'Clients initial started ', @StartIso,
                   N' UTC; ended ', @EndInitialIso,
                   N' UTC; baseline inserted ', @Inserted, N' rows.');

        -- Quiet incremental sweep
        DECLARE @IncrMsg nvarchar(4000) = N'Incremental skipped.';
        IF OBJECT_ID('dbo.usp_Sync_Clients_Incremental','P') IS NOT NULL
        BEGIN
            DECLARE @rc int;
            EXEC @rc = dbo.usp_Sync_Clients_Incremental
                @ChunkSize=100000, @LockTimeoutMs=600000, @UseAppLock=0,
                @EmitInfo=0, @Summary=@IncrMsg OUTPUT;
            IF (@rc < 0)
                SET @IncrMsg = CONCAT(@IncrMsg, N' (rc=', @rc, N')');
        END

        -- Return two rows
        SELECT 'Initial' AS Stage,     @InitialMsg AS Summary
        UNION ALL
        SELECT 'Incremental',          @IncrMsg;

        IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner='Session', @DbPrincipal='dbo';
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner='Session', @DbPrincipal='dbo';
        DECLARE @msg nvarchar(4000)=ERROR_MESSAGE();
        SELECT 'Initial' AS Stage, CAST(CONCAT(N'Clients initial failed: ', @msg) AS nvarchar(4000)) AS Summary;
        RETURN -50001;
    END CATCH
END
GO
