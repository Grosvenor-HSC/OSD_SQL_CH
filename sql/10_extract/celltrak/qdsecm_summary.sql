/* =========================
   0) RAW PULLS (unchanged inside OPENQUERY) 
   ========================= */

SET NOCOUNT ON;

DROP TABLE IF EXISTS #v_raw, #ex_raw, #miss_raw;

-- Visits (raw)
SELECT *
INTO #v_raw
FROM OPENQUERY([CELLTRAK],
'SELECT 
  CAST(AF.LOCATION AS VARCHAR(150)) AS LOCATION,
  CONCAT(CAST(PD.PATIENT_FIRST_NAME AS VARCHAR(150)), '' '', CAST(PD.PATIENT_LAST_NAME AS VARCHAR(150))) AS PATIENT_NAME,
  CONCAT(CAST(SD.STAFF_FIRST_NAME AS VARCHAR(150)), '' '', CAST(SD.STAFF_LAST_NAME AS VARCHAR(150))) AS STAFF_NAME,
  CAST(AD.ACTIVITY_ID AS VARCHAR(50)) AS ACTIVITY_ID,
  CAST(AD.ACTIVITY_TYPE AS VARCHAR(50)) AS ACTIVITY_TYPE,
  CAST(AD.staff_id AS VARCHAR(50)) AS staff_id,
  CAST(AD.patient_id AS VARCHAR(50)) AS patient_id,
  CAST(AD.status AS VARCHAR(50)) AS status,
  CAST(AD.scheduled_start_date AS VARCHAR(50)) AS scheduled_start_date,
  CAST(AD.scheduled_start_time AS VARCHAR(50)) AS scheduled_start_time,
  CAST(AD.scheduled_end_date   AS VARCHAR(50)) AS scheduled_end_date,
  CAST(AD.scheduled_end_time   AS VARCHAR(50)) AS scheduled_end_time,
  CAST(AD.ACTIVITY_START_DATE  AS VARCHAR(50)) AS ACTIVITY_START_DATE,
  CAST(AD.ACTIVITY_START_TIME  AS VARCHAR(50)) AS ACTIVITY_START_TIME,
  CAST(AD.ACTIVITY_END_DATE    AS VARCHAR(50)) AS ACTIVITY_END_DATE,
  CAST(AD.ACTIVITY_END_TIME    AS VARCHAR(50)) AS ACTIVITY_END_TIME,
  CAST(AD.duration             AS VARCHAR(50)) AS duration,
  CAST(AD.SCHEDULED_VARIANCE   AS VARCHAR(50)) AS SCHEDULED_VARIANCE,
  CAST(AD.PUNCTUALITY          AS VARCHAR(50)) AS PUNCTUALITY
FROM CTVIEW_STD.ACTIVITY_DETAILS AD
JOIN CELLTRAK.CTVIEW_STD.STAFF_DETAILS   SD ON AD.staff_id   = SD.STAFF_ID
JOIN CELLTRAK.CTVIEW_STD.PATIENT_DETAILS PD ON AD.PATIENT_ID = PD.PATIENT_ID
LEFT JOIN CELLTRAK.CTVIEW_STD.ACTIVITY_FILTERS AF ON AD.ACTIVITY_ID = AF.ACTIVITY_ID 
WHERE AD.scheduled_start_date BETWEEN DATEADD(''day'', -28, CURRENT_DATE()) AND DATEADD(''day'', -21, CURRENT_DATE())');

-- Exceptions (raw)
SELECT *
INTO #ex_raw
FROM OPENQUERY([CELLTRAK],
'SELECT 
  CAST(CASE 
        WHEN FR.CHOICE_VALUE = ''CAN'' THEN ''Late Cancellation''
        WHEN FR.CHOICE_VALUE = ''DEC'' THEN ''Client Declined''
        WHEN FR.CHOICE_VALUE = ''NAH'' THEN ''No Response''
        ELSE ''Other-'' || FR.CHOICE_VALUE 
      END AS VARCHAR(255)) AS Exception_Description,
  CAST(AD.activity_id AS VARCHAR(50)) AS activity_id,
  CAST(AD.staff_id    AS VARCHAR(50)) AS staff_id,
  CAST(AD.patient_id  AS VARCHAR(50)) AS patient_id,
  CAST(AD.status      AS VARCHAR(50)) AS status,
  CAST(AD.closed_status AS VARCHAR(50)) AS closed_status,
  CAST(AD.scheduled_start_date AS VARCHAR(50)) AS scheduled_start_date,
  CAST(AD.scheduled_start_time AS VARCHAR(50)) AS scheduled_start_time,
  CAST(AD.scheduled_end_date   AS VARCHAR(50)) AS scheduled_end_date,
  CAST(AD.scheduled_end_time   AS VARCHAR(50)) AS scheduled_end_time,
  CAST(AD.scheduled_duration   AS VARCHAR(50)) AS scheduled_duration,
  CAST(AD.activity_start_date  AS VARCHAR(50)) AS activity_start_date,
  CAST(AD.activity_start_time  AS VARCHAR(50)) AS activity_start_time,
  CAST(AD.ACTIVITY_END_DATE    AS VARCHAR(50)) AS ACTIVITY_END_DATE,
  CAST(AD.activity_end_time    AS VARCHAR(50)) AS activity_end_time
FROM CTVIEW_STD.ACTIVITY_DETAILS AD
JOIN CTVIEW_STD.FORM_RESPONSES FR 
  ON AD.ACTIVITY_ID = FR.ACTIVITY_ID
 AND FR.SECTION_NAME = ''Client Visit Exception''
 AND FR.FIELD_LABEL  = ''Visit Variation''
WHERE AD.ASSUMED_START_DATE BETWEEN DATEADD(''day'', -28, CURRENT_DATE()) AND DATEADD(''day'', -21, CURRENT_DATE())
  AND AD.STATUS <> ''FINISHED''');

-- Missed visits (no actual start)
SELECT *
INTO #miss_raw
FROM OPENQUERY([CELLTRAK],
'SELECT CAST(AD.ACTIVITY_ID AS VARCHAR(50)) as ACTIVITY_ID
 FROM CELLTRAK.CTVIEW_STD.ACTIVITY_DETAILS AD
 WHERE AD.ACTIVITY_START_DATE is null
   AND AD.scheduled_start_date BETWEEN DATEADD(''day'', -28, CURRENT_DATE()) AND DATEADD(''day'', -21, CURRENT_DATE())');

-- Light indexes for join/group keys
CREATE CLUSTERED INDEX IX_vraw_act ON #v_raw (ACTIVITY_ID);
CREATE NONCLUSTERED INDEX IX_vraw_staff ON #v_raw (staff_id, LOCATION, scheduled_start_date, scheduled_start_time);
CREATE NONCLUSTERED INDEX IX_vraw_patient ON #v_raw (patient_id, LOCATION);
CREATE CLUSTERED INDEX IX_exraw_act ON #ex_raw (activity_id);
CREATE CLUSTERED INDEX IX_miss_act  ON #miss_raw (ACTIVITY_ID);



/* =========================
   1) ENRICH ONCE (types, minutes, flags)
   ========================= */

DROP TABLE IF EXISTS #visits;

;WITH v AS (
  SELECT
    TRY_CAST(ACTIVITY_ID AS INT) AS ACTIVITY_ID,
    TRY_CAST(staff_id   AS INT)  AS staff_id,
    TRY_CAST(patient_id AS INT)  AS patient_id,
    LOCATION,
    PATIENT_NAME,
    STAFF_NAME,
    ACTIVITY_TYPE,
    status,
    TRY_CONVERT(datetime2(0), scheduled_start_date + ' ' + scheduled_start_time) AS scheduled_start_dtm,
    TRY_CONVERT(datetime2(0), scheduled_end_date   + ' ' + scheduled_end_time)   AS scheduled_end_dtm,
    TRY_CONVERT(datetime2(0), ACTIVITY_START_DATE  + ' ' + ACTIVITY_START_TIME)  AS activity_start_dtm,
    TRY_CONVERT(datetime2(0), ACTIVITY_END_DATE    + ' ' + ACTIVITY_END_TIME)    AS activity_end_dtm,
    TRY_CAST(SCHEDULED_VARIANCE AS INT)  AS scheduled_variance,
    TRY_CAST(PUNCTUALITY AS FLOAT)       AS punctuality
  FROM #v_raw
),
e AS (
  SELECT activity_id,
         MAX(CASE WHEN Exception_Description IN ('Late Cancellation','Client Declined','No Response')
                  THEN Exception_Description ELSE 'Other' END) AS exception_class
  FROM #ex_raw
  GROUP BY activity_id
),
m AS (SELECT ACTIVITY_ID FROM #miss_raw)
SELECT
  v.LOCATION,
  v.PATIENT_NAME,
  v.STAFF_NAME,
  v.ACTIVITY_ID,
  v.ACTIVITY_TYPE,
  v.staff_id,
  v.patient_id,
  v.status,
  v.scheduled_start_dtm,
  v.scheduled_end_dtm,
  v.activity_start_dtm,
  v.activity_end_dtm,
  v.scheduled_variance,
  v.punctuality,

  calc.scheduled_minutes,
  calc.actual_minutes,

  -- stable visit key
  CONCAT(CAST(v.patient_id AS varchar(20)),'_',
         CONVERT(varchar(19), v.scheduled_start_dtm, 120),'_',
         CONVERT(varchar(19), v.scheduled_end_dtm,   120)) AS VisitUniqueKey,

  -- core flags
  CASE WHEN e.activity_id IS NOT NULL THEN 1 ELSE 0 END AS is_exception,
  e.exception_class,
  CASE WHEN m.activity_id IS NOT NULL THEN 1 ELSE 0 END AS is_missed,
  CASE WHEN e.activity_id IS NULL AND m.activity_id IS NULL THEN 1 ELSE 0 END AS is_delivered,

  -- issues derived once
  CASE WHEN e.activity_id IS NULL AND m.activity_id IS NULL AND (v.punctuality < -30 OR v.punctuality > 30) THEN 1 ELSE 0 END AS is_early_late,
  CASE WHEN e.activity_id IS NULL AND m.activity_id IS NULL AND calc.actual_minutes IS NOT NULL AND calc.actual_minutes <= 5 THEN 1 ELSE 0 END AS is_le_5min,
  CASE WHEN e.activity_id IS NULL AND m.activity_id IS NULL AND calc.actual_minutes IS NOT NULL AND calc.scheduled_minutes IS NOT NULL
            AND calc.actual_minutes < 0.6 * calc.scheduled_minutes THEN 1 ELSE 0 END AS is_lt_60pct
INTO #visits
FROM v
LEFT JOIN e ON v.ACTIVITY_ID = e.activity_id
LEFT JOIN m ON v.ACTIVITY_ID = m.activity_id
CROSS APPLY (
  SELECT
    DATEDIFF(MINUTE, v.scheduled_start_dtm, v.scheduled_end_dtm) AS scheduled_minutes,
    CASE WHEN v.activity_start_dtm IS NULL OR v.activity_end_dtm IS NULL
         THEN NULL
         ELSE DATEDIFF(MINUTE, v.activity_start_dtm, v.activity_end_dtm)
    END AS actual_minutes
) calc;

-- indexes for downstream grouping & joins
CREATE CLUSTERED INDEX IX_visits_vk       ON #visits (VisitUniqueKey, staff_id);
CREATE NONCLUSTERED INDEX IX_visits_staff  ON #visits (staff_id, LOCATION, scheduled_start_dtm);
CREATE NONCLUSTERED INDEX IX_visits_patient ON #visits (patient_id, LOCATION);
CREATE NONCLUSTERED INDEX IX_visits_loc     ON #visits (LOCATION);



/* =========================
   2) SHARED PRE-AGG TABLES (double-ups, adjacency)
   ========================= */

-- Double-up stats per VisitUniqueKey
DROP TABLE IF EXISTS #visit_dups;

SELECT
  VisitUniqueKey,
  COUNT(DISTINCT staff_id) AS staff_cnt,
  COUNT(activity_start_dtm) AS start_cnt,
  DATEDIFF(MINUTE, MIN(activity_start_dtm), MAX(activity_start_dtm)) AS start_span_min
INTO #visit_dups
FROM #visits
GROUP BY VisitUniqueKey;

CREATE CLUSTERED INDEX IX_visit_dups ON #visit_dups (VisitUniqueKey);

-- Per staff/location: back-to-back (actual gap < 5) and scheduled clashes
DROP TABLE IF EXISTS #staff_timefacts;

WITH x AS (
  SELECT
    staff_id, LOCATION,
    scheduled_start_dtm, scheduled_end_dtm,
    activity_start_dtm, activity_end_dtm,
    LAG(activity_end_dtm)  OVER (PARTITION BY staff_id, LOCATION ORDER BY activity_start_dtm)  AS prev_actual_end,
    LAG(scheduled_end_dtm) OVER (PARTITION BY staff_id, LOCATION ORDER BY scheduled_start_dtm) AS prev_sched_end
  FROM #visits
)
SELECT
  staff_id, LOCATION,
  SUM(CASE WHEN activity_start_dtm IS NOT NULL AND prev_actual_end IS NOT NULL
            AND DATEDIFF(MINUTE, prev_actual_end, activity_start_dtm) < 5 THEN 1 ELSE 0 END) AS back_to_back_cnt,
  SUM(CASE WHEN scheduled_start_dtm < prev_sched_end THEN 1 ELSE 0 END) AS scheduled_clash_cnt
INTO #staff_timefacts
FROM x
GROUP BY staff_id, LOCATION;

CREATE CLUSTERED INDEX IX_staff_timefacts ON #staff_timefacts (staff_id, LOCATION);



/* =========================
   3) STAFF SUMMARY
   ========================= */

DROP TABLE IF EXISTS tbl_QDSStoredStaffSummary;

WITH base AS (
  SELECT
    LOCATION, staff_id,
    MAX(STAFF_NAME)                        AS staff_name,
    COUNT(*)                               AS planned_visits,
    SUM(scheduled_minutes)                 AS planned_minutes,

    SUM(CASE WHEN is_exception=1 AND is_missed=0 AND exception_class IN ('Late Cancellation','Client Declined') THEN 1 ELSE 0 END) AS exc_decline_cancel,
    SUM(CASE WHEN is_exception=1 AND is_missed=0 AND exception_class='No Response' THEN 1 ELSE 0 END)                               AS exc_no_reply,

    SUM(CASE WHEN is_delivered=1 THEN 1 ELSE 0 END)                                                                                AS delivered_visits,
    SUM(CASE WHEN is_delivered=1 THEN actual_minutes END)                                                                           AS delivered_minutes,
    SUM(CASE WHEN is_delivered=1 THEN scheduled_minutes END)                                                                        AS delivered_sched_minutes,
    AVG(CASE WHEN is_delivered=1 THEN PUNCTUALITY END)                                                                              AS delivered_avg_punct,

    SUM(CASE WHEN is_delivered=1 AND actual_minutes <= 5 THEN 1 ELSE 0 END)                                                         AS issues_le_5,
    SUM(CASE WHEN is_delivered=1 AND (scheduled_minutes - actual_minutes) > 30 THEN 1 ELSE 0 END)                                   AS issues_long_duration,
    SUM(CASE WHEN is_missed=1 AND is_exception=0 THEN 1 ELSE 0 END)                                                                 AS issues_missed,
    SUM(CASE WHEN is_delivered=1 AND is_lt_60pct=1 THEN 1 ELSE 0 END)                                                               AS issues_lt_60pct,
    SUM(CASE WHEN is_delivered=1 AND is_early_late=1 THEN 1 ELSE 0 END)                                                             AS issues_early_late
  FROM #visits
  GROUP BY LOCATION, staff_id
),
doubleups AS (
  SELECT v.staff_id, v.LOCATION, COUNT(DISTINCT v.VisitUniqueKey) AS double_up_visits
  FROM #visits v
  JOIN #visit_dups d ON d.VisitUniqueKey = v.VisitUniqueKey
  WHERE d.staff_cnt > 1
  GROUP BY v.staff_id, v.LOCATION
),
diff5 AS (
  SELECT v.staff_id, v.LOCATION, COUNT(DISTINCT v.VisitUniqueKey) AS gt5min_between_carers
  FROM #visits v
  JOIN #visit_dups d ON d.VisitUniqueKey = v.VisitUniqueKey
  WHERE d.staff_cnt > 1 AND (d.start_cnt < d.staff_cnt OR d.start_span_min > 5)
  GROUP BY v.staff_id, v.LOCATION
)
SELECT
  b.LOCATION                                      AS [Location],
  b.staff_id                                      AS [Carer ID],
  b.staff_name                                    AS [Carer Name],

  ROUND(
    CASE WHEN (b.planned_visits - (b.exc_decline_cancel + b.exc_no_reply)) = 0 THEN 0
         ELSE (b.planned_visits - (b.exc_decline_cancel + b.exc_no_reply + b.issues_missed)) * 1.0
              / (b.planned_visits - (b.exc_decline_cancel + b.exc_no_reply))
    END, 2) AS [Compliance - (Planned - Exceptions - Missed) / (Planned - Exceptions) Percentage],

  b.planned_visits                                 AS [Planned - Visits],
  CONCAT(b.planned_minutes/60, ':', RIGHT('0' + CONVERT(varchar(2), b.planned_minutes%60), 2))       AS [Planned - Duration (hh:mm)],

  b.exc_decline_cancel                              AS [Exceptions - Client Declined / Late Cancellation],
  b.exc_no_reply                                    AS [Exceptions - No reply],
  CASE WHEN b.planned_visits=0 THEN 0 ELSE (b.exc_decline_cancel + b.exc_no_reply)*1.0/b.planned_visits END AS [Exceptions - Percentage],

  b.delivered_visits                                AS [Delivered - Visits],
  CASE WHEN b.planned_visits=0 THEN 0 ELSE b.delivered_visits*1.0/b.planned_visits END                 AS [Delivered - Visits Percentage],
  CONCAT(b.delivered_minutes/60, ':', RIGHT('0' + CONVERT(varchar(2), b.delivered_minutes%60), 2))      AS [Delivered - Duration (hh:mm)],
  CASE WHEN b.delivered_sched_minutes=0 THEN 0 ELSE b.delivered_minutes*1.0/b.delivered_sched_minutes END AS [Delivered - Duration Percentage],

  (CASE WHEN b.delivered_avg_punct IS NULL THEN '00:00'
        ELSE (CASE WHEN CAST(b.delivered_avg_punct AS INT) < 0 THEN '-' ELSE '' END) +
             RIGHT('0' + CAST(ABS(CAST(b.delivered_avg_punct AS INT))/60 AS varchar(2)),2) + ':' +
             RIGHT('0' + CAST(ABS(CAST(b.delivered_avg_punct AS INT))%60 AS varchar(2)),2)
   END)                                             AS [Delivered - Average Punctuality (hh:mm)],

  b.issues_le_5                                     AS [Issues - Visits Less Than 5 mins],
  b.issues_long_duration                            AS [Issues - Long Duration (Actual more than 30 minutes over planned)],
  b.issues_missed                                   AS [Issues - Missed Visits],
  b.issues_lt_60pct                                 AS [Issues - Visits Actual Less Than 60% Of Planned],
  ISNULL(d.double_up_visits,0)                      AS [Double Up Visits],
  b.issues_early_late                               AS [Issues - Early / Late Visits],
  ISNULL(df.gt5min_between_carers,0)                AS [Issues - Logged in more than 5 mins difference Between Carers],
  ISNULL(t.back_to_back_cnt,0)                      AS [Issues - Back to Back Visits],
  ISNULL(t.scheduled_clash_cnt,0)                   AS [Issues - Clashing Visits],

  -- 7+ consecutive days working (per staff/location)
  (SELECT COUNT(*) FROM (
     SELECT MIN(work_date) AS seq_start, COUNT(*) AS ct
     FROM (
       SELECT DISTINCT CONVERT(date, v2.scheduled_start_dtm) AS work_date,
              DATEADD(day, -ROW_NUMBER() OVER (ORDER BY CONVERT(date, v2.scheduled_start_dtm)), CONVERT(date, v2.scheduled_start_dtm)) grp
       FROM #visits v2
       WHERE v2.staff_id = b.staff_id AND v2.LOCATION = b.LOCATION AND v2.is_missed = 0
     ) q GROUP BY grp HAVING COUNT(*) >= 7
   ) z)                                             AS [Issues - Instances of working 7 or more days]
INTO tbl_QDSStoredStaffSummary
FROM base b
LEFT JOIN doubleups d           ON d.staff_id = b.staff_id AND d.LOCATION = b.LOCATION
LEFT JOIN diff5     df          ON df.staff_id = b.staff_id AND df.LOCATION = b.LOCATION
LEFT JOIN #staff_timefacts t    ON t.staff_id = b.staff_id AND t.LOCATION = b.LOCATION;



/* =========================
   4) CLIENT SUMMARY
   ========================= */

DROP TABLE IF EXISTS tbl_QDSStoredClientSummary;

WITH base AS (
  SELECT
    LOCATION, patient_id,
    MAX(PATIENT_NAME)                      AS patient_name,
    COUNT(*)                               AS planned_visits,
    SUM(scheduled_minutes)                 AS planned_minutes,

    SUM(CASE WHEN is_exception=1 AND is_missed=0 AND exception_class IN ('Late Cancellation','Client Declined') THEN 1 ELSE 0 END) AS exc_decline_cancel,
    SUM(CASE WHEN is_exception=1 AND is_missed=0 AND exception_class='No Response' THEN 1 ELSE 0 END)                                AS exc_no_reply,

    SUM(CASE WHEN is_delivered=1 THEN 1 ELSE 0 END)                                                                                AS delivered_visits,
    SUM(CASE WHEN is_delivered=1 THEN actual_minutes END)                                                                           AS delivered_minutes,
    SUM(CASE WHEN is_delivered=1 THEN scheduled_minutes END)                                                                        AS delivered_sched_minutes,
    AVG(CASE WHEN is_delivered=1 THEN PUNCTUALITY END)                                                                              AS delivered_avg_punct,

    SUM(CASE WHEN is_delivered=1 AND actual_minutes <= 5 THEN 1 ELSE 0 END)                                                         AS issues_lt5,
    SUM(CASE WHEN is_delivered=1 AND (scheduled_minutes - actual_minutes) > 30 THEN 1 ELSE 0 END)                                   AS issues_long,
    SUM(CASE WHEN is_missed=1 THEN 1 ELSE 0 END)                                                                                    AS issues_missed,
    SUM(CASE WHEN is_delivered=1 AND is_lt_60pct=1 THEN 1 ELSE 0 END)                                                               AS issues_lt60,
    SUM(CASE WHEN is_delivered=1 AND is_early_late=1 THEN 1 ELSE 0 END)                                                             AS issues_early_late
  FROM #visits
  GROUP BY LOCATION, patient_id
),
doubleups AS (
  SELECT v.patient_id, v.LOCATION, COUNT(DISTINCT v.VisitUniqueKey) AS double_up_visits
  FROM #visits v
  JOIN #visit_dups d ON d.VisitUniqueKey = v.VisitUniqueKey
  WHERE d.staff_cnt > 1
  GROUP BY v.patient_id, v.LOCATION
)
SELECT
  b.LOCATION                         AS [Location],
  b.patient_id                       AS [Customer ID],
  b.patient_name                     AS [Customer Name],

  ROUND(
    CASE WHEN (b.planned_visits - (b.exc_decline_cancel + b.exc_no_reply)) = 0 THEN 0
         ELSE (b.planned_visits - (b.exc_decline_cancel + b.exc_no_reply + b.issues_missed)) * 1.0
              / (b.planned_visits - (b.exc_decline_cancel + b.exc_no_reply))
    END, 2)                          AS [Compliance - (Planned - Exceptions - Missed) / (Planned - Exceptions) Percentage],

  b.planned_visits                   AS [Planned - Visits],
  CONCAT(b.planned_minutes/60, ':', RIGHT('0' + CONVERT(varchar(2), b.planned_minutes%60), 2))         AS [Planned - Duration (hh:mm)],

  b.exc_decline_cancel               AS [Exceptions - Client Declined / Late Cancellation],
  b.exc_no_reply                     AS [Exceptions - No reply],
  CASE WHEN b.planned_visits=0 THEN 0 ELSE (b.exc_decline_cancel + b.exc_no_reply)*1.0/b.planned_visits END AS [Exceptions - Percentage],

  b.delivered_visits                 AS [Delivered - Visits],
  CASE WHEN b.planned_visits=0 THEN 0 ELSE b.delivered_visits*1.0/b.planned_visits END                 AS [Delivered - Visits Percentage],
  CONCAT(b.delivered_minutes/60, ':', RIGHT('0' + CONVERT(varchar(2), b.delivered_minutes%60), 2))      AS [Delivered - Duration (hh:mm)],
  CASE WHEN b.delivered_sched_minutes=0 THEN 0 ELSE b.delivered_minutes*1.0/b.delivered_sched_minutes END AS [Delivered - Duration Percentage],

  (CASE WHEN b.delivered_avg_punct IS NULL THEN '00:00'
        ELSE (CASE WHEN CAST(b.delivered_avg_punct AS INT) < 0 THEN '-' ELSE '' END) +
             RIGHT('0' + CAST(ABS(CAST(b.delivered_avg_punct AS INT))/60 AS varchar(2)),2) + ':' +
             RIGHT('0' + CAST(ABS(CAST(b.delivered_avg_punct AS INT))%60 AS varchar(2)),2)
   END)                              AS [Delivered - Average Punctuality],

  b.issues_lt5                       AS [Issues - Visits Less Than 5 mins],
  b.issues_long                      AS [Issues - Long Duration (Actual more than 30 minutes over planned)],
  b.issues_missed                    AS [Issues - Missed Visits],
  b.issues_lt60                      AS [Issues - Visits Actual Less Than 60% Of Planned],
  ISNULL(d.double_up_visits,0)       AS [Double Up Visits],
  b.issues_early_late                AS [Issues - Early / Late Visits]
INTO tbl_QDSStoredClientSummary
FROM base b
LEFT JOIN doubleups d ON d.patient_id=b.patient_id AND d.LOCATION=b.LOCATION;



/* =========================
   5) OVERALL SUMMARY
   ========================= */

DROP TABLE IF EXISTS tbl_QDSStoredOverallSummary;

WITH base AS (
  SELECT
    LOCATION,
    COUNT(*)                                                 AS visits,
    SUM(scheduled_minutes)                                   AS planned_minutes,

    SUM(CASE WHEN is_delivered=1 THEN 1 ELSE 0 END)          AS completed_visits,
    SUM(CASE WHEN is_delivered=1 THEN actual_minutes END)     AS completed_minutes,

    SUM(CASE WHEN is_missed=1 THEN 1 ELSE 0 END)             AS missed_visits,
    SUM(CASE WHEN is_missed=1 THEN scheduled_minutes END)    AS missed_minutes,

    SUM(CASE WHEN is_exception=1 THEN 1 ELSE 0 END)          AS exception_visits,
    AVG(punctuality)                                         AS avg_punct,

    -- punctuality buckets over delivered
    SUM(CASE WHEN is_delivered=1 AND ABS(punctuality) <= 15 THEN 1 ELSE 0 END)                                                            AS w15_cnt,
    SUM(CASE WHEN is_delivered=1 AND ((punctuality BETWEEN -30 AND -16) OR (punctuality BETWEEN 16 AND 30)) THEN 1 ELSE 0 END)           AS w30_cnt,
    SUM(CASE WHEN is_delivered=1 AND ((punctuality BETWEEN -60 AND -31) OR (punctuality BETWEEN 31 AND 60)) THEN 1 ELSE 0 END)           AS w60_cnt,
    SUM(CASE WHEN is_delivered=1 AND (punctuality < -60 OR punctuality > 60) THEN 1 ELSE 0 END)                                          AS g60_cnt,
    SUM(CASE WHEN is_delivered=1 AND actual_minutes < 5 THEN 1 ELSE 0 END)                                                               AS lt5_cnt,

    SUM(CAST(actual_minutes AS float))                                                             AS sum_actual_all,        -- for % Duration Delivered
    SUM(CAST(scheduled_minutes AS float))                                                          AS sum_sched_all,
    SUM(CASE WHEN is_missed=0 THEN CAST(actual_minutes AS float) END)                              AS sum_actual_excl_missed,
    SUM(CASE WHEN is_missed=0 THEN CAST(scheduled_minutes AS float) END)                           AS sum_sched_excl_missed
  FROM #visits
  GROUP BY LOCATION
)
SELECT
  LOCATION                                               AS [Location],
  visits                                                 AS [Visits],
  CONCAT(planned_minutes/60, ':', RIGHT('0' + CONVERT(varchar(2), planned_minutes%60),2)) AS [Planned Duration],

  completed_visits                                       AS [Completed Visits],
  CONCAT(completed_minutes/60, ':', RIGHT('0' + CONVERT(varchar(2), completed_minutes%60),2))       AS [Completed Duration],

  missed_visits                                          AS [Missed Visits],
  CONCAT(missed_minutes/60, ':', RIGHT('0' + CONVERT(varchar(2), missed_minutes%60),2))             AS [Missed Visits Duration],

  CASE WHEN visits=0 THEN 0 ELSE completed_visits*1.0/visits END                                   AS [% Completed via CellTrak],
  CASE WHEN visits=0 THEN 0 ELSE missed_visits*1.0/visits END                                      AS [% Missed Visits],
  CASE WHEN visits=0 THEN 0 ELSE exception_visits*1.0/visits END                                   AS [% No Delivery (Exceptions)],

  CASE WHEN NULLIF(sum_sched_all,0) IS NULL THEN 0 ELSE sum_actual_all / sum_sched_all END          AS [% Duration Delivered],
  CASE WHEN NULLIF(sum_sched_excl_missed,0) IS NULL THEN 0 ELSE sum_actual_excl_missed / sum_sched_excl_missed END AS [% Duration Delivered (Excluding Missed Visits)],

  CASE WHEN visits=0 THEN 0 ELSE lt5_cnt*1.0/visits END                                             AS [% Visits < 5 mins],

  (CASE WHEN avg_punct IS NULL THEN '00:00'
        ELSE (CASE WHEN CAST(avg_punct AS INT) < 0 THEN '-' ELSE '' END) +
             RIGHT('0' + CAST(ABS(CAST(avg_punct AS INT))/60 AS varchar(2)),2) + ':' +
             RIGHT('0' + CAST(ABS(CAST(avg_punct AS INT))%60 AS varchar(2)),2)
   END)                                                                                            AS [Average Punctuality],

  -- punctuality distributions over delivered visits
  w15_cnt AS [Delivered within 15 +/- minutes of Start - Count],
  CASE WHEN NULLIF(completed_visits,0) IS NULL THEN 0 ELSE w15_cnt*1.0/completed_visits END       AS [Delivered within 15 +/- minutes of Start- % of completed visits],

  w30_cnt AS [Delivered within 15 to 30 +/- minutes of Start - Count],
  CASE WHEN NULLIF(completed_visits,0) IS NULL THEN 0 ELSE w30_cnt*1.0/completed_visits END       AS [Delivered within 15 to 30 +/- minutes of Start - % of completed visits],

  w60_cnt AS [Delivered within 30 to 60 +/- minutes of Start - Count],
  CASE WHEN NULLIF(completed_visits,0) IS NULL THEN 0 ELSE w60_cnt*1.0/completed_visits END       AS [Delivered within 30 to 60 +/- minutes of Start - % of completed visits],

  g60_cnt AS [Delivered greater than 60 +/- minutes of Start - Count],
  CASE WHEN NULLIF(completed_visits,0) IS NULL THEN 0 ELSE g60_cnt*1.0/completed_visits END       AS [Delivered greater than 60 +/- minutes of Start - % of completed visits]
INTO tbl_QDSStoredOverallSummary
FROM base;



/* =========================
   6) CLEANUP
   ========================= */

DROP TABLE IF EXISTS #visit_dups;
DROP TABLE IF EXISTS #staff_timefacts;
DROP TABLE IF EXISTS #visits;
DROP TABLE IF EXISTS #v_raw;
DROP TABLE IF EXISTS #ex_raw;
DROP TABLE IF EXISTS #miss_raw;

SET NOCOUNT OFF;
