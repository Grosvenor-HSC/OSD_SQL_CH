CREATE OR ALTER PROCEDURE dbo.usp_Sync_Visits_Incremental
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
    -- Declare once; we'll SET these in both branches later
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

            ;WITH CarerCounts AS (
                SELECT AHD.MLINKREF, COUNT(*) AS NumberCarers
                FROM dbo.ACTIVITY_HD AHD WITH (NOLOCK)
                JOIN #NextKeys NK ON NK.ACT_REF = AHD.ACT_REF
                WHERE AHD.MLINKREF <> 0
                GROUP BY AHD.MLINKREF
            ),
            VisitsBase AS (
                SELECT
                    CAST(AHD.ACT_REF     AS varchar(50)) AS VisitReference,
                    CAST(AHD.CLIENT_REF  AS varchar(50)) AS ClientReference,
                    CAST(AHD.EMP_REF     AS varchar(50)) AS EmployeeReference,
                    CAST(CPDT.EMP_REF    AS varchar(50)) AS CareplanEmployeeReference,
                    CASE WHEN AHD.EMP_REF = 0 THEN 'Unallocated' ELSE 'Allocated' END AS VisitAllocation,
                    CPDT.QUANTITY AS PlannedQuantity,
                    IIF(CPDT.EMP_REF IS NULL OR CPDT.EMP_REF = 0, 1, 0) AS NoEmpInTemplate,
                    IIF(CPDT.EMP_REF IS NOT NULL AND CPDT.EMP_REF <> AHD.EMP_REF, 1, 0) AS EmpChangedFromTemplate,
                    IIF(TRY_CAST(CPDT.TIMEOFDAY AS TIME) IS NOT NULL
                        AND TRY_CAST(CPDT.TIMEOFDAY AS TIME) <> CAST(AHD.START_DTM AS TIME), 1, 0) AS TimeChangedFromTemplate,
                    CAST(AHD.END_DTM   AS TIME)      AS VisitEndTime,
                    CAST(AHD.END_DTM   AS DATE)      AS VisitEndDate,
                    CAST(AHD.END_DTM   AS DATETIME2) AS VisitEndDateTime,
                    CAST(CL.BranchReference AS varchar(50)) AS BranchReference,
                    CAST(AHD.ORIGSTDTM AS TIME)      AS VisitOriginalStartTime,
                    CAST(AHD.ORIGSTDTM AS DATE)      AS VisitOriginalStartDate,
                    CAST(AHD.START_DTM AS TIME)      AS VisitStartTime,
                    TRY_CAST(CPDT.TIMEOFDAY AS TIME) AS CareplanVisitStartTime,
                    CAST(AHD.START_DTM AS DATE)      AS VisitStartDate,
                    CAST(AHD.START_DTM AS DATETIME2) AS VisitStartDateTime,
                    DATEADD(day, 1 - DATEPART(weekday, CAST(AHD.START_DTM AS DATE)), CAST(AHD.START_DTM AS DATE)) AS WeekStartDate,
                    DATEADD(day, 7 - DATEPART(weekday, CAST(AHD.END_DTM   AS DATE)), CAST(AHD.END_DTM   AS DATE)) AS WeekEndDate,
                    AHD.CPLAN_DET_REF                AS CareplanRef,
                    SHD.SERVICE_CODE                 AS VisitServiceCode,
                    CAST(CHD.CONTRACT_REF AS varchar(50)) AS ContractReference,
                    CASE 
                        WHEN AHD.CPLAN_DET_REF <> 0 THEN 'From Template Careplan'
                        WHEN AHD.CPLAN_DET_REF = 0 AND AHD.RNB_VISIT = 'Y' THEN 'From Booking'
                        WHEN AHD.CPLAN_DET_REF = 0 AND AHD.RNB_VISIT <> 'Y' THEN 'Ad-Hoc Entry'
                        ELSE '' 
                    END AS VisitOrigin,
                    AHD.INV_STATUS                   AS VisitInvoiceStatus,
                    AHD.PAY_STATUS                   AS VisitPayStatus,
                    CASE WHEN AHD.MLINKREF > 0 THEN 'Yes' ELSE 'No' END AS VisitMultiEmployeeFlag,
                    CAST(DATEDIFF(MINUTE, AHD.START_DTM, AHD.END_DTM) AS FLOAT) / 60 AS VisitCalculatedDuration,
                    SHD.SERVICE_CODE                 AS ServiceCode,
                    CS.DESCRIPTION                   AS ContractSource,
                    AHD.MLINKREF                     AS MultiCareRef,
                    AHD.CANC_PAY                     AS CancelPayFlag
                FROM dbo.ACTIVITY_HD AS AHD WITH (NOLOCK)
                JOIN #NextKeys NK ON NK.ACT_REF = AHD.ACT_REF
                LEFT JOIN dbo.tbl_Clients  AS CL  WITH (NOLOCK) ON CL.ClientReference = AHD.CLIENT_REF
                LEFT JOIN dbo.CONTRACT_DT  AS CDT WITH (NOLOCK) ON AHD.CONT_DET_REF   = CDT.CONT_DET_REF
                LEFT JOIN dbo.CONTRACT_HD  AS CHD WITH (NOLOCK) ON CDT.CONTRACT_REF   = CHD.CONTRACT_REF
                LEFT JOIN dbo.SERVICE_HD   AS SHD WITH (NOLOCK) ON AHD.SERVICE_REF    = SHD.SERVICE_REF
                LEFT JOIN dbo.CAREPLAN_DT  AS CPDT WITH (NOLOCK) ON AHD.CPLAN_DET_REF = CPDT.CPLAN_DET_REF
                LEFT JOIN dbo.CHSYSDEC     AS CS  WITH (NOLOCK) ON CHD.CONTRACT_SOURCE= CS.DECODE_REF
                WHERE AHD.[TYPE] <> 1
            )
            MERGE dbo.tbl_Visits AS tgt
            USING (
                SELECT 
                    v.VisitReference,
                    v.ClientReference,
                    v.EmployeeReference,
                    v.CareplanEmployeeReference,
                    v.VisitAllocation,
                    v.PlannedQuantity,
                    v.NoEmpInTemplate,
                    v.EmpChangedFromTemplate,
                    v.TimeChangedFromTemplate,
                    v.VisitEndTime,
                    v.VisitEndDate,
                    v.VisitEndDateTime,
                    v.BranchReference,
                    v.VisitOriginalStartTime,
                    v.VisitOriginalStartDate,
                    v.VisitStartTime,
                    v.CareplanVisitStartTime,
                    v.VisitStartDate,
                    v.VisitStartDateTime,
                    v.WeekStartDate,
                    v.WeekEndDate,
                    v.CareplanRef,
                    v.VisitServiceCode,
                    v.ContractReference,
                    v.VisitOrigin,
                    v.VisitInvoiceStatus,
                    v.VisitPayStatus,
                    v.VisitMultiEmployeeFlag,
                    v.VisitCalculatedDuration,
                    v.ServiceCode,
                    v.ContractSource,
                    v.MultiCareRef,
                    IIF(v.NoEmpInTemplate = 0 AND v.EmpChangedFromTemplate = 0 AND v.TimeChangedFromTemplate = 0, 1, 0) AS NotChangedFromTemplate,
                    ISNULL(cc.NumberCarers, 1) AS NumberCarersOnVisit,
                    v.CancelPayFlag
                FROM VisitsBase v
                LEFT JOIN CarerCounts cc ON v.MultiCareRef = cc.MLINKREF
            ) AS src
               ON tgt.VisitReference = src.VisitReference
            WHEN MATCHED THEN
                UPDATE SET
                    tgt.ClientReference           = src.ClientReference,
                    tgt.EmployeeReference         = src.EmployeeReference,
                    tgt.CareplanEmployeeReference = src.CareplanEmployeeReference,
                    tgt.VisitAllocation           = src.VisitAllocation,
                    tgt.PlannedQuantity           = src.PlannedQuantity,
                    tgt.NoEmpInTemplate           = src.NoEmpInTemplate,
                    tgt.EmpChangedFromTemplate    = src.EmpChangedFromTemplate,
                    tgt.TimeChangedFromTemplate   = src.TimeChangedFromTemplate,
                    tgt.VisitEndTime              = src.VisitEndTime,
                    tgt.VisitEndDate              = src.VisitEndDate,
                    tgt.VisitEndDateTime          = src.VisitEndDateTime,
                    tgt.BranchReference           = src.BranchReference,
                    tgt.VisitOriginalStartTime    = src.VisitOriginalStartTime,
                    tgt.VisitOriginalStartDate    = src.VisitOriginalStartDate,
                    tgt.VisitStartTime            = src.VisitStartTime,
                    tgt.CareplanVisitStartTime    = src.CareplanVisitStartTime,
                    tgt.VisitStartDate            = src.VisitStartDate,
                    tgt.VisitStartDateTime        = src.VisitStartDateTime,
                    tgt.WeekStartDate             = src.WeekStartDate,
                    tgt.WeekEndDate               = src.WeekEndDate,
                    tgt.CareplanRef               = src.CareplanRef,
                    tgt.VisitServiceCode          = src.VisitServiceCode,
                    tgt.ContractReference         = src.ContractReference,
                    tgt.VisitOrigin               = src.VisitOrigin,
                    tgt.VisitInvoiceStatus        = src.VisitInvoiceStatus,
                    tgt.VisitPayStatus            = src.VisitPayStatus,
                    tgt.VisitMultiEmployeeFlag    = src.VisitMultiEmployeeFlag,
                    tgt.VisitCalculatedDuration   = src.VisitCalculatedDuration,
                    tgt.ServiceCode               = src.ServiceCode,
                    tgt.ContractSource            = src.ContractSource,
                    tgt.MultiCareRef              = src.MultiCareRef,
                    tgt.NotChangedFromTemplate    = src.NotChangedFromTemplate,
                    tgt.NumberCarersOnVisit       = src.NumberCarersOnVisit,
                    tgt.CancelPayFlag             = src.CancelPayFlag,
                    tgt.UpdatedAtUTC              = @RunStartedAt
            WHEN NOT MATCHED BY TARGET THEN
                INSERT (
                    VisitReference, ClientReference, EmployeeReference, CareplanEmployeeReference,
                    VisitAllocation, PlannedQuantity, NoEmpInTemplate, EmpChangedFromTemplate, TimeChangedFromTemplate,
                    VisitEndTime, VisitEndDate, VisitEndDateTime,
                    BranchReference, VisitOriginalStartTime, VisitOriginalStartDate,
                    VisitStartTime, CareplanVisitStartTime, VisitStartDate, VisitStartDateTime,
                    WeekStartDate, WeekEndDate,
                    CareplanRef, VisitServiceCode, ContractReference, VisitOrigin,
                    VisitInvoiceStatus, VisitPayStatus, VisitMultiEmployeeFlag,
                    VisitCalculatedDuration, ServiceCode, ContractSource, MultiCareRef,
                    NotChangedFromTemplate, NumberCarersOnVisit, CancelPayFlag,
                    CreatedAtUTC, UpdatedAtUTC
                )
                VALUES (
                    src.VisitReference, src.ClientReference, src.EmployeeReference, src.CareplanEmployeeReference,
                    src.VisitAllocation, src.PlannedQuantity, src.NoEmpInTemplate, src.EmpChangedFromTemplate, src.TimeChangedFromTemplate,
                    src.VisitEndTime, src.VisitEndDate, src.VisitEndDateTime,
                    src.BranchReference, src.VisitOriginalStartTime, src.VisitOriginalStartDate,
                    src.VisitStartTime, src.CareplanVisitStartTime, src.VisitStartDate, src.VisitStartDateTime,
                    src.WeekStartDate, src.WeekEndDate,
                    src.CareplanRef, src.VisitServiceCode, src.ContractReference, src.VisitOrigin,
                    src.VisitInvoiceStatus, src.VisitPayStatus, src.VisitMultiEmployeeFlag,
                    src.VisitCalculatedDuration, src.ServiceCode, src.ContractSource, src.MultiCareRef,
                    src.NotChangedFromTemplate, src.NumberCarersOnVisit, src.CancelPayFlag,
                    @RunStartedAt, @RunStartedAt
                )
            WHEN NOT MATCHED BY SOURCE
                 AND EXISTS (
                     SELECT 1
                     FROM #NextKeys nn
                     WHERE CAST(nn.ACT_REF AS varchar(50)) = tgt.VisitReference
                 )
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
GO
