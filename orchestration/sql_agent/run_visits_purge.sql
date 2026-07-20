/*
Purpose:
    SQL Agent job step for weekly Visits retention maintenance.

Recommended schedule:
    Weekly, outside the update new db daily-refresh window.
*/

USE [DOM_LIVE];
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;

EXEC dbo.usp_Purge_Visits_Expired
    @RetentionYears   = 3,
    @BatchSize        = 10000,
    @LockTimeoutMs    = 600000,
    @UseAppLock       = 1,
    @EmitInfo         = 0,
    @ReturnSummaryRow = 1;
GO
