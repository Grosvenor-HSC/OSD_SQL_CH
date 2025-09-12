SET DATEFIRST 1;

-- ==========================================
-- Recreate table (explicit definition)
-- ==========================================
IF OBJECT_ID('dbo.tbl_ClientStartLeaveDates', 'U') IS NOT NULL
    DROP TABLE dbo.tbl_ClientStartLeaveDates;

CREATE TABLE dbo.tbl_ClientStartLeaveDates (
    ClientReference       VARCHAR(50) NOT NULL,
    BranchReference       VARCHAR(50) NOT NULL,
    GLOBAL_START_DATE     DATE        NULL,
    GLOBAL_WEEK_START     DATE        NULL,
    GLOBAL_START_MONTH    TINYINT     NULL,
    GLOBAL_START_YEAR     SMALLINT    NULL,
    GLOBAL_END_DATE       DATE        NULL,
    GLOBAL_WEEK_END       DATE        NULL,
    GLOBAL_END_MONTH      TINYINT     NULL,
    GLOBAL_END_YEAR       SMALLINT    NULL,
    UPDATED_LEAVE_DATES   DATE        NULL,
    GLOBAL_STATUS         VARCHAR(50) NOT NULL,
    CreatedAtUTC          datetime2(3) NOT NULL CONSTRAINT DF_tbl_ClientStartLeaveDates_CreatedAtUTC DEFAULT SYSUTCDATETIME(),
    UpdatedAtUTC          datetime2(3) NOT NULL CONSTRAINT DF_tbl_ClientStartLeaveDates_UpdatedAtUTC DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_tbl_ClientStartLeaveDates_ClientReference PRIMARY KEY CLUSTERED (ClientReference)
);

-- ==========================================
-- Populate (single aggregation, then derive)
-- ==========================================
DECLARE @RunStartedAt datetime2(3) = SYSUTCDATETIME();

INSERT INTO dbo.tbl_ClientStartLeaveDates (
    ClientReference,
    BranchReference,
    GLOBAL_START_DATE,
    GLOBAL_WEEK_START,
    GLOBAL_START_MONTH,
    GLOBAL_START_YEAR,
    GLOBAL_END_DATE,
    GLOBAL_WEEK_END,
    GLOBAL_END_MONTH,
    GLOBAL_END_YEAR,
    UPDATED_LEAVE_DATES,
    GLOBAL_STATUS,
    CreatedAtUTC,
    UpdatedAtUTC
)
SELECT
    s.ClientReference,
    s.BranchReference,
    s.GLOBAL_START_DATE,
    CASE 
        WHEN s.GLOBAL_START_DATE IS NOT NULL
        THEN DATEADD(DAY, 1 - DATEPART(WEEKDAY, s.GLOBAL_START_DATE), s.GLOBAL_START_DATE)
        ELSE NULL
    END AS GLOBAL_WEEK_START,
    MONTH(s.GLOBAL_START_DATE)  AS GLOBAL_START_MONTH,
    YEAR(s.GLOBAL_START_DATE)   AS GLOBAL_START_YEAR,
    s.GLOBAL_END_DATE,
    CASE 
        WHEN s.GLOBAL_END_DATE IS NOT NULL
        THEN DATEADD(DAY, 1 - DATEPART(WEEKDAY, s.GLOBAL_END_DATE), s.GLOBAL_END_DATE)
        ELSE NULL
    END AS GLOBAL_WEEK_END,
    MONTH(s.GLOBAL_END_DATE)    AS GLOBAL_END_MONTH,
    YEAR(s.GLOBAL_END_DATE)     AS GLOBAL_END_YEAR,
    ISNULL(CONVERT(DATE, s.GLOBAL_END_DATE), CONVERT(DATE, GETDATE())) AS UPDATED_LEAVE_DATES,
    s.GLOBAL_STATUS,
    @RunStartedAt,
    @RunStartedAt
FROM (
    -- SourceTable: pre-aggregate once
    SELECT
        C.ClientReference,
        C.BranchReference,
        /* Decide start between client start and first visit start */
        CASE 
            WHEN MIN(C.ClientStartDate) IS NULL AND MIN(V.VisitStartDate) IS NOT NULL THEN MIN(V.VisitStartDate)
            WHEN MIN(C.ClientStartDate) IS NOT NULL AND MIN(V.VisitStartDate) IS NULL THEN MIN(C.ClientStartDate)
            WHEN MIN(C.ClientStartDate) >= MIN(V.VisitStartDate) THEN MIN(V.VisitStartDate)
            ELSE MIN(C.ClientStartDate)
        END AS GLOBAL_START_DATE,
        MAX(C.ClientLeaveDate) AS GLOBAL_END_DATE,
        MAX(C.ClientStatus)    AS GLOBAL_STATUS   -- grouped by status; MAX just selects a value
    FROM dbo.tbl_Clients AS C WITH (NOLOCK)
    LEFT JOIN dbo.tbl_Visits  AS V WITH (NOLOCK)
           ON V.ClientReference = C.ClientReference
    GROUP BY
        C.ClientReference,
        C.BranchReference,
        C.ClientStatus
) AS s;

-- ==========================================
-- Supporting indexes (match baseline intent)
-- ==========================================
CREATE NONCLUSTERED INDEX IX_ClientStartLeave_WeekStart
  ON dbo.tbl_ClientStartLeaveDates (GLOBAL_WEEK_START);

CREATE NONCLUSTERED INDEX IX_ClientStartLeave_WeekEnd
  ON dbo.tbl_ClientStartLeaveDates (GLOBAL_WEEK_END);

CREATE NONCLUSTERED INDEX IX_ClientStartLeave_Status
  ON dbo.tbl_ClientStartLeaveDates (GLOBAL_STATUS);
