---
name: t-sql-upserts-merge
description: >-
  Writes an upsert for Azure SQL Database that is still correct when two sessions run it at the
  same moment, and refuses the MERGE shapes that lose rows. Use when asked to "insert or update",
  "insert if not exists", "add or update", "make this insert idempotent", "upsert", "write a
  MERGE", "sync a staging table into the target table", or to port ON CONFLICT DO UPDATE or ON
  DUPLICATE KEY UPDATE; and use when duplicate rows appear that nothing in the application
  created, or when error 2627, 2601, 8672, 10713 or a deadlock shows up under load. Covers why
  IF EXISTS then UPDATE ELSE INSERT is a race, what MERGE needs to be safe, which MERGE shapes to
  refuse outright, and the two patterns that are safe without MERGE. Key and index design belongs
  to design-azure-sql-schema, and general T-SQL dialect to t-sql-correctness.
---

# Write an upsert that survives concurrency, and refuse the dangerous MERGE

An upsert looks like a one-statement problem and is a concurrency problem. Both of the shapes a
model reaches for first, `IF EXISTS ... UPDATE ELSE INSERT` and a bare `MERGE`, are races. They
pass every single-session test and fail the first time two callers arrive together.

Measured on 2026-08-28 against a live engine reporting `EngineEdition` 5 and Edition `SQL Azure`.
The full runs, statement by statement, are in
[references/verified-behaviour.md](references/verified-behaviour.md).

## What the race actually costs

Eight sessions, twenty increments each, one hot key. A correct upsert ends at 160.

| Pattern | Result | Cost |
|---|---|---|
| `UPDATE` then `INSERT` when `@@ROWCOUNT = 0`, no hint | one session died on `Msg 2627`, final value **140** | 20 writes lost, and the caller saw one error, not twenty |
| `MERGE` with no lock hint, 4 sessions | 2 of 4 raised `Msg 2627`, final value **2** of 4 | half the batch rolled back |
| `IF EXISTS` on a table with **no unique key**, 2 sessions | **2 rows for one key, no error at all** | silent duplicates, and nothing in the log to find later |
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
serializable. Between the test and the insert there is a window, and wrapping the two statements
in `BEGIN TRAN` does not close it, because a transaction makes the pair atomic on failure without
making the read block anyone. Verified: two sessions with a two second gap between the test and
the write both reported `INSERT branch`.

## Three upserts that hold

Each of these reached 160 out of 160 under eight concurrent sessions.

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

Two things make it safe, and both are required. `HOLDLOCK` is a synonym for `SERIALIZABLE`, and
it is what holds a range lock across the match and the insert. **The unique index on the join key
is what makes that range lock narrow.** Without it the lock covers far more of the table: four
concurrent sessions against a table with no unique key produced `Msg 1205` deadlocks and rolled
two of them back.

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

**3. Try the insert, and treat the duplicate key as the update signal.** Best when the row
usually does not exist yet, because the common path takes no extra lock.

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
raise 2627 against. Sizing and choosing that key is `design-azure-sql-schema`.

## When to refuse MERGE outright

Say no and write separate statements. Each of these is verified or documented, not folklore.

- **A partial batch with `WHEN NOT MATCHED BY SOURCE THEN DELETE`.** That clause belongs to a full
  reload, where the source is the complete intended contents of the table, and never to an upsert
  of whichever rows this request happens to carry.
- **A source that can contain the same key twice.** `Msg 8672`, "The MERGE statement attempted to
  UPDATE or DELETE the same row more than once". Deduplicate the source first, with `GROUP BY` or
  a window function, rather than loosening the `ON` clause.
- **Any filter in the `ON` clause.** Documented: put only the columns being matched there.
  Verified: adding `AND t.qty > 100` to `ON` made an existing row look unmatched, so the
  `NOT MATCHED` branch fired and hit `Msg 2627` on the key that already existed. Row filters go in
  the `WHEN` clause or in a view or common table expression over the source.
- **A columnstore target.** Documented guidance is to avoid tables with any form of columnstore
  index as the target of `MERGE`, and to stage, then delete and insert in batches.
