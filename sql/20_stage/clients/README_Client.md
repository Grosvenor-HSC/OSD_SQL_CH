# Clients sync (stage) — Initial + Incremental

Location:
- `sql/20_stage/clients/Clients_Initial.sql`
- `sql/20_stage/clients/Clients_Incremental.sql`

These two procedures build and maintain `dbo.tbl_Clients` as the **staging baseline** for all downstream reporting and transforms.

---

## What the Initial does (`dbo.usp_Sync_Clients_Initial`)

### Goal
Create a **clean, deterministic baseline** of all clients by **dropping and recreating** `dbo.tbl_Clients`, then bulk-loading from the care system source tables.

### Inputs (source)
- `dbo.CLIENT` (core client record)
- `dbo.CONTACT_DT` + `dbo.CONTACT_HD` (addresses / names / contact details)
- `dbo.CHSYSDEC` (decode lookups for things like title, care group, disability, etc.)
- `dbo.tbl_Branch` (already staged from the Branch initial)

### Output (target)
- `dbo.tbl_Clients`

### Key behaviours
- **Exclusive applock** (`DOM_LIVE:Sync:Clients`)
  - Prevents overlapping runs (initial vs incremental).
- **Change Tracking fence at START**
  - Captures `BaselineFrom = CHANGE_TRACKING_CURRENT_VERSION()` at the beginning.
  - Stores it into `dbo.CT_Watermark` for the `Clients` process.
  - This gives the incremental a clean “start point” for “top-off”.
- **Hard reset of the target**
  - Drops `dbo.tbl_Clients` even if it exists as a view/synonym/table, then recreates it.
  - Uses dynamic SQL to avoid “stale metadata” binding issues.
- **Bulk insert**
  - Inserts using `TABLOCK` for speed and minimal logging where possible.
- **Indexes after load**
  - Adds the PK and supporting indexes after loading to keep the insert fast.
- **(Optional) enable CT on target**
  - Not strictly required for the sync logic (we read CT from sources), but keeps things consistent with your newer pattern set.

### Branch mapping logic (important)
The branch is assigned using:
1. A special “Portsmouth vs Southampton” override for `GS_REF = 1970000043` based on location description.
2. Otherwise, fall back to matching `tbl_Branch.Old_Branch_UUID = TRY_CONVERT(int, CLIENT.GS_REF)`.

This is deliberately done to preserve the “Portsmouth is a derived branch” behaviour you baked into Branch initial.

---

## What the Incremental does (`dbo.usp_Sync_Clients_Incremental`)

### Goal
Apply **only the client rows that changed** since the last sync:
- Inserts (new clients)
- Updates (existing clients)
- Deletes (clients removed from source)

### Inputs
Same sources as Initial, plus:
- `dbo.CT_Watermark` (stores `LastSyncVersion` per process)

### Output
- Updates `dbo.tbl_Clients`
- Advances watermark in `dbo.CT_Watermark`

### Key behaviours
- **Exclusive applock**
  - Same lock as Initial so only one sync can run at a time.
- **CT window fenced at START**
  - Reads:
    - `@LastSyncVersion` from `CT_Watermark`
    - `@ToVersion = CHANGE_TRACKING_CURRENT_VERSION()` at the start
  - All change detection happens inside `[LastSyncVersion, ToVersion]`.
- **Retention safety check**
  - Computes `CHANGE_TRACKING_MIN_VALID_VERSION(...)` across CT-enabled tables.
  - If watermark is too old, the procedure refuses (or can auto-run initial if enabled).
- **Changed-set driven**
  - Builds a list of `ClientRef` values that changed from:
    - `CLIENT` CT
    - plus `CONTACT_DT`, `CONTACT_HD`, `CHSYSDEC` *if CT is enabled on those tables*
  - If CT isn’t enabled on a referenced table, those changes won’t trigger updates (and that’s intentional/explicit).
- **Chunked MERGE**
  - Processes `#Changed` in chunks (`@ChunkSize`) to control locking/log pressure.
  - Uses an action log table for accurate inserted/updated counts.
- **Deletes**
  - Applies deletes where CT reports `CLIENT` deletions.
- **Watermark only advances at the end**
  - If the proc fails mid-run, the watermark isn’t advanced, so the next run retries safely.

---

## Why they’re structured this way (the “design intent”)

### 1) Deterministic baseline + safe incremental “top-off”
The initial sets a CT watermark at the **start**, not the end. That matters:
- You get a stable baseline snapshot point.
- Any changes happening during the long baseline load will be picked up by the incremental afterwards.

### 2) No reliance on timestamps
Many of these systems have unreliable “last updated” timestamps or no usable audit columns.
Change Tracking gives you a solid, low-maintenance delta mechanism.

### 3) Concurrency control
The applock prevents two bad outcomes:
- Incremental trying to MERGE into a table being dropped/recreated.
- Two incrementals racing and corrupting your watermark.

### 4) Performance: build fast, index later
Baseline loads are faster when:
- table is a heap at insert time (or has minimal indexes)
- indexes are created after the load

### 5) Explicit handling of the “Portsmouth” branch anomaly
The branch naming override exists because your branch staging creates a derived “Portsmouth” record from Southampton.
If client branch assignment doesn’t replicate that logic, you end up with “missing Branch_UUID” clients.

---

## Operational notes / gotchas

- **Run with SQLCMD mode OFF.**
  Errors like “Could not find stored procedure 'CLIENT_REF'” are usually from executing a mangled batch, not from the stored proc logic.
- **If CT isn’t enabled on CONTACT_* or CHSYSDEC**
  then changes to addresses/decodes won’t trigger client refreshes until CLIENT itself changes.
- **If CT retention window is exceeded**
  incremental must be re-baselined (or run with auto-initial enabled if you choose that behaviour).

---

## Quick usage

Initial (and capture summary):
```sql
DECLARE @s nvarchar(4000);
EXEC dbo.usp_Sync_Clients_Initial @Summary=@s OUTPUT;
SELECT @s AS Summary;
