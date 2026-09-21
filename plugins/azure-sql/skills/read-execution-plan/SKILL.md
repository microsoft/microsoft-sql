---
name: read-execution-plan
description: >-
  Retrieves an Azure SQL Database execution plan, estimated or actual, and pulls out the
  small set of facts that explain slowness: operators, estimated versus actual row counts,
  warnings, missing-index hints, and the memory grant, instead of returning the whole plan
  XML. Use when someone says "read this execution plan", "why did the optimizer choose a
  scan here", "show me the actual plan not the estimated one", or hands over a plan and asks
  what is wrong with it. Also covers retrieval itself: SET SHOWPLAN_XML, SET STATISTICS XML,
  the plan-handle views, and Query Store, and the several ways a same-looking call returns
  the wrong kind of plan, a stub, or NULL without raising an error. Not general slow-query
  triage (diagnose-slow-query), lock analysis (diagnose-blocking-and-deadlocks), or
  instance-level CPU or memory pressure (diagnose-resource-pressure).
---

# Read an Azure SQL Database execution plan

Gets the plan that explains a query, in the smallest form that carries the signal, and tells
estimated numbers from measured ones. Measured 2026-08-29 against a live engine
reporting `EngineEdition` 5 and Edition `SQL Azure`; claims one session cannot measure are
attributed to Microsoft Learn inline.

## Estimated is not actual, and the sources disagree about which you get

| Source | Returns | Runs the query? |
|---|---|---|
| `SET SHOWPLAN_XML ON` | Estimated plan only | No |
| `SET STATISTICS XML ON` | Actual plan, `ActualRows` on every operator | Yes, for real |
| `sys.dm_exec_query_plan` | Estimated plan only, even after the query has run | No |
| `sys.dm_exec_query_plan_stats` | Last execution's actual plan | No, but off by default |
| `sys.dm_exec_query_statistics_xml` | Actual plan of a query running right now | No |
| `sys.query_store_plan` plus `sys.query_store_runtime_stats` | Actual plan and aggregated stats, persisted | No |

`sys.dm_exec_query_plan` is the trap. It returns without error for a plan whose query has run
thousands of times, and the XML still carries zero occurrences of `ActualRows`. Reporting its
numbers as what happened is the wrong turn this skill exists for.

## Retrieval, in order