- **High concurrency at scale.** Documented: at scale `MERGE` may introduce complicated
  concurrency issues, and separate statements can perform better with less blocking.
- **Literal values in a frequently executed statement.** The optimizer does not apply simple
  parameterization to `MERGE`, so a `MERGE` with literals compiles a new plan every execution.
  Parameterize it.

`MERGE` also requires a semicolon terminator, and omitting it is `Msg 10713` rather than a
generic syntax error.

## The indexed view question, stated honestly

A long standing warning says a `MERGE` can leave an indexed view inconsistent with its base
tables, and that a routine consistency check will not report it. Half of that is current and half
is not, so both halves are set out rather than repeated.

**The half that holds.** By default an integrity check performs only **physical** consistency
checks on an indexed view. Logical checks, the ones that compare the materialized rows against
the base tables, run only when `EXTENDED_LOGICAL_CHECKS` is requested. So an indexed view that
disagrees with its base tables is genuinely invisible to a routine check, whatever put it there.
That is documented for Azure SQL Database today, and it is the reason this class of defect was
ever severe.

**The half that did not reproduce.** The published minimal reproduction, and four further shapes
including a two table view with a single column foreign key and an aggregated view over the same
join, were run against a current engine at compatibility levels 120, 130, 140, 150, 160 and 170.
**Every one stayed consistent.** The materialized view matched the recomputed result each time.
A related open report, a `MERGE` against a system versioned table with a nonclustered index on the
history table, also completed cleanly.

So do not tell a developer their indexed views are being corrupted today. Say this instead: this
class of defect produces no error and no failed check, so if an indexed view over a `MERGE` target
matters, verify it deliberately rather than assuming a clean integrity check covered it.

```sql
-- Compare the materialized rows against a recomputation, cheapest first check.
SELECT * FROM dbo.v_totals WITH (NOEXPAND);
SELECT region, SUM(amt), COUNT_BIG(*) FROM dbo.sales GROUP BY region;

-- Or ask for the logical checks explicitly.
DBCC CHECKTABLE ('dbo.v_totals') WITH EXTENDED_LOGICAL_CHECKS;
```

The repair, if the two ever disagree, is to drop and recreate the view's clustered index.

## Validation rules

- The key being upserted carries a unique index or a unique constraint. If it does not, the upsert
  is not finished, whichever pattern was used.
- Every `MERGE` carries `WITH (HOLDLOCK)` on the target, or a stated reason it runs with no
  concurrent writers.
- The `ON` clause contains only the columns matching source to target. No constants, no filters.
- The source of a `MERGE` cannot produce two rows for one key, and if it can, it is deduplicated
  before the statement.
- Every `MERGE` ends in a semicolon.
- A concurrency claim was tested with two sessions, not asserted in a comment.

## Do not

- Do not present `IF EXISTS ... UPDATE ELSE INSERT` as an upsert. It is a race, and wrapping it in
  a transaction does not fix it.
- Do not add `HOLDLOCK` and stop there. Without a unique index on the join key the range lock is
  wide, and four sessions were enough to produce `Msg 1205`.
- Do not translate `ON CONFLICT DO UPDATE` into `MERGE` reflexively. Two of the three safe
  patterns here are plain statements, and both are easier to review.
- Do not put a row filter in the `ON` clause to reduce the rows considered. It changes which
  branch fires, and the observed result was a duplicate key error.
- Do not use `READPAST` on a `MERGE` target with an insert branch. Documented: it can produce
  inserts that violate unique constraints.
- Do not claim an indexed view is being corrupted by `MERGE` today without reproducing it. It did
  not reproduce here at any compatibility level.
- Do not treat a clean integrity check as evidence an indexed view agrees with its base tables.
  That comparison is not part of the default check.
- Do not design the retry loop here. Which errors are worth retrying, and how, is separate work,
  and a deadlock victim needs a retry rather than a louder message.

## References

- [references/verified-behaviour.md](references/verified-behaviour.md): every run behind this
  page, with the statements, the session counts and the exact messages, plus the indexed view
  reproduction attempts and what each one returned. Read it when a claim here is being disputed,
  or before changing one of the numbers.
