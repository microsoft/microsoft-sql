---
name: t-sql-upserts-merge
description: >-
  Writes an upsert for Azure SQL Database that is still correct when two sessions run it at the
  same moment, and refuses the MERGE shapes that lose rows. Use when asked to "insert or update",
  "insert if not exists", "add or update", "make this insert idempotent", "upsert", "write a
  MERGE", "sync a staging table into the target table", make a row-by-row load or import safe to
  run twice, or port ON CONFLICT DO UPDATE or ON DUPLICATE KEY UPDATE; and use when duplicate rows
  appear that nothing in the application created, or when error 2627, 2601, 8672, 10713 or a
  deadlock shows up under load. Covers why IF EXISTS then UPDATE ELSE INSERT is a race, what MERGE
  needs to be safe, which MERGE shapes to refuse outright, and the two patterns that are safe
  without MERGE. Key and index design belongs to design-azure-sql-schema, and general T-SQL
  dialect to t-sql-correctness.
---

# Write an upsert that survives concurrency, and refuse the dangerous MERGE

An upsert looks like a one-statement problem and is a concurrency problem. Both of the shapes a
model reaches for first, `IF EXISTS ... UPDATE ELSE INSERT` and a bare `MERGE`, are races. They
pass every single-session test and fail the first time two callers arrive together.

Measured on 2026-08-28 against a live engine reporting `EngineEdition` 5 and Edition `SQL Azure`.
Open [the measured runs](references/merge-hazards-and-concurrency.md) when a number below is
disputed, or before changing one.

## What the race actually costs

Eight sessions, twenty increments each, one hot key. A correct upsert ends at 160.

| Pattern | Result | Cost |
|---|---|---|
| `UPDATE` then `INSERT` when `@@ROWCOUNT = 0`, no hint | one session died on `Msg 2627`, final value **140** | 20 writes lost; the caller saw one error, not twenty |
| `MERGE` with no lock hint, 4 sessions | 2 of 4 raised `Msg 2627`, final value **2** of 4 | half the batch rolled back |
| `IF EXISTS` on a table with **no unique key**, 2 sessions | **2 rows for one key, no error at all** | silent duplicates, nothing in the log to find later |
| `MERGE WITH (HOLDLOCK)` on a unique key | 160, no failures, no deadlocks | correct |
| `UPDATE WITH (SERIALIZABLE)` then `INSERT` | 160, no failures | correct |
| `UPDATE`, then `INSERT` inside `TRY` catching 2627 | 160, no failures | correct |

The third row is the one to fear. The others raise an error someone can see. That one returns
success to both callers and leaves the table wrong.

## Why the naive shape is a race

```sql
-- WRONG. Two sessions can both take the ELSE branch.
IF EXISTS (SELECT 1 FROM dbo.counters WHERE k = @k)
    UPDATE dbo.counters SET n = n + 1 WHERE k = @k;
ELSE
    INSERT INTO dbo.counters (k, n) VALUES (@k, 1);
```

The `SELECT` takes a shared lock and releases it immediately, under every isolation level below
serializable, so there is a window between the test and the insert. `BEGIN TRAN` does not close
it: a transaction makes the pair atomic on failure without making the read block anyone.
Verified with a two second gap in the window, both sessions reported `INSERT branch`.

## Three upserts that hold

Each reached 160 of 160 under eight concurrent sessions.

**1. MERGE, when the statement genuinely needs more than one action.**

```sql
BEGIN TRAN;
MERGE dbo.counters WITH (HOLDLOCK) AS t
USING (SELECT @k AS k) AS s
    ON t.k = s.k
WHEN MATCHED THEN
    UPDATE SET t.n = t.n + 1
WHEN NOT MATCHED THEN
    INSERT (k, n) VALUES (s.k, 1);
COMMIT;
```

The hint goes on the target, before the alias. Two things make it safe and both are required.
`HOLDLOCK` is documented as a synonym for `SERIALIZABLE`, and it is what holds a range lock across
the match and the insert. **The unique index on the join key is what makes that range lock
narrow.** Without it the lock covers far more of the table: four concurrent sessions against a
table with no unique key produced `Msg 1205` deadlocks and rolled two of them back.

