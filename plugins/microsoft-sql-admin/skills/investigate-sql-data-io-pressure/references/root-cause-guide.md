# Data IO Pressure — Root Cause Decision Tree

Use the findings from all investigation steps to determine the root cause and next steps.

---

## `PAGEIOLATCH_SH` / `PAGEIOLATCH_EX` dominant with high file read latency

**Root cause: Storage bottleneck — disk cannot keep up with data read/write demand.**

Next steps:
1. Review Step 4 `avg_read_latency_ms` — if consistently > 20ms, storage is the bottleneck
2. On-premises: check SAN/disk queue depth, RAID configuration, consider faster storage (SSD/NVMe)
3. Azure SQL: the service tier's IOPS limit is likely being hit — scale up the tier or move to Hyperscale
4. Add covering indexes (Step 6) to reduce the number of pages that need to be read
5. Review Step 3 for the top physical-read queries and optimize them

---

## `PAGEIOLATCH` dominant with low PLE and healthy file latency

**Root cause: Buffer pool memory pressure — working set exceeds available memory.**

Next steps:
1. On-premises: increase `max server memory` or add physical RAM
2. Azure SQL: scale to a tier with more memory
3. Optimize the top logical-read queries from Step 3 — reduce scan width with better indexes
4. Check if other databases on the same instance are competing for buffer pool
5. Consider partitioning large tables to reduce the active working set

---

## High physical reads with scan patterns detected (Step 6)

**Root cause: Query design — table/index scans reading entire tables from disk.**

Next steps:
1. Create nonclustered indexes on the filter and join columns for the identified queries
2. Add INCLUDE columns to make indexes covering (avoid key lookups)
3. Review WHERE clauses for sargability issues (functions on columns prevent seeks)
4. Consider filtered indexes for queries targeting a subset of rows

---

## No active pressure but high historical physical reads (Step 3)

**Root cause: Periodic IO-intensive workload — not currently active but recurring.**

Next steps:
1. Identify the schedule of the high-IO queries (ETL, reporting, maintenance)
2. Move IO-intensive jobs to off-peak hours
3. Add indexes to reduce physical reads for the top cumulative consumers
4. Consider Read Scale-Out (Azure SQL) or readable secondary replicas for reporting queries
