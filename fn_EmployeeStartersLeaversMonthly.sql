SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
ALTER    FUNCTION [dbo].[fn_EmployeeStartersLeaversMonthly]
(
    @StartDate DATE,
    @EndDate DATE
)
RETURNS @Results TABLE
(
    [Year] INT,
    [Month] INT,
    BranchName NVARCHAR(255),
    BranchReference NVARCHAR(255),
    Starters INT,
    Avg_Hours_Starters_Per_Week FLOAT,
    Leavers INT,
    Avg_Hours_Leavers_Per_Week FLOAT
)
AS
BEGIN
    WITH Tally (N) AS (
        SELECT TOP (DATEDIFF(DAY, @StartDate, @EndDate) + 1)
            ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1
        FROM sys.all_objects
    ),
    DateRange AS (
        SELECT DATEADD(DAY, N, @StartDate) AS [Date]
        FROM Tally
    ),
    FilteredDateRange AS (
        SELECT [Date]
        FROM DateRange
        WHERE DATEPART(WEEKDAY, [Date]) = 1 -- Monday
    ),
    BranchDates AS (
        SELECT DISTINCT
            YEAR(DR.[Date]) AS [Year],
            MONTH(DR.[Date]) AS [Month],
            B.BranchName,
            B.BranchUID AS BranchReference
        FROM FilteredDateRange DR
        CROSS JOIN tbl_BRANCH B
    ),
    NonDummyEmployees AS (
        SELECT DISTINCT EmployeeReference
        FROM tbl_employees
        WHERE EmployeeReference NOT IN (
            SELECT EmployeeReference FROM vw_DummyEmployees WHERE Answer = 'Yes'
        )
    ),
    ValidEmployees AS (
        SELECT 
            E.EmployeeReference,
            YEAR(EB.StartDate) AS StartYear,
            MONTH(EB.StartDate) AS StartMonth,
            YEAR(EB.EndDate) AS EndYear,
            MONTH(EB.EndDate) AS EndMonth,
            EB.BranchReference

        FROM tbl_employees E
        JOIN NonDummyEmployees NDE ON E.EmployeeReference = NDE.EmployeeReference
        JOIN [dbo].[tbl_EmployeeBranch] EB ON E.EmployeeReference = EB.EmployeeReference
        WHERE 
            (EB.StartDate BETWEEN @StartDate AND @EndDate)
            OR (EB.EndDate BETWEEN @StartDate AND @EndDate)
    ),
    EmployeeHoursFiltered AS (
        SELECT
            EH.EmployeeReference,
            EH.BranchReference,
            EH.TotalVisitDuration,
            EH.DistinctVisitDays,
            E.StartYear,
            E.StartMonth,
            E.EndYear,
            E.EndMonth
        FROM vw_EmployeeHours EH
        JOIN ValidEmployees E ON EH.EmployeeReference = E.EmployeeReference and E.BranchReference = EH.BranchReference
      
    ),
    StarterAgg AS (
        SELECT 
            E.BranchReference,
            bd.[Year] AS StartYear,
            bd.[Month] AS StartMonth,
            COUNT(*) AS StarterCount
        FROM ValidEmployees E
        JOIN BranchDates BD ON E.BranchReference = BD.BranchReference and E.StartYear = BD.[Year] and E.StartMonth = BD.[Month]
        GROUP BY E.BranchReference, bd.[Year], bd.[Month]
    ),
    StarterHoursAgg AS (
        SELECT 
            EH.BranchReference,
            EH.StartYear,
            EH.StartMonth,
            ISNULL(SUM(EH.TotalVisitDuration) * 7.0 / NULLIF(SUM(EH.DistinctVisitDays), 0), 0) AS AvgHours
        FROM EmployeeHoursFiltered EH
        JOIN BranchDates BD ON EH.BranchReference = BD.BranchReference and EH.StartYear = BD.[Year] and EH.StartMonth = BD.[Month]
        GROUP BY EH.BranchReference, EH.StartYear, EH.StartMonth
    ),
    LeaverAgg AS (
        SELECT 
            E.BranchReference,
            E.EndYear,
            E.EndMonth,
            COUNT(*) AS LeaverCount
        FROM ValidEmployees E
        JOIN BranchDates BD ON E.BranchReference = BD.BranchReference and E.EndYear = BD.[Year] and E.EndMonth = BD.[Month]
        GROUP BY E.BranchReference, E.EndYear, E.EndMonth
    ),
    LeaverHoursAgg AS (
        SELECT 
            EH.BranchReference,
            EH.EndYear,
            EH.EndMonth,
            ISNULL(SUM(EH.TotalVisitDuration) * 7.0 / NULLIF(SUM(EH.DistinctVisitDays), 0), 0) AS AvgHours
        FROM EmployeeHoursFiltered EH
        JOIN BranchDates BD ON EH.BranchReference = BD.BranchReference and EH.StartYear = BD.[Year] and EH.StartMonth = BD.[Month]

        GROUP BY EH.BranchReference, EH.EndYear, EH.EndMonth
    )
    INSERT INTO @Results
    SELECT 
        BD.[Year],
        BD.[Month],
        BD.BranchName,
        BD.BranchReference,
        ISNULL(SA.StarterCount, 0) AS Starters,
        ISNULL(SH.AvgHours, 0) AS Avg_Hours_Starters_Per_Week,
        ISNULL(LA.LeaverCount, 0) AS Leavers,
        ISNULL(LH.AvgHours, 0) AS Avg_Hours_Leavers_Per_Week
    FROM BranchDates BD
    LEFT JOIN StarterAgg SA 
        ON SA.[StartYear] = BD.[Year] and SA.[StartMonth] = BD.[Month] AND SA.BranchReference = BD.BranchReference
    LEFT JOIN StarterHoursAgg SH 
        ON SH.[StartYear] = BD.[Year] and SH.[StartMonth] = BD.[Month] AND SH.BranchReference = BD.BranchReference
    LEFT JOIN LeaverAgg LA 
        ON LA.[EndYear] = BD.[Year] and LA.[EndMonth] = BD.[Month] AND LA.BranchReference = BD.BranchReference
    LEFT JOIN LeaverHoursAgg LH 
        ON LH.[EndYear] = BD.[Year] and LH.[EndMonth] = BD.[Month] AND LH.BranchReference = BD.BranchReference;

    RETURN;
END;
GO
