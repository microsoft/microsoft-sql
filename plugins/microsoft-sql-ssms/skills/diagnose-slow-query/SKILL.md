---
name: diagnose-slow-query
description: >-
  Triages a slow Azure SQL Database query into one of four causes before anyone touches an index
  or a service tier: volatile, duration swings across executions; blocked, waiting on another
  session; regressed, a worse plan replaced a good one; or growing, duration rises with data
  volume. Reads Query Store runtime stats, plan history and per-plan waits, and knows where AUTO
  capture mode silently drops the query asked about. Use when a query "used to be fast" or runs
  inconsistently: "this took a second yesterday and ten today", "sometimes it's fast and
  sometimes it isn't", "did last night's deployment make this slower". Ends in a diagnosis, not a
  fix: CPU, memory, IO and tier go to diagnose-resource-pressure, blocking and deadlocks to
  diagnose-blocking-and-deadlocks, the plan itself to read-execution-plan, a query Query Store
  missed to capture-with-extended-events.
---

# Diagnose a slow Azure SQL Database query

**This is a triage, not a fix.** It turns "this is slow" into one of four labels, volatile, blocked,
regressed, or growing, and hands the labeled query to the skill that answers that label. Answering
the label, reading the plan XML, or capturing an event session, belongs elsewhere.

Measured on 2026-08-29 against a live engine reporting Edition `SQL Azure` and EngineEdition 5
(`Microsoft SQL Azure (RTM) - 12.0.2000.8`). Column names, capture modes, duration units and the
plan forcing failure reasons were re-checked against Microsoft Learn on 2026-09-03.

## The fact that changes how you look

**Query Store is on by default and still does not hold a complete record of what ran.** A database
created moments before this was written already reported `actual_state_desc` `READ_WRITE`, so
enabling it is never the first step. Its capture mode there was `AUTO`, which ignores infrequent
queries and queries with insignificant compile and execution duration, against thresholds Microsoft
Learn describes only as internally determined. A query run four times and then flushed with
`sys.sp_query_store_flush_db` still produced zero rows in `sys.query_store_query`; setting
`QUERY_CAPTURE_MODE = ALL` captured the same shape on its next execution. **Absence from Query
Store is not evidence a query is fine.** Read the mode rather than assuming it: two Microsoft Learn
pages disagree about the default for SQL Server builds, `ALL` on one and `AUTO` on the other, so
`sys.database_query_store_options` is the only answer that is about your database.

The plan cache is not a rescue for that gap. On this engine a query against a user table can carry
a cached compiled plan with a nonzero `usecounts` in `sys.dm_exec_cached_plans` and still return
zero matching rows in `sys.dm_exec_query_stats`, confirmed by an exact row count before and after
the query ran.

A second trap sits next to the first. A query Query Store **did** capture is not stored as the
text that ran. Executed as
`SELECT COUNT(*) FROM dbo.q WHERE id>0 /*QSTIME_cheap4*/`, it is stored in `query_sql_text` as
`(@1 tinyint)SELECT COUNT(*) FROM [dbo].[q] WHERE [id]>@1`. Neither the literal nor the comment
appears anywhere, so a `LIKE` search for either returns the same empty, error free result the
`AUTO` gap produces, for a different reason. Re-measured on separate fresh databases on 2026-08-29:
comment stripping held on every capture, including a two table JOIN whose literal was **not**
rewritten, so only the comment stripping is unconditional. Treat the count that guarantees capture
as unknown: a cheap query stayed absent through four executions and a flush on two databases, while
a costlier JOIN run 30 times on a third was captured.

## Step 1: is it running right now, and is it blocked

Before reading any history, check the present:

```sql
DECLARE @session_id smallint = @@SPID; -- replace with the observed slow session id
SELECT session_id, status, blocking_session_id, wait_type, total_elapsed_time, cpu_time, command
FROM sys.dm_exec_requests
WHERE session_id = @session_id;
```

`blocking_session_id` other than 0 means this is not a Query Store investigation at all. Stop and
hand it to `diagnose-blocking-and-deadlocks`, which reads the chain and the head blocker. Plan
history on a session waiting for a lock answers the wrong question.

## Step 2: find the query, and know when you will not

```sql
SELECT qsq.query_id, qsqt.query_sql_text, qsp.plan_id
FROM sys.query_store_query qsq
JOIN sys.query_store_query_text qsqt ON qsq.query_text_id = qsqt.query_text_id
JOIN sys.query_store_plan qsp ON qsq.query_id = qsp.query_id
WHERE qsqt.query_sql_text LIKE '%<a distinctive fragment>%';
```

