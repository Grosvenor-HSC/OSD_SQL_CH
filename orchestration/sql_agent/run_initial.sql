-- ONE-TIME INITIAL LOAD
-- Run in SSMS with SQLCMD Mode enabled (Query > SQLCMD Mode)

-- Stage initial loads
:r sql\20_stage\branches\initial.sql
:r sql\20_stage\employees\initial.sql
:r sql\20_stage\clients\initial.sql
:r sql\20_stage\visits\initial.sql

-- Optional stage loads (if present/needed)
-- :r sql\20_stage\diaries\client_initial.sql
-- :r sql\20_stage\diaries\employees_initial.sql
-- :r sql\20_stage\absences\client_initial.sql
-- :r sql\20_stage\absences\employees_initial.sql

-- Core enrichment
:r sql\30_core\visits_distance\incremental.sql

-- Reporting builds
:r sql\40_reporting\qds\build_tbl_qds.sql
