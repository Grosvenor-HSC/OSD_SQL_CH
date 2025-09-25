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
        -- Preconditions
        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_databases WHERE database_id = DB_ID())
            RAISERROR('Change Tracking is not enabled at the database level.', 16, 1);
        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.CLIENT'))
            RAISERROR('Change Tracking is not enabled on dbo.CLIENT.', 16, 1);

        -- CT snapshot at start
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
            Branch_UUID           VARCHAR(50)  NOT NULL,
            UUID                  VARCHAR(50)  NOT NULL,
            Case_No               VARCHAR(50)  NULL,
            DOB                   DATE         NULL,
            First_Line_Address    VARCHAR(255) NULL,
            Second_Line_Address   VARCHAR(255) NULL,
            Third_Line_Address    VARCHAR(255) NULL,
            Fourth_Line_Address   VARCHAR(255) NULL,
            Postcode              VARCHAR(20)  NULL,
            Forenames             VARCHAR(100) NULL,
            Surname               VARCHAR(100) NULL,
            Email                 VARCHAR(255) NULL,
            Telephone_1           VARCHAR(50)  NULL,
            Telephone_2           VARCHAR(50)  NULL,
            Title                 VARCHAR(50)  NULL,
            [Group]               VARCHAR(50)  NULL,
            CH_Code               VARCHAR(50)  NULL,
            Gender                VARCHAR(20)  NULL,
            StartDate             DATE         NULL,
            LeaveDate             DATE         NULL,
            Status                VARCHAR(20)  NULL,
            Disability_1          VARCHAR(100) NULL,
            Disability_2          VARCHAR(100) NULL,
            Disability_3          VARCHAR(100) NULL,
            Ethnicity             VARCHAR(100) NULL,
            LeftReason            VARCHAR(100) NULL,
            Religion              VARCHAR(100) NULL,
            Location              VARCHAR(100) NULL,
            Type                  VARCHAR(100) NULL,
            External_Reference    VARCHAR(100) NULL,
            CreatedAtUTC          datetime2(3) NOT NULL CONSTRAINT DF_tbl_Clients_CreatedAtUTC DEFAULT SYSUTCDATETIME(),
            UpdatedAtUTC          datetime2(3) NOT NULL CONSTRAINT DF_tbl_Clients_UpdatedAtUTC DEFAULT SYSUTCDATETIME(),
            CONSTRAINT PK_tbl_Clients PRIMARY KEY CLUSTERED (UUID)
        );

        -- Baseline load
        ;WITH BaseClient AS (
            SELECT
                -- Prefer name match to new Branch table; if missing, fall back to old-branch UUID match
                COALESCE(b_by_name.UUID, b_by_old.UUID)                                   AS Branch_UUID,

                CAST(C.CLIENT_REF AS varchar(50))                                        AS UUID,
                C.CASE_NO                                                                 AS Case_No,
                C.DATEOFBIRTH                                                             AS DOB,

                LTRIM(RTRIM(CHD.ADDRESS1))                                               AS First_Line_Address,
                LTRIM(RTRIM(CHD.ADDRESS2))                                               AS Second_Line_Address,
                LTRIM(RTRIM(CHD.ADDRESS3))                                               AS Third_Line_Address,
                LTRIM(RTRIM(CHD.ADDRESS4))                                               AS Fourth_Line_Address,

                CHD.POSTCODE                                                              AS Postcode,
                CHD.FORENAMES                                                             AS Forenames,
                CHD.SURNAME                                                               AS Surname,
                CHD.EMAIL                                                                 AS Email,
                CHD.TEL_NO1                                                               AS Telephone_1,
                CHD.TEL_NO2                                                               AS Telephone_2,

                CTL.DESCRIPTION                                                           AS Title,
                CG.DESCRIPTION                                                            AS [Group],
                C.CLIENT_CODE                                                             AS CH_Code,

                CASE WHEN C.SEX = 'M' THEN 'Male'
                     WHEN C.SEX = 'F' THEN 'Female'
                     ELSE 'Other' END                                                     AS Gender,

                C.START_DATE                                                              AS StartDate,
                C.LEFT_DATE                                                               AS LeaveDate,

                CSE.DESCRIPTION                                                           AS Status,
                CD1.DESCRIPTION                                                           AS Disability_1,
                CD2.DESCRIPTION                                                           AS Disability_2,
                CD3.DESCRIPTION                                                           AS Disability_3,
                CE.DESCRIPTION                                                            AS Ethnicity,
                CLR.DESCRIPTION                                                           AS LeftReason,
                CR.DESCRIPTION                                                            AS Religion,
                CL.DESCRIPTION                                                            AS Location,
                CTY.DESCRIPTION                                                           AS Type,

                C.EXTCLREF                                                                AS External_Reference
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
            LEFT JOIN dbo.CHSYSDEC AS CR   ON C.RELORG_REF   = CR.DECODE_REF
            LEFT JOIN dbo.CHSYSDEC AS CTY  ON C.CLIENT_TYPE  = CTY.DECODE_REF
            LEFT JOIN dbo.CHSYSDEC AS CL   ON C.LOCATION_REF = CL.DECODE_REF
            LEFT JOIN dbo.CHSYSDEC AS CSE  ON C.STATUS       = CSE.DECODE_REF

            -- Decide a "branch name" only for the 1970000043 special case (Southampton vs Portsmouth);
            -- we always attempt name match first, then fall back to old-branch UUID join.
            OUTER APPLY (
                SELECT CASE 
                         WHEN C.GS_REF = '1970000043' AND CL.DESCRIPTION = 'Southampton' THEN N'Southampton'
                         WHEN C.GS_REF = '1970000043' AND (CL.DESCRIPTION <> 'Southampton' OR CL.DESCRIPTION IS NULL) THEN N'Portsmouth'
                         ELSE NULL
                       END AS BranchName
            ) pick

            -- name match against NEW branch schema (Branch_Name, UUID)
            LEFT JOIN dbo.tbl_Branch AS b_by_name
              ON pick.BranchName IS NOT NULL
             AND b_by_name.Branch_Name = pick.BranchName

            -- fallback: match against Old_Branch_UUID
            LEFT JOIN dbo.tbl_Branch AS b_by_old
              ON pick.BranchName IS NULL
             AND b_by_old.Old_Branch_UUID = CAST(C.GS_REF AS varchar(20))
        )
        INSERT INTO dbo.tbl_Clients (
            Branch_UUID, UUID, Case_No, DOB,
            First_Line_Address, Second_Line_Address, Third_Line_Address, Fourth_Line_Address,
            Postcode, Forenames, Surname, Email, Telephone_1, Telephone_2,
            Title, [Group], CH_Code, Gender, StartDate, LeaveDate, Status, Disability_1, Disability_2, Disability_3, Ethnicity,
            LeftReason, Religion, Location, Type,
            CreatedAtUTC, UpdatedAtUTC
        )
        SELECT
            Branch_UUID, UUID, Case_No, DOB,
            First_Line_Address, Second_Line_Address, Third_Line_Address, Fourth_Line_Address,
            Postcode, Forenames, Surname, Email, Telephone_1, Telephone_2,
            Title, [Group], CH_Code, Gender, StartDate, LeaveDate, Status, Disability_1, Disability_2, Disability_3, Ethnicity,
            LeftReason, Religion, Location, Type,
            @RunStartedAt, @RunStartedAt
        FROM BaseClient
        WHERE Branch_UUID IS NOT NULL;

        DECLARE @Inserted int = @@ROWCOUNT;

        -- Indexes after load
        CREATE NONCLUSTERED INDEX IX_tbl_Clients_Branch_UUID ON dbo.tbl_Clients (Branch_UUID);
        CREATE NONCLUSTERED INDEX IX_tbl_Clients_StartLeave  ON dbo.tbl_Clients (StartDate, LeaveDate);

        -- Initial summary
        DECLARE @EndInitialUTC datetime2(3) = SYSUTCDATETIME();
        DECLARE @EndInitialIso varchar(33)  = CONVERT(varchar(33), @EndInitialUTC, 126);
        DECLARE @InitialMsg nvarchar(4000) =
            CONCAT(N'Clients initial started ', @StartIso,
                   N' UTC; ended ', @EndInitialIso,
                   N' UTC; baseline inserted ', @Inserted, N' rows.');

        -- Quiet incremental sweep (optional)
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
