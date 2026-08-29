---
name: read-execution-plan
description: >-
  Retrieves an Azure SQL Database execution plan, estimated or actual, and pulls out the
  small set of facts that explain slowness: operators, estimated versus actual row counts,
  warnings, missing-index hints, and the memory grant, instead of returning the whole plan
  XML. Use when someone says "read this execution plan", "why did the optimizer choose a
  scan here", "show me the actual plan not the estimated one", or hands over a plan and asks
  what is wrong with it. Also covers retrieval itself: SET SHOWPLAN_XML, SET STATISTICS XML,
  the dynamic management views, and Query Store, and why a same-looking DMV call can
  silently return the wrong kind of plan. Covers one plan's retrieval and interpretation,
  not general slow-query triage (diagnose-slow-query), lock analysis
  (diagnose-blocking-and-deadlocks), or instance-level CPU or memory pressure
  (diagnose-resource-pressure).
---

# Read an Azure SQL Database execution plan

Gets the plan that actually explains a query, in the smallest form that carries the signal,
and tells estimated numbers apart from measured ones. It does not diagnose blocking, resource
pressure, or a whole workload; those are other skills' jobs.

Measured on 2026-08-29 against a live engine reporting `EngineEdition` 5 and Edition `SQL Azure`.
Every number, error message and behavior below was run, not looked up.

## The distinction that drives everything else

**Estimated** is what the optimizer expected before running anything. **Actual** is what
happened. The two sources that look interchangeable are not:

| Source | What it returns | Executes the query? |
|---|---|---|
| `SET SHOWPLAN_XML ON` | Estimated plan only | No |
| `SET STATISTICS XML ON` | Actual plan, with `ActualRows` on every operator | Yes, for real |
| `sys.dm_exec_query_plan(plan_handle)` | Estimated plan only, even for a plan that has already run | No new execution, but no actual numbers either |
| `sys.dm_exec_query_plan_stats(plan_handle)` | Actual plan of the last execution, with `ActualRows` populated | No, but only if enabled first |
| `sys.query_store_plan` / `sys.query_store_runtime_stats` | Actual plan and aggregated runtime stats, persisted | No |

The one that trips agents up is `sys.dm_exec_query_plan`. It is the DMV whose name and
signature look like the answer, it returns without error for a plan handle whose query has
executed many times, and the XML it returns still carries zero occurrences of `ActualRows`
on every operator, verified against a plan for a query that had just run. Reporting numbers
from it as what happened is the exact wrong turn this skill exists to prevent.

`sys.dm_exec_query_plan_stats` is the one that actually returns the last real execution, and
it is silent about why it looks empty: the database-scoped configuration
`LAST_QUERY_PLAN_STATS` defaults to **off**, and while it is off the view returns zero rows
for every plan, with no error. Turn it on once per database:

```sql
ALTER DATABASE SCOPED CONFIGURATION SET LAST_QUERY_PLAN_STATS = ON;
```

## Retrieval, in order

1. **Decide estimated or actual before writing any query.** Estimated is enough to check
   which indexes the optimizer considered and whether a predicate is sargable. Actual is
   needed for anything about row-count accuracy, spills, or real duration.

2. **Estimated plan, no execution:** `SET SHOWPLAN_XML ON` followed by the query, in its own
   batch. `SET SHOWPLAN_XML ON` and `SET STATISTICS XML ON` must each be **the only
   statement in their batch**; combined with any other statement, including another `SET`,
   the engine rejects the batch outright with `The SET SHOWPLAN statements must be the only
   statements in the batch`, confirmed against this engine. It does not run part of the
   batch and skip the rest; nothing runs.

3. **Actual plan by re-running:** `SET STATISTICS XML ON` followed by the query, same
   one-statement-per-batch rule. This executes the query for real. Never wrap a write
   statement in it expecting a dry run; the insert, update or delete happens.

4. **Actual plan without re-running**, for a query that already ran: turn on
   `LAST_QUERY_PLAN_STATS` as above, find the plan handle for the object (`sys.dm_exec_procedure_stats`
   for a procedure, `sys.dm_exec_query_stats` for ad hoc text), then call
   `sys.dm_exec_query_plan_stats(plan_handle)`, not `sys.dm_exec_query_plan`.

5. **Query Store**, for history across executions and forced plans: it is on by default in
   this environment (`sys.database_query_store_options.actual_state_desc` read `READ_WRITE`
   on a freshly created database, with nothing configured). Its default capture policy is
   `AUTO`, and AUTO does not guarantee a query is captured after any particular number of
   executions. What was actually observed here, as one uncontrolled data point rather than a
   timing rule: a query run three times in a row was absent from `sys.query_store_query` on
   an immediate check and again eight seconds later; the same query text was present roughly
   fifteen minutes later, after dozens of unrelated batches, including other agents' sessions
   on this shared instance, had run in between. Elapsed time was never isolated from
   execution count or overall instance activity, so this does not establish that waiting is
   what closed the gap. A separate, more controlled check against this same engine found the
   opposite for a simpler, auto-parameterizable query: it stayed absent even after 30
   executions and an explicit `sp_query_store_flush_db`. **Treat absence from Query Store as
   unresolved, never as proof a query did not run, and do not wait on it**; use the
   plan-handle route from step 4 instead.

   A query that **is** captured can still look absent to a text search: `query_sql_text`
   stores the engine's parameterized form, not the literal text submitted. A query sent with
   a literal comparison value and a comment was stored, on this same engine, as
   `(@1 tinyint)SELECT COUNT(*) FROM [dbo].[q] WHERE [id]>@1`, with the comment gone. A
   `LIKE` search for the original literal value or comment returns nothing for a query that
   is genuinely there. Match on `object_id` for a procedure, or on the parameterized shape,
   rather than a `LIKE` search against the original literal SQL.

