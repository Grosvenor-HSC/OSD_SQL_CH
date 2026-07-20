/*
Purpose:
    Incrementally load new/updated/deleted client diary records into dbo.tbl_ClientDiary
    using SQL Server Change Tracking.

Source:
    dbo.CLIENT_DY (+ optional dbo.CHSYSDEC, dbo.CLIENT)

Target:
    dbo.tbl_ClientDiary

Run type:
    Incremental (daily)

Design:
    - Fences CT window at start (From watermark -> ToVersion)
    - Chunked MERGE to control log/locks
    - Optional purge of diary rows for deleted/deactivated clients (if CT enabled on dbo.CLIENT)
    - Optional refresh when entry-type decode text changes (if CT enabled on dbo.CHSYSDEC)
    - Safe to re-run (watermark advances only on success)

Notes:
    - Requires CT enabled at DB level and on dbo.CLIENT_DY.
    - Requires dbo.CLIENT_DY to have a primary key (used to re-join CHANGETABLE rows).
    - Requires dbo.tbl_ClientDiary to exist (run initial first).
*/

USE [DOM_LIVE];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE [dbo].[usp_Sync_ClientDiary_Incremental]
    @ChunkSize         int  = 100000,
    @LockTimeoutMs     int  = 60000,
    @UseAppLock        bit  = 1,
    @EmitInfo          bit  = 0,                          -- 0=silent, 1=progress
    @Summary           nvarchar(4000) = NULL OUTPUT,      -- one-line summary
    @ReturnSummaryRow  bit  = 1                           -- emit SELECT Stage/Summary row
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET ANSI_WARNINGS ON;

    DECLARE @Process       sysname      = N'ClientDiary';
    DECLARE @RunStartedAt  datetime2(3) = SYSUTCDATETIME();
    DECLARE @StartIso      varchar(33)  = CONVERT(varchar(33), @RunStartedAt, 126);
    DECLARE @EndUTC        datetime2(3);
    DECLARE @EndIso        varchar(33);
    DECLARE @DurationSec   int;

    /* Concurrency */
    DECLARE @LockResource sysname = N'DOM_LIVE:Sync:ClientDiary';
    DECLARE @LockOwner    sysname = N'Session';
    DECLARE @DbPrincipal  sysname = N'dbo';
    DECLARE @lockResult   int;
    DECLARE @lockHeld     bit = 0;

    /* Single-exit helpers */
    DECLARE @rc int = 0;

    IF @UseAppLock = 1
    BEGIN
        EXEC @lockResult = sys.sp_getapplock
            @Resource=@LockResource,
            @LockMode='Exclusive',
            @LockOwner=@LockOwner,
            @DbPrincipal=@DbPrincipal,
            @LockTimeout=@LockTimeoutMs;

        IF @lockResult NOT IN (0,1)
        BEGIN
            SET @Summary = N'ClientDiary incremental failed: could not acquire applock.';
            IF @ReturnSummaryRow=1 SELECT N'Incremental' AS Stage, @Summary AS Summary;
            RETURN @lockResult;
        END

        SET @lockHeld = 1;
    END

    BEGIN TRY
        /* ------------------------------------------------------------
           1) Preconditions
           ------------------------------------------------------------ */
        IF OBJECT_ID(N'dbo.tbl_ClientDiary', N'U') IS NULL
        BEGIN
            SET @Summary = N'ClientDiary incremental failed: missing dbo.tbl_ClientDiary (run ClientDiary initial first).';
            IF @ReturnSummaryRow=1 SELECT N'Incremental' AS Stage, @Summary AS Summary;
            SET @rc = -300;
            GOTO Finally;
        END

        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_databases WHERE database_id = DB_ID())
        BEGIN
            SET @Summary = N'ClientDiary incremental failed: Change Tracking is not enabled at DB level.';
            IF @ReturnSummaryRow=1 SELECT N'Incremental' AS Stage, @Summary AS Summary;
            SET @rc = -100;
            GOTO Finally;
        END

        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.CLIENT_DY'))
        BEGIN
            SET @Summary = N'ClientDiary incremental failed: CT not enabled on dbo.CLIENT_DY.';
            IF @ReturnSummaryRow=1 SELECT N'Incremental' AS Stage, @Summary AS Summary;
            SET @rc = -210;
            GOTO Finally;
        END

        DECLARE @CT_CLIENT bit = CASE WHEN EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.CLIENT'))   THEN 1 ELSE 0 END;
        DECLARE @CT_DEC    bit = CASE WHEN EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.CHSYSDEC')) THEN 1 ELSE 0 END;

        /* Watermark table */
        IF OBJECT_ID(N'dbo.CT_Watermark', N'U') IS NULL
        BEGIN
            CREATE TABLE dbo.CT_Watermark
            (
                ProcessName     sysname      PRIMARY KEY,
                LastSyncVersion bigint       NOT NULL,
                LastSyncTime    datetime2(3) NOT NULL DEFAULT SYSUTCDATETIME()
            );
        END

        IF NOT EXISTS (SELECT 1 FROM dbo.CT_Watermark WITH (HOLDLOCK, UPDLOCK) WHERE ProcessName=@Process)
        BEGIN
            INSERT INTO dbo.CT_Watermark(ProcessName, LastSyncVersion) VALUES (@Process, 0);
        END

        DECLARE @LastSyncVersion bigint =
            (SELECT LastSyncVersion FROM dbo.CT_Watermark WITH (HOLDLOCK, UPDLOCK) WHERE ProcessName=@Process);

        DECLARE @ToVersion bigint = CHANGE_TRACKING_CURRENT_VERSION();

        /* CT retention safety: if watermark is older than min valid => re-baseline */
        DECLARE @MinValid bigint =
        (
            SELECT MAX(CHANGE_TRACKING_MIN_VALID_VERSION(object_id))
            FROM sys.change_tracking_tables
            WHERE object_id IN
            (
                OBJECT_ID(N'dbo.CLIENT_DY'),
                CASE WHEN @CT_CLIENT=1 THEN OBJECT_ID(N'dbo.CLIENT')   ELSE NULL END,
                CASE WHEN @CT_DEC=1    THEN OBJECT_ID(N'dbo.CHSYSDEC') ELSE NULL END
            )
        );

        IF @MinValid IS NOT NULL AND @LastSyncVersion < @MinValid
        BEGIN
            SET @Summary = CONCAT(
                N'ClientDiary incremental failed: watermark ', @LastSyncVersion,
                N' < CT min valid ', @MinValid, N' (re-baseline required).'
            );
            IF @ReturnSummaryRow=1 SELECT N'Incremental' AS Stage, @Summary AS Summary;
            SET @rc = -200;
            GOTO Finally;
        END

        IF @EmitInfo=1
            RAISERROR('ClientDiary CT window: From=%I64d To=%I64d', 0, 1, @LastSyncVersion, @ToVersion) WITH NOWAIT;

        /* ------------------------------------------------------------
           2) Build changed keyset
              (ClientRef, DiaryRef) from CT changes on CLIENT_DY
           ------------------------------------------------------------ */
        IF OBJECT_ID('tempdb..#Changed') IS NOT NULL DROP TABLE #Changed;
        CREATE TABLE #Changed
        (
            ClientRef INT NOT NULL,
            DiaryRef  INT NOT NULL,
            CONSTRAINT PK_Changed PRIMARY KEY (ClientRef, DiaryRef)
        );

        /* Build join predicate back to CLIENT_DY using its real PK columns */
        DECLARE @JoinPK nvarchar(max);

        ;WITH pk AS
        (
            SELECT c.name AS colname, ic.key_ordinal
            FROM sys.indexes i
            JOIN sys.index_columns ic ON i.object_id=ic.object_id AND i.index_id=ic.index_id
            JOIN sys.columns c ON c.object_id=ic.object_id AND c.column_id=ic.column_id
            WHERE i.object_id = OBJECT_ID(N'dbo.CLIENT_DY')
              AND i.is_primary_key = 1
        )
        SELECT @JoinPK =
            STUFF((
                SELECT ' AND cdy.' + QUOTENAME(colname) + ' = x.' + QUOTENAME(colname)
                FROM pk
                ORDER BY key_ordinal
                FOR XML PATH(''), TYPE
            ).value('.','nvarchar(max)'), 1, 5, '');

        IF @JoinPK IS NULL OR LEN(@JoinPK)=0
        BEGIN
            SET @Summary = N'ClientDiary incremental failed: dbo.CLIENT_DY has no primary key (cannot re-join CHANGETABLE rows).';
            IF @ReturnSummaryRow=1 SELECT N'Incremental' AS Stage, @Summary AS Summary;
            SET @rc = -211;
            GOTO Finally;
        END

        DECLARE @sql nvarchar(max) = N'
