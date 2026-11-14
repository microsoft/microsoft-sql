# DMV and XQuery reference for execution plans

## Contents

- [Retrieval query for each source](#retrieval-query-for-each-source)
- [When the plan comes back NULL, a stub, or a root node only](#when-the-plan-comes-back-null-a-stub-or-a-root-node-only)
- [Who is allowed to read a plan](#who-is-allowed-to-read-a-plan)
- [The XQuery battery](#the-xquery-battery)
- [Plan XML attributes, field by field](#plan-xml-attributes-field-by-field)
- [Plan sizes](#plan-sizes)

## Retrieval query for each source

The queries below assume a table of tens of thousands of rows with an index that does not cover
the filtered column.

**Estimated or actual by re-running.** This is the query behind the sizes table at the end. Swap
`SHOWPLAN_XML` for `STATISTICS XML` to get the actual plan; the
one-statement-per-batch rule and the `Msg 1067` on breaking it are identical for both:

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

**Actual plan of a query already run, by object.** Turn the scoped configuration on once per
database, then look the plan up by object id, not by scanning the cache. On a busy instance a
`sys.dm_exec_query_stats` join to `sys.dm_exec_sql_text` filtered with `LIKE` across every
cached plan can take minutes; filtered by `object_id` it returns in under a second:

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

`sys.dm_exec_query_plan(ps.plan_handle)` in the same shape returns a plan with zero occurrences
of `ActualRows` for the same already-executed procedure. `sys.dm_exec_query_plan_stats` in its
place returns `ActualRows` on every operator, but only once the scoped configuration above is on;
before that, zero rows and no error.

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

On a freshly created database with nothing configured,
`sys.database_query_store_options.actual_state_desc` reads `READ_WRITE` and
`query_capture_mode_desc` reads `AUTO`: Query Store ships on. Learn documents `AUTO` as the SQL
Database default and `ALL` as the SQL Server default, and says Query Store cannot be turned off
here at all: `SET QUERY_STORE = OFF` returns a warning and leaves it running.

**Capture timing under `AUTO` is not something to reason from.** A query run a few times can be
absent from `sys.query_store_query` immediately, and can stay absent through more executions and
an explicit `sp_query_store_flush_db`; a query can also appear much later, with no clear link to
execution count, elapsed time or instance activity. **Treat absence from Query Store as
unresolved, never as proof the query did not run, and do not wait on it or retry on a timer**; the
plan-handle route above does not depend on the capture policy at all.

**A captured query can still look absent to a `LIKE` search.** `query_sql_text` stores the
parameterized form, not the text submitted. A query with a literal comparison value and a trailing
comment is stored as:

```
(@1 tinyint)SELECT COUNT(*) FROM [dbo].[q] WHERE [id]>@1
```

with the comment gone and the literal replaced by a parameter. A `LIKE` search for the literal
or the comment returns zero rows for a query that is genuinely captured. Match on `object_id`,
as above, or on the parameterized shape you expect, not the string you submitted.

## When the plan comes back NULL, a stub, or a root node only

Four silent outcomes, all documented on the Learn pages for
[sys.dm_exec_query_plan](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-objects/sys-dm-exec-query-plan-transact-sql)
and
[sys.dm_exec_query_plan_stats](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-objects/sys-dm-exec-query-plan-stats-transact-sql).

| What you see | Cause | Instead |
|---|---|---|
| `query_plan` is `NULL` | The plan meets 128 levels of nested elements, past what the `xml` type holds. Older engines raised error 6335; current ones return `NULL` | `sys.dm_exec_text_query_plan`, below: `nvarchar(max)`, no nesting limit |
| `query_plan` is `NULL` | Evicted, or never cacheable: bulk operations, and statements carrying string literals over 8 KB | Re-run under `SET STATISTICS XML ON`; the cache has nothing to give |
| `query_plan` holds statement text, no operator tree | An ad hoc query that used simple or forced parameterization; the plan sits under the prepared statement | Fetch the prepared query's plan handle, not the ad hoc one |
| `_plan_stats` returns a root node and no `RelOp` | The engine judged the query simple, typically OLTP shaped, and returned a simplified Showplan | Nothing is broken. For the operator tree, re-run under `SET STATISTICS XML ON` |

The text form of the same plan. `0, -1` asks for the whole batch rather than one statement's
offsets:

```sql
SELECT ps.execution_count, tqp.query_plan
FROM sys.dm_exec_procedure_stats ps
CROSS APPLY sys.dm_exec_text_query_plan(ps.plan_handle, 0, -1) tqp
WHERE ps.object_id = OBJECT_ID('dbo.<procedure_name>');
```

## Who is allowed to read a plan

Neither is implied by `SELECT`, and this failure is loud: a permission error, not an empty
result.

| To do this | You need |
|---|---|
| `SET SHOWPLAN_XML`, `SET STATISTICS XML`, `SET STATISTICS PROFILE` | `SHOWPLAN` on every database holding an object the statement references: `GRANT SHOWPLAN TO [user];` |
| `sys.dm_exec_query_plan`, `_plan_stats`, `_statistics_xml`, `_text_query_plan` | `VIEW DATABASE STATE`, or membership in the `##MS_ServerStateReader##` server role |
| The same views on a Basic, S0, S1 or elastic pool database | `VIEW DATABASE STATE` is not enough. Server admin, Microsoft Entra admin, or `##MS_ServerStateReader##` |

## The XQuery battery

Querying the `xml`-typed plan column directly returns only the fields that carry signal.
Requires `QUOTED_IDENTIFIER ON`. In a client session that leaves it off, such as the ODBC
`sqlcmd` without `-I`, `SESSIONPROPERTY('QUOTED_IDENTIFIER')` reads `0`, and `.nodes()`,
`.value()` and `.exist()` then all fail with `Msg 1934`.

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

Against a two-table join with a filter, an aggregate and a sort, the first query returns one row
per operator and the second a single row, for example `HasWarnings = 0`, `HasMissingIndex = 1`
and the grant in kilobytes. Combined, both results are a small fraction of the full plan document
for the same plan.

## Plan XML attributes, field by field

| Attribute | Where | Meaning |
|---|---|---|
| `PhysicalOp` / `LogicalOp` | `RelOp` | The operator the engine chose, and the relational operation it implements. When these differ (a `Hash Match` implementing an `Aggregate`, for example) the physical choice is the one to question. |
| `EstimateRows` | `RelOp` | Compile-time row estimate for that operator. Present on every plan, estimated or actual. |
| `ActualRows` | `RunTimeCountersPerThread`, nested under `RelOp` | Only present on an actual plan. A wide gap against `EstimateRows` on the same operator is the strongest single signal in the document. |
| `Warnings` | Child of `RelOp`, only present when triggered | Spills, missing join predicates, and plan-affecting implicit conversions surface here. Its absence means none of those conditions fired; it does not mean the plan is optimal. |
| `MissingIndexes` / `MissingIndexGroup` `Impact` | Under `QueryPlan`, sibling of the operator tree | A single-query suggestion with an estimated percentage improvement. It has no visibility into the rest of the workload or existing indexes. |
| `MemoryGrantInfo` `GrantedMemory` / `MaxUsedMemory` | Under `QueryPlan` | Granted and actually used memory, in kilobytes. `MaxUsedMemory` approaching or exceeding `GrantedMemory` signals spill risk even with no `Warnings` element present. |
| `IsMemoryGrantFeedbackAdjusted` | `MemoryGrantInfo` | Whether the engine already adjusted this grant from a previous execution's feedback. A first-time plan can read `"No: Accurate Grant"`. |

## Plan sizes

| Query shape | Source | Size |
|---|---|---|
| Single table, filter, aggregate, sort | Estimated (`SHOWPLAN_XML`) | several thousand characters |
| Single table, filter, aggregate, sort | Actual (`STATISTICS XML`) | larger than the estimated plan |
| Two-table join, filter, aggregate, sort | Actual, via `dm_exec_query_plan_stats` | over ten thousand characters |
| Same two-table join | The XQuery battery result, both queries combined | under a thousand characters |

A client truncates `nvarchar(max)` and `xml` output to a fixed display width, so the full
document needs that turned off separately. The XQuery battery avoids the question: the
reduction happens on the server and only the small result crosses the wire.
