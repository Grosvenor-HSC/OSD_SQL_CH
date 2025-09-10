SET DATEFIRST 1;

-- Drop table if it already exists
IF OBJECT_ID('dbo.tbl_EmployeesAbsences', 'U') IS NOT NULL
    DROP TABLE dbo.tbl_EmployeesAbsences;

-- Create table in advance with PascalCase naming and tbbl_ prefix
CREATE TABLE dbo.tbl_EmployeesAbsences (
    BranchReference NVARCHAR(50),
    EmployeeReference NVARCHAR(50),
    AbsenceReason NVARCHAR(255),
    AbsenceEndDate DATETIME,
    AbsenceStartDate DATETIME,
    UpdatedEndDate DATETIME,
    AbsenceALStatus NVARCHAR(50),
    UpdatedEndDateWeek DATE,
    UpdatedStartDateWeek DATE,
    UpdatedEndDateMonth DATE,
    UpdatedStartDateMonth DATE,
    UpdatedEndDateYear DATE,
    UpdatedStartDateYear DATE,
    ID CHAR(32), -- MD5 hash
    Duration INT,
    Comment NVARCHAR(MAX)
);

-- Insert data into the pre-created table
INSERT INTO dbo.tbl_EmployeesAbsences (
    BranchReference,
    EmployeeReference,
    AbsenceReason,
    AbsenceEndDate,
    AbsenceStartDate,
    UpdatedEndDate,
    AbsenceALStatus,
    UpdatedEndDateWeek,
    UpdatedStartDateWeek,
    UpdatedEndDateMonth,
    UpdatedStartDateMonth,
    UpdatedEndDateYear,
    UpdatedStartDateYear,
    ID,
    Duration,
    Comment
)
SELECT
    E.BranchReference,
    IDY.EMP_REF AS EmployeeReference,
    CR.DESCRIPTION AS AbsenceReason,
    IDY.END_DTM AS AbsenceEndDate,
    IDY.START_DTM AS AbsenceStartDate,
    CASE 
        WHEN IDY.END_DTM IS NULL AND ESLD.[GlobalStartDate] IS NULL THEN GETDATE()
        WHEN IDY.END_DTM IS NULL AND ESLD.[GlobalStartDate] IS NOT NULL THEN ESLD.[GlobalEndDate]
        ELSE IDY.END_DTM
    END AS UpdatedEndDate,
    CASE 
        WHEN IDY.ALEAVESTAT = '' THEN 'Entered' 
        WHEN IDY.ALEAVESTAT = 'C' THEN 'Confirmed' 
        WHEN IDY.ALEAVESTAT = 'P' THEN 'Part-Paid' 
        WHEN IDY.ALEAVESTAT = 'F' THEN 'Fully-Paid' 
        ELSE 'Unknown'
    END AS AbsenceALStatus,
    DATEADD(DAY, 7 - DATEPART(WEEKDAY, CONVERT(DATE, 
        CASE 
            WHEN IDY.END_DTM IS NULL AND ESLD.[GlobalStartDate] IS NOT NULL THEN ESLD.[GlobalEndDate]
            WHEN IDY.END_DTM IS NULL THEN GETDATE()
            ELSE IDY.END_DTM
        END)), 
        CONVERT(DATE, 
        CASE 
            WHEN IDY.END_DTM IS NULL AND ESLD.[GlobalStartDate] IS NOT NULL THEN ESLD.[GlobalEndDate]
            WHEN IDY.END_DTM IS NULL THEN GETDATE()
            ELSE IDY.END_DTM
        END)
    ) AS UpdatedEndDateWeek,
    DATEADD(DAY, 7 - DATEPART(WEEKDAY, CONVERT(DATE, IDY.START_DTM)), CONVERT(DATE, IDY.START_DTM)) AS UpdatedStartDateWeek,
    EOMONTH(
        CASE 
            WHEN IDY.END_DTM IS NULL AND ESLD.[GlobalStartDate] IS NOT NULL THEN ESLD.[GlobalEndDate]
            WHEN IDY.END_DTM IS NULL THEN GETDATE()
            ELSE IDY.END_DTM
        END
    ) AS UpdatedEndDateMonth,
    EOMONTH(IDY.START_DTM) AS UpdatedStartDateMonth,
    CONVERT(DATE, DATEADD(YY, DATEDIFF(YY, 0, 
        CASE 
            WHEN IDY.END_DTM IS NULL AND ESLD.[GlobalStartDate] IS NOT NULL THEN ESLD.[GlobalEndDate]
            WHEN IDY.END_DTM IS NULL THEN GETDATE()
            ELSE IDY.END_DTM
        END
    ) + 1, -1)) AS UpdatedEndDateYear,
    CONVERT(DATE, DATEADD(YY, DATEDIFF(YY, 0, IDY.START_DTM) + 1, -1)) AS UpdatedStartDateYear,
    CONVERT(VARCHAR(32), HashBytes('MD5', CONCAT(IDY.EMP_REF, IDY.START_DTM, CR.DESCRIPTION)), 2) AS ID,
    CASE 
        WHEN IDY.END_DTM IS NULL AND ESLD.[GlobalStartDate] IS NOT NULL THEN DATEDIFF(DAY, IDY.START_DTM, ESLD.[GlobalEndDate])
        ELSE DATEDIFF(DAY, IDY.START_DTM, IDY.END_DTM)
    END AS Duration,
    IDY.COMMENT
FROM [dbo].INACTIVE_DY IDY WITH (NOLOCK)
LEFT JOIN [dbo].CHSYSDEC CR WITH (NOLOCK) ON CR.DECODE_REF = IDY.REASON
LEFT JOIN dbo.tbl_Employees E WITH (NOLOCK) ON E.EmployeeReference = IDY.EMP_REF
JOIN [dbo].[tbl_EmployeeStartLeaveDates] ESLD ON ESLD.EmployeeReference = E.EmployeeReference
-- WHERE 
--     IDY.EMP_REF <> 0 
--     AND IDY.rectype = 'E'
--     AND CR.DESCRIPTION NOT IN ('From Another Branch', 'Input Error', 'Resigned ', 'Do not use');

-- Create indexes after insert for performance
CREATE NONCLUSTERED INDEX IX_EmployeesAbsences_EmployeeReference
    ON dbo.tbl_EmployeesAbsences (EmployeeReference);

CREATE NONCLUSTERED INDEX IX_EmployeesAbsences_UpdatedEndDate
    ON dbo.tbl_EmployeesAbsences (UpdatedEndDate);

CREATE NONCLUSTERED INDEX IX_EmployeesAbsences_ID
    ON dbo.tbl_EmployeesAbsences (ID);
