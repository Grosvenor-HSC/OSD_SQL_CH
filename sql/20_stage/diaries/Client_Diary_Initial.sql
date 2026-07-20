USE [DOM_LIVE];
GO

SET ANSI_NULLS ON;
GO

SET QUOTED_IDENTIFIER ON;
GO

ALTER PROCEDURE [dbo].[usp_Sync_ClientDiary_Initial]
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Process       sysname      = N'ClientDiary';
    DECLARE @RunStartedAt  datetime2(3) = SYSUTCDATETIME();
    DECLARE @StartIso      varchar(33)  = CONVERT(varchar(33), @RunStartedAt, 126);
    DECLARE @BaselineFrom  bigint;
    DECLARE @LockResource  sysname      = N'DOM_LIVE:Sync:ClientDiary';
    DECLARE @lockResult    int;
    DECLARE @lockHeld      bit          = 0;

    EXEC @lockResult = sys.sp_getapplock
        @Resource = @LockResource,
        @LockMode = 'Exclusive',
        @LockOwner = 'Session',
        @DbPrincipal = 'dbo',
        @LockTimeout = 600000;

    IF @lockResult NOT IN (0, 1)
    BEGIN
        SELECT
            'Initial' AS Stage,
            CAST(
                N'ClientDiary initial failed: could not acquire applock.'
                AS nvarchar(4000)
            ) AS Summary;

        RETURN -1;
    END;

    SET @lockHeld = 1;

    BEGIN TRY
        IF NOT EXISTS
        (
            SELECT 1
            FROM sys.change_tracking_databases
            WHERE database_id = DB_ID()
        )
        BEGIN
            THROW 50001, 'Change Tracking is not enabled at the database level.', 1;
        END;

        IF NOT EXISTS
        (
            SELECT 1
            FROM sys.change_tracking_tables
            WHERE object_id = OBJECT_ID(N'dbo.CLIENT_DY')
        )
        BEGIN
            THROW 50002, 'Change Tracking is not enabled on dbo.CLIENT_DY.', 1;
        END;

        SET @BaselineFrom = CHANGE_TRACKING_CURRENT_VERSION();

        IF OBJECT_ID(N'dbo.CT_Watermark', N'U') IS NULL
        BEGIN
            CREATE TABLE dbo.CT_Watermark
            (
                ProcessName     sysname      NOT NULL,
                LastSyncVersion bigint       NOT NULL,
                LastSyncTime    datetime2(3) NOT NULL
                    CONSTRAINT DF_CT_Watermark_LastSyncTime
                    DEFAULT SYSUTCDATETIME(),

                CONSTRAINT PK_CT_Watermark
                    PRIMARY KEY (ProcessName)
            );
        END;

        MERGE dbo.CT_Watermark AS target
        USING
        (
            SELECT @Process AS ProcessName
        ) AS source
            ON target.ProcessName = source.ProcessName

        WHEN MATCHED THEN
            UPDATE SET
                LastSyncVersion = @BaselineFrom,
                LastSyncTime = SYSUTCDATETIME()

        WHEN NOT MATCHED THEN
            INSERT
            (
                ProcessName,
                LastSyncVersion,
                LastSyncTime
            )
            VALUES
            (
                @Process,
                @BaselineFrom,
                SYSUTCDATETIME()
            );

        IF OBJECT_ID(N'dbo.tbl_ClientDiary', N'U') IS NOT NULL
        BEGIN
            DROP TABLE dbo.tbl_ClientDiary;
        END;

        CREATE TABLE dbo.tbl_ClientDiary
        (
            Client_UUID                 varchar(20)    NOT NULL,
            UUID                        varchar(20)    NOT NULL,
            Client_Diary_Entry_Date     date           NULL,
            Client_Diary_Entry_Type     nvarchar(255)  NULL,
            Client_Diary_Entry_Text     nvarchar(max)  NULL,
            Client_Diary_Review_Date    date           NULL,
            Client_Diary_Action         bit            NULL,
            Client_Diary_Action_Date    date           NULL,
            Client_Diary_Done_Date      date           NULL,
            Client_Diary_Reminded       bit            NULL,

            CreatedAtUTC datetime2(3) NOT NULL
                CONSTRAINT DF_tbl_ClientDiary_CreatedAtUTC
                DEFAULT SYSUTCDATETIME(),

            UpdatedAtUTC datetime2(3) NOT NULL
                CONSTRAINT DF_tbl_ClientDiary_UpdatedAtUTC
                DEFAULT SYSUTCDATETIME(),

            CONSTRAINT PK_tbl_ClientDiary
                PRIMARY KEY (Client_UUID, UUID)
        );

        DECLARE @sql nvarchar(max) = N'
