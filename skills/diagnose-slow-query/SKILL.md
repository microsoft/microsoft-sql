---
name: diagnose-slow-query
description: >-
  Triages a slow Azure SQL Database query into one of four causes before anyone touches an index or
  a service tier: volatile, duration swings across executions; blocked, waiting on another session
  right now; regressed, a worse plan replaced a good one; or growing, duration rises with data
  volume over time. Reads Query Store's runtime stats, plan history, and per-plan wait composition
  to reach that verdict, and knows where the default AUTO capture mode silently drops the query
  someone is asking about. Use when a query, report, or job "used to be fast" or runs
  inconsistently: "this took a second yesterday and ten today", "sometimes it's fast and sometimes
  it isn't", "did last night's deployment make this slower". Ends in a diagnosis, not a fix: CPU,
  memory, IO and tier go to diagnose-resource-pressure, a blocking chain or deadlock goes to
  diagnose-blocking-and-deadlocks, reading the plan operator by operator goes to
  read-execution-plan, and a query Query Store missed goes to capture-with-extended-events.
---

# Diagnose a slow Azure SQL Database query

**This is a triage, not a fix.** It turns "this is slow" into one of four labels, volatile,
blocked, regressed, or growing, and hands the labeled query to the skill that answers that label.
Answering the label itself, reading the plan XML, or capturing an event session, belongs elsewhere.

Measured on 2026-08-29 against a live engine reporting Edition `SQL Azure` and EngineEdition 5
(`Microsoft SQL Azure (RTM) - 12.0.2000.8`). Every query, error number, and permission below was
run against that engine, not recalled.

## The fact that changes how you look

**Query Store does not hold a complete record of every query that ran, even though it is on by
default.** A database created moments before this was written already showed
`actual_state_desc` `READ_WRITE`, so enabling it is never the first step. But its default capture
mode is `AUTO`, and `AUTO` applies internal thresholds that drop ad hoc and infrequently executed
queries. A query run four times and then flushed with `sys.sp_query_store_flush_db` still produced
zero rows in `sys.query_store_query`. Setting `QUERY_CAPTURE_MODE = ALL` and running the same shape
of query again captured it on the very next execution. **Absence from Query Store is not evidence a
query is fine.** It is evidence it was cheap enough, or rare enough, for `AUTO` to skip it, and the
two look identical from the query itself.

The plan cache is not a rescue for this gap. On this engine, a query against a user table can carry
a cached compiled plan with a nonzero `usecounts` in `sys.dm_exec_cached_plans`, and still return
zero matching rows in `sys.dm_exec_query_stats`, confirmed by an exact row-count check before and
after the query ran, not by a text match that could have missed it. Do not use the plan cache as a
substitute source of truth for whether or how often a query executed. Query Store, once it has
actually captured the query, is the more trustworthy of the two.

There is a second, independent trap sitting right next to that one. Even a query Query Store
**did** capture is not stored as the text that ran: `sys.query_store_query_text` holds normalized
text, with literals replaced by parameters and comments stripped. Confirmed on this engine, a
query executed as

```sql
SELECT COUNT(*) FROM dbo.q WHERE id>0 /*QSTIME_cheap4*/
```

is stored in `query_sql_text` as

```
(@1 tinyint)SELECT COUNT(*) FROM [dbo].[q] WHERE [id]>@1
```

Neither the literal `0` nor the comment `QSTIME_cheap4` appears anywhere in the stored text. A
`LIKE` search for either returns zero rows for a query that is sitting right there, the same empty,
error-free result the `AUTO` gap above produces, for a completely different reason. An agent that
only checks for the `AUTO` gap still gets burned by this one, because both look identical from the
query's absence alone.

Both were re-measured on separate, freshly created databases on 2026-08-29. The comment-stripping
half of normalization held every time a query was captured at all, including a JOIN across two
tables, whose literal was **not** rewritten to a parameter, simple parameterization does not apply
to every query shape, but whose comment vanished from the stored text exactly the same way. So
comment-stripping is the more dependable half of this trap: it does not wait on the query being
simple enough to auto-parameterize. The `AUTO` capture gap itself did not resolve to a fixed
execution count or a fixed query shape: a cheap single-table query stayed absent through 4
executions and a flush on two separate databases, while a costlier JOIN executed 30 times on a
third database was captured. Treat the count needed to guarantee capture as unknown rather than as
a specific number, and do not assume a handful of extra executions will fix an absence. What was
not measured, and is not claimed here, is how long an `AUTO`-skipped query stays absent on its
own: this skill states what was checked, absent at flush time and still absent on immediate
re-check, and takes no position on whether it might appear later under further, unprompted
repetition.

