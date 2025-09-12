USE [DOM_LIVE]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

ALTER PROCEDURE [dbo].[usp_Sync_ClientDiary_Incremental]
    @ChunkSize         int  = 100000,
    @LockTimeoutMs     int  = 60000,
    @UseAppLock        bit  = 1,
    @EmitInfo          bit  = 0,                          -- 0=silent, 1=print progress
    @Summary           nvarchar(4000) = NULL OUTPUT,      -- one-line summary
    @ReturnSummaryRow  bit  = 1                           -- emit SELECT Stage/Summary row
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Process       sysname      = N'ClientDiary';
    DECLARE @RunStartedAt  datetime2(3) = SYSUTCDATETIME();
    DECLARE @StartIso      varchar(33)  = CONVERT(varchar(33), @RunStartedAt, 126);
    DECLARE @EndUTC        datetime2(3);
    DECLARE @EndIso        varchar(33);
    DECLARE @DurationSec   int;

    -- 0) Concurrency
    DECLARE @LockResource sysname = N'DOM_LIVE:Sync:ClientDiary';
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
            SET @Summary = N'ClientDiary incremental failed: could not acquire applock.';
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            RETURN @lockResult;
        END
        SET @lockHeld = 1;
    END

    BEGIN TRY
        -- 1) Preconditions & bounds
        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_databases WHERE database_id = DB_ID())
        BEGIN
            IF @EmitInfo=1 RAISERROR('Change Tracking is not enabled at DB level.', 16, 1);
            SET @Summary = N'ClientDiary incremental failed: CT not enabled at DB level.';
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;
            RETURN -100;
        END

        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.CLIENT_DY'))
        BEGIN
            IF @EmitInfo=1 RAISERROR('CT not enabled on dbo.CLIENT_DY.',16,1);
            SET @Summary = N'ClientDiary incremental failed: CT not enabled on dbo.CLIENT_DY.';
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;
            RETURN -210;
        END

        DECLARE @CT_CLIENT bit = CASE WHEN EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.CLIENT'))   THEN 1 ELSE 0 END;
        DECLARE @CT_CET    bit = CASE WHEN EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.CHSYSDEC')) THEN 1 ELSE 0 END;

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

        DECLARE @MinValid bigint =
        (
            SELECT MAX(CHANGE_TRACKING_MIN_VALID_VERSION(object_id))
            FROM sys.change_tracking_tables
            WHERE object_id IN (
                OBJECT_ID(N'dbo.CLIENT_DY'),
                CASE WHEN @CT_CLIENT=1 THEN OBJECT_ID(N'dbo.CLIENT')   ELSE NULL END,
                CASE WHEN @CT_CET=1    THEN OBJECT_ID(N'dbo.CHSYSDEC') ELSE NULL END
            )
        );

        IF @MinValid IS NOT NULL AND @LastSyncVersion < @MinValid
        BEGIN
            IF @EmitInfo=1 RAISERROR('Watermark (%I64d) < CT min valid (%I64d). Re-baseline required.',16,1,@LastSyncVersion,@MinValid);
            SET @Summary = CONCAT(N'ClientDiary incremental failed: watermark ', @LastSyncVersion, N' < min valid ', @MinValid, N' (re-baseline).');
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;
            RETURN -200;
        END

        DECLARE @ToVersion bigint = CHANGE_TRACKING_CURRENT_VERSION();

        IF @EmitInfo=1
        BEGIN
            RAISERROR('ClientDiary CT incremental window:', 0, 1) WITH NOWAIT;
            RAISERROR('  From = %I64d', 0, 1, @LastSyncVersion) WITH NOWAIT;
            RAISERROR('  To   = %I64d', 0, 1, @ToVersion) WITH NOWAIT;
        END

        -- 2) Build changed key set
        IF OBJECT_ID('tempdb..#Changed') IS NOT NULL DROP TABLE #Changed;
        CREATE TABLE #Changed (ClientRef varchar(20) NOT NULL, DiaryRef varchar(20) NOT NULL, CONSTRAINT PK_Changed PRIMARY KEY (ClientRef, DiaryRef));

        DECLARE @JoinPK nvarchar(max);
        ;WITH pk AS (
            SELECT c.name AS colname, ic.key_ordinal
            FROM sys.indexes i
            JOIN sys.index_columns ic ON i.object_id=ic.object_id AND i.index_id=ic.index_id
            JOIN sys.columns c ON c.object_id=ic.object_id AND c.column_id=ic.column_id
            WHERE i.object_id = OBJECT_ID(N'dbo.CLIENT_DY') AND i.is_primary_key = 1
        )
        SELECT @JoinPK =
            STUFF((
                SELECT ' AND cdy.' + QUOTENAME(colname) + ' = x.' + QUOTENAME(colname)
                FROM pk
                ORDER BY key_ordinal
                FOR XML PATH(''), TYPE).value('.','nvarchar(max)'),1,5,'');

        IF @JoinPK IS NULL OR LEN(@JoinPK)=0
        BEGIN
            IF @EmitInfo=1 RAISERROR('dbo.CLIENT_DY has no primary key; cannot join CHANGETABLE.', 16, 1);
            SET @Summary = N'ClientDiary incremental failed: CLIENT_DY has no PK.';
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;
            RETURN -211;
        END

        DECLARE @sql nvarchar(max) = N'
