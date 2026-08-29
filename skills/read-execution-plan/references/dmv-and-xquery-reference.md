# DMV and XQuery reference for execution plans

## Contents

- [Retrieval query for each source](#retrieval-query-for-each-source)
- [The XQuery battery](#the-xquery-battery)
- [Plan XML attributes, field by field](#plan-xml-attributes-field-by-field)
- [Sizes actually measured](#sizes-actually-measured)

## Retrieval query for each source

Every query below was run against a table of tens of thousands of rows with an index that
did not cover the filtered column, on this engine.

**Estimated plan, no execution.** Must be the only statement in its batch:

```sql
SET SHOWPLAN_XML ON;
GO
SELECT customer_id, COUNT(*) AS n, SUM(amount) AS total
FROM dbo.orders
WHERE status = 'open'
GROUP BY customer_id
HAVING COUNT(*) > 5
ORDER BY total DESC;
GO
SET SHOWPLAN_XML OFF;
GO
```

**Actual plan, executes the query.** Same one-statement-per-batch rule:

```sql
SET STATISTICS XML ON;
GO
SELECT customer_id, COUNT(*) AS n, SUM(amount) AS total
FROM dbo.orders
WHERE status = 'open'
GROUP BY customer_id
HAVING COUNT(*) > 5
ORDER BY total DESC;
GO
SET STATISTICS XML OFF;
GO
```

**Actual plan of a query already run, by object.** Turn the scoped configuration on once
per database, then look the plan up by object id rather than scanning the whole cache by
text; on a busy instance a `sys.dm_exec_query_stats` join to `sys.dm_exec_sql_text` filtered
with `LIKE` across every cached plan took several minutes, where the same lookup filtered by
`object_id` returned in under a second:

```sql
ALTER DATABASE SCOPED CONFIGURATION SET LAST_QUERY_PLAN_STATS = ON;

SELECT
  ps.execution_count,
  ps.total_logical_reads / ps.execution_count AS avg_logical_reads,
  qp.query_plan
FROM sys.dm_exec_procedure_stats ps
CROSS APPLY sys.dm_exec_query_plan_stats(ps.plan_handle) qp
WHERE ps.object_id = OBJECT_ID('dbo.<procedure_name>');
```

Confirmed on this engine: `sys.dm_exec_query_plan(ps.plan_handle)` in the same shape returns
a plan with zero occurrences of `ActualRows`, for the same already-executed procedure.
`sys.dm_exec_query_plan_stats` in its place returned a plan with `ActualRows` present on
every operator, and only after the scoped configuration above was turned on; before that it
returned zero rows, with no error.

**Query Store**, for a persisted history. Prefer matching on `object_id` (join
`sys.query_store_query` to the procedure or module, if there is one) over a `LIKE` search on
`query_sql_text`, for the reason given below:

```sql
SELECT qsq.query_id, qsqt.query_sql_text, qsrs.count_executions, qsrs.avg_duration,
       qsrs.avg_logical_io_reads, qsp.query_plan, qsp.is_forced_plan
FROM sys.query_store_query qsq
JOIN sys.query_store_query_text qsqt ON qsq.query_text_id = qsqt.query_text_id
JOIN sys.query_store_plan qsp ON qsp.query_id = qsq.query_id
JOIN sys.query_store_runtime_stats qsrs ON qsrs.plan_id = qsp.plan_id
WHERE qsq.object_id = OBJECT_ID('dbo.<procedure_name>');
```

`sys.database_query_store_options.actual_state_desc` read `READ_WRITE` on a freshly created
database with nothing configured, so this engine ships with Query Store already on.
`query_capture_mode_desc` read `AUTO`.

**What was actually observed about capture timing, stated as one data point, not a rule.**
A query executed three times in a row was absent from `sys.query_store_query` on an
immediate check and again eight seconds later. The same query text was present on a check
made roughly fifteen minutes later, after dozens of unrelated batches, including other
agents' concurrent sessions on this shared instance, had run in between. Execution count,
elapsed time and overall instance activity were never isolated from one another in that
observation, so it does not show that waiting is what closed the gap, only that the gap
closed at some point. A separate, more controlled check against this same engine ran a
simpler, auto-parameterizable query 4 times, then 30 times, including an explicit
`sp_query_store_flush_db` between checks, and the query stayed absent from
`sys.query_store_query` throughout. The two observations do not agree on what makes AUTO
capture a query, and neither pins the mechanism down. **Treat a query's absence from Query
Store as unresolved, never as proof it did not run, and do not wait on it or retry on a
timer**; use the plan-handle route above, which does not depend on Query Store's capture
policy at all.

**A captured query can still look absent to a `LIKE` search.** `query_sql_text` stores the
form the engine parameterized, not the literal text submitted. On this engine, a query
submitted with a literal comparison value and a trailing comment was stored as:

```
(@1 tinyint)SELECT COUNT(*) FROM [dbo].[q] WHERE [id]>@1
```

with the comment gone and the literal replaced by a parameter. A `LIKE` search for the
original literal value, or for the comment, returns zero rows for a query that is genuinely
captured. Match on `object_id`, as above, or on the parameterized shape you expect the
engine to produce, rather than the exact string you submitted.

## The XQuery battery

Pulling the whole plan document to the client and parsing it there is the expensive path.
Querying the `xml`-typed plan column directly, with XQuery, returns only the fields that
carry signal. This requires `QUOTED_IDENTIFIER ON` in the session; without it, `.nodes()`,
`.value()` and `.exist()` all fail with `Msg 1934`, an error that names indexed views,
computed columns, filtered indexes, query notifications and spatial indexes and does not
mention XML methods or the session setting at all. A client's default session may already
have it off; confirmed on this engine's default client session, `SESSIONPROPERTY('QUOTED_IDENTIFIER')`
read `0`.

Per-operator estimate versus actual, in one round trip:

```sql
SET QUOTED_IDENTIFIER ON;
GO
;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
SELECT
  n.value('@NodeId', 'int') AS NodeId,
  n.value('@PhysicalOp', 'varchar(50)') AS PhysicalOp,
  n.value('@EstimateRows', 'float') AS EstRows,
  n.value('(.//RunTimeCountersPerThread/@ActualRows)[1]', 'float') AS ActualRows,
  n.value('(.//Warnings)[1]', 'varchar(200)') AS WarningPresent
FROM sys.dm_exec_procedure_stats ps
CROSS APPLY sys.dm_exec_query_plan_stats(ps.plan_handle) qp
CROSS APPLY qp.query_plan.nodes('//RelOp') AS t(n)
WHERE ps.object_id = OBJECT_ID('dbo.<procedure_name>')
ORDER BY NodeId;
GO
```

Plan-level summary, in the same round trip shape:

```sql
;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
SELECT
  qp.query_plan.exist('//Warnings') AS HasWarnings,
  qp.query_plan.exist('//MissingIndexes') AS HasMissingIndex,
  qp.query_plan.value('(//MemoryGrantInfo/@GrantedMemory)[1]', 'int') AS GrantedMemoryKB
FROM sys.dm_exec_procedure_stats ps
CROSS APPLY sys.dm_exec_query_plan_stats(ps.plan_handle) qp
WHERE ps.object_id = OBJECT_ID('dbo.<procedure_name>');
```

Run against a two-table join with a filter, an aggregate and a sort, on this engine, the
first query returned 6 rows and the second returned a single row reading `HasWarnings = 0`,
`HasMissingIndex = 1`, `GrantedMemoryKB = 2672`. Combined, both results ran under 850
characters, against a full plan document of roughly 13,150 characters for the same plan,
about six percent of the size.

## Plan XML attributes, field by field

| Attribute | Where | Meaning |
|---|---|---|
| `PhysicalOp` / `LogicalOp` | `RelOp` | The operator the engine chose, and the relational operation it implements. When these differ (a `Hash Match` implementing an `Aggregate`, for example) the physical choice is the one to question. |
| `EstimateRows` | `RelOp` | Compile-time row estimate for that operator. Present on every plan, estimated or actual. |
| `ActualRows` | `RunTimeCountersPerThread`, nested under `RelOp` | Only present on an actual plan. A wide gap against `EstimateRows` on the same operator is the strongest single signal in the document. |
| `Warnings` | Child of `RelOp`, only present when triggered | Spills, missing join predicates, and plan-affecting implicit conversions surface here. Its absence, on the plans measured for this skill, meant none of those conditions fired; it does not mean the plan is optimal. |
| `MissingIndexes` / `MissingIndexGroup` `Impact` | Under `QueryPlan`, sibling of the operator tree | A single-query suggestion with an estimated percentage improvement. It has no visibility into the rest of the workload or existing indexes. |
| `MemoryGrantInfo` `GrantedMemory` / `MaxUsedMemory` | Under `QueryPlan` | Granted and actually used memory, in kilobytes. `MaxUsedMemory` approaching or exceeding `GrantedMemory` signals spill risk even with no `Warnings` element present. |
| `IsMemoryGrantFeedbackAdjusted` | `MemoryGrantInfo` | Whether the engine already adjusted this grant from a previous execution's feedback. Read as `"No: Accurate Grant"` on a first-time plan measured here. |

## Sizes actually measured

| Query shape | Source | Size |
|---|---|---|
| Single table, filter, aggregate, sort | Estimated (`SHOWPLAN_XML`) | 7,816 characters |
| Single table, filter, aggregate, sort | Actual (`STATISTICS XML`) | 9,758 characters |
| Two-table join, filter, aggregate, sort | Actual, via `dm_exec_query_plan_stats` | 13,150 characters |
| Same two-table join | The XQuery battery result, both queries combined | Under 850 characters |

A default client tool may truncate `nvarchar(max)`/`xml` output to a fixed display width;
retrieving the full document as text needs that truncation turned off, separately from
everything above. The XQuery battery avoids the question entirely, because the reduction
happens on the server and only the small result crosses the wire.