INSERT INTO #Changed(ClientRef, DiaryRef)
SELECT DISTINCT cdy.CLIENT_REF, cdy.CL_DY_REF
FROM CHANGETABLE(CHANGES dbo.CLIENT_DY, @fromV) AS x
JOIN dbo.CLIENT_DY AS cdy ON ' + @JoinPK + N'
WHERE x.SYS_CHANGE_VERSION <= @toV;
';

        EXEC sys.sp_executesql
            @sql,
            N'@fromV bigint, @toV bigint',
            @fromV=@LastSyncVersion,
            @toV=@ToVersion;

        /* Optional: track decode-text changes affecting diary ENTRY_TYPE */
        IF @CT_DEC = 1
        BEGIN
            INSERT INTO #Changed(ClientRef, DiaryRef)
            SELECT DISTINCT cdy.CLIENT_REF, cdy.CL_DY_REF
            FROM CHANGETABLE(CHANGES dbo.CHSYSDEC, @LastSyncVersion) d
            JOIN dbo.CLIENT_DY cdy ON cdy.ENTRY_TYPE = d.DECODE_REF
            WHERE d.SYS_CHANGE_VERSION <= @ToVersion
              AND NOT EXISTS
              (
                  SELECT 1
                  FROM #Changed z
                  WHERE z.ClientRef = cdy.CLIENT_REF
                    AND z.DiaryRef  = cdy.CL_DY_REF
              );
        END
        ELSE IF @EmitInfo=1
            RAISERROR('Note: CT not enabled on CHSYSDEC; ENTRY_TYPE text changes will not trigger refresh.', 0, 1) WITH NOWAIT;

        /* Optional: find clients to purge (deleted or S/R) */
        IF OBJECT_ID('tempdb..#ClientsToPurge') IS NOT NULL DROP TABLE #ClientsToPurge;
        CREATE TABLE #ClientsToPurge (ClientRef INT NOT NULL PRIMARY KEY);

        IF @CT_CLIENT = 1
        BEGIN
            INSERT INTO #ClientsToPurge(ClientRef)
            SELECT DISTINCT x.CLIENT_REF
            FROM CHANGETABLE(CHANGES dbo.CLIENT, @LastSyncVersion) x
            LEFT JOIN dbo.CLIENT c ON c.CLIENT_REF = x.CLIENT_REF
            WHERE x.SYS_CHANGE_VERSION <= @ToVersion
              AND (x.SYS_CHANGE_OPERATION = 'D' OR c.RECTYPE IN ('S','R'));
        END
        ELSE IF @EmitInfo=1
            RAISERROR('Note: CT not enabled on CLIENT; client deletes/SR will not auto-purge diary rows.', 0, 1) WITH NOWAIT;

        DECLARE @ToProcess int = (SELECT COUNT(*) FROM #Changed);

        IF @EmitInfo=1
            RAISERROR('Diary rows to process: %d', 0, 1, @ToProcess) WITH NOWAIT;

        IF @ToProcess = 0 AND NOT EXISTS (SELECT 1 FROM #ClientsToPurge)
        BEGIN
            UPDATE dbo.CT_Watermark
              SET LastSyncVersion=@ToVersion,
                  LastSyncTime=SYSUTCDATETIME()
            WHERE ProcessName=@Process;

            SET @EndUTC = SYSUTCDATETIME();
            SET @EndIso = CONVERT(varchar(33), @EndUTC, 126);
            SET @DurationSec = DATEDIFF(SECOND, @RunStartedAt, @EndUTC);

            SET @Summary = CONCAT(
                N'ClientDiary incremental started ', @StartIso, N' UTC; ended ', @EndIso,
                N' UTC; inserted 0, updated 0, deleted 0; advanced watermark to ',
                CAST(@ToVersion AS nvarchar(30)), N'; duration=', @DurationSec, N' sec.'
            );

            IF @ReturnSummaryRow=1 SELECT N'Incremental' AS Stage, @Summary AS Summary;
            SET @rc = 0;
            GOTO Finally;
        END

        /* ------------------------------------------------------------
           3) Chunked MERGE
           ------------------------------------------------------------ */
        DECLARE @TotalInserted bigint = 0, @TotalUpdated bigint = 0, @TotalDeleted int = 0;

        WHILE EXISTS (SELECT 1 FROM #Changed)
        BEGIN
            IF OBJECT_ID('tempdb..#Next') IS NOT NULL DROP TABLE #Next;
            CREATE TABLE #Next
            (
                ClientRef INT NOT NULL,
                DiaryRef  INT NOT NULL,
                CONSTRAINT PK_Next PRIMARY KEY (ClientRef, DiaryRef)
            );

            INSERT INTO #Next(ClientRef, DiaryRef)
            SELECT TOP (@ChunkSize) ClientRef, DiaryRef
            FROM #Changed
            ORDER BY ClientRef, DiaryRef;

            IF OBJECT_ID('tempdb..#ActLog') IS NOT NULL DROP TABLE #ActLog;
            CREATE TABLE #ActLog(Action nvarchar(10) NOT NULL);

            ;WITH Base AS
            (
                SELECT
                    Client_UUID            = cdy.CLIENT_REF,
                    UUID                   = cdy.CL_DY_REF,
                    Client_Diary_Entry_Date = cdy.ENTRY_DATE,
                    Client_Diary_Entry_Type = NULLIF(LTRIM(RTRIM(cet.DESCRIPTION)), N''),
                    Client_Diary_Entry_Text = cdy.ENTRY_TEXT
                FROM dbo.CLIENT_DY cdy
                JOIN #Next n
                  ON n.ClientRef = cdy.CLIENT_REF
                 AND n.DiaryRef  = cdy.CL_DY_REF
                JOIN dbo.CLIENT c
                  ON c.CLIENT_REF = cdy.CLIENT_REF
                LEFT JOIN dbo.CHSYSDEC cet
                  ON cet.DECODE_REF = cdy.ENTRY_TYPE
                WHERE c.RECTYPE NOT IN ('S','R')
            )
            MERGE dbo.tbl_ClientDiary AS tgt
            USING Base AS src
              ON  tgt.Client_UUID = src.Client_UUID
              AND tgt.UUID        = src.UUID
            WHEN MATCHED THEN
                UPDATE SET
                    tgt.Client_Diary_Entry_Date = src.Client_Diary_Entry_Date,
                    tgt.Client_Diary_Entry_Type = src.Client_Diary_Entry_Type,
                    tgt.Client_Diary_Entry_Text = src.Client_Diary_Entry_Text,
                    tgt.UpdatedAtUTC            = @RunStartedAt
            WHEN NOT MATCHED BY TARGET THEN
                INSERT
                (
                    Client_UUID, UUID,
                    Client_Diary_Entry_Date, Client_Diary_Entry_Type, Client_Diary_Entry_Text,
                    CreatedAtUTC, UpdatedAtUTC
                )
                VALUES
                (
                    src.Client_UUID, src.UUID,
                    src.Client_Diary_Entry_Date, src.Client_Diary_Entry_Type, src.Client_Diary_Entry_Text,
                    @RunStartedAt, @RunStartedAt
                )
            WHEN NOT MATCHED BY SOURCE
                 AND EXISTS
                 (
                     SELECT 1
                     FROM #Next nn
                     WHERE nn.ClientRef = tgt.Client_UUID
                       AND nn.DiaryRef  = tgt.UUID
                 )
                 THEN DELETE
            OUTPUT $action INTO #ActLog(Action);

            DECLARE @i int = 0, @u int = 0, @d int = 0;

            SELECT
                @i = SUM(CASE WHEN Action='INSERT' THEN 1 ELSE 0 END),
                @u = SUM(CASE WHEN Action='UPDATE' THEN 1 ELSE 0 END),
                @d = SUM(CASE WHEN Action='DELETE' THEN 1 ELSE 0 END)
            FROM #ActLog;

            SET @TotalInserted += ISNULL(@i,0);
            SET @TotalUpdated  += ISNULL(@u,0);
            SET @TotalDeleted  += ISNULL(@d,0);

            IF @EmitInfo=1
                RAISERROR('ClientDiary chunk: inserted=%d updated=%d deleted=%d (running %d/%d/%d)',
                          0,1,@i,@u,@d,@TotalInserted,@TotalUpdated,@TotalDeleted) WITH NOWAIT;

            DELETE c
            FROM #Changed c
            JOIN #Next n
              ON n.ClientRef = c.ClientRef
             AND n.DiaryRef  = c.DiaryRef;
        END

        /* Purge for client deletes/SR */
        IF EXISTS (SELECT 1 FROM #ClientsToPurge)
        BEGIN
            IF OBJECT_ID('tempdb..#PurgeLog') IS NOT NULL DROP TABLE #PurgeLog;
            CREATE TABLE #PurgeLog (ClientRef INT NOT NULL);

            DELETE tgt
            OUTPUT DELETED.Client_UUID INTO #PurgeLog(ClientRef)
            FROM dbo.tbl_ClientDiary tgt
            JOIN #ClientsToPurge p
              ON p.ClientRef = tgt.Client_UUID;

            DECLARE @Purged int = (SELECT COUNT(*) FROM #PurgeLog);
            SET @TotalDeleted += @Purged;

            IF @EmitInfo=1
                RAISERROR('Purged diary rows for deleted/deactivated clients: %d', 0, 1, @Purged) WITH NOWAIT;
        END

        /* ------------------------------------------------------------
           4) Advance watermark + summary
           ------------------------------------------------------------ */
        UPDATE dbo.CT_Watermark
          SET LastSyncVersion=@ToVersion,
              LastSyncTime=SYSUTCDATETIME()
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

        IF @ReturnSummaryRow=1
            SELECT N'Incremental' AS Stage, @Summary AS Summary;

        SET @rc = 0;

Finally:
        IF @lockHeld=1
            EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;

        RETURN @rc;
    END TRY
    BEGIN CATCH
        IF @lockHeld=1
            EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;

        DECLARE @err nvarchar(4000)=ERROR_MESSAGE();
        DECLARE @num int=ERROR_NUMBER(), @sev int=ERROR_SEVERITY(), @st int=ERROR_STATE(),
                @lin int=ERROR_LINE(), @proc sysname=ERROR_PROCEDURE();
        DECLARE @procName sysname = ISNULL(@proc, N'<adhoc>');

        IF @EmitInfo=1
            RAISERROR('usp_Sync_ClientDiary_Incremental failed (%d, sev %d, state %d) at %s line %d: %s',
                      16,1,@num,@sev,@st,@procName,@lin,@err);

        SET @Summary = CONCAT(N'ClientDiary incremental failed: ', @err);
        IF @ReturnSummaryRow=1 SELECT N'Incremental' AS Stage, @Summary AS Summary;

        RETURN -50001;
    END CATCH
END;
GO