**2. UPDATE first, insert only if nothing was updated.** Fewer moving parts, and the better
choice when the row usually already exists.

```sql
BEGIN TRAN;
UPDATE dbo.counters WITH (SERIALIZABLE) SET n = n + 1 WHERE k = @k;
IF @@ROWCOUNT = 0
    INSERT INTO dbo.counters (k, n) VALUES (@k, 1);
COMMIT;
```

`SERIALIZABLE` on the `UPDATE` is not decoration. Without it this is the row that ended at 140.

**3. Catch the duplicate key and treat it as the update signal.** Best when the row usually does
not exist, because the common path takes no extra lock.

```sql
UPDATE dbo.counters SET n = n + 1 WHERE k = @k;
IF @@ROWCOUNT = 0
BEGIN
    BEGIN TRY
        INSERT INTO dbo.counters (k, n) VALUES (@k, 1);
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER() IN (2601, 2627)
            UPDATE dbo.counters SET n = n + 1 WHERE k = @k;
        ELSE
            THROW;
    END CATCH
END
```

All three still depend on a unique constraint or unique index on the key being upserted. **Without
one, none of them is safe**, because there is nothing for the range lock to hold and nothing to
raise 2627 against. Sizing that key is `design-azure-sql-schema`.

## When to refuse MERGE outright

Say no and write separate statements. Each is verified or documented, not folklore.

- **A partial batch with `WHEN NOT MATCHED BY SOURCE THEN DELETE`.** That clause belongs to a full
  reload, never to an upsert of whichever rows this request happens to carry. Verified: a target
  holding `A`, `B`, `C` and a source naming only `A` ended with one row and no error.
- **A source that can contain the same key twice.** `Msg 8672`, "The MERGE statement attempted to
  UPDATE or DELETE the same row more than once". Deduplicate the source first, with `GROUP BY` or
  a window function, rather than loosening the `ON` clause.
- **Any filter in the `ON` clause.** Documented: put only the columns being matched there.
  Verified: adding `AND t.qty > 100` to `ON` made an existing row look unmatched, so the
  `NOT MATCHED` branch fired and hit `Msg 2627` on the key that already existed. Row filters go in
  the `WHEN` clause or in a view or common table expression over the source.
- **A columnstore target.** Documented: avoid any form of columnstore index as a `MERGE` target,
  and instead stage, then delete and insert in batches.
- **High concurrency at scale.** Documented: at scale `MERGE` may introduce complicated
  concurrency issues, and separate statements can perform better with less blocking.
- **Literal values in a frequently executed statement.** Simple parameterization is not applied to
  `MERGE`, so literals compile a new plan every execution. Pass parameters through
  `sys.sp_executesql`. Building the statement by concatenation instead is `prevent-sql-injection`.

`MERGE` also requires a semicolon terminator, and omitting it is `Msg 10713` by number rather than
a generic syntax error.

## The indexed view question, stated honestly

A long standing warning says a `MERGE` can leave an indexed view inconsistent with its base
tables, and a routine consistency check will not report it. Half of that is current.

**The half that holds.** An integrity check performs only **physical** consistency checks on an
indexed view. The logical checks, which compare the materialized rows against the base tables, run
only under `EXTENDED_LOGICAL_CHECKS`. So a view that disagrees with its base tables is invisible to
a routine check, whatever put it there. Documented for Azure SQL Database today, and why this
defect class was ever severe.

**The half that did not reproduce.** The published minimal reproduction and four further shapes,
including an aggregated view over a two table join, stayed consistent at compatibility levels 120
through 170. So do not tell a developer their indexed views are being corrupted today. Say instead
that this defect raises no error and fails no check, so an indexed view over a `MERGE` target has
to be verified deliberately. The repair, if the two ever disagree, is to drop and recreate the
view's clustered index.

## Check it worked

