-- Indexing recommendations:
CREATE UNIQUE CLUSTERED INDEX IX_tbl_Branch_BranchUID ON [dbo].[tbl_Branch] (BranchUID);

CREATE NONCLUSTERED INDEX IX_tbl_Branch_BranchName ON [dbo].[tbl_Branch] (BranchName);

CREATE NONCLUSTERED INDEX IX_tbl_Branch_Brand ON [dbo].[tbl_Branch] (Brand);

CREATE NONCLUSTERED INDEX IX_tbl_Branch_BranchNameBrand ON [dbo].[tbl_Branch] (BranchName, Brand);  -- Only if you filter/join by both

-- To speed up joins to CONTRACT_DT and CONTRACT_ORG
CREATE INDEX IX_CONTRACT_HD_CONTRACT_REF ON dbo.CONTRACT_HD (CONTRACT_REF);

-- For STATUS, CONTRACT_TYPE, CONTRACT_SOURCE if those columns are used in other queries as well
CREATE INDEX IX_CONTRACT_HD_STATUS ON dbo.CONTRACT_HD (STATUS);
CREATE INDEX IX_CONTRACT_HD_CONTRACT_TYPE ON dbo.CONTRACT_HD (CONTRACT_TYPE);
CREATE INDEX IX_CONTRACT_HD_CONTRACT_SOURCE ON dbo.CONTRACT_HD (CONTRACT_SOURCE);

-- For performance with CONTRULE_HD join (if heavily used elsewhere)
CREATE INDEX IX_CONTRACT_HD_CONTRACT_REF_RECTYPE ON dbo.CONTRACT_HD (CONTRACT_REF);
