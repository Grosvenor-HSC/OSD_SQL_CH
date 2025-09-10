SET DATEFIRST 1;

-- Step 1: Define the table explicitly
IF OBJECT_ID('[dbo].[tbl_ClientAbsences]', 'U') IS NOT NULL
    DROP TABLE [dbo].[tbl_ClientAbsences];

CREATE TABLE [dbo].[tbl_ClientAbsences](
    InactiveReference nvarchar(55),
    BranchReference nvarchar(55),
    ClientReference INT,
    AbsenceReason NVARCHAR(255),
    AbsenceStartDate DATE,
    AbsenceEndDate DATE,
    UpdatedLeaveDate DATE,
    AbsenceEndDate_Week DATE,
    AbsenceStartDate_Week DATE,
    AbsenceEndMonth INT,
    AbsenceStartMonth INT,
    AbsenceEndYear INT,
    AbsenceStartYear INT,
    DaysOnLeave INT
);

-- Step 2: Insert data into the defined table
INSERT INTO [dbo].[tbl_ClientAbsences] (
    InactiveReference,
    BranchReference,
    ClientReference,
    AbsenceReason,
    AbsenceStartDate,
    AbsenceEndDate,
    UpdatedLeaveDate,
    AbsenceEndDate_Week,
    AbsenceStartDate_Week,
    AbsenceEndMonth,
    AbsenceStartMonth,
    AbsenceEndYear,
    AbsenceStartYear,
    DaysOnLeave
)
SELECT 
    InactiveReference AS InactiveReference,
    BranchReference,
    ClientReference,
    AbsenceReason,
    AbsenceStartDate,
    AbsenceEndDate,
    UpdatedLeaveDate,
    DATEADD(day, 1 - DATEPART(weekday, UpdatedLeaveDate), UpdatedLeaveDate) AS AbsenceEndDate_Week,
    DATEADD(day, 1 - DATEPART(weekday, AbsenceStartDate), AbsenceStartDate) AS AbsenceStartDate_Week,
    MONTH(UpdatedLeaveDate) AS AbsenceEndMonth,
    MONTH(AbsenceStartDate) AS AbsenceStartMonth,
    YEAR(UpdatedLeaveDate) AS AbsenceEndYear,
    YEAR(AbsenceStartDate) AS AbsenceStartYear,
    DATEDIFF(day, AbsenceStartDate, UpdatedLeaveDate) AS DaysOnLeave
FROM (
    SELECT        
        idy.INACT_REF AS InactiveReference,
        C.BranchReference,
        IDY.CLIENT_REF AS ClientReference,
        CAST(IDY.START_DT AS date) AS AbsenceStartDate,
        CAST(IDY.END_DT AS date) AS AbsenceEndDate,
        CR.DESCRIPTION AS AbsenceReason,
        COALESCE(CAST(IDY.END_DT AS date), CAST(CSLD.GLOBAL_END_DATE AS date), CAST(GETDATE() AS date)) AS UpdatedLeaveDate
    FROM [dbo].INACTIVE_DY AS IDY WITH (NOLOCK)
    INNER JOIN dbo.tbl_Clients AS C WITH (NOLOCK)
        ON IDY.CLIENT_REF = C.ClientReference
    INNER JOIN dbo.tbl_ClientStartLeaveDates AS CSLD WITH (NOLOCK)
        ON CSLD.ClientReference = C.ClientReference
    INNER JOIN dbo.tbl_Branch AS B WITH (NOLOCK)
        ON C.BranchReference = B.BranchUID
    LEFT JOIN [dbo].CHSYSDEC AS CR WITH (NOLOCK) 
        ON CR.DECODE_REF = IDY.REASON
    INNER JOIN dbo.vw_ClientHours AS CH WITH (NOLOCK)
        ON CH.ClientReference = C.ClientReference
    WHERE IDY.rectype NOT IN ('S','R')
) AS SourceTable;

-- Step 3: Add indexes for performance
CREATE INDEX IX_tbl_ClientAbsences_InactiveReference ON [dbo].[tbl_ClientAbsences](InactiveReference);
CREATE INDEX IX_tbl_ClientAbsences_ClientReference ON [dbo].[tbl_ClientAbsences](ClientReference);
CREATE INDEX IX_tbl_ClientAbsences_BranchReference ON [dbo].[tbl_ClientAbsences](BranchReference);
CREATE INDEX IX_tbl_ClientAbsences_AbsenceStartDate ON [dbo].[tbl_ClientAbsences](AbsenceStartDate);
CREATE INDEX IX_tbl_ClientAbsences_AbsenceEndDate ON [dbo].[tbl_ClientAbsences](AbsenceEndDate);
