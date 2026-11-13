# Wait Category Analysis — Root Cause Guide

## Root Cause Decision Tree

This is the prescriptive decision tree for determining the primary root cause. Use the **dominant wait category** (the one with the highest total wait time across all affected queries):

### If Lock is dominant:
> **Blocking** is the primary cause of intermittent slowness. Queries are waiting to acquire locks held by other sessions. This typically happens when one session holds a transaction open while other sessions try to access the same data, or when there are long-running transactions that cause locks to be held for extended periods.

{{Run {{`check-live-blocking`}} skill}}.
{{Run {{`query-store-volatile-historical-slow-queries-comparison`}} skill}} (Step 2) with the suspect query ID to compare slow vs fast intervals.

**Recommended Next Steps:**
1. Detect the query causing the head block and tune it to improve performance and lower resource utilization by applying standard query‑optimization practices, including reducing large scans, slow I/O, and tempdb usage.
2. If blocking is intermittent and cannot be caught live, set up passive monitoring using the {{`create-xe-session`}} skill filtered to the suspect query to capture the blocker's identity next time it occurs.
3. After the XE session captures data, run the {{`blocking-root-cause-analysis`}} skill for full analysis.
4. {{if MAXDOP setting is 0 (unlimited), consider setting it to a reasonable value (e.g., 4 or 8) to reduce the likelihood of long-running queries holding locks for extended periods.}}

### If CPU is dominant:
> **CPU contention** is the primary cause. Queries are spending excessive time on CPU, which could be caused by plan regressions, parameter sniffing, resource throttling, or genuinely expensive queries.

{{If Plan Count > 1 this indicates plan regression or parameter sniffing. Run  {{`query-store-volatile-historical-slow-queries-comparison`}} skill (Step 1) to identify which queries are affected}}.
{{Run {{`query-store-volatile-historical-slow-queries-comparison`}} skill}} (Step 2) with suspect query IDs to identify when the CPU spike started.
**Recommended Next Steps:**
1. Look for queries with high Avg CPU Time relative to Avg Duration — a ratio close to 1.0 means the query is truly CPU-bound
2. Consider forcing a known-good execution plan via `sp_query_store_force_plan`
3. Review parameter sniffing: check if the query uses parameters that cause vastly different data distributions.
4. Check if statistics are up to date, as outdated stats can lead to bad plans that consume more CPU.

### If IO is dominant:
> **IO contention** is the primary cause. Queries are waiting for data pages to be read from disk, which could be caused by missing indexes, resource throttling, large table scans, or competing I/O-heavy workloads.

{{Run {{`missing-index-analysis`}} skill}} to check for missing index recommendations on affected queries.

**Recommended Next Steps:**
1. Check if statistics are up to date, as outdated stats can lead to inefficient plans with high IO.
2. Review the queries' logical reads — high logical reads often indicate full table scans or inefficient access patterns
3. If Azure SQL, check the resource limits (DTU/vCore IO limits) are being hit
4. Consider adding covering indexes to eliminate key lookups
5. Consider grouping separate transactions into batches to consolidate IO costs.
6. {{if PAGEIOLATCH_ it points to an IO issue. If there is no IO in the page latch wait name, it points to a different type of problem (for example, tempdb contention). if LOG_RATE_GOVERNOR, POOL_LOG_RATE_GOVERNOR, and WRITELOG, these indicate more of log IO issues}}

### If Memory is dominant:
> **Memory grant issues** are the primary cause. Queries are requesting more memory than available for sorting or hashing operations, often due to bad cardinality estimates causing over- or under-estimation of required memory.

**Recommended Next Steps:**
1. Review the affected queries' execution plans for Sort or Hash warnings
2. Check for outdated statistics that could cause bad cardinality estimates (`UPDATE STATISTICS`)
3. Look for queries with high memory grants relative to actual memory used
4. Consider enabling Memory Grant Feedback if available on your SQL version

### If Latch / PAGELATCH is dominant:
> **Latch contention** is the primary cause. PAGELATCH_* waits are lightweight synchronization waits on in-memory data pages — not memory grant pressure. Common causes include last-page insert contention on tables with ever-increasing keys (IDENTITY/SEQUENCE), tempdb allocation bitmap hotspots (PFS/GAM/SGAM pages), and page splits from fragmented indexes.

{{Run Step 5 (PAGELATCH Contention Diagnostic) to identify the specific pages and contention type.}}

**Recommended Next Steps:**
1. If contention is on tempdb PFS/GAM/SGAM pages, add more tempdb data files (one per logical CPU, up to 8)
2. If contention is last-page insert on a user table, consider a non-sequential clustering key (e.g., GUID, hash partition) or enabling optimized locking (SQL Server 2022+)
3. If page splits are the cause, review fill factor settings and index fragmentation
4. For high-concurrency INSERT workloads, consider partitioning the target table to spread inserts across multiple pages

### If Network is dominant:
> **Network latency** is the primary cause. Queries may be completing quickly on the server but spending significant time transferring results to the client.

**Recommended Next Steps:**
1. Check if affected queries return large result sets that could be filtered or paginated.
2. Investigate client-side network connectivity.
3. Consider reducing result set sizes with more selective WHERE clauses or pagination.
4. Consider checking the client side code for inefficient data retrieval patterns (e.g., N+1 queries).

## No Wait Data Found

If the query returns no rows:
- State: "No wait statistics found in Query Store for the specified lookback period."
- This could mean Query Store wait stats collection is not enabled, or the lookback period has no data.
- Suggest checking if wait stats capture is enabled: `SELECT actual_state_desc, query_capture_mode_desc FROM sys.database_query_store_options`

