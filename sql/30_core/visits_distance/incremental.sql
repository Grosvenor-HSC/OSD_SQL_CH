-- Incremental window
DECLARE @Now   DATETIME2(0) = GETDATE();
DECLARE @Since DATETIME2(0);

SELECT @Since = MAX(V2.VisitStartDateTime)
FROM dbo.tbl_Visits AS V2 WITH (NOLOCK)
JOIN dbo.tbl_VisitsDistance AS tvd WITH (NOLOCK)
  ON tvd.ACT_REF = V2.VisitReference;

IF @Since IS NULL SET @Since = '1900-01-01';

WITH FilteredActivity AS (      -- keep only columns needed downstream
    SELECT 
        V.VisitReference,
        V.EmployeeReference,
        CAST(V.VisitStartDateTime AS DATETIME2(0)) AS VisitStartDateTime,
        CAST(V.VisitStartDateTime AS DATE)         AS VisitDate,
        E.Postcode       AS EmployeePostcode,
        C.ClientPostcode,
        V.VisitPayStatus,
        V.CancelPayFlag,
        V.VisitServiceCode,
        CAST(AV.REASON AS VARCHAR(255)) AS Reason
    FROM dbo.tbl_Visits AS V WITH (NOLOCK)
    INNER JOIN dbo.tbl_Employees AS E WITH (NOLOCK)
        ON E.EmployeeReference = V.EmployeeReference
    INNER JOIN dbo.tbl_Clients   AS C WITH (NOLOCK)
        ON C.ClientReference = V.ClientReference
    LEFT  JOIN dbo.ACTIVITY_VARS AS AV WITH (NOLOCK)
        ON AV.ACT_REF = V.VisitReference
    WHERE
        V.VisitStartDateTime >= @Since
        AND V.VisitStartDateTime <  @Now
        AND V.VisitPayStatus   NOT IN (5, -1)
        AND V.VisitServiceCode NOT IN ('1GH','1TV','BU','1GH-CAS','CCS','CGS','CGS-S')
        AND V.EmployeeReference <> 0
        AND E.INTERFACE <> 'N'
        AND C.ClientPostcode <> 'NO MILES'
        AND NOT (
              (V.VisitPayStatus = 4 AND COALESCE(CAST(AV.REASON AS VARCHAR(255)),'') NOT IN ('No Response','Refused Visit'))
           OR (V.CancelPayFlag = 'Y' AND COALESCE(CAST(AV.REASON AS VARCHAR(255)),'') NOT IN ('No Response','Refused Visit'))
           OR (V.VisitServiceCode LIKE 'SNC%' AND COALESCE(CAST(AV.REASON AS VARCHAR(255)),'') NOT IN ('No Response','Refused Visit'))
        )
),
Numbered AS (
    SELECT
        fa.*,
        ROW_NUMBER() OVER (
            PARTITION BY fa.EmployeeReference, fa.VisitDate
            ORDER BY fa.VisitStartDateTime
        ) AS VisitRank,
        COUNT(*) OVER (
            PARTITION BY fa.EmployeeReference, fa.VisitDate
        ) AS TotalVisits
    FROM FilteredActivity AS fa
),
Legs AS (
    -- (1) Home/Prev -> Current (single pass; handles Home->First inline)
    SELECT
        n.VisitReference,
        CASE WHEN n.VisitRank = 1
             THEN n.EmployeePostcode
             ELSE LAG(n.ClientPostcode) OVER (PARTITION BY n.EmployeeReference, n.VisitDate ORDER BY n.VisitRank)
        END AS frompcode,
        n.ClientPostcode AS topcode
    FROM Numbered AS n

    UNION ALL
    -- (2) Last -> Home
    SELECT
        n.VisitReference,
        n.ClientPostcode,
        n.EmployeePostcode
    FROM Numbered AS n
    WHERE n.VisitRank = n.TotalVisits
),
UniqueLegs AS (
    SELECT
        l.VisitReference,
        l.frompcode,
        l.topcode
    FROM Legs AS l
    WHERE l.frompcode IS NOT NULL
      AND l.topcode  IS NOT NULL
      AND l.frompcode <> l.topcode          -- skip zero-distance loops
    GROUP BY l.VisitReference, l.frompcode, l.topcode
)
INSERT INTO dbo.tbl_VisitsDistance (ACT_REF, frompcode, topcode, DISTANCE)
SELECT
    u.VisitReference AS ACT_REF,
    u.frompcode,
    u.topcode,
    dm.DISTANCE
FROM UniqueLegs AS u
JOIN dbo.Distance_Matrix AS dm
  ON dm.PCODE_FR = u.frompcode
 AND dm.PCODE_TO = u.topcode
WHERE NOT EXISTS (
    SELECT 1
    FROM dbo.tbl_VisitsDistance AS tvd
    WHERE tvd.ACT_REF   = u.VisitReference
      AND tvd.frompcode = u.frompcode
      AND tvd.topcode   = u.topcode
);
