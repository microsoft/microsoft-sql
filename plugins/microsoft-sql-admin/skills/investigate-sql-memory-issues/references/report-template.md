# Memory Pressure Investigation — Report Template

Use this template to format the final report. Replace `{{placeholders}}` with actual values.

```
## Memory Pressure Investigation Report
Database:   {{database name}}
Date:       {{current date in YYYY-MM-DD format}}
Data Source: sys.dm_db_resource_stats, sys.dm_exec_query_memory_grants, sys.dm_os_memory_clerks,
             sys.dm_exec_query_stats, sys.query_store_runtime_stats
Parameters: TopN={{TopN}}, MemoryThreshold={{MemoryThreshold}}%,
            ConfirmLookback={{ConfirmLookbackMinutes}}m, HistoryLookback={{HistoryLookbackHours}}h,
            MinGrant={{MinGrantKB}}KB

---

### Step 1 — Memory Pressure Confirmation

{{If no rows returned from Step 1:}}
"Average memory usage did not exceed {{MemoryThreshold}}% in the last {{ConfirmLookbackMinutes}} minutes.
Memory pressure is not currently sustained. Consider expanding ConfirmLookbackMinutes
or reviewing Steps 5–7 for historical memory events and top grant consumers."

{{If row returned:}}
"Confirmed: average memory = {{avg_memory_percent}}%, max = {{max_memory_percent}}%
over the last {{ConfirmLookbackMinutes}} minutes. Active investigation warranted."

---

### Step 2 — Resource Semaphore Health

| Semaphore ID | Pool ID | Total KB | Available KB | Granted KB | Used KB | Grantees | Waiters | Timeouts | Forced Grants | Status |
|:---:|:---:|---:|---:|---:|---:|---:|---:|---:|---:|--------|
{{One row per resource semaphore. Flag waiter_count > 0 as CRITICAL.}}

{{If waiter_count > 0:}}
"CRITICAL: {{waiter_count}} queries are waiting for memory grants. Immediate investigation of
grant consumers (Step 3) and top historical consumers (Steps 6–7) is required."

---

### Step 3 — Active and Waiting Memory Grant Consumers

| Session | Status | Wait Type | Requested KB | Granted KB | Required KB | Used KB | Max Used KB | Assessment | CPU (ms) | Elapsed (ms) | Query Hash |
|:---:|--------|-----------|---:|---:|---:|---:|---:|----------|---:|---:|------|
{{Top {{TopN}} rows. Waiters (grant_time IS NULL) listed first.}}

{{For each session with WAITING status:}}
"Session {{session_id}}: Waiting for {{requested_memory_kb}} KB grant for {{grant_wait_time_ms}} ms.
Query hash: {{query_hash}}. This query is blocked on RESOURCE_SEMAPHORE."

{{For each session with OVER-GRANTED status:}}
"Session {{session_id}}: Granted {{granted_memory_kb}} KB but only used {{max_used_memory_kb}} KB
({{usage_percent}}%). Recommend OPTION (MAX_GRANT_PERCENT) or statistics update."

---

### Step 4 — Memory Clerk Breakdown

| Clerk Type | Description | Total Pages (MB) | Virtual Committed (MB) |
|-----------|-------------|---:|---:|
{{Top {{TopN}} clerks. Note: Buffer Pool dominance is normal unless paired with pressure signals.}}

{{Identify the dominant non-buffer-pool clerk and state its implications.}}

---

### Step 5 — Out-of-Memory Events

{{If unsupported platform message returned:}}
"sys.dm_os_out_of_memory_events is not available on this platform. Rely on Steps 2–4
for live pressure signals."

{{If no rows returned:}}
"No OOM events recorded in the last {{HistoryLookbackHours}} hours."

{{If rows returned:}}
"{{count}} OOM events detected in the last {{HistoryLookbackHours}} hours.
Most recent: {{event_time}}, cause: {{oom_cause}}.
This indicates critical memory pressure — immediate remediation recommended."

---

### Step 6 — Historical Top Memory Grant Consumers (Plan Cache)

| Query Hash | Plan Hash | Executions | Max Grant (MB) | Avg Grant (MB) | Max Used (MB) | Avg Used (MB) | Avg Ideal (MB) | Efficiency | Spills | Last Exec |
|------|------|---:|---:|---:|---:|---:|---:|----------|---:|------|
{{Top {{TopN}} rows. Flag OVER-GRANTED and UNDER-GRANTED (spills).}}

---

### Step 7 — Historical Top Memory Grant Consumers (Query Store)

{{If Query Store not enabled: "Query Store is not enabled on this database. Skip this step."}}

| Query Hash | Plans | Executions | Avg Max Used (MB) | Max Used (MB) | Avg CPU (ms) | Last Interval |
|------|---:|---:|---:|---:|---:|------|
{{Top {{TopN}} rows from hash version. Call out multi-plan queries for parameter sniffing risk.}}

---

### Root Cause Assessment

{{Use the remediation guide to state the dominant root cause.}}

---

### Recommended Next Steps

{{Based on the root cause found, use the prescriptive guidance from the remediation guide.}}
```