## Wait Stats Auxiliary Mapping Table

| Category | Wait Types | Explanation |
|----------|-----------|-------------------------------|
| CPU | SOS_SCHEDULER_YIELD | Occurs when a task voluntarily yields the scheduler for other tasks to execute. During this wait, the task is waiting in a runnable queue for its quantum to be renewed, that is, waiting to be scheduled to run on the CPU again. Prolonged waits on this wait type most frequently indicate opportunities to optimize queries that perform index or table scans. Focus on plan regression, missing index, stats updates, and query rewrites. Optimizing runtimes reduces the need for tasks to be yielding multiple times. If query times for such CPU-consuming tasks are acceptable, then this wait type is expected and can be ignored. |
| Worker Thread | THREADPOOL | Occurs when a task (query or login/logout) is waiting for a worker thread to execute it. This can indicate that the maximum worker thread setting is misconfigured, or, most commonly, that batch executions are taking unusually long, thus reducing the number of worker threads available to satisfy other batches. Examine the performance of batches (queries) and reduce query duration by either reducing bottlenecks (blocking, parallelism, I/O, latch waits), or providing proper indexing or query design. |
| Lock | LCK_M_* | Lock waits occur when a query is waiting for a lock to be released by another transaction. Locks are used to ensure the consistency of data. SQL Server has various lock types (e.g., Shared, Exclusive) |
| Latch | LATCH_* PAGELATCH_* | Latch waits occur when a task is waiting for a latch to be released. Latches are lightweight synchronization primitives used to protect internal memory structures. High latch waits can indicate contention on internal structures, often due to inefficient query plans or high concurrency. |
| Buffer IO | PAGEIOLATCH_* | PAGEIOLATCH waits occur when a task is waiting for a page to be read from disk into the buffer pool. High PAGEIOLATCH waits can indicate I/O bottlenecks or insufficient memory for caching frequently accessed pages. |
| Compilation | RESOURCE_SEMAPHORE_QUERY_COMPILE | RESOURCE_SEMAPHORE_QUERY_COMPILE waits occur when a query is waiting for resources to compile. This can indicate complex queries or insufficient memory for query compilation. |
| SQL CLR | CLR_* SQLCLR | SQLCLR waits occur when a task is waiting for a SQL CLR operation to complete. This can indicate long-running or blocking CLR operations. |
| Mirroring | DBMIRROR_* | DBMIRROR waits occur in database mirroring scenarios when a task is waiting for mirroring operations to complete. |
| Transaction | XACT_* DTC TRAN_MARKLATCH TRANSACTION MUTEX | Transaction waits occur when a task is waiting for a transaction to complete. This can indicate contention or long-running transactions. |
| Idle | SLEEP_* LAZYWRITER SQLTRACE BUFFER FLUSH WAITFOR | Idle waits occur when a task is waiting for a specific event or condition to be met. These waits are generally not a cause for concern unless they are excessive. |
| Preemptive | PREEMPTIVE_* | Preemptive waits occur when SQL Server is waiting for an external resource or operation to complete. These waits can indicate issues with external dependencies or resource contention. |
| Service Broker | BROKER_* | Service Broker waits occur when a task is waiting for a Service Broker operation to complete. These waits can indicate issues with message processing or communication between services. |
| TranLog IO | LOGMGR LOGBUFFER WRITELOG CHECKPOINT | Transaction log I/O waits occur when a task is waiting for transaction log operations to complete. High log I/O waits can indicate disk bottlenecks or inefficient transaction log usage. |
| Network IO | ASYNC_NETWORK_IO WAITFOR PACKET NETWORK | Network I/O waits occur when a task is waiting for network operations to complete. High network I/O waits can indicate network latency or bandwidth issues. |
| Parallelism | CXCONSUMER CXPACKET CXSYNC_* EXCHANGE | Parallelism waits occur when a task is waiting for parallel query execution operations to complete. High parallelism waits can indicate suboptimal query plans or resource contention. |
| Memory | RESOURCE_SEMAPHORE CMEMTHREAD MEMORY_ALLOCATION MEMORY_GRANT | Memory waits occur when a task is waiting for memory resources to become available. High memory waits can indicate insufficient memory or inefficient query plans. |
| User Wait | WAITFOR RESULTS | User waits occur when a task is waiting for user input or interaction. These waits are generally not a cause for concern unless they are excessive. |
| Tracing | TRACEWRITE SQLTRACE FILE BUFFER WRITERS | Tracing waits occur when a task is waiting for tracing operations to complete. High tracing waits can indicate issues with trace configuration or performance. |
| Full Text Search | FT_* FULLTEXT GATHERER MSSEARCH | Full-text search waits occur when a task is waiting for full-text search operations to complete. High full-text search waits can indicate issues with indexing or query performance. |
| Disk IO | ASYNC_IO_COMPLETION BACKUPIO WRITE_COMPLETION | Disk I/O waits occur when a task is waiting for disk operations to complete. High disk I/O waits can indicate disk bottlenecks or inefficient I/O usage. |
| Replication / HADR | REPL_* HADR_* | Replication and HADR waits occur when a task is waiting for replication or high availability/disaster recovery operations to complete. High waits in this category can indicate issues with data synchronization or failover processes. |
| Log Rate Governor | LOG_RATE_GOVERNOR_* | Log Rate Governor waits occur when a task is waiting for log rate governor operations to complete. High waits in this category can indicate issues with log rate management or throttling. |