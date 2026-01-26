/*
Sanity checks after a run.
Edit table/view names to match your environment.
*/

-- === Row counts ===
-- Replace these names with your actual target tables/views
-- SELECT COUNT(*) AS Branches  FROM dbo.Branch;
-- SELECT COUNT(*) AS Employees FROM dbo.Employee;
-- SELECT COUNT(*) AS Clients   FROM dbo.Client;
-- SELECT COUNT(*) AS Visits    FROM dbo.Visits;

-- === Date coverage ===
-- SELECT MIN(VisitDate) AS MinVisitDate, MAX(VisitDate) AS MaxVisitDate FROM dbo.Visits;

-- === Recent activity ===
-- SELECT TOP (50) * FROM dbo.Visits ORDER BY VisitDate DESC;

-- === Null / key checks (examples) ===
-- SELECT COUNT(*) AS NullClientIds FROM dbo.Visits WHERE ClientId IS NULL;
-- SELECT COUNT(*) AS NullEmployeeIds FROM dbo.Visits WHERE EmployeeId IS NULL;
