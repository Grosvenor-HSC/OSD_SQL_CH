-- DAILY REFRESH
-- Run in SSMS with SQLCMD Mode enabled (Query > SQLCMD Mode)

-- Stage incrementals
:r sql\20_stage\branches\incremental.sql
:r sql\20_stage\employees\incremental.sql
:r sql\20_stage\clients\incremental.sql
:r sql\20_stage\visits\incremental.sql

-- Optional incrementals (if present/needed)
-- :r sql\20_stage\diaries\client_incremental.sql
-- :r sql\20_stage\diaries\employees_incremental.sql
-- :r sql\20_stage\absences\client_incremental.sql
-- :r sql\20_stage\absences\employees_incremental.sql

-- Core enrichment
:r sql\30_core\visits_distance\incremental.sql

-- Reporting builds
:r sql\40_reporting\qds\build_tbl_qds.sql
