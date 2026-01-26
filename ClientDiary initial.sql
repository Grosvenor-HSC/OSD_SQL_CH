USE [DOM_LIVE]
GO
/****** Object:  StoredProcedure [dbo].[usp_Sync_ClientDiary_Initial]    Script Date: 26/01/2026 20:44:12 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

ALTER   PROCEDURE [dbo].[usp_Sync_ClientDiary_Initial]
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

    -- applock
    EXEC @lockResult = sys.sp_getapplock
        @Resource=@LockResource, @LockMode='Exclusive',
        @LockOwner='Session', @DbPrincipal='dbo', @LockTimeout=600000;
    IF @lockResult NOT IN (0,1)
    BEGIN
        SELECT 'Initial' AS Stage, CAST(N'ClientDiary initial failed: could not acquire applock.' AS nvarchar(4000)) AS Summary;
        RETURN -1;
    END
    SET @lockHeld = 1;

    BEGIN TRY
        -- Preconditions
        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_databases WHERE database_id = DB_ID())
            RAISERROR('Change Tracking is not enabled at the database level.', 16, 1);
        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.CLIENT_DY'))
            RAISERROR('Change Tracking is not enabled on dbo.CLIENT_DY.', 16, 1);

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
        IF OBJECT_ID('dbo.tbl_ClientDiary', 'U') IS NOT NULL
            DROP TABLE dbo.tbl_ClientDiary;

        CREATE TABLE dbo.tbl_ClientDiary (
            Client_UUID                 VARCHAR(20)    NOT NULL,
            UUID                        VARCHAR(20)    NOT NULL,
            Client_Diary_Entry_Date     DATETIME       NULL,
            Client_Diary_Entry_Type     NVARCHAR(255)  NULL,
            Client_Diary_Entry_Text     NVARCHAR(MAX)  NULL,
            CreatedAtUTC                datetime2(3)   NOT NULL CONSTRAINT DF_tbl_ClientDiary_CreatedAtUTC DEFAULT SYSUTCDATETIME(),
            UpdatedAtUTC                datetime2(3)   NOT NULL CONSTRAINT DF_tbl_ClientDiary_UpdatedAtUTC DEFAULT SYSUTCDATETIME(),
            CONSTRAINT PK_tbl_ClientDiary PRIMARY KEY (Client_UUID, UUID)
        );

        /* Baseline load (dynamic SQL to avoid column-binding issues) */
        DECLARE @sql nvarchar(max) = N'
INSERT INTO dbo.tbl_ClientDiary (
    Client_UUID, UUID, Client_Diary_Entry_Date, Client_Diary_Entry_Type,
    Client_Diary_Entry_Text, CreatedAtUTC, UpdatedAtUTC
)
SELECT 
    CAST(CDY.CLIENT_REF AS varchar(20))   AS Client_UUID,
    CAST(CDY.CL_DY_REF  AS varchar(20))   AS UUID,
    CDY.ENTRY_DATE                         AS Client_Diary_Entry_Date,
    CET.DESCRIPTION                        AS Client_Diary_Entry_Type,
    CDY.ENTRY_TEXT                         AS Client_Diary_Entry_Text,
    @RunStartedAt                          AS CreatedAtUTC,
    @RunStartedAt                          AS UpdatedAtUTC
FROM dbo.CLIENT_DY AS CDY WITH (NOLOCK)
JOIN dbo.CLIENT AS C WITH (NOLOCK)
  ON C.CLIENT_REF = CDY.CLIENT_REF
LEFT JOIN dbo.CHSYSDEC AS CET WITH (NOLOCK)
  ON CET.DECODE_REF = CDY.ENTRY_TYPE
WHERE C.RECTYPE NOT IN (''S'',''R'');';

        DECLARE @params nvarchar(200) = N'@RunStartedAt datetime2(3)';
        EXEC sp_executesql @sql, @params, @RunStartedAt=@RunStartedAt;

        DECLARE @Inserted int = @@ROWCOUNT;

        -- Indexes (names aligned with YOUR columns)
        CREATE NONCLUSTERED INDEX IX_tbl_ClientDiary_Client
            ON dbo.tbl_ClientDiary (Client_UUID) INCLUDE (Client_Diary_Entry_Date);

        CREATE NONCLUSTERED INDEX IX_tbl_ClientDiary_EntryDate
            ON dbo.tbl_ClientDiary (Client_Diary_Entry_Date);

        CREATE NONCLUSTERED INDEX IX_tbl_ClientDiary_EntryType
            ON dbo.tbl_ClientDiary (Client_Diary_Entry_Type);

        -- Build initial line
        DECLARE @EndInitialUTC datetime2(3) = SYSUTCDATETIME();
        DECLARE @EndInitialIso varchar(33)  = CONVERT(varchar(33), @EndInitialUTC, 126);
        DECLARE @InitialMsg nvarchar(4000) =
            CONCAT(N'ClientDiary initial started ', @StartIso,
                   N' UTC; ended ', @EndInitialIso,
                   N' UTC; baseline inserted ', @Inserted, N' rows.');

        -- Quiet incremental sweep
        DECLARE @IncrMsg nvarchar(4000) = N'Incremental skipped.';
        IF OBJECT_ID('dbo.usp_Sync_ClientDiary_Incremental','P') IS NOT NULL
        BEGIN
            DECLARE @rc int;
            EXEC @rc = dbo.usp_Sync_ClientDiary_Incremental
                @ChunkSize=100000, @LockTimeoutMs=600000, @UseAppLock=0,
                @EmitInfo=0, @Summary=@IncrMsg OUTPUT;
            IF (@rc < 0)
                SET @IncrMsg = CONCAT(@IncrMsg, N' (rc=', @rc, N')');
        END

        -- Return two rows: Initial + Incremental
        SELECT 'Initial' AS Stage,     @InitialMsg AS Summary
        UNION ALL
        SELECT 'Incremental',          @IncrMsg;

        IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner='Session', @DbPrincipal='dbo';
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner='Session', @DbPrincipal='dbo';
        DECLARE @msg nvarchar(4000)=ERROR_MESSAGE();
        SELECT 'Initial' AS Stage, CAST(CONCAT(N'ClientDiary initial failed: ', @msg) AS nvarchar(4000)) AS Summary;
        RETURN -50001;
    END CATCH
END