**1. Estimated plan, no execution.** A `SET SHOWPLAN` statement must be the only statement in
its batch, and cannot be used inside a stored procedure ([Learn](https://learn.microsoft.com/sql/t-sql/statements/set-showplan-xml-transact-sql)).
Pair it with anything else and the whole batch fails with `Msg 1067`, `The SET SHOWPLAN
statements must be the only statements in the batch`; nothing runs, not even the first half.

```sql
SET SHOWPLAN_XML ON;
GO
SELECT status, COUNT(*) FROM dbo.orders WHERE status = 'open' GROUP BY status;
GO
SET SHOWPLAN_XML OFF;
GO
```

**2. Actual plan by re-running.** Same batch rule, and it executes the query for real. Never
wrap an insert, update, delete or merge in it expecting a dry run.

```sql
SET STATISTICS XML ON;
GO
SELECT status, COUNT(*) FROM dbo.orders WHERE status = 'open' GROUP BY status;
GO
SET STATISTICS XML OFF;
GO
```

**3. Actual plan without re-running.** `sys.dm_exec_query_plan_stats` returns the last real
execution, and is silent about why it looks empty: the scoped configuration
`LAST_QUERY_PLAN_STATS` defaults to `OFF` ([Learn](https://learn.microsoft.com/sql/t-sql/statements/alter-database-scoped-configuration-transact-sql)),
and while it is off the view returns zero rows for every plan with no error. Turn it on once
per database, then look the plan up by object id rather than scanning the cache by text:

```sql
ALTER DATABASE SCOPED CONFIGURATION SET LAST_QUERY_PLAN_STATS = ON;

SELECT ps.execution_count, qp.query_plan
FROM sys.dm_exec_procedure_stats AS ps
CROSS APPLY sys.dm_exec_query_plan_stats(ps.plan_handle) AS qp
WHERE ps.object_id = OBJECT_ID('dbo.<procedure_name>');
```

**4. A query still running**, where there is no finished plan to fetch:

```sql
SELECT r.session_id, qs.query_plan
FROM sys.dm_exec_requests AS r
CROSS APPLY sys.dm_exec_query_statistics_xml(r.session_id) AS qs
WHERE r.session_id <> @@SPID;
```

**5. Query Store**, for history and forced plans. Already on, and it cannot be turned off:
`ALTER DATABASE CURRENT SET QUERY_STORE = OFF` returns the warning `'QUERY_STORE=OFF' is
supported in this version of SQL Server` and leaves it running ([Learn](https://learn.microsoft.com/sql/relational-databases/performance/manage-the-query-store)).
Advice telling you to enable it was written for SQL Server, which also defaults
`QUERY_CAPTURE_MODE` to `ALL` where Azure SQL Database defaults to `AUTO`. Under `AUTO` a
query can be absent from `sys.query_store_query` after several executions: unresolved, never
proof it did not run, and not worth waiting on. Use step 3. Match on `object_id`, not a `LIKE`
search against the SQL you submitted, because `query_sql_text` stores the parameterized form:
a literal and a trailing comment came back here as
`(@1 tinyint)SELECT COUNT(*) FROM [dbo].[q] WHERE [id]>@1`.

**6. Pull the small part, not the whole XML.** A two-operator plan measured here was 7.8 KB
and a two-table join 13 KB, both too large to paste into a response. Reduce on the server.
Every `.nodes()`, `.value()` and `.exist()` call needs `QUOTED_IDENTIFIER ON`, which a
client's default session may have off; without it the call fails with `Msg 1934`, an error
naming indexed views, computed columns, filtered indexes, query notifications and spatial
indexes, and never the setting that caused it.

```sql
SET QUOTED_IDENTIFIER ON;
GO
;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
SELECT n.value('@NodeId', 'int') AS NodeId,
       n.value('@PhysicalOp', 'varchar(50)') AS PhysicalOp,
       n.value('@EstimateRows', 'float') AS EstRows,
       n.value('(.//RunTimeCountersPerThread/@ActualRows)[1]', 'float') AS ActualRows
FROM sys.dm_exec_procedure_stats AS ps
CROSS APPLY sys.dm_exec_query_plan_stats(ps.plan_handle) AS qp
CROSS APPLY qp.query_plan.nodes('//RelOp') AS t(n)
WHERE ps.object_id = OBJECT_ID('dbo.<procedure_name>')
ORDER BY NodeId;
```

Open [references/dmv-and-xquery-reference.md](references/dmv-and-xquery-reference.md) before
writing the retrieval query, to get the plan-level half of this battery (warnings,
missing-index hint, memory grant) and what each plan XML attribute means.

## Four ways a plan comes back empty or wrong, with no error

- **`query_plan` is NULL at 128 levels of nesting.** The `xml` type's nesting limit means
  `sys.dm_exec_query_plan` cannot return a deeply nested plan and returns NULL instead of
  raising [error 6335](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-objects/sys-dm-exec-query-plan-transact-sql).
  `sys.dm_exec_text_query_plan(plan_handle, 0, -1)` returns the same plan as text and has no
  such limit. Reach for it whenever `query_plan` is NULL on a plan you know exists.
- **The plan is a stub.** For an ad hoc query using simple or forced parameterization,
  `query_plan` holds the statement text and no operator tree. Fetch the plan handle of the
  prepared parameterized query instead.
- **`query_plan_stats` returns a root node only.** For a query the engine judges simple,
  typically OLTP shaped, it returns a Showplan holding just the `SELECT` node. No `RelOp` rows
  is a real answer from a real plan, not a broken query.
- **The plan was evicted, or never cached.** Bulk operations and statements carrying string
  literals over 8 KB are never cached, so no plan-handle route reaches them.

Two permissions gate all of this and neither is implied by `SELECT`: the `SET` options need
`SHOWPLAN` on every database holding a referenced object, the views need `VIEW DATABASE
STATE`, and on Basic, S0, S1 and elastic pool databases they need `##MS_ServerStateReader##`.

## Check it worked

```sql
SELECT SESSIONPROPERTY('QUOTED_IDENTIFIER') AS quoted_identifier,
       (SELECT value FROM sys.database_scoped_configurations
        WHERE name = 'LAST_QUERY_PLAN_STATS') AS last_query_plan_stats;
```

Both must read `1`. A `0` in the first column is the `Msg 1934` coming; a `0` in the second is
step 3's empty result set, which you would misread as "no plan".

Then confirm the plan is the kind you asked for. One string tells them apart, so ask the plan
rather than the view's name:

```sql
SELECT CASE WHEN CAST(qp.query_plan AS nvarchar(max)) LIKE '%ActualRows%'
            THEN 'actual' ELSE 'estimated' END AS plan_kind
FROM sys.dm_exec_procedure_stats AS ps
CROSS APPLY sys.dm_exec_query_plan_stats(ps.plan_handle) AS qp
WHERE ps.object_id = OBJECT_ID('dbo.<procedure_name>');
```

`estimated` means those row counts are guesses and every claim from them must say so. Zero
rows means step 3's configuration is still off, or the plan left the cache.

If you do pull the whole document to a client, `xml` truncates at 256 characters by default
and a truncated plan parses as a corrupt one. Per `sqlcmd 1.10.0` help and
[Learn](https://learn.microsoft.com/sql/tools/sqlcmd/sqlcmd-utility), `-y` sets that width and
`0` removes the cap:

```bash
sqlcmd -y 0 -Q "SELECT CAST(qp.query_plan AS nvarchar(max)) FROM sys.dm_exec_cached_plans cp
CROSS APPLY sys.dm_exec_query_plan(cp.plan_handle) qp WHERE cp.objtype = 'Proc'"
```

Step 6 avoids the question: the reduction happens on the server.

## Reading what comes back

- **`EstimateRows` against `ActualRows`, per operator.** A large gap means the estimate was
  wrong there, from stale statistics, a correlated predicate, or a parameter-sensitive plan.
  It is the most useful comparison in the document.
- **`Warnings`**, when present, names a real problem on that operator: a sort or hash spill, a
  join with no equality predicate, an implicit conversion that changed the plan. Its absence
  means none of those fired, not that the plan is fine.
- **`MissingIndexes`** is a single-query hint with an `Impact` percentage, blind to the rest
  of the workload, indexes it would duplicate, and write cost. It is a lead.
- **`MemoryGrantInfo`** carries `GrantedMemory` against `MaxUsedMemory`. A wide gap is an
  over-generous grant; `MaxUsedMemory` at or above `GrantedMemory` is spill risk even with no
  `Warnings` element.

## Do not

- Do not report `EstimateRows` as what happened. Say "estimated" every time it is the only
  number you have, and never present `sys.dm_exec_query_plan` output as the actual plan.
- Do not put a `SET SHOWPLAN` or `SET STATISTICS XML` statement in a batch with anything else,
  or inside a stored procedure. The batch is rejected whole, not run in part.
- Do not run `SET STATISTICS XML ON` around a write expecting a dry run. It runs.
- Do not call `.nodes()`, `.value()` or `.exist()` before `SET QUOTED_IDENTIFIER ON`.
- Do not treat a `MissingIndexes` hint as instruction to create it.
- Do not paste the full plan XML into a response or into context "to be safe".
- Do not read a NULL `query_plan`, a root-only plan, or an absence from Query Store as an
  error or as proof the query never ran. Each has a documented cause above, and none of them
  is fixed by waiting.

## References

- [references/dmv-and-xquery-reference.md](references/dmv-and-xquery-reference.md), when you
  need the full retrieval query for a source in the table above, the rest of the XQuery
  battery, or the meaning of a plan XML attribute you are about to quote.