INSERT INTO dbo.tbl_ClientDiary
(
    Client_UUID,
    UUID,
    Client_Diary_Entry_Date,
    Client_Diary_Entry_Type,
    Client_Diary_Entry_Text,
    Client_Diary_Review_Date,
    Client_Diary_Action,
    Client_Diary_Action_Date,
    Client_Diary_Done_Date,
    Client_Diary_Reminded,
    CreatedAtUTC,
    UpdatedAtUTC
)
SELECT
    CAST(CDY.CLIENT_REF AS varchar(20)),
    CAST(CDY.CL_DY_REF AS varchar(20)),
    CDY.ENTRY_DATE,
    CET.DESCRIPTION,
    CDY.ENTRY_TEXT,
    CDY.REVIEW_DATE,
    CASE
        WHEN CDY.ACTION = ''Y'' THEN CAST(1 AS bit)
        ELSE CAST(0 AS bit)
    END,
    CDY.ACTIONDT,
    CDY.REVDONE_DT,
    CASE
        WHEN CDY.REMINDED = ''Y'' THEN CAST(1 AS bit)
        ELSE CAST(0 AS bit)
    END,
    @RunStartedAt,
    @RunStartedAt
FROM dbo.CLIENT_DY AS CDY
INNER JOIN dbo.CLIENT AS C
    ON C.CLIENT_REF = CDY.CLIENT_REF
LEFT JOIN dbo.CHSYSDEC AS CET
    ON CET.DECODE_REF = CDY.ENTRY_TYPE
WHERE C.RECTYPE NOT IN (''S'', ''R'');';

        DECLARE @params nvarchar(200) =
            N'@RunStartedAt datetime2(3)';

        DECLARE @Inserted int;

        EXEC sys.sp_executesql
            @sql,
            @params,
            @RunStartedAt = @RunStartedAt;

        SET @Inserted = @@ROWCOUNT;

        CREATE NONCLUSTERED INDEX IX_tbl_ClientDiary_Client
            ON dbo.tbl_ClientDiary (Client_UUID)
            INCLUDE (Client_Diary_Entry_Date);

        CREATE NONCLUSTERED INDEX IX_tbl_ClientDiary_EntryDate
            ON dbo.tbl_ClientDiary (Client_Diary_Entry_Date);

        CREATE NONCLUSTERED INDEX IX_tbl_ClientDiary_EntryType
            ON dbo.tbl_ClientDiary (Client_Diary_Entry_Type);

        DECLARE @EndInitialUTC datetime2(3) = SYSUTCDATETIME();
        DECLARE @EndInitialIso varchar(33) =
            CONVERT(varchar(33), @EndInitialUTC, 126);

        DECLARE @InitialMsg nvarchar(4000) =
            CONCAT
            (
                N'ClientDiary initial started ',
                @StartIso,
                N' UTC; ended ',
                @EndInitialIso,
                N' UTC; baseline inserted ',
                @Inserted,
                N' rows.'
            );

        DECLARE @IncrMsg nvarchar(4000) = N'Incremental skipped.';

        IF OBJECT_ID(N'dbo.usp_Sync_ClientDiary_Incremental', N'P') IS NOT NULL
        BEGIN
            DECLARE @rc int;

            EXEC @rc = dbo.usp_Sync_ClientDiary_Incremental
                @ChunkSize = 100000,
                @LockTimeoutMs = 600000,
                @UseAppLock = 0,
                @EmitInfo = 0,
                @Summary = @IncrMsg OUTPUT;

            IF @rc < 0
            BEGIN
                SET @IncrMsg =
                    CONCAT(@IncrMsg, N' (rc=', @rc, N')');
            END;
        END;

        SELECT
            'Initial' AS Stage,
            @InitialMsg AS Summary

        UNION ALL

        SELECT
            'Incremental',
            @IncrMsg;

        IF @lockHeld = 1
        BEGIN
            EXEC sys.sp_releaseapplock
                @Resource = @LockResource,
                @LockOwner = 'Session',
                @DbPrincipal = 'dbo';

            SET @lockHeld = 0;
        END;

        RETURN 0;
    END TRY
    BEGIN CATCH
        IF @lockHeld = 1
        BEGIN
            EXEC sys.sp_releaseapplock
                @Resource = @LockResource,
                @LockOwner = 'Session',
                @DbPrincipal = 'dbo';
        END;

        DECLARE @msg nvarchar(4000) = ERROR_MESSAGE();

        SELECT
            'Initial' AS Stage,
            CAST
            (
                CONCAT(N'ClientDiary initial failed: ', @msg)
                AS nvarchar(4000)
            ) AS Summary;

        RETURN -50001;
    END CATCH;
END;
GO