INSERT INTO #Changed(ClientRef, DiaryRef)
SELECT DISTINCT CAST(cdy.CLIENT_REF AS varchar(20)), CAST(cdy.CL_DY_REF AS varchar(20))
FROM CHANGETABLE(CHANGES dbo.CLIENT_DY, @fromV) AS x
JOIN dbo.CLIENT_DY AS cdy ON ' + @JoinPK + N'
WHERE x.SYS_CHANGE_VERSION <= @toV;';

        EXEC sp_executesql @sql, N'@fromV bigint, @toV bigint', @fromV=@LastSyncVersion, @toV=@ToVersion;

        IF @CT_CET = 1
        BEGIN
            INSERT INTO #Changed(ClientRef, DiaryRef)
            SELECT DISTINCT CAST(cdy.CLIENT_REF AS varchar(20)), CAST(cdy.CL_DY_REF AS varchar(20))
            FROM CHANGETABLE(CHANGES dbo.CHSYSDEC, @LastSyncVersion) d
            JOIN dbo.CLIENT_DY cdy ON cdy.ENTRY_TYPE = d.DECODE_REF
            WHERE d.SYS_CHANGE_VERSION <= @ToVersion
              AND NOT EXISTS (SELECT 1 FROM #Changed z WHERE z.ClientRef = CAST(cdy.CLIENT_REF AS varchar(20)) AND z.DiaryRef = CAST(cdy.CL_DY_REF AS varchar(20)));
        END
        ELSE IF @EmitInfo=1
            RAISERROR('Note: CT not enabled on CHSYSDEC; entry-type text updates not tracked.', 0, 1) WITH NOWAIT;

        -- Find clients to purge (deleted or S/R)
        IF OBJECT_ID('tempdb..#ClientsToPurge') IS NOT NULL DROP TABLE #ClientsToPurge;
        CREATE TABLE #ClientsToPurge (ClientRef varchar(20) NOT NULL PRIMARY KEY);

        IF @CT_CLIENT = 1
        BEGIN
            INSERT INTO #ClientsToPurge(ClientRef)
            SELECT DISTINCT CAST(x.CLIENT_REF AS varchar(20))
            FROM CHANGETABLE(CHANGES dbo.CLIENT, @LastSyncVersion) x
            LEFT JOIN dbo.CLIENT c ON c.CLIENT_REF = x.CLIENT_REF
            WHERE x.SYS_CHANGE_VERSION <= @ToVersion
              AND (x.SYS_CHANGE_OPERATION = 'D' OR c.RECTYPE IN ('S','R'));
        END
        ELSE IF @EmitInfo=1
            RAISERROR('Note: CT not enabled on CLIENT; deactivations/deletes won''t purge diary rows automatically.', 0, 1) WITH NOWAIT;

        DECLARE @ToProcess int = (SELECT COUNT(*) FROM #Changed);
        IF @EmitInfo=1 RAISERROR('Diary rows to process: %d', 0, 1, @ToProcess) WITH NOWAIT;

        IF @ToProcess = 0 AND NOT EXISTS (SELECT 1 FROM #ClientsToPurge)
        BEGIN
            UPDATE dbo.CT_Watermark
              SET LastSyncVersion = @ToVersion, LastSyncTime = SYSUTCDATETIME()
            WHERE ProcessName = @Process;

            SET @EndUTC = SYSUTCDATETIME();
            SET @EndIso = CONVERT(varchar(33), @EndUTC, 126);
            SET @DurationSec = DATEDIFF(SECOND, @RunStartedAt, @EndUTC);

            SET @Summary = CONCAT(
                N'ClientDiary incremental started ', @StartIso, N' UTC; ended ', @EndIso,
                N' UTC; inserted 0, updated 0, deleted 0; advanced watermark to ',
                CAST(@ToVersion AS nvarchar(30)), N'; duration=', @DurationSec, N' sec.'
            );

            IF @EmitInfo=1 RAISERROR('No changes. Watermark advanced.', 0, 1) WITH NOWAIT;
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;

            IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;
            RETURN 0;
        END

        -- 3) Chunked UPSERT
        DECLARE @TotalInserted bigint = 0, @TotalUpdated bigint = 0, @TotalDeleted int = 0;

        WHILE EXISTS (SELECT 1 FROM #Changed)
        BEGIN
            IF OBJECT_ID('tempdb..#Next') IS NOT NULL DROP TABLE #Next;
            CREATE TABLE #Next (ClientRef varchar(20) NOT NULL, DiaryRef varchar(20) NOT NULL, CONSTRAINT PK_Next PRIMARY KEY (ClientRef, DiaryRef));

            INSERT INTO #Next(ClientRef, DiaryRef)
            SELECT TOP (@ChunkSize) ClientRef, DiaryRef
            FROM #Changed
            ORDER BY ClientRef, DiaryRef;

            IF OBJECT_ID('tempdb..#ActLog') IS NOT NULL DROP TABLE #ActLog;
            CREATE TABLE #ActLog(Action nvarchar(10) NOT NULL);

            ;WITH Base AS
            (
                SELECT
                    ClientReference           = CAST(cdy.CLIENT_REF AS varchar(20)),
                    ClientDiaryReference      = CAST(cdy.CL_DY_REF  AS varchar(20)),
                    ClientDiaryEntryDate      = cdy.ENTRY_DATE,
                    ClientDiaryEntryType      = cet.DESCRIPTION,
                    ClientDiaryEntryText      = cdy.ENTRY_TEXT,
                    ClientDiaryReminded       = cdy.REMINDED,
                    ClientDiaryReviewDate     = cdy.REVIEW_DATE,
                    ClientDiaryAction         = cdy.ACTION,
                    ClientDiaryActionDate     = cdy.ACTIONDT,
                    ClientDiaryReviewDoneDate = cdy.REVDONE_DT
                FROM dbo.CLIENT_DY cdy
                JOIN #Next n
                  ON n.ClientRef = CAST(cdy.CLIENT_REF AS varchar(20))
                 AND n.DiaryRef  = CAST(cdy.CL_DY_REF  AS varchar(20))
                INNER JOIN dbo.CLIENT c
                  ON c.CLIENT_REF = cdy.CLIENT_REF
                LEFT JOIN dbo.CHSYSDEC cet
                  ON cet.DECODE_REF = cdy.ENTRY_TYPE
                WHERE c.RECTYPE NOT IN ('S','R')
            )
            MERGE dbo.tbl_ClientDiary AS tgt
            USING Base AS src
              ON  tgt.ClientReference      = src.ClientReference
              AND tgt.ClientDiaryReference = src.ClientDiaryReference
            WHEN MATCHED THEN
                UPDATE SET
                    tgt.ClientDiaryEntryDate      = src.ClientDiaryEntryDate,
                    tgt.ClientDiaryEntryType      = src.ClientDiaryEntryType,
                    tgt.ClientDiaryEntryText      = src.ClientDiaryEntryText,
                    tgt.ClientDiaryReminded       = src.ClientDiaryReminded,
                    tgt.ClientDiaryReviewDate     = src.ClientDiaryReviewDate,
                    tgt.ClientDiaryAction         = src.ClientDiaryAction,
                    tgt.ClientDiaryActionDate     = src.ClientDiaryActionDate,
                    tgt.ClientDiaryReviewDoneDate = src.ClientDiaryReviewDoneDate,
                    tgt.UpdatedAtUTC              = @RunStartedAt
            WHEN NOT MATCHED BY TARGET THEN
                INSERT (
                    ClientReference, ClientDiaryReference,
                    ClientDiaryEntryDate, ClientDiaryEntryType, ClientDiaryEntryText,
                    ClientDiaryReminded, ClientDiaryReviewDate,
                    ClientDiaryAction, ClientDiaryActionDate, ClientDiaryReviewDoneDate,
                    CreatedAtUTC, UpdatedAtUTC
                )
                VALUES (
                    src.ClientReference, src.ClientDiaryReference,
                    src.ClientDiaryEntryDate, src.ClientDiaryEntryType, src.ClientDiaryEntryText,
                    src.ClientDiaryReminded, src.ClientDiaryReviewDate,
                    src.ClientDiaryAction, src.ClientDiaryActionDate, src.ClientDiaryReviewDoneDate,
                    @RunStartedAt, @RunStartedAt
                )
            WHEN NOT MATCHED BY SOURCE
                 AND EXISTS (SELECT 1 FROM #Next nn WHERE nn.ClientRef = tgt.ClientReference AND nn.DiaryRef = tgt.ClientDiaryReference)
                 THEN DELETE
            OUTPUT $action INTO #ActLog(Action);

            DECLARE @i int = 0, @u int = 0, @d int = 0;
            SELECT @i = SUM(CASE WHEN Action='INSERT' THEN 1 ELSE 0 END),
                   @u = SUM(CASE WHEN Action='UPDATE' THEN 1 ELSE 0 END),
                   @d = SUM(CASE WHEN Action='DELETE' THEN 1 ELSE 0 END)
            FROM #ActLog;

            SET @TotalInserted += ISNULL(@i,0);
            SET @TotalUpdated  += ISNULL(@u,0);
            SET @TotalDeleted  += ISNULL(@d,0);

            IF @EmitInfo=1
                RAISERROR('ClientDiary chunk upserted: inserted=%d updated=%d deleted=%d (running %d/%d/%d)',
                          0,1,@i,@u,@d,@TotalInserted,@TotalUpdated,@TotalDeleted) WITH NOWAIT;

            DELETE c
            FROM #Changed c
            JOIN #Next n ON n.ClientRef = c.ClientRef AND n.DiaryRef = c.DiaryRef;
        END

        -- Purge for client deletes/SR
        IF EXISTS (SELECT 1 FROM #ClientsToPurge)
        BEGIN
            IF OBJECT_ID('tempdb..#DelLog') IS NOT NULL DROP TABLE #DelLog;
            CREATE TABLE #DelLog (ClientRef varchar(20) NOT NULL);

            DELETE tgt
            OUTPUT DELETED.ClientReference INTO #DelLog(ClientRef)
            FROM dbo.tbl_ClientDiary tgt
            JOIN #ClientsToPurge p ON p.ClientRef = tgt.ClientReference;

            DECLARE @Purged int = (SELECT COUNT(*) FROM #DelLog);
            SET @TotalDeleted += @Purged;
            IF @EmitInfo=1 RAISERROR('Purged diary rows for deactivated/deleted clients: %d', 0, 1, @Purged) WITH NOWAIT;
        END

        -- 5) Advance watermark + summary
        UPDATE dbo.CT_Watermark
          SET LastSyncVersion=@ToVersion, LastSyncTime=SYSUTCDATETIME()
        WHERE ProcessName=@Process;

        SET @EndUTC = SYSUTCDATETIME();
        SET @EndIso = CONVERT(varchar(33), @EndUTC, 126);
        SET @DurationSec = DATEDIFF(SECOND, @RunStartedAt, @EndUTC);

        SET @Summary = CONCAT(
            N'ClientDiary incremental started ', @StartIso, N' UTC; ended ', @EndIso,
            N' UTC; inserted ', CAST(@TotalInserted AS nvarchar(20)),
            N', updated ', CAST(@TotalUpdated AS nvarchar(20)),
            N', deleted ', CAST(@TotalDeleted AS nvarchar(20)),
            N'; advanced watermark to ', CAST(@ToVersion AS nvarchar(30)),
            N'; duration=', CAST(@DurationSec AS nvarchar(20)), N' sec.'
        );

        IF @EmitInfo=1
        BEGIN
            RAISERROR('ClientDiary incremental sync complete.', 0, 1) WITH NOWAIT;
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
        IF @EmitInfo=1 RAISERROR('usp_Sync_ClientDiary_Incremental failed (%d, sev %d, state %d) at %s line %d: %s',16,1,@num,@sev,@st,@procName,@lin,@msg);
        SET @Summary = CONCAT(N'ClientDiary incremental failed: ', @msg);
        IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
        RETURN -50001;
    END CATCH
END
GO
