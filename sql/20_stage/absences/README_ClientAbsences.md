# Client Absences (Stage) — Initial + Incremental

Folder: `sql/20_stage/absences`  
Objects:
- `dbo.usp_Sync_ClientAbsences_Initial`
- `dbo.usp_Sync_ClientAbsences_Incremental`
- Target table: `dbo.tbl_ClientAbsences`
- Watermark table: `dbo.CT_Watermark` (shared pattern across sync processes)

## What this loads

This stage loads **client absence events** from the source table(s):

- Source fact table: `dbo.INACTIVE_DY`
  - Key: `INACT_REF` (INT)
  - Client key: `CLIENT_REF` (INT)
  - Reason decode: `REASON` → `dbo.CHSYSDEC.DECODE_REF`

It writes to the staging table:

- `dbo.tbl_ClientAbsences`
  - `UUID` (INT) = `INACTIVE_DY.INACT_REF`
  - `Client_UUID` (INT) = `INACTIVE_DY.CLIENT_REF`
  - Reason text from `CHSYSDEC.DESCRIPTION`
  - Start/End as dates
  - `CreatedAtUTC`, `UpdatedAtUTC`

This dataset is used downstream by compliance/utilisation/reporting logic, so it must be deterministic and easy to reason about.

---

## Initial (`usp_Sync_ClientAbsences_Initial`) — what it does

The Initial procedure is a **one-time baseline** that:
1. Acquires an application lock (`sp_getapplock`) to prevent concurrent runs.
2. Validates Change Tracking is enabled:
   - at the database level
   - on the key source table (`dbo.INACTIVE_DY`)
3. **Fences the Change Tracking window at the start** using `CHANGE_TRACKING_CURRENT_VERSION()`.
   - This value is stored as the process watermark so incrementals can safely “top off” any changes that occur during the baseline load.
4. Drops and recreates `dbo.tbl_ClientAbsences` as a heap for fast bulk-style insert.
5. Loads the entire dataset.
6. Adds PK + supporting indexes after load (faster than building indexes during the load).
7. Optionally runs the incremental procedure *quietly* immediately after the baseline to capture any changes that occurred during the initial run.

### Why it’s structured this way

- **CT fencing**: If you capture the CT version at the *end* of the baseline, you can miss changes that happened mid-load. Capturing at the *start* guarantees the incremental can cover the entire “baseline load window”.
- **Drop/recreate + post-indexing**: Fastest and cleanest for one-time backfill. The procedure is explicit that it is *not* safe to re-run in prod because it replaces history.
- **AppLock**: Prevents two job steps or manual runs from overlapping and corrupting the watermark or the staging table build.
- **Watermark seeding**: Keeps a consistent pattern across all sync processes and supports reruns of incrementals.

---

## Incremental (`usp_Sync_ClientAbsences_Incremental`) — what it does

The Incremental procedure is a **daily upsert** driven by SQL Server Change Tracking:

1. Optionally acquires an AppLock (configurable).
2. Validates Change Tracking prerequisites (DB + INACTIVE_DY).
3. Reads the last watermark from `dbo.CT_Watermark` and fences a new upper bound CT version (`@ToVersion`) at the start.
4. Validates watermark vs CT retention:
   - Uses `CHANGE_TRACKING_MIN_VALID_VERSION(object_id)` to detect when retention has pruned required versions.
   - If watermark < min valid, it fails fast: baseline re-run required.
5. Builds a changed key set `#Changed` using `CHANGETABLE(CHANGES ...)`:
   - Always includes changes on `INACTIVE_DY`
   - Optionally includes “reason text changed” rows if CT is enabled on `CHSYSDEC`
6. Processes keys in chunks:
   - For each chunk, it builds a “Base” dataset and `MERGE`s into `dbo.tbl_ClientAbsences`
   - Handles inserts, updates, and deletes deterministically for that chunk
7. Advances the watermark to `@ToVersion` only after successful completion.
8. Produces a one-line summary containing row counts + final watermark.

### Why it’s structured this way

- **Idempotent / rerunnable**: Running the same incremental again should produce the same state (MERGE + deterministic deletes).
- **Chunked merge**: Prevents huge transactions, reduces lock pressure, and keeps log growth manageable.
- **Upper bound fence (`@ToVersion`)**: Ensures the run has a stable “end of window”. New changes after the run starts are picked up next time.
- **Min valid check**: CT is retention-based. Without this guard you can silently miss changes after retention cleanup.
- **Optional CHSYSDEC tracking**: If reason text changes matter and CT is enabled on decode table, those changes are reflected; if not, the procedure warns/notes.

---

## Operational notes

- The Initial procedure must run after the Clients baseline, because it references `CLIENT_REF` and downstream expects clients to exist.
- Incremental must run after Clients incremental to avoid missing newly created client references.
- If CT retention is too short for the job frequency, watermark can fall behind; the min-valid check will force a re-baseline rather than silently drifting.
