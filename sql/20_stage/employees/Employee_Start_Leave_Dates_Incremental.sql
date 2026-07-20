USE [DOM_LIVE];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Sync_EmployeeStartLeaveDates_Incremental
    @ChunkSize        int  = 100000,
    @LockTimeoutMs    int  = 60000,
    @UseAppLock       bit  = 1,
    @EmitInfo         bit  = 1,                       -- 0=quiet
    @Summary          nvarchar(4000) = NULL OUTPUT,   -- one-line summary
    @ReturnSummaryRow bit  = 1                        -- 1=SELECT Stage/Summary row
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Process       sysname      = N'EmployeeStartLeaveDates';
    DECLARE @RunStartedAt  datetime2(3) = SYSUTCDATETIME();
    DECLARE @StartIso      varchar(33)  = CONVERT(varchar(33), @RunStartedAt, 126);
    DECLARE @EndUTC        datetime2(3);
    DECLARE @EndIso        varchar(33);
    DECLARE @DurationSec   int;

    /* ----------------------- 0) Concurrency guard ----------------------- */
    DECLARE @LockResource sysname = N'DOM_LIVE:Sync:EmployeeStartLeaveDates';
    DECLARE @LockOwner    sysname = N'Session';
    DECLARE @DbPrincipal  sysname = N'dbo';
    DECLARE @lockResult   int;
    DECLARE @lockHeld     bit = 0;

    IF @UseAppLock = 1
    BEGIN
        EXEC @lockResult = sys.sp_getapplock
            @Resource=@LockResource, @LockMode='Exclusive',
            @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal,
            @LockTimeout=@LockTimeoutMs;

        IF @lockResult NOT IN (0,1)
        BEGIN
            IF @EmitInfo=1 RAISERROR('Could not acquire %s (rc=%d).',16,1,@LockResource,@lockResult);
            SET @Summary = N'EmployeeStartLeaveDates incremental failed: could not acquire applock.';
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            RETURN @lockResult;
        END
        SET @lockHeld = 1;
    END

    BEGIN TRY
        /* ----------------------- 1) Preconditions ----------------------- */
        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_databases WHERE database_id = DB_ID())
        BEGIN
            IF @EmitInfo=1 RAISERROR('Change Tracking is not enabled at DB level.', 16, 1);
            SET @Summary = N'EmployeeStartLeaveDates incremental failed: CT not enabled at DB level.';
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            GOTO FinallyRelease;
        END

        IF OBJECT_ID(N'dbo.tbl_EmployeeBranch', N'U') IS NULL
        BEGIN
            IF @EmitInfo=1 RAISERROR('Driver table dbo.tbl_EmployeeBranch is missing.', 16, 1);
            SET @Summary = N'EmployeeStartLeaveDates incremental failed: tbl_EmployeeBranch missing.';
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            GOTO FinallyRelease;
        END

        IF OBJECT_ID(N'dbo.tbl_EmployeeStartLeaveDates', N'U') IS NULL
        BEGIN
            IF @EmitInfo=1 RAISERROR('Target dbo.tbl_EmployeeStartLeaveDates is missing. Run initial.', 16, 1);
            SET @Summary = N'EmployeeStartLeaveDates incremental failed: target missing (run initial).';
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            GOTO FinallyRelease;
        END

        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.tbl_EmployeeBranch'))
        BEGIN
            IF @EmitInfo=1 RAISERROR('CT not enabled on dbo.tbl_EmployeeBranch.', 16, 1);
            SET @Summary = N'EmployeeStartLeaveDates incremental failed: CT not enabled on tbl_EmployeeBranch.';
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            GOTO FinallyRelease;
        END

        /* ----------------------- 2) Watermark ----------------------- */
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
            INSERT INTO dbo.CT_Watermark(ProcessName, LastSyncVersion) VALUES (@Process, 0);

        DECLARE @LastSyncVersion bigint =
            (SELECT LastSyncVersion FROM dbo.CT_Watermark WITH (HOLDLOCK, UPDLOCK) WHERE ProcessName=@Process);

        DECLARE @MinValid bigint = CHANGE_TRACKING_MIN_VALID_VERSION(OBJECT_ID(N'dbo.tbl_EmployeeBranch'));
        IF @MinValid IS NOT NULL AND @LastSyncVersion < @MinValid
        BEGIN
            IF @EmitInfo=1 RAISERROR('Watermark %I64d < CT min valid %I64d (re-baseline required).',16,1,@LastSyncVersion,@MinValid);
            SET @Summary = CONCAT(N'EmployeeStartLeaveDates incremental failed: watermark ', @LastSyncVersion, N' < min valid ', @MinValid, N'.');
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            GOTO FinallyRelease;
        END

        DECLARE @ToVersion bigint = CHANGE_TRACKING_CURRENT_VERSION();

        IF @EmitInfo=1
        BEGIN
            RAISERROR('EmployeeStartLeaveDates CT window:', 0, 1) WITH NOWAIT;
            RAISERROR('  From=%I64d', 0, 1, @LastSyncVersion) WITH NOWAIT;
            RAISERROR('  To  =%I64d', 0, 1, @ToVersion)       WITH NOWAIT;
        END

        /* ----------------------- 3) Ensure KeyMap exists with UUID type matching tbl_EmployeeBranch.UUID ----------------------- */
        DECLARE @UuidType sysname;
        DECLARE @UuidMaxLen smallint;
        DECLARE @UuidPrecision tinyint;
        DECLARE @UuidScale tinyint;
        DECLARE @UuidCollation sysname;

        SELECT
            @UuidType      = t.name,
            @UuidMaxLen    = c.max_length,
            @UuidPrecision = c.precision,
            @UuidScale     = c.scale,
            @UuidCollation = c.collation_name
        FROM sys.columns c
        JOIN sys.types t
          ON t.user_type_id = c.user_type_id
        WHERE c.object_id = OBJECT_ID(N'dbo.tbl_EmployeeBranch')
          AND c.name = N'UUID';

        IF @UuidType IS NULL
            RAISERROR('Could not resolve dbo.tbl_EmployeeBranch.UUID datatype.', 16, 1);

        IF OBJECT_ID(N'dbo.tbl_EmployeeBranch_KeyMap', N'U') IS NULL
        BEGIN
            DECLARE @createKeyMap nvarchar(max);

            SET @createKeyMap =
                N'CREATE TABLE dbo.tbl_EmployeeBranch_KeyMap (' + CHAR(10) +
                N'  UUID ' +
                CASE
                    WHEN @UuidType IN (N'varchar', N'char', N'nvarchar', N'nchar', N'binary', N'varbinary')
                        THEN QUOTENAME(@UuidType) + N'(' + CASE WHEN @UuidMaxLen = -1 THEN N'max' ELSE CONVERT(varchar(10), CASE WHEN @UuidType IN (N'nvarchar',N'nchar') THEN @UuidMaxLen/2 ELSE @UuidMaxLen END) END + N')'
                             + CASE WHEN @UuidCollation IS NOT NULL AND @UuidType IN (N'varchar',N'char',N'nvarchar',N'nchar') THEN N' COLLATE ' + QUOTENAME(@UuidCollation) ELSE N'' END
                    WHEN @UuidType IN (N'decimal', N'numeric')
                        THEN QUOTENAME(@UuidType) + N'(' + CONVERT(varchar(10), @UuidPrecision) + N',' + CONVERT(varchar(10), @UuidScale) + N')'
                    ELSE QUOTENAME(@UuidType)
                END +
                N' NOT NULL PRIMARY KEY,' + CHAR(10) +
                N'  Employee_UUID varchar(50) NOT NULL,' + CHAR(10) +
                N'  UpdatedAtUTC  datetime2(3) NOT NULL CONSTRAINT DF_tbl_EB_KeyMap_UpdatedAtUTC DEFAULT SYSUTCDATETIME()' + CHAR(10) +
                N');';

            EXEC sys.sp_executesql @createKeyMap;

            -- seed
            DECLARE @seedKeyMap nvarchar(max) =
                N'INSERT INTO dbo.tbl_EmployeeBranch_KeyMap (UUID, Employee_UUID)
                  SELECT eb.UUID, eb.Employee_UUID
                  FROM dbo.tbl_EmployeeBranch eb;';
            EXEC sys.sp_executesql @seedKeyMap;
        END
        ELSE
        BEGIN
            -- keep it updated (I/U only; D handled by keeping old mapping)
            DECLARE @mergeKeyMap nvarchar(max) =
                N'MERGE dbo.tbl_EmployeeBranch_KeyMap AS m
                  USING (SELECT eb.UUID, eb.Employee_UUID FROM dbo.tbl_EmployeeBranch eb) AS s
                    ON m.UUID = s.UUID
                  WHEN MATCHED AND m.Employee_UUID <> s.Employee_UUID THEN
                    UPDATE SET m.Employee_UUID = s.Employee_UUID, m.UpdatedAtUTC = SYSUTCDATETIME()
                  WHEN NOT MATCHED BY TARGET THEN
                    INSERT (UUID, Employee_UUID) VALUES (s.UUID, s.Employee_UUID);';
            EXEC sys.sp_executesql @mergeKeyMap;
        END

        /* ----------------------- 4) Build changed Employee_UUID set ----------------------- */
        IF OBJECT_ID('tempdb..#Changed') IS NOT NULL DROP TABLE #Changed;
        CREATE TABLE #Changed (Employee_UUID varchar(50) NOT NULL PRIMARY KEY);

        -- I/U
        INSERT INTO #Changed(Employee_UUID)
        SELECT DISTINCT eb.Employee_UUID
        FROM CHANGETABLE(CHANGES dbo.tbl_EmployeeBranch, @LastSyncVersion) ct
        JOIN dbo.tbl_EmployeeBranch eb
          ON eb.UUID = ct.UUID
        WHERE ct.SYS_CHANGE_VERSION <= @ToVersion
          AND ct.SYS_CHANGE_OPERATION IN ('I','U');

        -- D (resolved via KeyMap)
        INSERT INTO #Changed(Employee_UUID)
        SELECT DISTINCT km.Employee_UUID
        FROM CHANGETABLE(CHANGES dbo.tbl_EmployeeBranch, @LastSyncVersion) ct
        JOIN dbo.tbl_EmployeeBranch_KeyMap km
          ON km.UUID = ct.UUID
        WHERE ct.SYS_CHANGE_VERSION <= @ToVersion
          AND ct.SYS_CHANGE_OPERATION = 'D'
          AND NOT EXISTS (SELECT 1 FROM #Changed z WHERE z.Employee_UUID = km.Employee_UUID);

        DECLARE @ToProcess int = (SELECT COUNT(*) FROM #Changed);
        IF @EmitInfo=1 RAISERROR('Changed employees to (re)aggregate: %d', 0, 1, @ToProcess) WITH NOWAIT;

        IF @ToProcess = 0
        BEGIN
            UPDATE dbo.CT_Watermark
              SET LastSyncVersion=@ToVersion, LastSyncTime=SYSUTCDATETIME()
            WHERE ProcessName=@Process;

            SET @EndUTC = SYSUTCDATETIME();
            SET @EndIso = CONVERT(varchar(33), @EndUTC, 126);
            SET @DurationSec = DATEDIFF(SECOND, @RunStartedAt, @EndUTC);

            SET @Summary = CONCAT(
                N'EmployeeStartLeaveDates incremental started ', @StartIso, N' UTC; ended ', @EndIso,
                N' UTC; inserted 0, updated 0, deleted 0; advanced watermark to ',
                CAST(@ToVersion AS nvarchar(30)), N'; duration=', @DurationSec, N' sec.'
            );
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            GOTO FinallyRelease;
        END

        /* ----------------------- 5) Chunked MERGE into target (incl delete when no branch rows remain) ----------------------- */
        DECLARE @TotalInserted bigint = 0, @TotalUpdated bigint = 0, @TotalDeleted bigint = 0;

        WHILE EXISTS (SELECT 1 FROM #Changed)
        BEGIN
            IF OBJECT_ID('tempdb..#Next') IS NOT NULL DROP TABLE #Next;
            CREATE TABLE #Next (Employee_UUID varchar(50) NOT NULL PRIMARY KEY);

            INSERT INTO #Next(Employee_UUID)
            SELECT TOP (@ChunkSize) Employee_UUID
            FROM #Changed
            ORDER BY Employee_UUID;

            IF OBJECT_ID('tempdb..#ActLog') IS NOT NULL DROP TABLE #ActLog;
            CREATE TABLE #ActLog(Action nvarchar(10) NOT NULL);

            ;WITH base AS
            (
                SELECT
                    eb.Employee_UUID,
                    MIN(CAST(eb.Start_Date AS date)) AS MinStartDate,
                    MAX(CAST(eb.End_Date   AS date)) AS MaxEndDate,
                    SUM(CASE WHEN eb.End_Date IS NULL THEN 1 ELSE 0 END) AS OpenRows,
                    MAX(CASE WHEN eb.[Status] = 'Active' THEN 2
                             WHEN eb.[Status] = 'Temporarily Inactive' THEN 1
                             ELSE 0 END) AS StatusRank
                FROM dbo.tbl_EmployeeBranch eb
                JOIN #Next n
                  ON n.Employee_UUID = eb.Employee_UUID
                GROUP BY eb.Employee_UUID
            ),
            Final AS
            (
                SELECT
                    Employee_UUID = b.Employee_UUID,
                    Start_Date    = ISNULL(b.MinStartDate, CAST('1998-01-01' AS date)),
                    End_Date      = CASE WHEN b.OpenRows > 0 THEN NULL ELSE b.MaxEndDate END,
                    [Status]      = CASE
                                      WHEN b.OpenRows > 0 THEN
                                        CASE WHEN b.StatusRank = 2 THEN 'Active'
                                             WHEN b.StatusRank = 1 THEN 'Temporarily Inactive'
                                             ELSE 'Unknown'
                                        END
                                      ELSE 'Permanently Inactive'
                                    END
                FROM base b
            )
            MERGE dbo.tbl_EmployeeStartLeaveDates AS tgt
            USING (
                SELECT n.Employee_UUID, f.Start_Date, f.End_Date, f.[Status]
                FROM #Next n
                LEFT JOIN Final f
                  ON f.Employee_UUID = n.Employee_UUID
            ) AS src
              ON tgt.Employee_UUID = src.Employee_UUID
            WHEN MATCHED AND src.Start_Date IS NOT NULL THEN
                UPDATE SET
                    tgt.Start_Date   = src.Start_Date,
                    tgt.End_Date     = src.End_Date,
                    tgt.[Status]     = src.[Status],
                    tgt.UpdatedAtUTC = @RunStartedAt
            WHEN NOT MATCHED BY TARGET AND src.Start_Date IS NOT NULL THEN
                INSERT (Start_Date, End_Date, [Status], Employee_UUID, CreatedAtUTC, UpdatedAtUTC)
                VALUES (src.Start_Date, src.End_Date, src.[Status], src.Employee_UUID, @RunStartedAt, @RunStartedAt)
            WHEN MATCHED AND src.Start_Date IS NULL THEN
                DELETE
            OUTPUT $action INTO #ActLog(Action);

            DECLARE @i int=0, @u int=0, @d int=0;
            SELECT
                @i = SUM(CASE WHEN Action='INSERT' THEN 1 ELSE 0 END),
                @u = SUM(CASE WHEN Action='UPDATE' THEN 1 ELSE 0 END),
                @d = SUM(CASE WHEN Action='DELETE' THEN 1 ELSE 0 END)
            FROM #ActLog;

            SET @TotalInserted += ISNULL(@i,0);
            SET @TotalUpdated  += ISNULL(@u,0);
            SET @TotalDeleted  += ISNULL(@d,0);

            IF @EmitInfo=1
                RAISERROR('EmployeeStartLeaveDates chunk: ins=%d upd=%d del=%d (running ins=%I64d upd=%I64d del=%I64d)',
                          0,1,@i,@u,@d,@TotalInserted,@TotalUpdated,@TotalDeleted) WITH NOWAIT;

            DELETE c
            FROM #Changed c
            JOIN #Next n ON n.Employee_UUID = c.Employee_UUID;
        END

        /* ----------------------- 6) Advance watermark + summary ----------------------- */
        UPDATE dbo.CT_Watermark
          SET LastSyncVersion = @ToVersion,
              LastSyncTime    = SYSUTCDATETIME()
        WHERE ProcessName = @Process;

        SET @EndUTC = SYSUTCDATETIME();
        SET @EndIso = CONVERT(varchar(33), @EndUTC, 126);
        SET @DurationSec = DATEDIFF(SECOND, @RunStartedAt, @EndUTC);

        SET @Summary = CONCAT(
            N'EmployeeStartLeaveDates incremental started ', @StartIso, N' UTC; ended ', @EndIso,
            N' UTC; inserted ', CAST(@TotalInserted AS nvarchar(20)),
            N', updated ', CAST(@TotalUpdated AS nvarchar(20)),
            N', deleted ', CAST(@TotalDeleted AS nvarchar(20)),
            N'; advanced watermark to ', CAST(@ToVersion AS nvarchar(30)),
            N'; duration=', CAST(@DurationSec AS nvarchar(20)), N' sec.'
        );

        IF @EmitInfo=1 RAISERROR('EmployeeStartLeaveDates incremental sync complete.', 0, 1) WITH NOWAIT;
        IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;

FinallyRelease:
        IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;

        DECLARE @msg nvarchar(4000)=ERROR_MESSAGE();
        DECLARE @num int=ERROR_NUMBER(), @sev int=ERROR_SEVERITY(), @st int=ERROR_STATE(), @lin int=ERROR_LINE(), @proc sysname=ERROR_PROCEDURE();
        DECLARE @procName sysname = ISNULL(@proc, N'<adhoc>');

        IF @EmitInfo=1 RAISERROR('usp_Sync_EmployeeStartLeaveDates_Incremental failed (%d, sev %d, state %d) at %s line %d: %s',
                                 16,1,@num,@sev,@st,@procName,@lin,@msg);

        SET @Summary = CONCAT(N'EmployeeStartLeaveDates incremental failed: ', @msg);
        IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
        RETURN -50001;
    END CATCH
END
GO
