-- Drop existing table if it exists
IF OBJECT_ID('dbo.tbl_ClientDiary', 'U') IS NOT NULL
    DROP TABLE dbo.tbl_ClientDiary;

-- Create the new table explicitly
CREATE TABLE dbo.tbl_ClientDiary (
    ClientReference VARCHAR(20) NOT NULL,
    ClientDiaryReference VARCHAR(20) NOT NULL,
    ClientDiaryEntryDate DATETIME NULL,
    ClientDiaryEntryType NVARCHAR(255) NULL,
    ClientDiaryEntryText NVARCHAR(MAX) NULL,
    ClientDiaryReminded NVarchar(1) NULL,
    ClientDiaryReviewDate DATETIME NULL,
    ClientDiaryAction NVARCHAR(255) NULL,
    ClientDiaryActionDate DATETIME NULL,
    ClientDiaryReviewDoneDate DATETIME NULL,
    CONSTRAINT PK_tbl_ClientDiary PRIMARY KEY (ClientReference, ClientDiaryReference)
);

-- Populate the table
INSERT INTO dbo.tbl_ClientDiary (
    ClientReference,
    ClientDiaryReference,
    ClientDiaryEntryDate,
    ClientDiaryEntryType,
    ClientDiaryEntryText,
    ClientDiaryReminded,
    ClientDiaryReviewDate,
    ClientDiaryAction,
    ClientDiaryActionDate,
    ClientDiaryReviewDoneDate
)
SELECT 
    CDY.CLIENT_REF,
    CDY.CL_DY_REF,
    CDY.ENTRY_DATE,
    CET.DESCRIPTION,
    CDY.ENTRY_TEXT,
    CDY.REMINDED,
    CDY.REVIEW_DATE,
    CDY.ACTION,
    CDY.ACTIONDT,
    CDY.REVDONE_DT
FROM [dbo].CLIENT_DY AS CDY WITH (NOLOCK)
INNER JOIN [dbo].CLIENT AS C WITH (NOLOCK)
    ON C.CLIENT_REF = CDY.CLIENT_REF
LEFT JOIN [dbo].CHSYSDEC AS CET WITH (NOLOCK)
    ON CET.DECODE_REF = CDY.ENTRY_TYPE
WHERE C.RECTYPE NOT IN ('S', 'R');