One session proves nothing, so run the upsert from two shells at once and compare the final value
against the arithmetic total. `sqlcmd -b` exits non-zero on an error, and `-m-1` prints
every message, including the severity 10 ones that otherwise arrive with no number at all.

**`-m-1` is an ODBC `sqlcmd` instruction**, meaning the 18.x build from `mssql-tools18` or the
Microsoft command line utilities, and `localhost,1433` is exactly where a reader is most likely to
be holding the other one. Measured 2026-09-05, go-sqlcmd 1.10.0, the 1.x build
`brew install sqlcmd` and `winget install sqlcmd` install, prints no `Msg` header on a severity 10
message at any `-m` value. `Msg 2627` below is severity 14 and arrives with its number on either
build, so this check still works; what go-sqlcmd will not show you is a severity 10 message from the
statements around it. The ODBC build is inside the container image at
`/opt/mssql-tools18/bin/sqlcmd`, one `docker exec` away.
`build-app-on-azure-sql` tells the two builds apart in one table.

```bash
UPSERT="BEGIN TRAN;
UPDATE dbo.counters WITH (SERIALIZABLE) SET n = n + 1 WHERE k = N'hot';
IF @@ROWCOUNT = 0 INSERT INTO dbo.counters (k, n) VALUES (N'hot', 1);
COMMIT;"
S=(-S localhost,1433 -d appdb -C -b -m-1)

sqlcmd "${S[@]}" -Q "CREATE TABLE dbo.counters (k NVARCHAR(50) NOT NULL PRIMARY KEY, n INT NOT NULL);"

for i in 1 2; do
  sqlcmd "${S[@]}" -Q "DECLARE @i INT = 0; WHILE @i < 50 BEGIN $UPSERT SET @i += 1; END" &
done
wait

sqlcmd "${S[@]}" -Q "SELECT n, COUNT(*) OVER () AS rows_for_key FROM dbo.counters WHERE k = N'hot';"
```

Expected: `n` is 100 and `rows_for_key` is 1. Below 100 means writes were lost, more than one row
means the key carries no unique index. Delete `WITH (SERIALIZABLE)` and rerun: the count falls
short, or one shell exits non-zero on `Msg 2627`. Against Azure SQL Database only `-S` and the
authentication flags change.

Check an indexed view over the target separately, because nothing else will tell you.

```sql
-- Cheapest first: read the materialized rows, then recompute from the base table.
SELECT region, total, n FROM dbo.v_totals WITH (NOEXPAND) ORDER BY region;
SELECT region, SUM(amt), COUNT_BIG(*) FROM dbo.sales GROUP BY region ORDER BY region;

-- Or ask for the logical checks by name. Without this option they do not run.
DBCC CHECKTABLE ('dbo.v_totals') WITH EXTENDED_LOGICAL_CHECKS;
```

The two result sets must match row for row. `DBCC` must report 0 allocation and 0 consistency
errors.

## Do not

- Do not present `IF EXISTS ... UPDATE ELSE INSERT` as an upsert. It is a race, and wrapping it in
  a transaction does not fix it.
- Do not add `HOLDLOCK` and stop there. Without a unique index on the join key the range lock is
  wide, and four sessions produced `Msg 1205`.
- Do not translate `ON CONFLICT DO UPDATE` into `MERGE` reflexively. Two of the three safe
  patterns are plain statements and both are easier to review.
- Do not use `READPAST` on a `MERGE` target with an insert branch. Documented: it can produce
  inserts that violate unique constraints.
- Do not claim an indexed view is being corrupted by `MERGE` today without reproducing it, and do
  not treat a clean integrity check as evidence that one agrees with its base tables.
- Do not design the retry loop here. A deadlock victim needs a retry rather than a louder
  message, and which errors deserve one is separate work.

## References

- Open [the measured runs](references/merge-hazards-and-concurrency.md) when a number here is
  challenged, or when you need the message text for 2627, 8672, 10713 or 1205 as this engine
  printed it. Every concurrency run, every loud `MERGE` shape, all five indexed view attempts.
