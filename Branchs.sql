IF EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'dbo.tbl_Branch') AND type = 'U')
    DROP TABLE dbo.tbl_Branch;

CREATE TABLE [dbo].[tbl_Branch] (
    BranchUID VARCHAR(42) NOT NULL PRIMARY KEY,   -- SHA1 as hex, adjust size!
    BranchName NVARCHAR(100) NOT NULL,
    Brand NVARCHAR(100) NULL,
    Active NVARCHAR(20) NULL,
    EarlyPayRate DECIMAL(10,2) NULL,
    OldBranchUID VARCHAR(20) NULL
);


-- Populate the table (initially, just use SELECT INTO or INSERT)
INSERT INTO [dbo].[tbl_Branch] (BranchUID, BranchName, Brand, Active, EarlyPayRate, OldBranchUID)
SELECT 
    CAST(LOWER(master.dbo.fn_varbintohexstr(HASHBYTES('SHA1', CASE WHEN GS.GS_REF = '1970000043' AND GS.NAME IN ('Portsmouth', 'Southampton') THEN GS.NAME ELSE GS.NAME END))) AS VARCHAR(42)),
    CAST(CASE 
        WHEN GS.GS_REF = '1970000043' AND GS.NAME = 'Portsmouth' THEN 'Portsmouth'
        WHEN GS.GS_REF = '1970000043' AND GS.NAME = 'Southampton' THEN 'Southampton'
        ELSE GS.NAME
    END AS NVARCHAR(100)),
    CAST(GS.VATREG AS NVARCHAR(100)),
    CAST(GS.NHS_DEPT AS NVARCHAR(20)),
    CAST(EPIRT.[LowestBasicRate] AS DECIMAL(10,2)),
    CAST(GS.GS_REF AS VARCHAR(20))
FROM [dbo].GLOB_SITE GS
LEFT JOIN [dbo].CONTACT_DT CDT ON CDT.CNTA_DET_REF = GS.CNTA_DET_REF
LEFT JOIN [dbo].CONTACT_HD CHD ON CHD.CONTACT_REF = CDT.CONTACT_REF
LEFT JOIN [dbo].[tbl_EarlyPayInitialRatesTable] EPIRT ON EPIRT.Branch = GS.NAME
WHERE (GS.GS_REF <> '1970000069' and GS.GS_REF <> '1970000043')
UNION
SELECT 
    CAST(LOWER(master.dbo.fn_varbintohexstr(HASHBYTES('SHA1', 'Portsmouth' ))) AS VARCHAR(42)),
    CAST('Portsmouth' AS NVARCHAR(100)),
    CAST(GS.VATREG AS NVARCHAR(100)),
    CAST(GS.NHS_DEPT AS NVARCHAR(20)),
    CAST(EPIRT.[LowestBasicRate] AS DECIMAL(10,2)),
    CAST(GS.GS_REF AS VARCHAR(20))
FROM [dbo].GLOB_SITE GS
LEFT JOIN [dbo].CONTACT_DT CDT ON CDT.CNTA_DET_REF = GS.CNTA_DET_REF
LEFT JOIN [dbo].CONTACT_HD CHD ON CHD.CONTACT_REF = CDT.CONTACT_REF
LEFT JOIN [dbo].[tbl_EarlyPayInitialRatesTable] EPIRT ON EPIRT.Branch = GS.NAME
WHERE (GS.GS_REF = '1970000043')
UNION
SELECT 
    CAST(LOWER(master.dbo.fn_varbintohexstr(HASHBYTES('SHA1', 'Southampton'))) AS VARCHAR(42)),
    CAST('Southampton' AS NVARCHAR(100)),
    CAST(GS.VATREG AS NVARCHAR(100)),
    CAST(GS.NHS_DEPT AS NVARCHAR(20)),
    CAST(EPIRT.[LowestBasicRate] AS DECIMAL(10,2)),
    CAST(GS.GS_REF AS VARCHAR(20))
FROM [dbo].GLOB_SITE GS
LEFT JOIN [dbo].CONTACT_DT CDT ON CDT.CNTA_DET_REF = GS.CNTA_DET_REF
LEFT JOIN [dbo].CONTACT_HD CHD ON CHD.CONTACT_REF = CDT.CONTACT_REF
LEFT JOIN [dbo].[tbl_EarlyPayInitialRatesTable] EPIRT ON EPIRT.Branch = GS.NAME
WHERE (GS.GS_REF = '1970000043')
UNION
SELECT 
    CAST(LOWER(master.dbo.fn_varbintohexstr(HASHBYTES('SHA1', 'Old_Southampton'))) AS VARCHAR(42)),
    CAST('Old_Southampton' AS NVARCHAR(100)),
    CAST(GS.VATREG AS NVARCHAR(100)),
    CAST(GS.NHS_DEPT AS NVARCHAR(20)),
    CAST(EPIRT.[LowestBasicRate] AS DECIMAL(10,2)),
    CAST(GS.GS_REF AS VARCHAR(20))
FROM [dbo].GLOB_SITE GS
LEFT JOIN [dbo].CONTACT_DT CDT ON CDT.CNTA_DET_REF = GS.CNTA_DET_REF
LEFT JOIN [dbo].CONTACT_HD CHD ON CHD.CONTACT_REF = CDT.CONTACT_REF
LEFT JOIN [dbo].[tbl_EarlyPayInitialRatesTable] EPIRT ON EPIRT.Branch = GS.NAME
WHERE (GS.GS_REF = '1970000069')
-- BranchUID is already defined as PRIMARY KEY in the table definition, so a separate primary key index is not needed.
-- If you want to explicitly create a primary key constraint (if not already present), use:


CREATE NONCLUSTERED INDEX IX_tbl_Branch_BranchName ON [dbo].[tbl_Branch] (BranchName);
CREATE NONCLUSTERED INDEX IX_tbl_Branch_Brand ON [dbo].[tbl_Branch] (Brand);
CREATE NONCLUSTERED INDEX IX_tbl_Branch_BranchNameBrand ON [dbo].[tbl_Branch] (BranchName, Brand);  -- Only if you filter/join by both
;
