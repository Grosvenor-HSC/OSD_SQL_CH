/*
Purpose:
    Perform the initial full load of client records into the staging clients table.
    Establishes the baseline client dataset for all downstream processing.

Source:
    dbo.CLIENT (+ CONTACT_* + CHSYSDEC) + dbo.tbl_Branch

Target:
    dbo.tbl_Clients

Run type:
    Initial (full backfill)

Safe to re-run:
    NOT in production (destructive). This procedure drops/recreates tbl_Clients.
*/

USE [DOM_LIVE];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Sync_Clients_Initial
    @Summary nvarchar(4000) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Process       sysname      = N'Clients';
    DECLARE @RunStartedAt  datetime2(3) = SYSUTCDATETIME();
    DECLARE @StartIso      varchar(33)  = CONVERT(varchar(33), @RunStartedAt, 126);
    DECLARE @BaselineFrom  bigint;

    /* Concurrency */
    DECLARE @LockResource  sysname = N'DOM_LIVE:Sync:Clients';
    DECLARE @LockOwner     sysname = N'Session';
    DECLARE @DbPrincipal   sysname = N'dbo';
    DECLARE @lockResult    int;
    DECLARE @lockHeld      bit = 0;

    EXEC @lockResult = sys.sp_getapplock
        @Resource    = @LockResource,
        @LockMode    = 'Exclusive',
        @LockOwner   = @LockOwner,
        @DbPrincipal = @DbPrincipal,
        @LockTimeout = 600000;

    IF @lockResult NOT IN (0,1)
    BEGIN
        SET @Summary = N'Clients initial failed: could not acquire applock.';
        SELECT [Stage]=N'Initial', [Summary]=@Summary;
        RETURN -1;
    END;
    SET @lockHeld = 1;

    BEGIN TRY
        /* Preconditions */
        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_databases WHERE database_id = DB_ID())
            RAISERROR('Change Tracking is not enabled at the database level.', 16, 1);

        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.CLIENT'))
            RAISERROR('Change Tracking is not enabled on dbo.CLIENT.', 16, 1);

        IF OBJECT_ID(N'dbo.tbl_Branch', N'U') IS NULL
            RAISERROR('Missing dependency dbo.tbl_Branch. Run Branch initial first.', 16, 1);

        /* Fence CT window */
        SET @BaselineFrom = CHANGE_TRACKING_CURRENT_VERSION();

        /* Watermark upsert */
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
            UPDATE SET LastSyncVersion = @BaselineFrom,
                       LastSyncTime    = SYSUTCDATETIME()
        WHEN NOT MATCHED THEN
            INSERT (ProcessName, LastSyncVersion, LastSyncTime)
            VALUES (s.ProcessName, @BaselineFrom, SYSUTCDATETIME());

        /* ------------------------------------------------------------
           Hard reset target: drop view/synonym/table then recreate.
           Fail loudly if we can't drop due to dependencies.
           ------------------------------------------------------------ */
        DECLARE @ddl nvarchar(max) = N'
SET NOCOUNT ON;

IF OBJECT_ID(N''dbo.tbl_Clients'', N''V'') IS NOT NULL
    DROP VIEW dbo.tbl_Clients;

IF EXISTS (SELECT 1 FROM sys.synonyms WHERE name = N''tbl_Clients'' AND schema_id = SCHEMA_ID(N''dbo''))
    DROP SYNONYM dbo.tbl_Clients;

IF OBJECT_ID(N''dbo.tbl_Clients'', N''U'') IS NOT NULL
    DROP TABLE dbo.tbl_Clients;