## Step 1: is it running right now, and is it blocked

Before reading any history, check the present:

```sql
SELECT session_id, status, blocking_session_id, wait_type, total_elapsed_time, cpu_time, command
FROM sys.dm_exec_requests
WHERE session_id = <the session running the slow query>;
```

`blocking_session_id` other than 0 means this is not a Query Store investigation at all. Stop here
and hand it to `diagnose-blocking-and-deadlocks`, which reads the blocking chain and the head
blocker. Proceeding to plan history on a session that is simply waiting for a lock wastes the
Query Store read and answers the wrong question.

## Step 2: find the query, and know when you will not

Look it up by object or by text fragment:

```sql
SELECT qsq.query_id, qsqt.query_sql_text, qsp.plan_id
FROM sys.query_store_query qsq
JOIN sys.query_store_query_text qsqt ON qsq.query_text_id = qsqt.query_text_id
JOIN sys.query_store_plan qsp ON qsq.query_id = qsp.query_id
WHERE qsqt.query_sql_text LIKE '%<a distinctive fragment>%';
```

**The fragment has to survive normalization, or this returns nothing for a query that is right
there.** Never search on a comment tag copied from the original statement; the comment is stripped
on every capture, regardless of query shape. A literal value is less reliable to rule out than it
looks: it survives in the stored text for some query shapes, a JOIN in testing kept its literal,
and disappears into an `@N` parameter placeholder for others, a single-table predicate in testing
did not. Search on the parts normalization leaves alone instead, bracketed table and column names,
for example `%[dbo].[q]%`, and treat a literal-based search as a maybe, not a no. Matching on
`object_id` is only useful when the statement lives inside a stored procedure or function;
`object_id` is 0 for every ad hoc batch, so it will not tell two ad hoc queries apart. When none of
that is reliable, set `QUERY_CAPTURE_MODE = ALL` and run the query again to capture its shape
fresh, then read it directly instead of guessing at the normalized form.

If nothing comes back even after accounting for normalization, check `query_capture_mode_desc` in
`sys.database_query_store_options` before concluding the query never ran or was fast. If it reads
`AUTO` and the query in question was
a one-off, that is the likely explanation, not a clean bill of health. Set
`QUERY_CAPTURE_MODE = ALL` or `CUSTOM` for the duration of the investigation if it needs to be
caught going forward, and say so to whoever owns the database, because `ALL` captures overhead too.
A query that needs to be caught on its very next single occurrence, with no repeat, is
`capture-with-extended-events`'s job, not this skill's.

**Reading these views needs `VIEW DATABASE STATE`.** Without it, `sys.dm_exec_query_stats` returns
the exact error `VIEW DATABASE PERFORMANCE STATE permission denied in database '<name>'`, naming
the newer permission, but granting the older `VIEW DATABASE STATE` alone was sufficient here for
both `sys.dm_exec_query_stats` and every `sys.query_store_*` view tested. Do not wait on the newer
permission name if the older one is already granted; check first.

## Step 3: is it volatile

A single `avg_duration` is not a verdict. Rank instability with the coefficient of variation,
`stdev_duration` divided by `avg_duration`, per plan per interval, from `sys.query_store_runtime_stats`:

```sql
SELECT rs.plan_id, rs.avg_duration, rs.stdev_duration,
       rs.stdev_duration / NULLIF(rs.avg_duration, 0) AS coefficient_of_variation,
       rs.count_executions
FROM sys.query_store_runtime_stats rs
WHERE rs.plan_id IN (<the plan ids from step 2>)
ORDER BY coefficient_of_variation DESC;
```

Use this to **rank**, not to threshold. A query whose coefficient of variation is far above its own
neighbors, or above its own value in an earlier interval, is the one whose duration depends on
something outside the query text, usually the parameter values it was called with. That is a
volatile query, and the next question is which parameter shape is expensive, not what to tune.

## Step 4: is it regressed

`sys.query_store_plan` carries every distinct plan the optimizer produced for a `query_id`. More
than one `plan_id` means the plan changed, and the query's own history tells you whether that was
for the better:

```sql
SELECT qsp.plan_id, qsp.is_forced_plan, rs.avg_duration, rs.avg_cpu_time, rs.count_executions
FROM sys.query_store_plan qsp
JOIN sys.query_store_runtime_stats rs ON qsp.plan_id = rs.plan_id
WHERE qsp.query_id = <the query id>
ORDER BY qsp.plan_id;
```

