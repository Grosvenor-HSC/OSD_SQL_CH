-- Drop if exists
IF OBJECT_ID('dbo.tbl_ClientStartLeaveDates', 'U') IS NOT NULL
    DROP TABLE dbo.tbl_ClientStartLeaveDates;

-- Create the materialized table
CREATE TABLE dbo.tbl_ClientStartLeaveDates (
    ClientReference       VARCHAR(50) NOT NULL,
    BranchReference       VARCHAR(50) NOT NULL,
    GLOBAL_START_DATE     DATE NULL,
    GLOBAL_WEEK_START     DATE NULL,
    GLOBAL_START_MONTH    TINYINT NULL,
    GLOBAL_START_YEAR     SMALLINT NULL,
    GLOBAL_END_DATE       DATE NULL,
    GLOBAL_WEEK_END       DATE NULL,
    GLOBAL_END_MONTH      TINYINT NULL,
    GLOBAL_END_YEAR       SMALLINT NULL,
    UPDATED_LEAVE_DATES   DATE NULL,
    GLOBAL_STATUS         VARCHAR(50) NOT NULL
);

-- Populate the table
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
    GLOBAL_STATUS
)
SELECT 
    C.ClientReference,
    C.BranchReference,

    -- GLOBAL_START_DATE logic
    CASE 
        WHEN MIN(C.ClientStartDate) IS NULL AND MIN(V.VisitStartDate) IS NOT NULL THEN MIN(V.VisitStartDate)
        WHEN MIN(C.ClientStartDate) IS NOT NULL AND MIN(V.VisitStartDate) IS NULL THEN MIN(C.ClientStartDate)
        WHEN MIN(C.ClientStartDate) >= MIN(V.VisitStartDate) THEN MIN(V.VisitStartDate)
        ELSE MIN(C.ClientStartDate)
    END AS GLOBAL_START_DATE,

    -- GLOBAL_WEEK_START
    DATEADD(DAY, -((DATEPART(WEEKDAY, 
        CASE 
            WHEN MIN(C.ClientStartDate) IS NULL AND MIN(V.VisitStartDate) IS NOT NULL THEN MIN(V.VisitStartDate)
            WHEN MIN(C.ClientStartDate) IS NOT NULL AND MIN(V.VisitStartDate) IS NULL THEN MIN(C.ClientStartDate)
            WHEN MIN(C.ClientStartDate) >= MIN(V.VisitStartDate) THEN MIN(V.VisitStartDate)
            ELSE MIN(C.ClientStartDate)
        END
    ) + @@DATEFIRST - 2) % 7),
    CASE 
        WHEN MIN(C.ClientStartDate) IS NULL AND MIN(V.VisitStartDate) IS NOT NULL THEN MIN(V.VisitStartDate)
        WHEN MIN(C.ClientStartDate) IS NOT NULL AND MIN(V.VisitStartDate) IS NULL THEN MIN(C.ClientStartDate)
        WHEN MIN(C.ClientStartDate) >= MIN(V.VisitStartDate) THEN MIN(V.VisitStartDate)
        ELSE MIN(C.ClientStartDate)
    END) AS GLOBAL_WEEK_START,

    -- Start month/year
    MONTH(
        CASE 
            WHEN MIN(C.ClientStartDate) IS NULL AND MIN(V.VisitStartDate) IS NOT NULL THEN MIN(V.VisitStartDate)
            WHEN MIN(C.ClientStartDate) IS NOT NULL AND MIN(V.VisitStartDate) IS NULL THEN MIN(C.ClientStartDate)
            WHEN MIN(C.ClientStartDate) >= MIN(V.VisitStartDate) THEN MIN(V.VisitStartDate)
            ELSE MIN(C.ClientStartDate)
        END
    ) AS GLOBAL_START_MONTH,
    YEAR(
        CASE 
            WHEN MIN(C.ClientStartDate) IS NULL AND MIN(V.VisitStartDate) IS NOT NULL THEN MIN(V.VisitStartDate)
            WHEN MIN(C.ClientStartDate) IS NOT NULL AND MIN(V.VisitStartDate) IS NULL THEN MIN(C.ClientStartDate)
            WHEN MIN(C.ClientStartDate) >= MIN(V.VisitStartDate) THEN MIN(V.VisitStartDate)
            ELSE MIN(C.ClientStartDate)
        END
    ) AS GLOBAL_START_YEAR,

    -- GLOBAL_END_DATE
    MAX(C.ClientLeaveDate) AS GLOBAL_END_DATE,

    -- GLOBAL_WEEK_END
    CASE 
        WHEN MAX(C.ClientLeaveDate) IS NOT NULL THEN
            DATEADD(DAY, -((DATEPART(WEEKDAY, MAX(C.ClientLeaveDate)) + @@DATEFIRST - 2) % 7), MAX(C.ClientLeaveDate))
        ELSE NULL
    END AS GLOBAL_WEEK_END,

    -- End month/year
    MONTH(MAX(C.ClientLeaveDate)) AS GLOBAL_END_MONTH,
    YEAR(MAX(C.ClientLeaveDate)) AS GLOBAL_END_YEAR,

    -- Updated leave date
    ISNULL(CONVERT(DATE, MAX(C.ClientLeaveDate)), CONVERT(DATE, GETDATE())) AS UPDATED_LEAVE_DATES,

    [ClientStatus] AS GLOBAL_STATUS

FROM dbo.tbl_Clients C
LEFT JOIN dbo.tbl_Visits V ON C.ClientReference = V.ClientReference
GROUP BY C.ClientReference, C.BranchReference, 
         C.ClientStatus, C.ClientStartDate, C.ClientLeaveDate;

-- Add Primary Key
ALTER TABLE dbo.tbl_ClientStartLeaveDates
ADD CONSTRAINT PK_ClientStartLeaveDates PRIMARY KEY CLUSTERED (ClientReference);

-- Add supporting indexes
CREATE NONCLUSTERED INDEX IX_ClientStartLeave_WeekStart
ON dbo.tbl_ClientStartLeaveDates (GLOBAL_WEEK_START);

CREATE NONCLUSTERED INDEX IX_ClientStartLeave_WeekEnd
ON dbo.tbl_ClientStartLeaveDates (GLOBAL_WEEK_END);

CREATE NONCLUSTERED INDEX IX_ClientStartLeave_Status
ON dbo.tbl_ClientStartLeaveDates (GLOBAL_STATUS);
