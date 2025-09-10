IF EXISTS (SELECT 1 FROM sys.tables WHERE name = 'tbl_Clients' AND schema_id = SCHEMA_ID('dbo'))
    DROP TABLE dbo.tbl_Clients;

CREATE TABLE dbo.tbl_Clients (
    BranchReference      VARCHAR(50) NOT NULL,
    ClientReference      VARCHAR(50) NOT NULL,
    ClientCaseNo         VARCHAR(50) NULL,
    ClientDateofBirth    DATE NULL,
    Address1             VARCHAR(255) NULL,
    Address2             VARCHAR(255) NULL,
    Address3             VARCHAR(255) NULL,
    Address4             VARCHAR(255) NULL,
    ClientPostcode       VARCHAR(20) NULL,
    Outward_Code         VARCHAR(10) NULL,
    ClientForenames      VARCHAR(100) NULL,
    ClientSurname        VARCHAR(100) NULL,
    EMAIL                VARCHAR(255) NULL,
    TEL_NO1              VARCHAR(50) NULL,
    TEL_NO2              VARCHAR(50) NULL,
    ClientTitle          VARCHAR(50) NULL,
    ClientGroup          VARCHAR(50) NULL,
    ClientCode           VARCHAR(50) NULL,
    KeySafeYN            VARCHAR(5) NULL,
    KeySafe1             VARCHAR(50) NULL,
    KeySafe2             VARCHAR(50) NULL,
    KeySafe3             VARCHAR(50) NULL,
    ClientGender         VARCHAR(20) NULL,
    ClientStartDate      DATE NULL,
    ClientLeaveDate      DATE NULL,
    ClientStatus         VARCHAR(20) NULL,
    ClientDisability     VARCHAR(100) NULL,
    ClientDisability2    VARCHAR(100) NULL,
    ClientDisability3    VARCHAR(100) NULL,
    ClientEthnicity      VARCHAR(100) NULL,
    ClientLeftReason     VARCHAR(100) NULL,
    ClientReligion       VARCHAR(100) NULL,
    ClientLocation       VARCHAR(100) NULL,
    ClientType           VARCHAR(100) NULL,
    ExternalReference    VARCHAR(100) NULL,
    CNTA_DET_REF         INT NULL,
    LeftReason           VARCHAR(100) NULL
);

WITH BaseClient AS (
    SELECT
       case
            when C.GS_REF = '1970000043' and CL.DESCRIPTION  <> 'Southampton' then
                (select B.BranchUID from tbl_Branch B where B.BranchName = 'Portsmouth') 
            when C.GS_REF = '1970000043' and CL.DESCRIPTION  = 'Southampton' then
                (select B.BranchUID from tbl_Branch B where B.BranchName = 'Southampton')
            when C.GS_REF <> '1970000043' then
                (select B.BranchUID from tbl_Branch B where B.OldBranchUID = C.GS_REF) 
        end AS BranchReference,
        C.CLIENT_REF AS ClientReference,
        C.CASE_NO AS ClientCaseNo,
        C.DATEOFBIRTH AS ClientDateofBirth,
        LTRIM(RTRIM(CHD.ADDRESS1)) AS Address1,
        LTRIM(RTRIM(CHD.ADDRESS2)) AS Address2,
        LTRIM(RTRIM(CHD.ADDRESS3)) AS Address3,
        LTRIM(RTRIM(CHD.ADDRESS4)) AS Address4,
        LTRIM(RTRIM(CHD.POSTCODE)) AS ClientPostcode,
        LEFT(CHD.POSTCODE, CHARINDEX(' ', CHD.POSTCODE + ' ')-1) AS Outward_Code,
        CHD.FORENAMES AS ClientForenames,
        CHD.SURNAME AS ClientSurname,
        CHD.EMAIL,
        CHD.TEL_NO1,
        CHD.TEL_NO2,
        CTL.DESCRIPTION AS ClientTitle,
        CG.DESCRIPTION AS ClientGroup,
        C.CLIENT_CODE AS ClientCode,
        C.KEYSAFE AS KeySafeYN,
        C.KEYSAFENO AS KeySafe1,
        C.KEYSAFE2 AS KeySafe2,
        C.KEYSAFE3 AS KeySafe3,
        CASE WHEN C.SEX = 'M' THEN 'Male'
             WHEN C.SEX = 'F' THEN 'Female'
             ELSE 'Other'
        END AS ClientGender,
        C.START_DATE AS ClientStartDate,
        C.LEFT_DATE AS ClientLeaveDate,
        CSE.DESCRIPTION AS ClientStatus,
        CD1.DESCRIPTION AS ClientDisability,
        CD2.DESCRIPTION AS ClientDisability2,
        CD3.DESCRIPTION AS ClientDisability3,
        CE.DESCRIPTION AS ClientEthnicity,
        CLR.DESCRIPTION AS ClientLeftReason,
        CR.DESCRIPTION AS ClientReligion,
        CL.DESCRIPTION AS ClientLocation,
        CTY.DESCRIPTION AS ClientType,
        C.EXTCLREF AS ExternalReference,
        C.CNTA_DET_REF,
        LR.DESCRIPTION AS LeftReason
    FROM [dbo].CLIENT AS C
    LEFT JOIN [dbo].CONTACT_DT AS CDT ON CDT.CNTA_DET_REF = C.CNTA_DET_REF
    LEFT JOIN [dbo].CONTACT_HD AS CHD ON CHD.CONTACT_REF = CDT.CONTACT_REF
    LEFT JOIN [dbo].CHSYSDEC AS CTL ON CHD.TITLE = CTL.DECODE_REF
    LEFT JOIN [dbo].CHSYSDEC AS CG ON C.CARE_GRP_REF = CG.DECODE_REF
    LEFT JOIN [dbo].CHSYSDEC AS CD1 ON C.DISAB_REF = CD1.DECODE_REF
    LEFT JOIN [dbo].CHSYSDEC AS CD2 ON C.DISAB_REF2 = CD2.DECODE_REF
    LEFT JOIN [dbo].CHSYSDEC AS CD3 ON C.DISAB_REF3 = CD3.DECODE_REF
    LEFT JOIN [dbo].CHSYSDEC AS CE ON C.ETHNICITY = CE.DECODE_REF
    LEFT JOIN [dbo].CHSYSDEC AS CLR ON C.LEFTRES_REF = CLR.DECODE_REF
    LEFT JOIN [dbo].CHSYSDEC AS LR ON C.LEFTRES_REF = LR.DECODE_REF
    LEFT JOIN [dbo].CHSYSDEC AS CR ON C.RELORG_REF = CR.DECODE_REF
    LEFT JOIN [dbo].CHSYSDEC AS CTY ON C.CLIENT_TYPE = CTY.DECODE_REF
    LEFT JOIN [dbo].CHSYSDEC AS CL ON C.LOCATION_REF = CL.DECODE_REF
    LEFT JOIN [dbo].CHSYSDEC AS CSE ON C.STATUS = CSE.DECODE_REF

   
    
)

