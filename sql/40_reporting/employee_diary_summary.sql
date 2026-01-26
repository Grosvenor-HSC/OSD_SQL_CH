CREATE OR ALTER VIEW vw_EmployeeDiarySummary AS
WITH FilteredDiary AS (
    SELECT 
        ED.EmployeeReference,
        ED.EmployeeDiaryEntryType,
        ED.EmployeeDiaryEntryDate,
        E.BranchReference
    FROM [dbo].[tbl_EmployeesDiary] ED
    JOIN [dbo].[tbl_Employees] E ON ED.[EmployeeReference] = E.[EmployeeReference]
    join [dbo].[tbl_EmployeeStartLeaveDates] esld on  e.[EmployeeReference] = esld.[EmployeeReference]
    WHERE Esld.[GlobalStatus] <> 'Permanently Inactive'
),
ClassifiedDiary AS (
    SELECT 
        BranchReference,
        EmployeeDiaryEntryType,
        CASE 
            WHEN EmployeeDiaryEntryDate >= DATEADD(day, -273.5, GETDATE()) THEN 'Current'
            WHEN EmployeeDiaryEntryDate > DATEADD(day, -365, GETDATE()) 
                 AND EmployeeDiaryEntryDate <= DATEADD(day, -273.5, GETDATE()) THEN 'Upcoming'
            WHEN EmployeeDiaryEntryDate < DATEADD(day, -365, GETDATE()) THEN 'Expired'
            ELSE 'Other'
        END AS EntryStatus
    FROM FilteredDiary
),
DiaryCounts AS (
    SELECT 
        BranchReference,
        EmployeeDiaryEntryType,
        EntryStatus,
        COUNT(*) AS EntryCount
    FROM ClassifiedDiary
    GROUP BY BranchReference, EmployeeDiaryEntryType, EntryStatus
),
TotalCounts AS (
    SELECT 
        BranchReference,
        EmployeeDiaryEntryType,
        COUNT(*) AS CountTotal
    FROM FilteredDiary
    GROUP BY BranchReference, EmployeeDiaryEntryType
)
SELECT 
    T.BranchReference,
    T.EmployeeDiaryEntryType,
    T.CountTotal,
    ISNULL(C.EntryCount, 0) AS CountCurrent,
    ISNULL(E.EntryCount, 0) AS CountExpired,
    ISNULL(U.EntryCount, 0) AS CountUpcoming
FROM TotalCounts T
LEFT JOIN DiaryCounts C ON C.BranchReference = T.BranchReference 
    AND C.EmployeeDiaryEntryType = T.EmployeeDiaryEntryType AND C.EntryStatus = 'Current'
LEFT JOIN DiaryCounts E ON E.BranchReference = T.BranchReference 
    AND E.EmployeeDiaryEntryType = T.EmployeeDiaryEntryType AND E.EntryStatus = 'Expired'
LEFT JOIN DiaryCounts U ON U.BranchReference = T.BranchReference 
    AND U.EmployeeDiaryEntryType = T.EmployeeDiaryEntryType AND U.EntryStatus = 'Upcoming';
