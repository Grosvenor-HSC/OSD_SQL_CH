USE [DOM_LIVE];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

/* =======================================================================
   ClientDiary Baseline (seed watermark at start; stamp Created/Updated)
   ======================================================================= */
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @Process       sysname      = N'ClientDiary';
DECLARE @RunStartedAt  datetime2(3) = SYSUTCDATETIME();  -- baseline stamp for Created/Updated
DECLARE @BaselineFrom  bigint;   -- CT snapshot taken BEFORE we rebuild/load
DECLARE @LockResource  sysname    = N'DOM_LIVE:Sync:ClientDiary';
DECLARE @LockOwner     sysname    = N'Session';
DECLARE @DbPrincipal   sysname    = N'dbo';
DECLARE @lockResult    int;
DECLARE @lockHeld      bit        = 0;

/* 0) Concurrency guard */
EXEC @lockResult = sys.sp_getapplock
    @Resource    = @LockResource,
    @LockMode    = 'Exclusive',
    @LockOwner   = @LockOwner,
    @DbPrincipal = @DbPrincipal,
    @LockTimeout = 600000;

IF @lockResult NOT IN (0,1)
BEGIN
    RAISERROR('Could not acquire %s (rc=%d).',16,1,@LockResource,@lockResult);
    RETURN;
END
SET @lockHeld = 1;

BEGIN TRY
    /* 1) Preconditions */
    IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_databases WHERE database_id = DB_ID())
        RAISERROR('Change Tracking is not enabled at the database level.', 16, 1);

    IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.CLIENT_DY'))
        RAISERROR('Change Tracking is not enabled on dbo.CLIENT_DY.', 16, 1);

    /* 2) Take CT snapshot AT START */
    SET @BaselineFrom = CHANGE_TRACKING_CURRENT_VERSION();

    /* 3) Ensure watermark exists and seed to START snapshot */
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
      UPDATE SET LastSyncVersion = @BaselineFrom, LastSyncTime = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN
      INSERT (ProcessName, LastSyncVersion) VALUES (@Process, @BaselineFrom);

    RAISERROR('Seeded ClientDiary watermark to START snapshot %I64d.', 0, 1, @BaselineFrom) WITH NOWAIT;

    /* 4) Recreate target table (with CreatedAtUTC / UpdatedAtUTC + defaults) */
    IF OBJECT_ID('dbo.tbl_ClientDiary', 'U') IS NOT NULL
        DROP TABLE dbo.tbl_ClientDiary;

    CREATE TABLE dbo.tbl_ClientDiary (
        ClientReference           VARCHAR(20)   NOT NULL,
        ClientDiaryReference      VARCHAR(20)   NOT NULL,
        ClientDiaryEntryDate      DATETIME      NULL,
        ClientDiaryEntryType      NVARCHAR(255) NULL,
        ClientDiaryEntryText      NVARCHAR(MAX) NULL,
        ClientDiaryReminded       NVARCHAR(1)   NULL,
        ClientDiaryReviewDate     DATETIME      NULL,
        ClientDiaryAction         NVARCHAR(255) NULL,
        ClientDiaryActionDate     DATETIME      NULL,
        ClientDiaryReviewDoneDate DATETIME      NULL,
        CreatedAtUTC              datetime2(3)  NOT NULL CONSTRAINT DF_tbl_ClientDiary_CreatedAtUTC DEFAULT SYSUTCDATETIME(),
        UpdatedAtUTC              datetime2(3)  NOT NULL CONSTRAINT DF_tbl_ClientDiary_UpdatedAtUTC DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_tbl_ClientDiary PRIMARY KEY (ClientReference, ClientDiaryReference)
    );

    /* 5) Populate (stamp Created/Updated with @RunStartedAt) */
    INSERT INTO dbo.tbl_ClientDiary (
        ClientReference,
        ClientDiaryReference,
        ClientDiaryEntryDate,
        ClientDiaryEntryType,
        ClientDiaryEntryText,
        ClientDiaryReminded,
        ClientDiaryReviewDate,
        ClientDiaryAction,
        ClientDiaryActionDate,
        ClientDiaryReviewDoneDate,
        CreatedAtUTC,
        UpdatedAtUTC
    )
    SELECT 
        CDY.CLIENT_REF,
        CDY.CL_DY_REF,
        CDY.ENTRY_DATE,
        CET.DESCRIPTION,
        CDY.ENTRY_TEXT,
        CDY.REMINDED,
        CDY.REVIEW_DATE,
        CDY.ACTION,
        CDY.ACTIONDT,
        CDY.REVDONE_DT,
        @RunStartedAt,         -- CreatedAtUTC
        @RunStartedAt          -- UpdatedAtUTC
    FROM dbo.CLIENT_DY AS CDY WITH (NOLOCK)
    INNER JOIN dbo.CLIENT    AS C   WITH (NOLOCK)
        ON C.CLIENT_REF = CDY.CLIENT_REF
    LEFT JOIN  dbo.CHSYSDEC  AS CET WITH (NOLOCK)
        ON CET.DECODE_REF = CDY.ENTRY_TYPE
    WHERE C.RECTYPE NOT IN ('S','R');

    DECLARE @rows int = @@ROWCOUNT;
    RAISERROR('tbl_ClientDiary baseline complete. Inserted %d rows.', 0, 1, @rows) WITH NOWAIT;

    /* 6) Indexes */
    CREATE NONCLUSTERED INDEX IX_tbl_ClientDiary_Client
        ON dbo.tbl_ClientDiary (ClientReference) INCLUDE (ClientDiaryEntryDate);

    CREATE NONCLUSTERED INDEX IX_tbl_ClientDiary_EntryDate
        ON dbo.tbl_ClientDiary (ClientDiaryEntryDate);

    CREATE NONCLUSTERED INDEX IX_tbl_ClientDiary_EntryType
        ON dbo.tbl_ClientDiary (ClientDiaryEntryType);

    -- (Optional) helper index for troubleshooting recent changes
    -- CREATE NONCLUSTERED INDEX IX_tbl_ClientDiary_UpdatedAtUTC ON dbo.tbl_ClientDiary(UpdatedAtUTC);

    /* 7) Do NOT advance the watermark here. */
    IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;
END TRY
BEGIN CATCH
    IF @lockHeld=1 
        EXEC sys.sp_releaseapplock 
            @Resource=@LockResource, 
            @LockOwner=@LockOwner, 
            @DbPrincipal=@DbPrincipal;

    DECLARE @msg nvarchar(4000) = ERROR_MESSAGE();
    DECLARE @num int = ERROR_NUMBER(),
            @sev int = ERROR_SEVERITY(),
            @st  int = ERROR_STATE(),
            @lin int = ERROR_LINE(),
            @proc sysname = ERROR_PROCEDURE();
    DECLARE @procName sysname = ISNULL(@proc, N'<adhoc>');

    RAISERROR(
        'ClientDiary baseline failed (%d, sev %d, state %d) at %s line %d: %s',
        16, 1,
        @num, @sev, @st, @procName, @lin, @msg
    );

    RETURN;
END CATCH
GO