CREATE TABLE dbo.tbl_Clients
(
    Branch_UUID           int          NOT NULL,  -- tbl_Branch.UUID
    UUID                  int          NOT NULL,  -- CLIENT.CLIENT_REF

    Case_No               varchar(50)  NULL,
    DOB                   date         NULL,
    First_Line_Address    varchar(255) NULL,
    Second_Line_Address   varchar(255) NULL,
    Third_Line_Address    varchar(255) NULL,
    Fourth_Line_Address   varchar(255) NULL,
    Postcode              varchar(20)  NULL,
    Forenames             varchar(100) NULL,
    Surname               varchar(100) NULL,
    Email                 varchar(255) NULL,
    Telephone_1           varchar(50)  NULL,
    Telephone_2           varchar(50)  NULL,
    Title                 varchar(50)  NULL,
    Care_Group            varchar(50)  NULL,
    CH_Code               varchar(50)  NULL,
    Gender                varchar(20)  NULL,
    StartDate             date         NULL,
    LeaveDate             date         NULL,
    Status                varchar(20)  NULL,
    Disability_1          varchar(100) NULL,
    Disability_2          varchar(100) NULL,
    Disability_3          varchar(100) NULL,
    Ethnicity             varchar(100) NULL,
    LeftReason            varchar(100) NULL,
    Religion              varchar(100) NULL,
    Location              varchar(100) NULL,
    Type                  varchar(100) NULL,
    External_Reference    varchar(100) NULL,

    CreatedAtUTC          datetime2(3) NOT NULL CONSTRAINT DF_tbl_Clients_CreatedAtUTC DEFAULT SYSUTCDATETIME(),
    UpdatedAtUTC          datetime2(3) NOT NULL CONSTRAINT DF_tbl_Clients_UpdatedAtUTC DEFAULT SYSUTCDATETIME()
);
';
        EXEC sys.sp_executesql @ddl;

        /* ------------------------------------------------------------
           Baseline insert (dynamic) + capture inserted count safely
           ------------------------------------------------------------ */
        IF OBJECT_ID('tempdb..#Inserted', 'U') IS NOT NULL DROP TABLE #Inserted;
        CREATE TABLE #Inserted (Cnt int NOT NULL);

        DECLARE @ins nvarchar(max) = N'
