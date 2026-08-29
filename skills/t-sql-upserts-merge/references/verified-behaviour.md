# Verified behaviour: upserts, MERGE, and the indexed view question

## Contents

- [How this was measured](#how-this-was-measured)
- [The naive upsert races](#the-naive-upsert-races)
- [MERGE without a lock hint](#merge-without-a-lock-hint)
- [MERGE with HOLDLOCK](#merge-with-holdlock)
- [HOLDLOCK without a unique index on the join key](#holdlock-without-a-unique-index-on-the-join-key)
- [The three patterns that reached 160 of 160](#the-three-patterns-that-reached-160-of-160)
- [MERGE shapes that fail loudly](#merge-shapes-that-fail-loudly)
- [WHEN NOT MATCHED BY SOURCE THEN DELETE](#when-not-matched-by-source-then-delete)
- [The indexed view claim](#the-indexed-view-claim)
- [What is documented rather than measured](#what-is-documented-rather-than-measured)

## How this was measured

One engine, reachable over the network, reporting:

```text
SERVERPROPERTY('EngineEdition') = 5
SERVERPROPERTY('Edition')       = SQL Azure
```

Each concurrency run started separate client processes against the same database, one process per
session, and compared the final value against the arithmetic total. Date of the run: 2026-08-28.

Two tables carried the tests:

```sql
CREATE TABLE dbo.counter_pk    (k NVARCHAR(50) NOT NULL PRIMARY KEY, n INT NOT NULL);
CREATE TABLE dbo.counter_nokey (k NVARCHAR(50) NOT NULL,             n INT NOT NULL);
```

## The naive upsert races

Two sessions, a two second delay inserted between the existence test and the write so the window
is deterministic rather than lucky.

```sql
BEGIN TRAN;
IF EXISTS (SELECT 1 FROM dbo.counter_pk WHERE k = @k)
BEGIN WAITFOR DELAY '00:00:02'; UPDATE dbo.counter_pk SET n = n + 1 WHERE k = @k; END
ELSE
BEGIN WAITFOR DELAY '00:00:02'; INSERT INTO dbo.counter_pk (k, n) VALUES (@k, 1); END
COMMIT;
```

Both sessions printed `took INSERT branch`. One of them then failed:

```text
Msg 2627, Level 14, State 1, Server SQL Azure, Line 13
Violation of PRIMARY KEY constraint 'PK__counter___...'. Cannot insert duplicate key in object
'dbo.counter_pk'. The duplicate key value is (race1).
The statement has been terminated.
```

Final state: one row, `n = 1`. One of the two increments was lost.

The same code against `dbo.counter_nokey`, which has no unique key:

```text
INSERT branch
INSERT branch
DUPLICATE ROWS for race2: 2
```

**No error was raised.** Both callers were told the write succeeded, and the table holds two rows
for one logical key. This is the shape that does not show up in a log.

## MERGE without a lock hint

Four concurrent sessions, one key, target has a primary key:

```sql
MERGE dbo.counter_pk AS t
USING (SELECT @k AS k, 1 AS n) AS s ON t.k = s.k
WHEN MATCHED THEN UPDATE SET t.n = t.n + 1
WHEN NOT MATCHED THEN INSERT (k, n) VALUES (s.k, s.n);
```

Two sessions raised `Msg 2627` on the same constraint. Final value `n = 2` where four increments
were requested.

## MERGE with HOLDLOCK

Identical statement, one hint added:

```sql
MERGE dbo.counter_pk WITH (HOLDLOCK) AS t
USING (SELECT @k AS k, 1 AS n) AS s ON t.k = s.k
WHEN MATCHED THEN UPDATE SET t.n = t.n + 1
WHEN NOT MATCHED THEN INSERT (k, n) VALUES (s.k, s.n);
```

Four sessions: all four succeeded, `n = 4`, one row.

Eight sessions running twenty iterations each: all eight printed `session finished 20 iterations`,
final `n = 160` against an expected 160, one row, no deadlocks.

## HOLDLOCK without a unique index on the join key

The same `MERGE WITH (HOLDLOCK)` against `dbo.counter_nokey`, four sessions:

```text
Msg 1205, Level 13, State 18, Server SQL Azure, Line 4
Transaction (Process ID 88) was deadlocked on lock resources with another process and has been
chosen as the deadlock victim. Rerun the transaction.
```

Two of the four were chosen as victims and rolled back. The two survivors left one row with
`n = 2`. So the hint still serialized the work, but at the cost of a lock wide enough to deadlock,
and half the transactions were lost rather than duplicated.

The unique index is what turns that into a narrow key range lock. It is not optional.

## The three patterns that reached 160 of 160

Eight sessions, twenty iterations each, one hot key.

| Pattern | Outcome |
|---|---|
| `MERGE WITH (HOLDLOCK)` | 8 of 8 finished, `n = 160` |
| `UPDATE WITH (SERIALIZABLE)` then `INSERT` when `@@ROWCOUNT = 0` | 8 of 8 finished, `n = 160` |
| `UPDATE`, then `INSERT` inside `TRY` catching 2601 and 2627 | 8 of 8 finished, `n = 160` |
| `UPDATE` then `INSERT` with **no** hint | 7 of 8 finished, one raised `Msg 2627`, `n = 140` |

The last row is the measurement worth carrying: one duplicate key error at one moment cost the
whole remaining batch for that session, twenty writes, because the error terminated it.

## MERGE shapes that fail loudly

Target `dbo.prod (sku NVARCHAR(20) PRIMARY KEY, qty INT)` holding `A`, `B`, `C`.

**Duplicate keys in the source:**

```sql
MERGE dbo.prod AS t
USING (VALUES (N'A', 10), (N'A', 20)) AS s(sku, qty) ON t.sku = s.sku
WHEN MATCHED THEN UPDATE SET t.qty = s.qty
WHEN NOT MATCHED THEN INSERT (sku, qty) VALUES (s.sku, s.qty);
```

```text
Msg 8672, Level 16, State 1
The MERGE statement attempted to UPDATE or DELETE the same row more than once. This happens when a
target row matches more than one source row. A MERGE statement cannot UPDATE/DELETE the same row of
the target table multiple times. Refine the ON clause to ensure a target row matches at most one
source row, or use the GROUP BY clause to group the source rows.
```

**Missing terminator:**

```text
Msg 10713, Level 15, State 1
A MERGE statement must be terminated by a semi-colon (;).
```

**A filter in the ON clause**, `ON t.sku = s.sku AND t.qty > 100`, against a row that exists with
`qty` below 100:

```text
Msg 2627, Level 14, State 1
Violation of PRIMARY KEY constraint 'PK__prod__...'. Cannot insert duplicate key in object
'dbo.prod'. The duplicate key value is (A).
```

The row exists, so the intent was an update, but the extra condition made it unmatched and the
insert branch fired. This is the documented "unexpected and incorrect results" behaviour, and here
it surfaced as a constraint violation rather than as wrong data, because the key was protected.
On a table with no unique key it would have inserted a duplicate instead.

## WHEN NOT MATCHED BY SOURCE THEN DELETE

The single most destructive shape, and the easiest to add by accident, because it makes a `MERGE`
look complete.

```sql
-- dbo.prod holds A, B, C. The batch mentions only A.
MERGE dbo.prod AS t
USING (VALUES (N'A', 5)) AS s(sku, qty) ON t.sku = s.sku
WHEN MATCHED THEN UPDATE SET t.qty = s.qty
WHEN NOT MATCHED BY TARGET THEN INSERT (sku, qty) VALUES (s.sku, s.qty)
WHEN NOT MATCHED BY SOURCE THEN DELETE;
```

```text
before: A,B,C
after : A
rows left = 1
```

Two rows deleted, no error, no list of what went. The clause is correct only when the source is
the complete intended contents of the target.

## The indexed view claim

The claim under test: a `MERGE` can leave an indexed view inconsistent with its base tables, and
a routine consistency check will not report it.

**Attempt 1, the published minimal reproduction.** A single table, a schemabound view over two of
its columns with a unique clustered index, and a `MERGE` combining `WHEN MATCHED THEN UPDATE` on a
column outside the view with `WHEN NOT MATCHED BY SOURCE THEN DELETE`. Run at compatibility levels
120, 130, 140, 150, 160 and 170:

```text
compat 120: base=1 view=1  consistent
compat 130: base=1 view=1  consistent
compat 140: base=1 view=1  consistent
compat 150: base=1 view=1  consistent
compat 160: base=1 view=1  consistent
compat 170: base=1 view=1  consistent
```

**Attempt 2, the foreign key join elimination shape.** A parent and a child table, a single column
foreign key from child to parent with no cascade, a schemabound view joining the two with a unique
clustered index on the child key, and a `MERGE` on the child combining `UPDATE` with
`NOT MATCHED BY SOURCE THEN DELETE`. The view and the recomputation agreed, before and after.

**Attempt 3, the same join with aggregation.** `SUM` and `COUNT_BIG(*)` grouped by the parent key
over the same foreign key join. Agreed.

**Attempt 4, a matched delete.** `WHEN MATCHED AND <condition> THEN DELETE` alongside
`WHEN MATCHED THEN UPDATE`, and separately all three actions in one statement. Agreed.

**Attempt 5, a system versioned target.** A `MERGE` combining insert, update and delete against a
system versioned table carrying a nonclustered index on its history table, another open report in
the same family, completed and produced the expected current rows and history rows.

**Conclusion.** The corruption did not reproduce on this engine in any shape tried. Treat the
catalog note as describing a class of defect rather than current behaviour.

**What does still hold**, and it is what made the class severe: an integrity check performs only
physical consistency checks on an indexed view by default. The logical checks that compare the
materialized rows against the base tables run only under `EXTENDED_LOGICAL_CHECKS`. Both forms
were run here and both are accepted on this engine:

```sql
DBCC CHECKTABLE ('dbo.v_totals');
DBCC CHECKTABLE ('dbo.v_totals') WITH EXTENDED_LOGICAL_CHECKS;
DBCC CHECKDB;
DBCC CHECKDB WITH EXTENDED_LOGICAL_CHECKS;
```

The cheaper habit is to compare the view read with `NOEXPAND` against a recomputation from the
base tables, which needs no elevated permission and is a plain query.

## What is documented rather than measured

These come from the Microsoft Learn pages for `MERGE` and for the database consistency check,
read on 2026-08-28 for Azure SQL Database. They were not reproduced here.

- `HOLDLOCK` is called out as the way to prevent unique key violations where a `MERGE` both
  inserts and updates unique keys, and it is a synonym for `SERIALIZABLE`.
- The index guidance is a unique index on the join columns of the source and a unique clustered
  index on the join columns of the target.
- Only the matching columns belong in `ON`. Comparisons to other values, including constants, can
  return unexpected and incorrect results. Filters belong in a `WHEN` clause or a view.
- `READPAST` with an insert branch can produce inserts that violate unique constraints.
- Tables with any form of columnstore index are called out as poor `MERGE` targets.
- Simple parameterization is not applied to `MERGE`, so literals force a compile per execution.
- At scale, `MERGE` may introduce complicated concurrency issues, and discrete statements can
  block less.
- Inside an `AFTER` trigger, `@@ROWCOUNT` reflects the total rows affected by the whole `MERGE`,
  not just the action the trigger was declared for.
- The consistency check is unavailable on the Hyperscale service tier, where a per-table check is
  the documented substitute.