6. **Pull the small part, not the whole XML.** A two-operator plan measured here ran 7.8 KB
   as text; a two-table join with an aggregate and a sort ran 13 KB. Both numbers are
   already too large to justify pasting into a response. Query the XML column directly with
   XQuery instead of pulling the whole document to the client and parsing it there:

   ```sql
   SET QUOTED_IDENTIFIER ON;
   ```

   is required before any `.nodes()`, `.value()` or `.exist()` call against the plan
   column. Left off, the same call fails with `Msg 1934`, naming indexed views, computed
   columns, filtered indexes, query notifications and spatial indexes, the standard message
   for every feature that needs `QUOTED_IDENTIFIER` on, and it says nothing about XML data
   type methods or the session setting that is actually the cause. A client's default
   session may already have it off; set it explicitly rather than assuming.

   The full XQuery pattern, and what each attribute means, is in
   [references/dmv-and-xquery-reference.md](references/dmv-and-xquery-reference.md). Run
   it, on the same join plan above, to confirm the reduction: the operator list, the
   warnings flag, the missing-index hint and the memory grant together ran under 850
   characters, roughly six percent of the full plan.

## Reading what comes back

- **EstimateRows versus ActualRows, per operator.** A large gap means the optimizer's row
  estimate was wrong for that operator, from stale statistics, a correlated predicate, or a
  parameter-sensitive plan; it is the single most useful comparison in the plan and the
  reason to fetch actual, not estimated, numbers whenever the two can disagree.
- **Warnings**, when present, name a real problem on that operator: a sort or hash spill to
  disk, a join with no equality predicate, or an implicit conversion that changed the plan.
  Their absence is also information: no `<Warnings>` element on this engine, for the plans
  measured here, means none of those conditions fired.
- **MissingIndexes**, when present, is a single-query hint with an `Impact` percentage, not
  a mandate. It knows nothing about the rest of the workload, existing indexes it might
  duplicate, or write cost. Treat it as a lead to evaluate, never as something to apply
  automatically.
- **MemoryGrantInfo**, when present, carries `GrantedMemory` against `MaxUsedMemory`; a large
  gap between them signals an over-generous grant, and `MaxUsedMemory` at or above
  `GrantedMemory` signals a spill risk regardless of whether a `Warnings` element mentions
  one.

## Validation rules

- Estimated and actual were named explicitly before any row-count or timing claim was made.
- `sys.dm_exec_query_plan` was never presented as the actual plan; if actual numbers were
  needed, `sys.dm_exec_query_plan_stats` or a fresh `STATISTICS XML` run supplied them.
- `QUOTED_IDENTIFIER` was turned on before any XQuery method call against the plan XML.
- Absence from Query Store was treated as unresolved, never as proof a query did not run
  and never as something to wait out on a timer.
- A Query Store text search matched on `object_id` or the parameterized query shape, not a
  `LIKE` search against the original literal SQL.
- The response quoted the operator list, warnings, missing-index hint and memory grant, not
  the raw plan XML.
- A write statement's actual plan was retrieved with the re-execution flagged, never framed
  as a safe, side-effect-free check.

## Do not

- Do not report `EstimateRows` as what happened. Say "estimated" every time it is the only
  number available.
- Do not combine `SET SHOWPLAN_XML ON` or `SET STATISTICS XML ON` with any other statement
  in the same batch; the whole batch is rejected, not partially run.
- Do not run `SET STATISTICS XML ON` around an insert, update, delete or merge expecting a
  dry run. It executes the statement.
- Do not call `.nodes()`, `.value()` or `.exist()` on the plan XML before setting
  `QUOTED_IDENTIFIER ON`. The resulting error mentions everything except the real cause.
- Do not treat a `MissingIndexes` hint as an instruction to create the index.
- Do not paste the full plan XML into a response or into context "to be safe". Extract the
  fields above and quote those.
- Do not assume a query's absence from Query Store will resolve if you wait; one observation
  here suggested that, and a separate, more controlled check on the same engine found a
  query still absent after 30 executions. Go to the plan-handle route instead.
- Do not search `query_sql_text` with `LIKE` against the literal SQL you submitted; the
  stored text is parameterized and can differ enough that a real, captured query is missed.

## References

- [references/dmv-and-xquery-reference.md](references/dmv-and-xquery-reference.md): the
  full retrieval query for each source in the table above, the XQuery battery that extracts
  operators, warnings, missing indexes and the memory grant in one round trip, and what each
  plan XML attribute means. Read it while writing the actual retrieval query.