**The fragment has to survive normalization, or this returns nothing for a query that is right
there.** Never search on a comment tag from the original statement; it is stripped on every
capture, whatever the query shape. A literal is a maybe rather than a no, and so are the brackets:
the `@N` placeholders and the bracketed identifiers arrive together, as the single parameterization
rewrite that the `(@1 tinyint)` prefix marks, so a statement the engine did not rewrite keeps its
literal and keeps `dbo.q` unbracketed. Search the bare object name, `LIKE '%q%'`, which matches
both shapes, then read `query_sql_text` back to see which one you got. Measured 2026-09-03: an
assignment `SELECT` was captured and found by its bare name in the same run in which its bracketed
form matched nothing. Matching on `object_id` only helps inside a module: Microsoft Learn states
it is populated only for a statement compiled from a Transact-SQL module, and is 0 for every ad
hoc batch, so it cannot tell two ad hoc queries apart.

If nothing comes back after accounting for normalization, read the mode before concluding the query
never ran or was fast:

```sql
SELECT actual_state_desc, query_capture_mode_desc, readonly_reason,
       stale_query_threshold_days, max_storage_size_mb
FROM sys.database_query_store_options;
```

`AUTO` plus a one-off query is the likely explanation, not a clean bill of health: set
`QUERY_CAPTURE_MODE = ALL` or `CUSTOM` for the investigation, tell whoever owns the database
because `ALL` captures overhead too, and re-run the query. `READ_ONLY`
means Query Store stopped accepting data and `readonly_reason` says why: 65536 is the
`max_storage_size_mb` limit, 131072 the internal statement memory limit, 524288 the database out of
space. That is a capacity problem to raise, not a quiet workload. A query that must be caught on
its very next single occurrence is `capture-with-extended-events`'s job.

**Reading these views needs `VIEW DATABASE STATE`.** Without it, `sys.dm_exec_query_stats` returns
`VIEW DATABASE PERFORMANCE STATE permission denied in database '<name>'`, naming the newer
permission, but the older `VIEW DATABASE STATE` alone was sufficient here for that DMV and every
`sys.query_store_*` view tested, and Microsoft Learn agrees the greater permission satisfies it.
Check what the account already holds before asking for a grant.

## Step 3: is it volatile

A single `avg_duration` is not a verdict. Rank instability with the coefficient of variation,
`stdev_duration` divided by `avg_duration`, per plan per interval:

```sql
DECLARE @plan_id_1 bigint = 1; -- replace with a plan id from step 2
DECLARE @plan_id_2 bigint = 2; -- replace with another plan id from step 2
SELECT rs.plan_id, rs.avg_duration, rs.stdev_duration,
       rs.stdev_duration / NULLIF(rs.avg_duration, 0) AS coefficient_of_variation,
       rs.count_executions
FROM sys.query_store_runtime_stats rs
WHERE rs.plan_id IN (@plan_id_1, @plan_id_2)
  AND rs.execution_type = 0
ORDER BY coefficient_of_variation DESC;
```

`execution_type = 0` keeps aborted and exception executions out of the ranking. Duration columns
are **microseconds**, so a one second execution reads as 1000000.

Use this to **rank**, not to threshold. A coefficient of variation far above its neighbors, or
above its own earlier value, marks a query whose duration depends on something outside the query
text, usually the parameter values it was called with. That is volatile: the next question is which
parameter shape is expensive, not what to tune.

## Step 4: is it regressed

More than one `plan_id` for a `query_id` means the plan changed, and the query's own history says
whether that was for the better. In the interval still active one plan can hold several rows, one
flushed to disk and the rest in memory, so weight by `count_executions` instead of reading a row:

```sql
DECLARE @query_id bigint = 1; -- replace with the query id from step 2
SELECT qsp.plan_id, qsp.is_forced_plan,
       SUM(rs.avg_duration * rs.count_executions)
           / NULLIF(SUM(rs.count_executions), 0) AS weighted_duration,
       SUM(rs.count_executions) AS executions
FROM sys.query_store_plan qsp
JOIN sys.query_store_runtime_stats rs ON qsp.plan_id = rs.plan_id
WHERE qsp.query_id = @query_id
  AND rs.execution_type = 0
GROUP BY qsp.plan_id, qsp.is_forced_plan
ORDER BY qsp.plan_id;
```

If an earlier plan performed better, **force it back before removing the worse one**:

```sql
DECLARE @query_id bigint = 1; -- replace with the query id from step 2
DECLARE @plan_id bigint = 1;  -- replace with the earlier, better plan id
IF EXISTS
(
    SELECT 1
    FROM sys.query_store_plan
    WHERE query_id = @query_id AND plan_id = @plan_id
)
    EXEC sys.sp_query_store_force_plan @query_id = @query_id, @plan_id = @plan_id;
```

This ran clean against the test engine, and so did `sys.sp_query_store_unforce_plan` afterward.
Forcing is reversible and immediate; deleting query or plan history is neither, and throws away the
evidence the next regression needs. Forcing does not guarantee the plan gets used, so confirm it
took rather than trusting the `EXEC`.

## Step 5: is it growing

A duration that climbs steadily rather than jumping once is a different problem: the plan has not
changed, the data underneath it has. Compare one `plan_id` across intervals:

```sql
DECLARE @plan_id bigint = 1; -- replace with the plan id from step 2
SELECT rsi.start_time, rs.avg_duration, rs.avg_logical_io_reads, rs.count_executions
FROM sys.query_store_runtime_stats rs
JOIN sys.query_store_runtime_stats_interval rsi
  ON rs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
WHERE rs.plan_id = @plan_id
ORDER BY rsi.start_time;
```

