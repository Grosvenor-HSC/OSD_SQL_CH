-- Drop the table if it exists
IF OBJECT_ID('dbo.tbl_EmployeesDiary', 'U') IS NOT NULL
    DROP TABLE dbo.tbl_EmployeesDiary;
GO

-- Create the table with PascalCase columns
CREATE TABLE dbo.tbl_EmployeesDiary (
    EmployeeReference NVARCHAR(50),
    EmployeeDiaryEntryDate DATETIME,
    EmployeeDiaryReminded NVARCHAR(1),
    EmployeeDiaryReviewDate DATETIME,
    EmployeeDiaryEntryType NVARCHAR(255),
    EmployeeDiaryAction NVARCHAR(MAX),
    EmployeeDiaryActionDate DATETIME,
    EmployeeDiaryReviewDoneDate DATETIME,
    EmployeeDiaryReference INT,
    EmployeeDiaryBranchID INT
);
GO

-- Insert data into the newly created table
INSERT INTO dbo.tbl_EmployeesDiary (
    EmployeeReference,
    EmployeeDiaryEntryDate,
    EmployeeDiaryReminded,
    EmployeeDiaryReviewDate,
    EmployeeDiaryEntryType,
    EmployeeDiaryAction,
    EmployeeDiaryActionDate,
    EmployeeDiaryReviewDoneDate,
    EmployeeDiaryReference,
    EmployeeDiaryBranchID
)
SELECT
    EDY.EMP_REF,
    EDY.ENTRY_DATE,
    EDY.REMINDED,
    EDY.REVIEW_DATE,
    CET.DESCRIPTION,
    EDY.ACTION,
    EDY.ACTIONDT,
    EDY.REVDONE_DT,
    EDY.EMP_DY_REF,
    E.[BranchReference]
FROM [dbo].[EMPLOYEE_DY] AS EDY WITH (NOLOCK)
INNER JOIN [dbo].[tbl_Employees] AS E WITH (NOLOCK)
    ON E.[EmployeeReference] = EDY.[EMP_REF]
LEFT JOIN [dbo].[CHSYSDEC] AS CET WITH (NOLOCK)
    ON CET.DECODE_REF = EDY.ENTRY_TYPE;
GO

-- Create indexes with naming convention: ix_tbl_EmployeesDiary_<ColumnName>
CREATE NONCLUSTERED INDEX ix_tbl_EmployeesDiary_EmployeeReference
    ON dbo.tbl_EmployeesDiary (EmployeeReference);

CREATE NONCLUSTERED INDEX ix_tbl_EmployeesDiary_EmployeeDiaryEntryDate
    ON dbo.tbl_EmployeesDiary (EmployeeDiaryEntryDate);

CREATE NONCLUSTERED INDEX ix_tbl_EmployeesDiary_EmployeeDiaryReviewDate
    ON dbo.tbl_EmployeesDiary (EmployeeDiaryReviewDate);

CREATE NONCLUSTERED INDEX ix_tbl_EmployeesDiary_EmployeeDiaryActionDate
    ON dbo.tbl_EmployeesDiary (EmployeeDiaryActionDate);

CREATE NONCLUSTERED INDEX ix_tbl_EmployeesDiary_EmployeeDiaryBranchID
    ON dbo.tbl_EmployeesDiary (EmployeeDiaryBranchID);
GO
