# Query identity, cache and history lookup

These are
bounded query patterns, not instructions to run every query. Bind or safely quote
user values, use the connected database, and retain ambiguity in the answer.
All examples are read-only; none executes the user's workload.

## Capability and coverage

Read `sys.database_query_store_options` for actual/desired state, read-only reason,
capture mode and retention. Do not enable Query Store to satisfy a lookup.
SQL Server 2022+ uses `VIEW SERVER PERFORMANCE STATE` for plan-cache DMVs and
`VIEW DATABASE PERFORMANCE STATE` for Query Store runtime views; older SQL Server
uses the corresponding STATE permissions. Permission errors mean unavailable,
not empty history. Azure SQL has different server/database scope; use supported
database-scoped capabilities and report restrictions.

## Resolve the statement

- An explicit Query Store `query_id` is scoped to this database. Retrieve its text,
  `object_id`, `context_settings_id` and `query_hash` before crossing to cache.
- A plan handle can own several statements. Use statement offsets to extract the
  intended statement. Ask about genuinely unresolved choices; do not pick the
  first statement. An evicted handle cannot establish past nonexecution.
- For text, search for a distinctive bounded fragment, inspect returned statement
  text, and exclude the diagnostic lookup itself. Preserve literal values and
  object/context identity. An exact supplied query ID does not need a broad
  same-hash search.
- If available, `match_queries_by_canonical_form` can compare multiple candidate
  IDs in one call. Otherwise compare a bounded set of texts locally. Matching
  formatting is not semantic equivalence: the canonicalizer preserves literals
  and identifier spelling but does not resolve collation or SET context.
- A hash narrows candidates; it is not unique proof. Keep multiple matched
  query/context IDs separate. Do not collapse them into one history silently.

For an exact Query Store ID (replace 123 with the requested ID):

```sql
DECLARE @QueryId bigint = 123;
SELECT q.query_id, q.object_id, q.context_settings_id,
       CONVERT(varchar(20),q.query_hash,1) AS query_hash_hex,
       qt.query_sql_text
FROM sys.query_store_query AS q
JOIN sys.query_store_query_text AS qt ON qt.query_text_id=q.query_text_id
WHERE q.query_id=@QueryId;
```

When only text is known, use a bounded text search in Query Store and cache. Escape
LIKE wildcards if they are literal parts of the supplied text. Do not compile
merely to get a hash if existing history already resolves the statement.

## Current cache

Use the resolved hash below. The zero hash is a placeholder, not a useful query.
Database proof may come from text metadata or the plan's `dbid` attribute; NULL
alone never means the connected database. Return offsets and statement text to
separate statements in multi-statement batches. Values are cumulative since each
cache entry's creation, not the historical interval selected below.

```sql
DECLARE @QueryHash binary(8) = 0x0000000000000000;
SELECT TOP (20) qs.plan_handle, qs.sql_handle,
       qs.statement_start_offset, qs.statement_end_offset,
       SUBSTRING(st.text, qs.statement_start_offset/2+1,
         (CASE qs.statement_end_offset WHEN -1 THEN DATALENGTH(st.text)
          ELSE qs.statement_end_offset END-qs.statement_start_offset)/2+1) AS statement_text,
       CONVERT(varchar(20),qs.query_plan_hash,1) AS plan_hash_hex,
       qs.execution_count, qs.creation_time, qs.last_execution_time,
       1.0*qs.total_worker_time/NULLIF(qs.execution_count,0)/1000 AS avg_cpu_ms,
       1.0*qs.total_elapsed_time/NULLIF(qs.execution_count,0)/1000 AS avg_duration_ms,
       1.0*qs.total_logical_reads/NULLIF(qs.execution_count,0) AS avg_logical_reads
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
WHERE qs.query_hash=@QueryHash
  AND (st.dbid=DB_ID() OR (st.dbid IS NULL AND EXISTS (
       SELECT 1 FROM sys.dm_exec_plan_attributes(qs.plan_handle) AS pa
       WHERE pa.attribute=N'dbid' AND TRY_CONVERT(int,pa.value)=DB_ID())))
ORDER BY qs.last_execution_time DESC
OPTION (MAXDOP 1);
```

Report truncation when the candidate set exceeds the bound. Obtain XML with
`sys.dm_exec_query_plan` only for the selected handle when it helps the question.
A different plan hash may reflect parameter/context differences, not a regression.

## Query Store runtime intervals

Replace the query ID and UTC bounds. Keep execution types separate (0 regular,
3 aborted, 4 exception). Multiple rows can represent a single active interval;
aggregate by plan, interval and execution type. Never average averages without
execution weights. Duration/CPU are microseconds; reads are page counts.
An overlapping interval contains executions outside a requested partial interval;
report that granularity rather than claiming exact sub-interval measurements.

```sql
DECLARE @QueryId bigint = 123;
DECLARE @From datetimeoffset = '2026-01-01T00:00:00+00:00';
DECLARE @To datetimeoffset = '2026-01-02T00:00:00+00:00';
SELECT p.query_id, p.plan_id, rs.execution_type,
       i.runtime_stats_interval_id, i.start_time, i.end_time,
       SUM(rs.count_executions) AS executions,
       SUM(rs.avg_duration*rs.count_executions)/NULLIF(SUM(rs.count_executions),0)/1000.0 AS avg_duration_ms,
       SUM(rs.avg_cpu_time*rs.count_executions)/NULLIF(SUM(rs.count_executions),0)/1000.0 AS avg_cpu_ms,
       SUM(rs.avg_logical_io_reads*rs.count_executions)/NULLIF(SUM(rs.count_executions),0) AS avg_logical_reads,
       MIN(rs.first_execution_time) AS first_execution_time,
       MAX(rs.last_execution_time) AS last_execution_time
FROM sys.query_store_plan AS p
JOIN sys.query_store_runtime_stats AS rs ON rs.plan_id=p.plan_id
JOIN sys.query_store_runtime_stats_interval AS i
  ON i.runtime_stats_interval_id=rs.runtime_stats_interval_id
WHERE p.query_id=@QueryId AND i.start_time<@To AND i.end_time>@From
GROUP BY p.query_id,p.plan_id,rs.execution_type,
         i.runtime_stats_interval_id,i.start_time,i.end_time
ORDER BY i.start_time,p.plan_id,rs.execution_type;
```

Retrieve selected `sys.query_store_plan.query_plan` XML when plan comparison is
requested. Forced-plan status is a configuration fact, not proof that every
execution used that plan; inspect failure/forcing state where relevant.

Present cache and Query Store populations separately. Query Store survives cache
eviction but its capture mode, retention, cleanup, read-only state and permissions
limit coverage. Missing rows do not prove nonexecution. Establish comparable
workload, parameters and periods before claiming a performance change.

Sources: [runtime statistics and active-interval aggregation](https://learn.microsoft.com/sql/relational-databases/system-catalog-views/sys-query-store-runtime-stats-transact-sql),
[query cache counters](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-views/sys-dm-exec-query-stats-transact-sql).