INSERT INTO dbo.tbl_Clients (
    BranchReference,
    ClientReference,
    ClientCaseNo,
    ClientDateofBirth,
    Address1,
    Address2,
    Address3,
    Address4,
    ClientPostcode,
    Outward_Code,
    ClientForenames,
    ClientSurname,
    EMAIL,
    TEL_NO1,
    TEL_NO2,
    ClientTitle,
    ClientGroup,
    ClientCode,
    KeySafeYN,
    KeySafe1,
    KeySafe2,
    KeySafe3,
    ClientGender,
    ClientStartDate,
    ClientLeaveDate,
    ClientStatus,
    ClientDisability,
    ClientDisability2,
    ClientDisability3,
    ClientEthnicity,
    ClientLeftReason,
    ClientReligion,
    ClientLocation,
    ClientType,
    ExternalReference,
    CNTA_DET_REF,
    LeftReason
)
SELECT
    BranchReference,
    ClientReference,
    ClientCaseNo,
    ClientDateofBirth,
    Address1,
    Address2,
    Address3,
    Address4,
    ClientPostcode,
    Outward_Code,
    ClientForenames,
    ClientSurname,
    EMAIL,
    TEL_NO1,
    TEL_NO2,
    ClientTitle,
    ClientGroup,
    ClientCode,
    KeySafeYN,
    KeySafe1,
    KeySafe2,
    KeySafe3,
    ClientGender,
    ClientStartDate,
    ClientLeaveDate,
    ClientStatus,
    ClientDisability,
    ClientDisability2,
    ClientDisability3,
    ClientEthnicity,
    ClientLeftReason,
    ClientReligion,
    ClientLocation,
    ClientType,
    ExternalReference,
    CNTA_DET_REF,
    LeftReason
FROM BaseClient
 where BranchReference is not null

 -- Add primary key
ALTER TABLE dbo.tbl_Clients
ADD CONSTRAINT PK_tbl_Clients_ClientReference PRIMARY KEY CLUSTERED (ClientReference);

-- Add index on BranchReference
CREATE NONCLUSTERED INDEX IX_tbl_Clients_BranchReference
ON dbo.tbl_Clients (BranchReference);

-- Add composite index on ClientStartDate and ClientLeaveDate
CREATE NONCLUSTERED INDEX IX_tbl_Clients_StartLeave
ON dbo.tbl_Clients (ClientStartDate, ClientLeaveDate);
