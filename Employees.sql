DROP TABLE IF EXISTS dbo.tbl_Employees;

CREATE TABLE [dbo].[tbl_Employees] (
    EmployeeReference INT NOT NULL PRIMARY KEY CLUSTERED,
    BranchReference NVARCHAR(55) NOT NULL,
    EmployeeDateOfBirth DATE NULL,
    EmployeeAge INT NULL,
    EmployeeCode NVARCHAR(50) NOT NULL,
    EmployeeGender NVARCHAR(20) NULL,
    EmployeeForenames NVARCHAR(100) NULL,
    EmployeeSurname NVARCHAR(100) NULL,
    TelephoneNumber NVARCHAR(20) NULL,
    PayrollNumber NVARCHAR(50) NULL,
    Email NVARCHAR(100) NULL,
    Ethnicity NVARCHAR(100) NULL,
    Religion NVARCHAR(100) NULL,
    JobTitle NVARCHAR(100) NULL,
    Salaried NVARCHAR(20) NULL,
    Interface NVARCHAR(20) NULL,
    Driver NVARCHAR(20) NULL,
    FirstLineAddress NVARCHAR(100) NULL,
    SecondLineAddress NVARCHAR(100) NULL,
    ThirdLineAddress NVARCHAR(100) NULL,
    FourthLineAddress NVARCHAR(100) NULL,
    Postcode NVARCHAR(20) NULL,
    EmployeeSubLocation NVARCHAR(100) NULL
);

INSERT INTO tbl_Employees
(
    EmployeeReference,
    BranchReference,
    EmployeeDateOfBirth,
    EmployeeAge,
    EmployeeCode,
    EmployeeGender,
    EmployeeForenames,
    EmployeeSurname,
    TelephoneNumber,
    PayrollNumber,
    Email,
    Ethnicity,
    Religion,
    JobTitle,
    Salaried,
    Interface,
    Driver,
    FirstLineAddress,
    SecondLineAddress,
    ThirdLineAddress,
    FourthLineAddress,
    Postcode,
    EmployeeSubLocation
)
SELECT distinct
    E.EMP_REF                  AS EmployeeReference,
    E.GS_REF                   AS BranchReference,
    CAST(E.BIRTH_DATE AS DATE) AS EmployeeDateOfBirth,
    DATEDIFF(year, CAST(E.BIRTH_DATE AS DATE), GETDATE()) - 
        CASE WHEN DATEADD(year, DATEDIFF(year, E.BIRTH_DATE, GETDATE()), E.BIRTH_DATE) > GETDATE() THEN 1 ELSE 0 END AS EmployeeAge,
    E.EMP_CODE                 AS EmployeeCode,

    CASE E.SEX
        WHEN 'M' THEN 'Male'
        WHEN 'F' THEN 'Female'
        WHEN 'N' THEN 'Not Applicable'
        ELSE 'Unknown'
    END                         AS EmployeeGender,
    
    CHD.FORENAMES               AS EmployeeForenames,
    CHD.SURNAME                 AS EmployeeSurname,
    CHD.TEL_NO1                 AS TelephoneNumber,
    E.PAYROLL_NO                AS PayrollNumber,
    CHD.EMAIL                   AS Email,
    CEE.DESCRIPTION             AS Ethnicity,
    CER.DESCRIPTION             AS Religion,
    CEJT.DESCRIPTION            AS JobTitle,
    JQ.DESCRIPTION              AS Salaried,
    E.INTERFACE                 AS Interface,
    E.DRIVER                    AS Driver,
    CHD.ADDRESS1                AS FirstLineAddress,
    CHD.ADDRESS2                AS SecondLineAddress,
    CHD.ADDRESS3                AS ThirdLineAddress,
    CHD.ADDRESS4                AS FourthLineAddress,
    CHD.POSTCODE                AS Postcode,
    CEL.DESCRIPTION             AS EmployeeSubLocation
FROM [dbo].EMPLOYEE AS E WITH (NOLOCK)
LEFT JOIN [dbo].[tbl_EmployeeBranch] AS EB WITH (NOLOCK)
    ON E.EMP_REF = EB.[EmployeeReference]
    AND EB.[BranchEmployeeMainBranch] = 'Y'
LEFT JOIN [dbo].CONTACT_DT AS CDT WITH (NOLOCK)
    ON CDT.CNTA_DET_REF = E.CNTA_DET_REF
LEFT JOIN [dbo].CONTACT_HD AS CHD WITH (NOLOCK)
    ON CHD.CONTACT_REF = CDT.CONTACT_REF
LEFT JOIN [dbo].CHSYSDEC AS CEE WITH (NOLOCK)
    ON E.ETHNICITY = CEE.DECODE_REF
LEFT JOIN [dbo].CHSYSDEC AS CER WITH (NOLOCK)
    ON E.RELORG_REF = CER.DECODE_REF
LEFT JOIN [dbo].CHSYSDEC AS CEJT WITH (NOLOCK)
    ON E.JOBTITLE = CEJT.DECODE_REF
LEFT JOIN [dbo].CHSYSDEC AS CEL WITH (NOLOCK)
    ON E.LOCATION_REF = CEL.DECODE_REF
LEFT JOIN [dbo].CHSYSDEC AS JQ WITH (NOLOCK)
    ON E.JOB_QUAL = JQ.DECODE_REF
WHERE E.EMP_REF IS NOT NULL; -- Ensure no NULL EmployeeReferences

-- Index creation:
CREATE NONCLUSTERED INDEX IX_tbl_Employees_BranchReference ON [dbo].[tbl_Employees] (BranchReference);
CREATE NONCLUSTERED INDEX IX_tbl_Employees_EmployeeCode ON [dbo].[tbl_Employees] (EmployeeCode);
CREATE NONCLUSTERED INDEX IX_tbl_Employees_Salaried ON [dbo].[tbl_Employees] (Salaried);
CREATE NONCLUSTERED INDEX IX_tbl_Employees_Interface ON [dbo].[tbl_Employees] (Interface);