If an earlier plan performed better, **force it back before removing the worse one**:

```sql
EXEC sys.sp_query_store_force_plan @query_id = <query_id>, @plan_id = <the earlier, better plan_id>;
```

This ran clean against the test engine, and so did `sys.sp_query_store_unforce_plan` afterward.
Forcing is reversible and immediate; deleting query or plan history is neither, and throws away the
evidence the next regression will need. Reach for removal only after the forced plan has been
confirmed stable, never as the first move.

## Step 5: is it growing

A duration that climbs steadily, rather than jumping once, is a different problem from a
regression: the plan has not changed, but the data underneath it has. Compare the same `plan_id`
across `sys.query_store_runtime_stats_interval` periods rather than across plans:

```sql
SELECT rsi.start_time, rs.avg_duration, rs.avg_logical_io_reads, rs.count_executions
FROM sys.query_store_runtime_stats rs
JOIN sys.query_store_runtime_stats_interval rsi ON rs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
WHERE rs.plan_id = <the plan id>
ORDER BY rsi.start_time;
```

Rising `avg_logical_io_reads` alongside rising `avg_duration`, same plan throughout, is a table or
index that outgrew the plan shape that used to suit it, an indexing or schema question, not a
Query Store one. `stale_query_threshold_days` on `sys.database_query_store_options` bounds how far
back this history reaches; a value that looks unexpectedly short usually means that setting, not a
gap in what ran.

## Step 6: read the wait composition to route the next step

```sql
SELECT ws.wait_category_desc, SUM(ws.total_query_wait_time_ms) AS total_wait_ms
FROM sys.query_store_wait_stats ws
WHERE ws.plan_id = <the plan id>
GROUP BY ws.wait_category_desc
ORDER BY total_wait_ms DESC;
```

This view exists and returns category-labeled wait time per plan; no manual mapping from a numeric
wait category to a name is needed, the `_desc` column already carries it. Use the dominant category
to route, not to diagnose further here:

- `Lock` or `Latch` dominant: this is blocking or contention, not a slow plan. Go to
  `diagnose-blocking-and-deadlocks`.
- `CPU`, `Memory`, `Buffer IO`, or governance-related categories dominant: this is a resource
  question. Go to `diagnose-resource-pressure`.
- No single category dominates and the plan itself looks wrong for the data: go to
  `read-execution-plan` to find the operator responsible.

## Validation rules

- A currently running, currently blocked session was checked with `sys.dm_exec_requests` before any
  Query Store history was read.
- Absence from Query Store was never read as "this query is fine" without first checking
  `query_capture_mode_desc`.
- A `LIKE` search that found nothing in `sys.query_store_query_text` was rechecked against the
  normalized, comment-stripped shape before the query was called absent.
- The verdict came from a coefficient of variation or an interval comparison, never from a single
  `avg_duration` value.
- A plan change was answered by forcing the better plan before anything was removed.
- The wait category, not a guess, decided whether the handoff was to
  `diagnose-blocking-and-deadlocks` or `diagnose-resource-pressure`.

## Do not

- Do not report a query as fast, or as never having run, because it is missing from Query Store.
  Check `query_capture_mode_desc` first.
- Do not treat `sys.dm_exec_query_stats` as a fallback source of truth when Query Store comes up
  empty. A cached, used plan can still have zero rows there.
- Do not `LIKE`-search `sys.query_store_query_text` for a comment tag and conclude the query never
  ran; the comment is stripped on every capture. Do not trust a literal-based search either way,
  match on stable identifiers instead, or set `QUERY_CAPTURE_MODE = ALL` and re-run.
- Do not diagnose CPU, memory, IO, or service-tier pressure here. That is
  `diagnose-resource-pressure`.
- Do not build a blocking chain or read a deadlock graph here. That is
  `diagnose-blocking-and-deadlocks`.
- Do not walk the plan XML operator by operator here. That is `read-execution-plan`.
- Do not remove a query or a plan from Query Store to fix a regression when forcing the earlier
  plan already fixes it.
- Do not leave `QUERY_CAPTURE_MODE` set to `ALL` after the investigation ends; it captures every
  query, including trivial ones, at a cost the database owner should choose deliberately.

## References

- [references/query-store-queries.md](references/query-store-queries.md): the full text of every
  query above plus the coefficient-of-variation ranking across an entire database, the multi-plan
  finder, the normalized-text before-and-after with a working search pattern, and the exact
  wording of the `VIEW DATABASE STATE` permission error, each with what was run against the live
  engine to produce it.
