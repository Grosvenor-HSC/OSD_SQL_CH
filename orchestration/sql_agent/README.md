# Orchestration

## How these scripts run
`run_initial.sql` = one-time backfill order  
`run_daily.sql`   = normal daily order
`run_visits_purge.sql` = scheduled retention maintenance for old Visits

The scripts call stored procedures already deployed to `DOM_LIVE`.

### Running in SSMS
SSMS → Query → **SQLCMD Mode** → Execute

### Running via SQL Agent
Option A (simple): CmdExec step using `sqlcmd`  
Option B (cleaner): convert key scripts into stored procedures and call them in T-SQL job steps

## Recommended job separation

- `update new db` runs `run_daily.sql` daily.
- A separate weekly job runs `run_visits_purge.sql`, outside the daily refresh window.
- The purge uses the same application lock as the Visits incremental process, so it waits rather than overlapping.
- `run_initial.sql` disables `update new db` while the initial load is running and leaves it disabled until manually re-enabled after validation.
