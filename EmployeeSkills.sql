SET NOCOUNT ON;
SET XACT_ABORT ON;

IF OBJECT_ID('dbo.tbl_EmployeeSkills','U') IS NOT NULL
  DROP TABLE dbo.tbl_EmployeeSkills;
GO

CREATE TABLE dbo.tbl_EmployeeSkills (
    EmployeeReference                  VARCHAR(20)   NOT NULL,
    EmployeeKeySkillDescription        VARCHAR(255)  NOT NULL,
    EmployeeSkillReference             INT           NOT NULL,     -- SKILLREQ_REF
    EmployeeKeySkillValidFromDate      DATETIME2     NULL,
    EmployeeKeySkillValidToDate        DATETIME2     NULL,
    EmployeeKeySkillNotes              NVARCHAR(MAX) NULL,
    EmployeeKeySkillRefField           VARCHAR(50)   NULL,
    UpdatedEmployeeKeySkillValidToDate DATETIME2     NULL,
    EmployeeKeySkillCategory           VARCHAR(255)  NULL,
    BranchReference                    NVARCHAR(50)  NULL,
    CONSTRAINT PK_tbl_EmployeeSkills PRIMARY KEY CLUSTERED (EmployeeSkillReference)
);
GO

;WITH SR AS (
  SELECT
      sr.SKILLREQ_REF,
      sr.REFERENCE  AS EMP_REF,
      sr.SKILL_REF,
      /* parse safely in case the source is varchar */
      TRY_CONVERT(datetime2, sr.VAL_START_DTM) AS StartDT,
      TRY_CONVERT(datetime2, sr.VAL_END_DTM)   AS EndDT,
      CAST(sr.NOTES AS NVARCHAR(MAX))          AS Notes,
      sr.REFFIELD
  FROM dbo.SKILL_REQD sr WITH (NOLOCK)
  WHERE sr.REF_TYPE = 2
),
J AS (
  SELECT
      sr.SKILLREQ_REF,
      sr.EMP_REF,
      d.DESCRIPTION,
      sr.StartDT,
      sr.EndDT,
      sr.Notes,
      sr.REFFIELD,
      cat.DESC_TXT AS Cat,
      b.BranchUID,
      ROW_NUMBER() OVER (PARTITION BY sr.SKILLREQ_REF ORDER BY sr.StartDT DESC, sr.SKILLREQ_REF) AS rn
  FROM SR sr
  JOIN dbo.EMPLOYEE e WITH (NOLOCK) ON e.EMP_REF = sr.EMP_REF
  JOIN dbo.tbl_Branch b ON e.GS_REF = b.OldBranchUID
  CROSS APPLY (
      SELECT TOP 1 LTRIM(RTRIM(d.DESCRIPTION)) AS DESCRIPTION, d.VALUE1
      FROM dbo.CHSYSDEC d WITH (NOLOCK)
      WHERE d.DECODE_REF = sr.SKILL_REF AND d.GROUP1 = 2 AND d.CODE = 'SKIL'
      ORDER BY d.DECODE_REF
  ) d
  OUTER APPLY (
      SELECT TOP 1 sc.DESC_TXT
      FROM dbo.SKILL_CATS sc WITH (NOLOCK)
      WHERE sc.SKILL_REF = d.VALUE1
      ORDER BY sc.DESC_TXT
  ) cat
)
INSERT dbo.tbl_EmployeeSkills (
    EmployeeReference,
    EmployeeKeySkillDescription,
    EmployeeSkillReference,
    EmployeeKeySkillValidFromDate,
    EmployeeKeySkillValidToDate,
    EmployeeKeySkillNotes,
    EmployeeKeySkillRefField,
    UpdatedEmployeeKeySkillValidToDate,
    EmployeeKeySkillCategory,
    BranchReference
)
SELECT
    J.EMP_REF,
    J.DESCRIPTION,
    J.SKILLREQ_REF,
    J.StartDT,
    J.EndDT,
    J.Notes,
    J.REFFIELD,
    COALESCE(J.EndDT, SYSDATETIME()),
    J.Cat,
    J.BranchUID
FROM J
WHERE J.rn = 1;   -- safety net in case anything still fans out
GO

-- Helpful indexes
CREATE NONCLUSTERED INDEX IX_tbl_EmployeeSkills_EmployeeReference
  ON dbo.tbl_EmployeeSkills (EmployeeReference)
  INCLUDE (EmployeeKeySkillDescription, EmployeeKeySkillValidFromDate, EmployeeKeySkillValidToDate);

CREATE NONCLUSTERED INDEX IX_tbl_EmployeeSkills_BranchReference
  ON dbo.tbl_EmployeeSkills (BranchReference)

CREATE NONCLUSTERED INDEX IX_tbl_EmployeeSkills_EmployeeKeySkillDescription
  ON dbo.tbl_EmployeeSkills (EmployeeKeySkillDescription)
  INCLUDE (EmployeeReference, EmployeeKeySkillValidFromDate, EmployeeKeySkillValidToDate);