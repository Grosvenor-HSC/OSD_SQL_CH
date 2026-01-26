USE [DOM_LIVE]
GO
/****** Object:  StoredProcedure [dbo].[usp_Sync_ClientAbsences_Initial]    Script Date: 26/01/2026 20:43:27 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

ALTER   PROCEDURE [dbo].[usp_Sync_ClientAbsences_Initial]
    @Summary nvarchar(4000) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET ANSI_WARNINGS ON;

    DECLARE @Process       sysname      = N'ClientAbsences';
    DECLARE @RunStartedAt  datetime2(3) = SYSUTCDATETIME();
    DECLARE @StartIso      varchar(33)  = CONVERT(varchar(33), @RunStartedAt, 126);
    DECLARE @BaselineFrom  bigint;
    DECLARE @LockResource  sysname      = N'DOM_LIVE:Sync:ClientAbsences';
    DECLARE @lockResult    int;
    DECLARE @lockHeld      bit = 0;

    -- Concurrency (wide window for baseline)
    EXEC @lockResult = sys.sp_getapplock
        @Resource=@LockResource, @LockMode='Exclusive',
        @LockOwner='Session', @DbPrincipal='dbo', @LockTimeout=600000;
    IF @lockResult NOT IN (0,1)
    BEGIN
        SET @Summary = N'ClientAbsences initial failed: could not acquire applock.';
        SELECT 'Initial' AS Stage, @Summary AS Summary;
        RETURN -1;
    END;
    SET @lockHeld = 1;

    BEGIN TRY
        /* 1) Preconditions */
        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_databases WHERE database_id = DB_ID())
            RAISERROR('Change Tracking is not enabled at DB level.', 16, 1);
        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.INACTIVE_DY'))
            RAISERROR('Change Tracking is not enabled on dbo.INACTIVE_DY.', 16, 1);

        /* 2) Fence CT window at START so incremental can top-off */
        SET @BaselineFrom = CHANGE_TRACKING_CURRENT_VERSION();

        /* 3) Watermark at START snapshot */
        IF OBJECT_ID('dbo.CT_Watermark','U') IS NULL
        BEGIN
            CREATE TABLE dbo.CT_Watermark
            (
              ProcessName     sysname      PRIMARY KEY,
              LastSyncVersion bigint       NOT NULL,
              LastSyncTime    datetime2(3) NOT NULL DEFAULT SYSUTCDATETIME()
            );
        END;

        MERGE dbo.CT_Watermark AS T
        USING (SELECT @Process AS ProcessName) AS S
          ON T.ProcessName = S.ProcessName
        WHEN MATCHED THEN
            UPDATE SET LastSyncVersion=@BaselineFrom, LastSyncTime=SYSUTCDATETIME()
        WHEN NOT MATCHED THEN
            INSERT (ProcessName, LastSyncVersion, LastSyncTime)
            VALUES (@Process, @BaselineFrom, SYSUTCDATETIME());

        /* 4) Recreate target as heap (faster load) */
        IF OBJECT_ID(N'dbo.tbl_ClientAbsences', N'U') IS NOT NULL
            DROP TABLE dbo.tbl_ClientAbsences;

        CREATE TABLE dbo.tbl_ClientAbsences
        (
            UUID                 nvarchar(55)  NOT NULL,
            Client_UUID          nvarchar(55)  NULL,
            Absence_Reason       nvarchar(255) NULL,
            Absence_Start_Date   date          NULL,
            Absence_End_Date     date          NULL,
            CreatedAtUTC         datetime2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
            UpdatedAtUTC         datetime2(3)  NOT NULL DEFAULT SYSUTCDATETIME()
            -- PK added after load
        );

        /* 5) Baseline load (minimal logging) */
        INSERT INTO dbo.tbl_ClientAbsences WITH (TABLOCK)
        (
            UUID, Client_UUID, Absence_Reason,
            Absence_Start_Date, Absence_End_Date,
            CreatedAtUTC, UpdatedAtUTC
        )
        SELECT 
            CAST(IDY.INACT_REF  AS nvarchar(55)) AS UUID,
            CAST(IDY.CLIENT_REF AS nvarchar(55)) AS Client_UUID,
            NULLIF(LTRIM(RTRIM(CR.DESCRIPTION)), '') AS Absence_Reason,
            CAST(IDY.START_DT AS date)              AS Absence_Start_Date,
            -- If END_DT can be blank text in source, use TRY_CONVERT; otherwise just CAST
            TRY_CONVERT(date, NULLIF(LTRIM(RTRIM(CONVERT(varchar(30), IDY.END_DT, 126))), '')) AS Absence_End_Date,
            @RunStartedAt AS CreatedAtUTC,
            @RunStartedAt AS UpdatedAtUTC
        FROM dbo.INACTIVE_DY AS IDY
        LEFT JOIN dbo.CHSYSDEC AS CR
               ON CR.DECODE_REF = IDY.REASON
        WHERE IDY.rectype NOT IN ('S','R','E');

        DECLARE @Inserted int = @@ROWCOUNT;

        /* 6) Add PK + helpful indexes after load */
        ALTER TABLE dbo.tbl_ClientAbsences
          ADD CONSTRAINT PK_tbl_ClientAbsences PRIMARY KEY CLUSTERED (UUID);

        CREATE INDEX IX_tbl_ClientAbsences_Client_UUID
          ON dbo.tbl_ClientAbsences (Client_UUID);

        CREATE INDEX IX_tbl_ClientAbsences_Absence_Start_Date
          ON dbo.tbl_ClientAbsences (Absence_Start_Date);

        CREATE INDEX IX_tbl_ClientAbsences_Absence_End_Date
          ON dbo.tbl_ClientAbsences (Absence_End_Date);

        /* 7) Summaries + quiet incremental top-off */
        DECLARE @EndInitialUTC datetime2(3) = SYSUTCDATETIME();
        DECLARE @EndInitialIso varchar(33)  = CONVERT(varchar(33), @EndInitialUTC, 126);
        DECLARE @InitialMsg nvarchar(4000) =
            CONCAT(N'ClientAbsences initial started ', @StartIso,
                   N' UTC; ended ', @EndInitialIso,
                   N' UTC; baseline inserted ', @Inserted, N' rows.');

        DECLARE @IncrMsg nvarchar(4000) = N'Incremental skipped.';
        IF OBJECT_ID(N'dbo.usp_Sync_ClientAbsences_Incremental', N'P') IS NOT NULL
        BEGIN
            DECLARE @rc int;
            EXEC @rc = dbo.usp_Sync_ClientAbsences_Incremental
                @ChunkSize=50000, @LockTimeoutMs=600000, @UseAppLock=0,
                @EmitInfo=0, @Summary=@IncrMsg OUTPUT;
            IF (@rc < 0)
                SET @IncrMsg = CONCAT(@IncrMsg, N' (rc=', @rc, N')');
        END;

        SET @Summary = @InitialMsg;

        SELECT 'Initial' AS Stage,     @InitialMsg AS Summary
        UNION ALL
        SELECT 'Incremental',          @IncrMsg;

        IF @lockHeld=1
            EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner='Session', @DbPrincipal='dbo';

        RETURN 0;
    END TRY
    BEGIN CATCH
        IF @lockHeld=1
            EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner='Session', @DbPrincipal='dbo';
        DECLARE @msg nvarchar(4000)=ERROR_MESSAGE();
        SET @Summary = CONCAT(N'ClientAbsences initial failed: ', @msg);
        SELECT 'Initial' AS Stage, @Summary AS Summary;
        RETURN -50001;
    END CATCH
END
