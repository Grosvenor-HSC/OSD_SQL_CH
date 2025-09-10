IF OBJECT_ID('dbo.tbl_EmployeeStartLeaveDates', 'U') IS NOT NULL
    DROP TABLE dbo.tbl_EmployeeStartLeaveDates;

CREATE TABLE dbo.tbl_EmployeeStartLeaveDates (
    UpdatedGlobalStartDate DATE,
    GlobalStartDate DATE,
    GlobalEndDate DATE,
    GlobalStatus VARCHAR(50),
    EmployeeReference VARCHAR(50),
    UpdatedLeaveDate DATE,
    NumberOfBranches INT
);

INSERT INTO dbo.tbl_EmployeeStartLeaveDates (
    UpdatedGlobalStartDate,
    GlobalStartDate,
    GlobalEndDate,
    GlobalStatus,
    EmployeeReference,
    UpdatedLeaveDate,
    NumberOfBranches
)
SELECT
    MIN(emb.[StartDate]) AS UpdatedGlobalStartDate,
    ISNULL(MIN(emb.[StartDate]), CAST('1998-01-01' AS DATE)) AS GlobalStartDate,
    CASE
        WHEN EXISTS (
            SELECT 1 FROM dbo.tbl_EmployeeBranch eb
            WHERE eb.EmployeeReference = emb.EmployeeReference
            AND eb.EndDate IS NULL
        ) THEN NULL
        ELSE MAX(emb.EndDate)
    END AS GlobalEndDate,
    CASE
        WHEN EXISTS (
            SELECT 1 FROM dbo.tbl_EmployeeBranch eb
            WHERE eb.EmployeeReference = emb.EmployeeReference
            AND eb.EndDate IS NULL
        ) THEN
            CASE
                WHEN EXISTS (
                    SELECT 1 FROM dbo.tbl_EmployeeBranch eb
                    WHERE eb.EmployeeReference = emb.EmployeeReference
                    AND eb.STATUS = 'Active'
                ) THEN 'Active'
                WHEN EXISTS (
                    SELECT 1 FROM dbo.tbl_EmployeeBranch eb
                    WHERE eb.EmployeeReference = emb.EmployeeReference
                    AND eb.status = 'Temporarily Inactive'
                ) THEN 'Temporarily Inactive'
            END
        ELSE 'Permanently Inactive'
    END AS GlobalStatus,
    emb.EmployeeReference,
    ISNULL(
        CASE
            WHEN EXISTS (
                SELECT 1 FROM dbo.tbl_EmployeeBranch eb
                WHERE eb.EmployeeReference = emb.EmployeeReference
                AND eb.EndDate IS NULL
            ) THEN NULL
            ELSE MAX(emb.EndDate)
        END,
        CAST(GETDATE() AS DATE)
    ) AS UpdatedLeaveDate,
    COUNT(DISTINCT emb.BranchReference) AS NumberOfBranches
FROM dbo.tbl_EmployeeBranch emb
LEFT JOIN dbo.vw_EmployeeHours eh ON emb.EmployeeReference = eh.EmployeeReference
LEFT JOIN dbo.tbl_Employees e WITH (NOLOCK) ON emb.EmployeeReference = e.[EmployeeReference]
GROUP BY
    emb.EmployeeReference
