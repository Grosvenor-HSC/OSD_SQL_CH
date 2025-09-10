drop table if exists dbo.tbl_EmployeeBranch;

CREATE TABLE dbo.tbl_EmployeeBranch (
    EmployeeReference INT,
    BranchReference NVARCHAR(55),
    StartDate DATETIME,
    EndDate DATETIME,
    [Status] NVARCHAR(255),
    CareGroup NVARCHAR(255),
    LeftReason NVARCHAR(255),
    EmployeeBranchLocation NVARCHAR(255),
    BranchEmployeeMainBranch CHAR(1),
    BranchName NVARCHAR(255)
);

WITH cte_distinct_emp_branch AS (
    SELECT DISTINCT
        DK.INPRIKEY AS EmployeeReference,
        DK.OUTPRIKEY AS DISTBranchReference,
        DK.START_DATE AS StartDate,
        DK.[DATE] AS EndDate,
        DK.LEFTREASON,
        DK.LOCATION_REF,
        DK.[STATUS],
        DK.CARE_GRP_REF
    FROM [dbo].DISTKEY AS DK
),
FirstEmployeeVisits AS (
    SELECT
        EmployeeReference,
        OldBranchUID,
        MIN(VisitStartDate) AS FirstVisitStartDate,
        MAX(VisitEndDate) AS LastVisitEndDate
    FROM tbl_Visits V
    JOIN tbl_Branch B ON V.BranchReference = B.BranchUID
    GROUP BY EmployeeReference, OldBranchUID
)
INSERT INTO dbo.tbl_EmployeeBranch (
    EmployeeReference,
    BranchReference,
    StartDate,
    EndDate,
    [Status],
    CareGroup,
    LeftReason,
    EmployeeBranchLocation,
    BranchEmployeeMainBranch,
    BranchName
)
SELECT
    DK.EmployeeReference,
    CASE
        WHEN DK.DISTBranchReference = '1970000043' AND EL.DESCRIPTION <> 'Southampton' THEN
            (SELECT TOP 1 BranchUID FROM tbl_Branch WHERE BranchName = 'Portsmouth')
        WHEN DK.DISTBranchReference = '1970000043' AND EL.DESCRIPTION = 'Southampton' THEN
            (SELECT TOP 1 BranchUID FROM tbl_Branch WHERE BranchName = 'Southampton')
        WHEN DK.DISTBranchReference <> '1970000043' THEN
            (SELECT TOP 1 BranchUID FROM tbl_Branch WHERE OldBranchUID = DK.DISTBranchReference)
    END AS BranchReference,
    CASE 
        WHEN DK.StartDate IS NULL THEN V.FirstVisitStartDate
        WHEN DK.StartDate IS NOT NULL and V.FirstVisitStartDate < DK.StartDate THEN V.FirstVisitStartDate
        ELSE DK.StartDate
    END AS StartDate,
    CASE WHEN DK.EndDate IS NULL THEN null
        WHEN DK.EndDate IS NOT NULL and V.LastVisitEndDate > DK.EndDate THEN V.LastVisitEndDate
        ELSE DK.EndDate
    END AS EndDate,
    CASE WHEN ES.[DESCRIPTION] = '<No Selection>' THEN '' ELSE ES.DESCRIPTION END AS [Status],
    CASE WHEN ECG.[DESCRIPTION] = '<No Selection>' THEN '' ELSE ECG.DESCRIPTION END AS CareGroup,
    CASE WHEN ELR.[DESCRIPTION] = '<No Selection>' THEN '' ELSE ELR.DESCRIPTION END AS LeftReason,
    CASE WHEN EBL.[DESCRIPTION] = '<No Selection>' THEN '' ELSE EBL.DESCRIPTION END AS EmployeeBranchLocation,
    CASE WHEN DK.DISTBranchReference = E.GS_REF THEN 'Y' ELSE 'N' END AS BranchEmployeeMainBranch,
    B.BranchName
FROM cte_distinct_emp_branch AS DK
left JOIN dbo.tbl_Branch AS B ON DK.DISTBranchReference = B.OldBranchUID
JOIN [dbo].EMPLOYEE AS E ON DK.EmployeeReference = E.EMP_REF
JOIN [dbo].CHSYSDEC AS EL ON E.LOCATION_REF = EL.DECODE_REF
JOIN [dbo].CHSYSDEC AS ES ON ES.DECODE_REF = DK.STATUS
LEFT JOIN FirstEmployeeVisits AS V ON V.EmployeeReference = DK.EmployeeReference AND V.OldBranchUID = DK.DISTBranchReference
LEFT JOIN [dbo].CHSYSDEC AS ECG ON ECG.DECODE_REF = DK.CARE_GRP_REF
LEFT JOIN [dbo].CHSYSDEC AS ELR ON ELR.DECODE_REF = DK.LEFTREASON
LEFT JOIN [dbo].CHSYSDEC AS EBL ON EBL.DECODE_REF = DK.LOCATION_REF
where StartDate is not null
ORDER BY DK.EmployeeReference;
