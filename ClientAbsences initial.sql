CREATE OR ALTER PROCEDURE dbo.usp_Sync_ClientAbsences_Initial
    @Summary nvarchar(4000) = NULL OUTPUT   -- optional: first row text if you still want it
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Process       sysname      = N'ClientAbsences';
    DECLARE @RunStartedAt  datetime2(3) = SYSUTCDATETIME();
    DECLARE @StartIso      varchar(33)  = CONVERT(varchar(33), @RunStartedAt, 126);
    DECLARE @BaselineFrom  bigint;
    DECLARE @LockResource  sysname      = N'DOM_LIVE:Sync:ClientAbsences';
    DECLARE @lockResult    int;
    DECLARE @lockHeld      bit = 0;

    EXEC @lockResult = sys.sp_getapplock
        @Resource=@LockResource, @LockMode='Exclusive', @LockOwner='Session',
        @DbPrincipal='dbo', @LockTimeout=600000;
    IF @lockResult NOT IN (0,1)
    BEGIN
        SET @Summary = N'ClientAbsences initial failed: could not acquire applock.';
        RETURN -1;
    END;
    SET @lockHeld = 1;

    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_databases WHERE database_id = DB_ID())
            RAISERROR('Change Tracking is not enabled at DB level.', 16, 1);
        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.INACTIVE_DY'))
            RAISERROR('Change Tracking is not enabled on dbo.INACTIVE_DY.', 16, 1);

        SET @BaselineFrom = CHANGE_TRACKING_CURRENT_VERSION();

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
        USING (SELECT @Process p, @BaselineFrom v) AS S(p,v)
          ON T.ProcessName = S.p
        WHEN MATCHED THEN
            UPDATE SET LastSyncVersion = S.v, LastSyncTime = SYSUTCDATETIME()
        WHEN NOT MATCHED THEN
            INSERT (ProcessName, LastSyncVersion, LastSyncTime)
            VALUES (S.p, S.v, SYSUTCDATETIME());

        IF OBJECT_ID('[dbo].[tbl_ClientAbsences]', 'U') IS NOT NULL
            DROP TABLE [dbo].[tbl_ClientAbsences];

        CREATE TABLE [dbo].[tbl_ClientAbsences](
            InactiveReference      nvarchar(55)  NOT NULL,
            ClientReference        int           NULL,
            AbsenceReason          nvarchar(255) NULL,
            AbsenceStartDate       date          NULL,
            AbsenceEndDate         date          NULL,
            UpdatedLeaveDate       date          NULL,
            AbsenceEndDate_Week    date          NULL,
            AbsenceStartDate_Week  date          NULL,
            AbsenceEndMonth        int           NULL,
            AbsenceStartMonth      int           NULL,
            AbsenceEndYear         int           NULL,
            AbsenceStartYear       int           NULL,
            DaysOnLeave            int           NULL,
            CreatedAtUTC           datetime2(3)  NOT NULL CONSTRAINT DF_tbl_ClientAbsences_CreatedAtUTC DEFAULT SYSUTCDATETIME(),
            UpdatedAtUTC           datetime2(3)  NOT NULL CONSTRAINT DF_tbl_ClientAbsences_UpdatedAtUTC DEFAULT SYSUTCDATETIME(),
            CONSTRAINT PK_tbl_ClientAbsences PRIMARY KEY CLUSTERED (InactiveReference)
        );

        -- Baseline load
        SET DATEFIRST 1;
        INSERT INTO [dbo].[tbl_ClientAbsences] (
            InactiveReference, ClientReference, AbsenceReason,
            AbsenceStartDate, AbsenceEndDate, UpdatedLeaveDate,
            AbsenceEndDate_Week, AbsenceStartDate_Week,
            AbsenceEndMonth, AbsenceStartMonth, AbsenceEndYear, AbsenceStartYear,
            DaysOnLeave, CreatedAtUTC, UpdatedAtUTC
        )
        SELECT 
            CAST(IDY.INACT_REF AS nvarchar(55)),
            IDY.CLIENT_REF,
            CR.DESCRIPTION,
            CAST(IDY.START_DT AS date),
            CAST(IDY.END_DT   AS date),
            CAST(IDY.END_DT   AS date),
            DATEADD(day, 1 - DATEPART(weekday, CAST(IDY.END_DT   AS date)), CAST(IDY.END_DT   AS date)),
            DATEADD(day, 1 - DATEPART(weekday, CAST(IDY.START_DT AS date)), CAST(IDY.START_DT AS date)),
            MONTH(CAST(IDY.END_DT   AS date)),
            MONTH(CAST(IDY.START_DT AS date)),
            YEAR(CAST(IDY.END_DT   AS date)),
            YEAR(CAST(IDY.START_DT AS date)),
            DATEDIFF(day, CAST(IDY.START_DT AS date), CAST(IDY.END_DT AS date)),
            @RunStartedAt, @RunStartedAt
        FROM dbo.INACTIVE_DY AS IDY WITH (NOLOCK)
        LEFT JOIN dbo.CHSYSDEC AS CR WITH (NOLOCK)
          ON CR.DECODE_REF = IDY.REASON
        WHERE IDY.rectype NOT IN ('S','R','E');

        DECLARE @Inserted int = @@ROWCOUNT;

        -- Indexes after load
        CREATE INDEX IX_tbl_ClientAbsences_ClientReference  ON [dbo].[tbl_ClientAbsences](ClientReference);
        CREATE INDEX IX_tbl_ClientAbsences_AbsenceStartDate ON [dbo].[tbl_ClientAbsences](AbsenceStartDate);
        CREATE INDEX IX_tbl_ClientAbsences_AbsenceEndDate   ON [dbo].[tbl_ClientAbsences](AbsenceEndDate);

        -- Compose initial message
        DECLARE @EndInitialUTC datetime2(3) = SYSUTCDATETIME();
        DECLARE @EndInitialIso varchar(33)  = CONVERT(varchar(33), @EndInitialUTC, 126);
        DECLARE @InitialMsg nvarchar(4000) =
            CONCAT(N'ClientAbsences initial started ', @StartIso,
                   N' UTC; ended ', @EndInitialIso,
                   N' UTC; baseline inserted ', @Inserted, N' rows.');

        -- Immediately run incremental QUIETLY and capture its summary
        DECLARE @IncrMsg nvarchar(4000) = N'Incremental skipped.';
        IF OBJECT_ID('dbo.usp_Sync_ClientAbsences_Incremental','P') IS NOT NULL
        BEGIN
            DECLARE @rc int;
            EXEC @rc = dbo.usp_Sync_ClientAbsences_Incremental
                @ChunkSize=50000, @LockTimeoutMs=600000, @UseAppLock=0,
                @EmitInfo=0, @Summary=@IncrMsg OUTPUT;
            IF (@rc < 0)
                SET @IncrMsg = CONCAT(@IncrMsg, N' (rc=', @rc, N')');
        END

        SET @Summary = @InitialMsg;

        -- Return exactly two rows
        SELECT 'Initial'     AS Stage, @InitialMsg AS Summary
        UNION ALL
        SELECT 'Incremental' AS Stage, @IncrMsg;

        IF @lockHeld=1
            EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner='Session', @DbPrincipal='dbo';

        RETURN 0;
    END TRY
    BEGIN CATCH
        IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner='Session', @DbPrincipal='dbo';
        DECLARE @msg nvarchar(4000)=ERROR_MESSAGE();
        SET @Summary = CONCAT(N'ClientAbsences initial failed: ', @msg);
        RETURN -50001;
    END CATCH
END
GO