;WITH BaseClient AS
(
    SELECT
        Branch_UUID = COALESCE(b_by_name.UUID, b_by_old.UUID),
        UUID        = C.CLIENT_REF,

        Case_No              = ca.Case_No,
        DOB                  = ca.DOB,
        First_Line_Address   = ca.ADDRESS1,
        Second_Line_Address  = ca.ADDRESS2,
        Third_Line_Address   = ca.ADDRESS3,
        Fourth_Line_Address  = ca.ADDRESS4,
        Postcode             = ca.POSTCODE,
        Forenames            = ca.FORENAMES,
        Surname              = ca.SURNAME,
        Email                = ca.EMAIL,
        Telephone_1          = ca.TEL_NO1,
        Telephone_2          = ca.TEL_NO2,
        Title                = ca.TITLE,
        Care_Group           = ca.CARE_GRP,
        CH_Code              = ca.CLIENT_CODE,
        Gender               = CASE WHEN C.SEX = ''M'' THEN ''Male''
                                    WHEN C.SEX = ''F'' THEN ''Female''
                                    ELSE ''Other'' END,
        StartDate            = TRY_CONVERT(date, C.START_DATE),
        LeaveDate            = TRY_CONVERT(date, C.LEFT_DATE),
        Status               = ca.STATUS,
        Disability_1         = ca.DIS1,
        Disability_2         = ca.DIS2,
        Disability_3         = ca.DIS3,
        Ethnicity            = ca.ETHNICITY,
        LeftReason           = ca.LEFT_REASON,
        Religion             = ca.RELIGION,
        Location             = ca.LOCATION,
        Type                 = ca.TYPE,
        External_Reference   = ca.EXTCLREF
    FROM dbo.CLIENT AS C
    LEFT JOIN dbo.CONTACT_DT AS CDT
      ON CDT.CNTA_DET_REF = C.CNTA_DET_REF
    LEFT JOIN dbo.CONTACT_HD AS CHD
      ON CHD.CONTACT_REF  = CDT.CONTACT_REF

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

    CROSS APPLY
    (
        SELECT
            Case_No     = NULLIF(LTRIM(RTRIM(C.CASE_NO)), ''''),
            DOB         = TRY_CONVERT(date, C.DATEOFBIRTH),
            ADDRESS1    = NULLIF(LTRIM(RTRIM(CHD.ADDRESS1)), ''''),
            ADDRESS2    = NULLIF(LTRIM(RTRIM(CHD.ADDRESS2)), ''''),
            ADDRESS3    = NULLIF(LTRIM(RTRIM(CHD.ADDRESS3)), ''''),
            ADDRESS4    = NULLIF(LTRIM(RTRIM(CHD.ADDRESS4)), ''''),
            POSTCODE    = NULLIF(LTRIM(RTRIM(CHD.POSTCODE)), ''''),
            FORENAMES   = NULLIF(LTRIM(RTRIM(CHD.FORENAMES)), ''''),
            SURNAME     = NULLIF(LTRIM(RTRIM(CHD.SURNAME)), ''''),
            EMAIL       = NULLIF(LTRIM(RTRIM(CHD.EMAIL)), ''''),
            TEL_NO1     = NULLIF(LTRIM(RTRIM(CHD.TEL_NO1)), ''''),
            TEL_NO2     = NULLIF(LTRIM(RTRIM(CHD.TEL_NO2)), ''''),
            TITLE       = NULLIF(LTRIM(RTRIM(CTL.DESCRIPTION)), ''''),
            CARE_GRP    = NULLIF(LTRIM(RTRIM(CG.DESCRIPTION)), ''''),
            CLIENT_CODE = NULLIF(LTRIM(RTRIM(C.CLIENT_CODE)), ''''),
            STATUS      = NULLIF(LTRIM(RTRIM(CSE.DESCRIPTION)), ''''),
            DIS1        = CASE WHEN LTRIM(RTRIM(CD1.DESCRIPTION)) = ''<no selection>'' THEN NULL ELSE NULLIF(LTRIM(RTRIM(CD1.DESCRIPTION)), '''') END,
            DIS2        = CASE WHEN LTRIM(RTRIM(CD2.DESCRIPTION)) = ''<no selection>'' THEN NULL ELSE NULLIF(LTRIM(RTRIM(CD2.DESCRIPTION)), '''') END,
            DIS3        = CASE WHEN LTRIM(RTRIM(CD3.DESCRIPTION)) = ''<no selection>'' THEN NULL ELSE NULLIF(LTRIM(RTRIM(CD3.DESCRIPTION)), '''') END,
            ETHNICITY   = NULLIF(LTRIM(RTRIM(CE.DESCRIPTION)), ''''),
            LEFT_REASON = CASE WHEN LTRIM(RTRIM(CLR.DESCRIPTION)) = ''<no selection>'' THEN NULL ELSE NULLIF(LTRIM(RTRIM(CLR.DESCRIPTION)), '''') END,
            RELIGION    = CASE WHEN LTRIM(RTRIM(CR.DESCRIPTION))  = ''Not Declared''   THEN NULL ELSE NULLIF(LTRIM(RTRIM(CR.DESCRIPTION)), '''') END,
            LOCATION    = CASE WHEN LTRIM(RTRIM(CL.DESCRIPTION))  = ''<no selection>'' THEN NULL ELSE NULLIF(LTRIM(RTRIM(CL.DESCRIPTION)), '''') END,
            TYPE        = NULLIF(LTRIM(RTRIM(CTY.DESCRIPTION)), ''''),
            EXTCLREF    = NULLIF(LTRIM(RTRIM(C.EXTCLREF)), '''')
    ) AS ca

    OUTER APPLY
    (
        SELECT CASE
                 WHEN C.GS_REF = 1970000043 AND CL.DESCRIPTION = ''Southampton'' THEN N''Southampton''
                 WHEN C.GS_REF = 1970000043 AND (CL.DESCRIPTION <> ''Southampton'' OR CL.DESCRIPTION IS NULL) THEN N''Portsmouth''
                 ELSE NULL
               END AS BranchName
    ) AS pick

    LEFT JOIN dbo.tbl_Branch AS b_by_name
      ON pick.BranchName IS NOT NULL
     AND b_by_name.Branch_Name = pick.BranchName

    LEFT JOIN dbo.tbl_Branch AS b_by_old
      ON pick.BranchName IS NULL
     AND b_by_old.Old_Branch_UUID = TRY_CONVERT(int, C.GS_REF)
)
INSERT INTO dbo.tbl_Clients WITH (TABLOCK)
(
    Branch_UUID, UUID, Case_No, DOB,
    First_Line_Address, Second_Line_Address, Third_Line_Address, Fourth_Line_Address,
    Postcode, Forenames, Surname, Email, Telephone_1, Telephone_2,
    Title, Care_Group, CH_Code, Gender, StartDate, LeaveDate, Status,
    Disability_1, Disability_2, Disability_3, Ethnicity,
    LeftReason, Religion, Location, Type,
    External_Reference,
    CreatedAtUTC, UpdatedAtUTC
)
SELECT
    Branch_UUID, UUID, Case_No, DOB,
    First_Line_Address, Second_Line_Address, Third_Line_Address, Fourth_Line_Address,
    Postcode, Forenames, Surname, Email, Telephone_1, Telephone_2,
    Title, Care_Group, CH_Code, Gender, StartDate, LeaveDate, Status,
    Disability_1, Disability_2, Disability_3, Ethnicity,
    LeftReason, Religion, Location, Type,
    External_Reference,
    @RunStartedAt, @RunStartedAt
FROM BaseClient
WHERE Branch_UUID IS NOT NULL;

INSERT INTO #Inserted(Cnt) VALUES (@@ROWCOUNT);
';

        EXEC sys.sp_executesql
            @ins,
            N'@RunStartedAt datetime2(3)',
            @RunStartedAt = @RunStartedAt;

        DECLARE @Inserted int = (SELECT TOP (1) Cnt FROM #Inserted);

/* ------------------------------------------------------------
   Add PK + indexes AFTER load (single runtime-bound dynamic batch)
   Drops BOTH stats and indexes if they exist (same-name conflict)
   ------------------------------------------------------------ */
DECLARE @post nvarchar(max) = N'
-- PK
IF EXISTS
(
    SELECT 1
    FROM sys.key_constraints
    WHERE parent_object_id = OBJECT_ID(N''dbo.tbl_Clients'')
      AND name = N''PK_tbl_Clients''
)
BEGIN
    ALTER TABLE dbo.tbl_Clients DROP CONSTRAINT PK_tbl_Clients;
END;

ALTER TABLE dbo.tbl_Clients
    ADD CONSTRAINT PK_tbl_Clients PRIMARY KEY CLUSTERED (UUID);

-- Branch index name conflicts: drop STAT first, then INDEX
IF EXISTS
(
    SELECT 1
    FROM sys.stats
    WHERE object_id = OBJECT_ID(N''dbo.tbl_Clients'')
      AND name = N''IX_tbl_Clients_Branch_UUID''
)
    DROP STATISTICS dbo.tbl_Clients.IX_tbl_Clients_Branch_UUID;

IF EXISTS
(
    SELECT 1
    FROM sys.indexes
    WHERE object_id = OBJECT_ID(N''dbo.tbl_Clients'')
      AND name = N''IX_tbl_Clients_Branch_UUID''
)
    DROP INDEX IX_tbl_Clients_Branch_UUID ON dbo.tbl_Clients;

CREATE NONCLUSTERED INDEX IX_tbl_Clients_Branch_UUID
    ON dbo.tbl_Clients (Branch_UUID);

-- Start/Leave index name conflicts: drop STAT first, then INDEX
IF EXISTS
(
    SELECT 1
    FROM sys.stats
    WHERE object_id = OBJECT_ID(N''dbo.tbl_Clients'')
      AND name = N''IX_tbl_Clients_StartLeave''
)
    DROP STATISTICS dbo.tbl_Clients.IX_tbl_Clients_StartLeave;

IF EXISTS
(
    SELECT 1
    FROM sys.indexes
    WHERE object_id = OBJECT_ID(N''dbo.tbl_Clients'')
      AND name = N''IX_tbl_Clients_StartLeave''
)
    DROP INDEX IX_tbl_Clients_StartLeave ON dbo.tbl_Clients;

CREATE NONCLUSTERED INDEX IX_tbl_Clients_StartLeave
    ON dbo.tbl_Clients (StartDate, LeaveDate);
';

EXEC sys.sp_executesql @post;

        /* Optional: enable CT on target */
        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.tbl_Clients'))
        BEGIN
            ALTER TABLE dbo.tbl_Clients
                ENABLE CHANGE_TRACKING WITH (TRACK_COLUMNS_UPDATED = ON);
        END

        DECLARE @EndUTC datetime2(3) = SYSUTCDATETIME();
        DECLARE @EndIso varchar(33)  = CONVERT(varchar(33), @EndUTC, 126);

        SET @Summary = CONCAT(
            N'Clients initial started ', @StartIso,
            N' UTC; ended ', @EndIso,
            N' UTC; baseline inserted ', @Inserted, N' rows; watermark set to ',
            CAST(@BaselineFrom AS nvarchar(30)), N'.'
        );

        SELECT [Stage]=N'Initial', [Summary]=@Summary;

        IF @lockHeld=1
            EXEC sys.sp_releaseapplock @Resource=@LockResource,@LockOwner=@LockOwner,@DbPrincipal=@DbPrincipal;

        RETURN 0;
    END TRY
    BEGIN CATCH
        IF @lockHeld=1
            EXEC sys.sp_releaseapplock @Resource=@LockResource,@LockOwner=@LockOwner,@DbPrincipal=@DbPrincipal;

        DECLARE @msg nvarchar(4000) = ERROR_MESSAGE();
        SET @Summary = CONCAT(N'Clients initial failed: ', @msg);
        SELECT [Stage]=N'Initial', [Summary]=@Summary;

        RAISERROR('usp_Sync_Clients_Initial failed: %s', 16, 1, @msg);
        RETURN -50001;
    END CATCH
END;
GO
