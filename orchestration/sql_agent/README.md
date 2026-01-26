# Orchestration

## How these scripts run
`run_initial.sql` = one-time backfill order  
`run_daily.sql`   = normal daily order

Both scripts use SQLCMD `:r` includes.

### Running in SSMS
SSMS → Query → **SQLCMD Mode** → Execute

### Running via SQL Agent
Option A (simple): CmdExec step using `sqlcmd`  
Option B (cleaner): convert key scripts into stored procedures and call them in T-SQL job steps