Rising `avg_logical_io_reads` alongside rising `avg_duration`, same plan throughout, is a table or
index that outgrew the plan shape that suited it, an indexing or schema question, not a Query
Store one. `stale_query_threshold_days` bounds how far back this reaches; history that looks
unexpectedly short usually means that setting, not a gap in what ran.

## Step 6: read the wait composition to route the next step

```sql
DECLARE @plan_id bigint = 1; -- replace with the plan id from step 2
SELECT ws.wait_category_desc, SUM(ws.total_query_wait_time_ms) AS total_wait_ms
FROM sys.query_store_wait_stats ws
WHERE ws.plan_id = @plan_id
GROUP BY ws.wait_category_desc
ORDER BY total_wait_ms DESC;
```

The `_desc` column carries the category name, so no mapping from numeric `wait_category` is
needed. Route on the dominant category, do not diagnose it here:

- `Lock`, `Latch` or `Buffer Latch`: contention, not a slow plan. Go to
  `diagnose-blocking-and-deadlocks`.
- `CPU`, `Memory`, `Buffer IO` or `Tran Log IO`: a resource question. Go to
  `diagnose-resource-pressure`. `Log Rate Governor` is a category too, but it reports a service
  behaviour the container cannot show you, so treat it as cloud only evidence.
- No single category dominant and the plan looks wrong for the data: go to `read-execution-plan`
  for the operator responsible.

## Check it worked

Two checks after acting on the verdict. Both are about the change, not Query Store.

**One: a forced plan actually took.** Run the query once more, then read the plan rows back:

```sql
DECLARE @query_id bigint = 1; -- replace with the query id from step 2
SELECT plan_id, is_forced_plan, force_failure_count,
       last_force_failure_reason, last_force_failure_reason_desc
FROM sys.query_store_plan
WHERE query_id = @query_id;
```

Expect one row at `is_forced_plan` = 1 with `force_failure_count` = 0 and
`last_force_failure_reason` = 0, and every other plan for that query at `is_forced_plan` = 0. A
nonzero reason names the refusal: 8712 `NO_INDEX`, an index the plan needs is gone; 8698 `NO_PLAN`,
the plan could not be verified for this query; 8690 `HINT_CONFLICT`, a query hint contradicts it.
The count only moves on a recompile, not on every execution, which is why the re-run comes first.

**Two: a new interval is measurably faster.**

```sql
EXEC sys.sp_query_store_flush_db;
DECLARE @old_plan_id bigint = 1; -- replace with the old plan id
DECLARE @new_plan_id bigint = 2; -- replace with the new plan id
SELECT rsi.start_time, rs.plan_id, rs.count_executions, rs.avg_duration
FROM sys.query_store_runtime_stats rs
JOIN sys.query_store_runtime_stats_interval rsi
  ON rs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
WHERE rs.plan_id IN (@old_plan_id, @new_plan_id)
  AND rs.execution_type = 0
ORDER BY rsi.start_time DESC;
```

Expect the newest `start_time` to carry the new `plan_id` only, its `count_executions` matching the
runs you just made, and its `avg_duration` below the old plan's. Durations are microseconds, so
two seconds down to 200 ms reads as roughly 2000000 against 200000, not 2 against 0.2. The old
`plan_id` still winning the newest interval means a forced plan did not take, and check one says why.
Unchanged durations on the new plan mean the plan was never the cause: the label was wrong, so go
back to step 6.

## Do not

- Do not report a query as fast, or as never having run, because it is missing from Query Store.
  Read `query_capture_mode_desc` first.
- Do not treat `sys.dm_exec_query_stats` as a fallback source of truth when Query Store comes up
  empty. A cached, used plan can still have zero rows there.
- Do not `LIKE` search `sys.query_store_query_text` for a comment tag, or for a bracketed
  identifier, and conclude the query never ran. Match the bare object name instead.
- Do not read a verdict out of one `avg_duration`, or compare two plans without weighting by
  `count_executions`.
- Do not call a forced plan done because the `EXEC` returned. Check `is_forced_plan` and
  `last_force_failure_reason` after a re-run.
- Do not remove a query or a plan from Query Store when forcing the earlier plan already fixes it.
- Do not diagnose CPU, memory, IO or service tier pressure here, that is
  `diagnose-resource-pressure`; do not build a blocking chain or read a deadlock graph, that is
  `diagnose-blocking-and-deadlocks`; do not walk the plan XML operator by operator, that is
  `read-execution-plan`.
- Do not leave `QUERY_CAPTURE_MODE` on `ALL` afterward. It captures every trivial query, at a cost
  the database owner should choose.

## References

- [references/query-store-queries.md](references/query-store-queries.md): open it when the step 2
  search finds nothing and you need the before and after of a normalized capture, when you want
  instability or multi plan queries ranked across the whole database, or when the permission error
  blocks the read and you need the grant that cleared it.
