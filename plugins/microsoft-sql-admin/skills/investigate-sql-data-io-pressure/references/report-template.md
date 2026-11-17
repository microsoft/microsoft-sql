# Data IO Pressure Investigation — Report Template

Use this template to present the final investigation results. Adapt sections based on which steps returned data.

```
## Data IO Pressure Investigation Report
Database:   {{database name}}
Date:       {{current date in YYYY-MM-DD format}}
Data Source: sys.dm_db_resource_stats, sys.dm_exec_requests, sys.dm_exec_query_stats,
             sys.dm_io_virtual_file_stats, sys.dm_os_performance_counters
Parameters: TopN={{TopN}}, DataIoThreshold={{DataIoThreshold}}%,
            ConfirmLookback={{ConfirmLookbackMinutes}}m, HistoryLookback={{HistoryLookbackHours}}h

---

### Step 1 — Data IO Pressure Confirmation

{{Include data_io_assessment from Step 1.}}
{{If no pressure confirmed, note to skip Steps 2 and 6 and proceed to historical analysis.}}

---

### Step 2 — Active Data IO Consumers

| Session | Status | Physical Reads | Logical Reads | Phys Reads/sec | DOP | Wait Type | Wait (ms) | Wait Resource | Object | Query Hash |
|---------|--------|----------------|---------------|----------------|-----|-----------|-----------|---------------|--------|------------|
{{Top rows. Flag physical_reads > 10K as ⚠ significant.}}

{{For each top session, include the query_hash and note if the plan is available for inspection.}}

---

### Step 3 — Historical Top Physical-Read Consumers

| Executions | Total Phys Reads | Phys/Exec | Total Logical Reads | Logical/Exec | Max Phys Reads | Last Exec | Object | Query Hash |
|------------|-----------------|-----------|--------------------:|------------:|----------------|-----------|--------|------------|
{{Top rows. Flag Phys/Exec > 1000 as ⚠ high per-execution disk IO.}}

---

### Step 4 — Data File Latency

| File Name | Type | Reads | Writes | Total MB Read | Avg Read Latency (ms) | Avg Write Latency (ms) | Total Stall (ms) |
|-----------|------|-------|--------|---------------|----------------------|------------------------|-------------------|
{{Flag avg_read_latency_ms > 20 as ⚠ slow. Note Azure SQL context if applicable.}}

---

### Step 5 — Buffer Pool Health

#### PLE per NUMA Node
| NUMA Node | PLE (sec) | Assessment |
|-----------|-----------|------------|
{{List each NUMA node. Flag PLE < 1000 as ⚠.}}

#### Buffer Pool Metrics
| Metric | Value | Assessment |
|--------|-------|------------|
| Buffer Cache Hit Ratio | {{ratio}} | {{< 99% = ⚠}} |
| Page Reads/sec (cumulative) | {{value}} | |
| Lazy Writes/sec (cumulative) | {{value}} | {{> 0 sustained = ⚠ eviction}} |
| Checkpoint Pages/sec (cumulative) | {{value}} | |

---

### Step 6 — Scan Pattern Detection

{{If no rows: "No table scans or clustered index scans detected in active sessions."}}
{{If rows: list sessions with detected scan patterns, query_hash, and recommended index actions.}}

---

### Root Cause Assessment

{{Use references/root-cause-guide.md to determine the root cause.}}

---

### Recommended Next Steps

{{Based on root cause, provide specific actions.}}
```
