USE [DOM_LIVE]
GO
/****** Object:  StoredProcedure [dbo].[usp_Sync_Visits_Incremental]    Script Date: 26/01/2026 20:50:28 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
ALTER   PROCEDURE [dbo].[usp_Sync_Visits_Incremental]
    @ChunkSize        int            = 100000,
    @LockTimeoutMs    int            = 60000,
    @UseAppLock       bit            = 1,
    @EmitInfo         bit            = 1,
    @Summary          nvarchar(4000) = NULL OUTPUT,
    @ReturnSummaryRow bit            = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET ANSI_WARNINGS ON;

    DECLARE @Process       sysname      = N'Visits';
    DECLARE @RunStartedAt  datetime2(3) = SYSUTCDATETIME();
    DECLARE @StartIso      varchar(33)  = CONVERT(varchar(33), @RunStartedAt, 126);
    DECLARE @EndUTC        datetime2(3) = NULL;
    DECLARE @EndIso        varchar(33)  = NULL;
    DECLARE @DurationSec   int          = NULL;

    /* 0) Concurrency guard */
    DECLARE @LockResource sysname = N'DOM_LIVE:Sync:Visits';
    DECLARE @LockOwner   sysname = N'Session';
    DECLARE @DbPrincipal sysname = N'dbo';
    DECLARE @lockResult  int;
    DECLARE @lockHeld    bit = 0;

    IF @UseAppLock = 1
    BEGIN
        EXEC @lockResult = sys.sp_getapplock
            @Resource=@LockResource, @LockMode='Exclusive',
            @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal, @LockTimeout=@LockTimeoutMs;

        IF @lockResult NOT IN (0,1)
        BEGIN
            IF @EmitInfo=1 RAISERROR('Could not acquire %s (rc=%d).',16,1,@LockResource,@lockResult);
            SET @Summary = N'Visits incremental failed: could not acquire applock.';
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            RETURN @lockResult;
        END
        SET @lockHeld = 1;
    END

    BEGIN TRY
        /* 1) Preconditions & bounds */
        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_databases WHERE database_id = DB_ID())
        BEGIN
            IF @EmitInfo=1 RAISERROR('Change Tracking is not enabled at the database level.',16,1);
            SET @Summary = N'Visits incremental failed: CT not enabled at DB level.';
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;
            RETURN -100;
        END

        IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(N'dbo.ACTIVITY_HD'))
        BEGIN
            IF @EmitInfo=1 RAISERROR('Change Tracking is not enabled on dbo.ACTIVITY_HD.',16,1);
            SET @Summary = N'Visits incremental failed: CT not enabled on ACTIVITY_HD.';
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;
            RETURN -210;
        END

        IF OBJECT_ID('dbo.CT_Watermark','U') IS NULL
        BEGIN
            CREATE TABLE dbo.CT_Watermark(
                ProcessName     sysname      PRIMARY KEY,
                LastSyncVersion bigint       NOT NULL,
                LastSyncTime    datetime2(3) NOT NULL DEFAULT SYSUTCDATETIME()
            );
        END

        IF NOT EXISTS (SELECT 1 FROM dbo.CT_Watermark WITH (HOLDLOCK, UPDLOCK) WHERE ProcessName=@Process)
            INSERT INTO dbo.CT_Watermark(ProcessName, LastSyncVersion) VALUES (@Process, 0);

        DECLARE @LastSyncVersion bigint =
            (SELECT LastSyncVersion FROM dbo.CT_Watermark WITH (HOLDLOCK, UPDLOCK) WHERE ProcessName=@Process);

        DECLARE @MinValid bigint = CHANGE_TRACKING_MIN_VALID_VERSION(OBJECT_ID(N'dbo.ACTIVITY_HD'));
        IF @MinValid IS NOT NULL AND @LastSyncVersion < @MinValid
        BEGIN
            IF @EmitInfo=1 RAISERROR('Watermark (%I64d) is older than CT min valid version (%I64d). Re-baseline required.',16,1,@LastSyncVersion,@MinValid);
            SET @Summary = CONCAT(N'Visits incremental failed: watermark ', @LastSyncVersion, N' < min valid ', @MinValid, N'.');
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
            IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;
            RETURN -200;
        END

        DECLARE @ToVersion bigint = CHANGE_TRACKING_CURRENT_VERSION();
        IF @EmitInfo=1
        BEGIN
            RAISERROR('Visits CT window:', 0, 1) WITH NOWAIT;
            RAISERROR('  From = %I64d', 0, 1, @LastSyncVersion) WITH NOWAIT;
            RAISERROR('  To   = %I64d', 0, 1, @ToVersion) WITH NOWAIT;
        END

        /* 2) Build changed key set */
        IF OBJECT_ID('tempdb..#Changed') IS NOT NULL DROP TABLE #Changed;
        CREATE TABLE #Changed (ACT_REF int NOT NULL PRIMARY KEY);

        INSERT INTO #Changed(ACT_REF)
        SELECT DISTINCT x.ACT_REF
        FROM CHANGETABLE(CHANGES dbo.ACTIVITY_HD, @LastSyncVersion) x
        WHERE x.SYS_CHANGE_VERSION <= @ToVersion;

        DECLARE @ToProcess int = (SELECT COUNT(*) FROM #Changed);
        IF @EmitInfo=1 RAISERROR('Visits to process: %d', 0, 1, @ToProcess) WITH NOWAIT;

        IF @ToProcess = 0
        BEGIN
            UPDATE dbo.CT_Watermark
              SET LastSyncVersion=@ToVersion, LastSyncTime=SYSUTCDATETIME()
            WHERE ProcessName=@Process;

            SET @EndUTC      = SYSUTCDATETIME();
            SET @EndIso      = CONVERT(varchar(33), @EndUTC, 126);
            SET @DurationSec = DATEDIFF(SECOND, @RunStartedAt, @EndUTC);

            SET @Summary = CONCAT(
                N'Visits incremental started ', @StartIso, N' UTC; ended ', @EndIso,
                N' UTC; inserted 0, updated 0, deleted 0; advanced watermark to ',
                CAST(@ToVersion AS nvarchar(30)), N'; duration=', @DurationSec, N' sec.'
            );
            IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;

            IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;
            RETURN 0;
        END

        /* 3) Chunked MERGE into dbo.tbl_Visits */
        DECLARE @TotalInserted bigint = 0, @TotalUpdated bigint = 0, @TotalDeleted int = 0;

        WHILE EXISTS (SELECT 1 FROM #Changed)
        BEGIN
            IF OBJECT_ID('tempdb..#NextKeys') IS NOT NULL DROP TABLE #NextKeys;
            CREATE TABLE #NextKeys (ACT_REF int NOT NULL PRIMARY KEY);

            INSERT INTO #NextKeys(ACT_REF)
            SELECT TOP (@ChunkSize) ACT_REF
            FROM #Changed
            ORDER BY ACT_REF;

            IF OBJECT_ID('tempdb..#ActLog') IS NOT NULL DROP TABLE #ActLog;
            CREATE TABLE #ActLog(Action nvarchar(10) NOT NULL);

            ;WITH VisitsBase AS (
                                 SELECT
                    CAST(AHD.ACT_REF     AS varchar(50)) AS UUID,
                    CAST(AHD.CLIENT_REF  AS varchar(50)) AS Client_UUID,
                    CASE WHEN AHD.EMP_REF = 0  THEN NULL ELSE CAST(AHD.EMP_REF  AS varchar(50)) END AS Employee_UUID,
                    CASE WHEN CPDT.EMP_REF = 0 THEN NULL ELSE CAST(CPDT.EMP_REF AS varchar(50)) END AS Planned_Employee_UUID,
                    CASE WHEN AHD.CPLAN_DET_REF = 0 THEN NULL ELSE AHD.CPLAN_DET_REF END          AS Careplan_UUID,
                    CASE WHEN AHD.GS_REF = 0 THEN NULL ELSE AHD.GS_REF END                       AS Group_UUID,         
                    CAST(C.[Branch_UUID] AS varchar(50))       AS Branch_UUID,
                    CAST(CHD.CONTRACT_REF AS varchar(50)) AS Contract_UUID,
                    CASE WHEN AHD.MLINKREF = 0 THEN NULL ELSE AHD.MLINKREF END                     AS Linked_Visit_UUID,
                    CAST(COALESCE(CPDT.QUANTITY,0) * 60 AS INT)                                    AS Planned_Duration,
                    CAST(AHD.ORIGSTDTM AS DATETIME2)                                              AS Planned_Visit_Start_Date_Time,
                    CAST(DATEADD(MINUTE, COALESCE(CPDT.QUANTITY,0), AHD.ORIGSTDTM) AS DATETIME2)  AS Planned_Visit_End_Date_Time,
                    DATEDIFF(MINUTE, AHD.START_DTM, AHD.END_DTM)                                   AS Actual_Duration,
                    CAST(AHD.START_DTM AS DATETIME2)                                              AS Actual_Visit_Start_Date_Time,
                    CAST(AHD.END_DTM   AS DATETIME2)                                              AS Actual_Visit_End_Date_Time,
                    SHD.SERVICE_CODE                                                                AS Visit_Code,
                    CASE 
                        WHEN AHD.CPLAN_DET_REF <> 0                        THEN 'From Template Careplan'
                        WHEN AHD.CPLAN_DET_REF = 0 AND AHD.RNB_VISIT = 'Y' THEN 'From Booking'
                        WHEN AHD.CPLAN_DET_REF = 0 AND AHD.RNB_VISIT <> 'Y' THEN 'Ad-Hoc Entry'
                        ELSE '' 
                    END                                                                             AS Visit_Origin,
                    AHD.INV_STATUS                                                                  AS Visit_Invoice_Status,
                    AHD.PAY_STATUS                                                                  AS Visit_Pay_Status,
                    CASE WHEN LEN(AHD.CANC_PAY) >= 1 THEN AHD.CANC_PAY ELSE NULL END                AS Cancel_Pay_Flag
                FROM dbo.ACTIVITY_HD AS AHD
                JOIN #NextKeys NK                 ON NK.ACT_REF       = AHD.ACT_REF          -- <<< missing in your proc
                LEFT JOIN dbo.CONTRACT_DT  AS CDT ON AHD.CONT_DET_REF = CDT.CONT_DET_REF
                LEFT JOIN dbo.CONTRACT_HD  AS CHD ON CDT.CONTRACT_REF = CHD.CONTRACT_REF
                LEFT JOIN dbo.SERVICE_HD   AS SHD ON AHD.SERVICE_REF  = SHD.SERVICE_REF
                LEFT JOIN dbo.CAREPLAN_DT  AS CPDT ON AHD.CPLAN_DET_REF = CPDT.CPLAN_DET_REF
                join tbl_Clients c on ahd.CLIENT_REF = C.UUID
                WHERE AHD.[TYPE] <> 1
                AND AHD.START_DTM >= DATEADD(year, -3, SYSUTCDATETIME()) 
            )
            MERGE dbo.tbl_Visits AS tgt
            USING (SELECT * FROM VisitsBase) AS src
              ON tgt.UUID = src.UUID
            WHEN MATCHED THEN
                UPDATE SET
                    tgt.Client_UUID              = src.Client_UUID,
                    tgt.Employee_UUID            = src.Employee_UUID,
                    tgt.Planned_Employee_UUID    = src.Planned_Employee_UUID,
                    tgt.Careplan_UUID            = src.Careplan_UUID,
                    tgt.Branch_UUID              = src.Branch_UUID,
                    tgt.Contract_UUID            = src.Contract_UUID,
                    tgt.Linked_Visit_UUID        = src.Linked_Visit_UUID,
                    tgt.Planned_Duration         = src.Planned_Duration,
                    tgt.Planned_Visit_Start_Date_Time = src.Planned_Visit_Start_Date_Time,
                    tgt.Planned_Visit_End_Date_Time   = src.Planned_Visit_End_Date_Time,
                    tgt.Actual_Duration          = src.Actual_Duration,
                    tgt.Actual_Visit_Start_Date_Time  = src.Actual_Visit_Start_Date_Time,
                    tgt.Actual_Visit_End_Date_Time    = src.Actual_Visit_End_Date_Time,
                    tgt.Visit_Code               = src.Visit_Code,
                    tgt.Visit_Origin             = src.Visit_Origin,
                    tgt.Visit_Invoice_Status     = src.Visit_Invoice_Status,
                    tgt.Visit_Pay_Status         = src.Visit_Pay_Status,
                    tgt.Cancel_Pay_Flag          = src.Cancel_Pay_Flag,
                    tgt.UpdatedAtUTC             = @RunStartedAt
            WHEN NOT MATCHED BY TARGET THEN
                INSERT (UUID, Client_UUID, Employee_UUID, Planned_Employee_UUID, Careplan_UUID,
                        Branch_UUID, Contract_UUID, Linked_Visit_UUID, Planned_Duration,
                        Planned_Visit_Start_Date_Time, Planned_Visit_End_Date_Time, Actual_Duration,
                        Actual_Visit_Start_Date_Time, Actual_Visit_End_Date_Time, Visit_Code,
                        Visit_Origin, Visit_Invoice_Status, Visit_Pay_Status, Cancel_Pay_Flag,
                        CreatedAtUTC, UpdatedAtUTC)
                VALUES (src.UUID, src.Client_UUID, src.Employee_UUID, src.Planned_Employee_UUID, src.Careplan_UUID,
                        src.Branch_UUID, src.Contract_UUID, src.Linked_Visit_UUID, src.Planned_Duration,
                        src.Planned_Visit_Start_Date_Time, src.Planned_Visit_End_Date_Time, src.Actual_Duration,
                        src.Actual_Visit_Start_Date_Time, src.Actual_Visit_End_Date_Time, src.Visit_Code,
                        src.Visit_Origin, src.Visit_Invoice_Status, src.Visit_Pay_Status, src.Cancel_Pay_Flag,
                        @RunStartedAt, @RunStartedAt)
            WHEN NOT MATCHED BY SOURCE
                 AND EXISTS (SELECT 1 FROM #NextKeys nn WHERE CAST(nn.ACT_REF AS varchar(50)) = tgt.UUID)
                 THEN DELETE
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
                RAISERROR('Visits chunk: inserted=%d updated=%d deleted=%d (running %d/%d/%d)',
                          0,1,@i,@u,@d,@TotalInserted,@TotalUpdated,@TotalDeleted) WITH NOWAIT;

            DELETE c
            FROM #Changed c
            JOIN #NextKeys n ON n.ACT_REF = c.ACT_REF;
        END

        /* 4) Advance watermark + summary */
        UPDATE dbo.CT_Watermark
          SET LastSyncVersion=@ToVersion, LastSyncTime=SYSUTCDATETIME()
        WHERE ProcessName=@Process;

        SET @EndUTC      = SYSUTCDATETIME();
        SET @EndIso      = CONVERT(varchar(33), @EndUTC, 126);
        SET @DurationSec = DATEDIFF(SECOND, @RunStartedAt, @EndUTC);

        SET @Summary = CONCAT(
            N'Visits incremental started ', @StartIso, N' UTC; ended ', @EndIso,
            N' UTC; inserted ', CAST(@TotalInserted AS nvarchar(20)),
            N', updated ', CAST(@TotalUpdated AS nvarchar(20)),
            N', deleted ', CAST(@TotalDeleted AS nvarchar(20)),
            N'; advanced watermark to ', CAST(@ToVersion AS nvarchar(30)),
            N'; duration=', CAST(@DurationSec AS nvarchar(20)), N' sec.'
        );

        IF @EmitInfo=1 RAISERROR('Visits incremental sync complete.', 0, 1) WITH NOWAIT;
        IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;

        IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF @lockHeld=1 EXEC sys.sp_releaseapplock @Resource=@LockResource, @LockOwner=@LockOwner, @DbPrincipal=@DbPrincipal;
        DECLARE @msg nvarchar(4000)=ERROR_MESSAGE();
        DECLARE @num int=ERROR_NUMBER(), @sev int=ERROR_SEVERITY(), @st int=ERROR_STATE(), @lin int=ERROR_LINE(), @proc sysname=ERROR_PROCEDURE();
        DECLARE @procName sysname = ISNULL(@proc, N'<adhoc>');
        IF @EmitInfo=1 RAISERROR('usp_Sync_Visits_Incremental failed (%d, sev %d, state %d) at %s line %d: %s',
                                 16,1,@num,@sev,@st,@procName,@lin,@msg);
        SET @Summary = CONCAT(N'Visits incremental failed: ', @msg);
        IF @ReturnSummaryRow=1 SELECT 'Incremental' AS Stage, @Summary AS Summary;
        RETURN -50001;
    END CATCH
END
