# CPU Pressure Investigation — Final Report Template

Combine available step results into this unified report. Omit sections for steps that were
skipped or could not be queried, and record those limitations as evidence gaps:

```
## CPU Pressure Investigation Report
Database:   {{database name from Step 0 if known}}
Date:       {{current date in YYYY-MM-DD format}}
Data Source: {{only the diagnostic sources actually queried}}
Parameters: TopN={{TopN}}, ConfirmLookback={{ConfirmLookbackMinutes}}m,
            HistoryLookback={{HistoryLookbackHours}}h, CpuThreshold={{CpuThresholdMs}}ms

---

### Step 0 — Target and Engine

Server: {{server_name from Step 0, if available}}
Database: {{database_name from Step 0, if available}}
Engine edition: {{engine_edition}}
Major version: {{major_version}}
Diagnostic permissions: {{Step 0 effective permission flags; note any unavailable checks}}
Path: {{server DMVs / Azure resource stats / database-scoped Query Store}}

{{For the database-scoped Query Store path, omit server-DMV Steps 1–3 and 5–6.
Retain any collected Azure resource-stats Step 1, including performance-state-only
access or a successful unknown-permission attempt. Report database CPU percentage
separately from Query Store recorded query CPU, even if Query Store has no evidence.
Do not present Query Store recorded CPU as instance CPU % or live wait evidence.}}

### Step 1 — CPU Signals

{{If Azure resource stats have no samples or a query failed:}}
"CPU pressure could not be confirmed from resource stats; this is an evidence gap, not
evidence of no pressure. Continue with the available live and historical steps."

{{If Azure resource stats have samples:}}
"Average CPU = {{avg_cpu_percent}}%, max = {{max_cpu_percent}}% over the sampled window.
{{Compare to CpuThresholdPct before classifying sustained pressure.}}"

{{If SQL Server / IaaS / Edge:}}
"Snapshot: {{runnable_tasks}} runnable tasks across {{online_schedulers}} online
schedulers. This is not historical CPU utilization; investigate live and historical queries."

{{For every failed diagnostic step, record the actual tool error and affected step as an
evidence gap. Do not turn a permission error, empty sample window, or unavailable DMV
into a 'no CPU pressure detected' conclusion. When the effective principal lacks
state-viewing permissions, empty live/plan-cache results are visibility-limited.}}

---

### Step 2 — Real-Time CPU Pressure Summary

| Session | Request | Status | CPU (ms) | Elapsed (ms) | Wait Type | Wait (ms) |
|---------|---------|--------|----------|--------------|-----------|-----------|
{{Top {{TopN}} rows. CPU time can exceed elapsed time for parallel requests because it is
cumulative across workers; do not derive "non-CPU time" by subtracting them. If diagnostic
permissions are insufficient or unknown, do not claim that zero visible rows mean no active
CPU-consuming sessions.}}

---

### Step 3 — Active Offender Hashes

{{For each session from Step 3:}}
#### Session {{session_id}} — {{status}}
- **CPU**: {{cpu_time_ms}} ms | **Elapsed**: {{elapsed_time_ms}} ms
- **Request**: {{request_id}} | **Wait**: {{wait_type}} ({{wait_time_ms}} ms)
- **Object**: {{object_name}}

query_hash:
{{query_hash}}
---

### Step 4 — Historical Top CPU Consumers (Plan Cache)

| Executions | Total CPU (ms) | CPU/Exec (ms) | Max CPU (ms) | Last Exec | Database | Object |
|------------|---------------|---------------|--------------|-----------|----------|--------|
{{Top {{TopN}} rows. Flag CPU/Exec > 5000ms as high per-execution cost.}}

{{If using database-scoped Query Store instead of plan cache:}}
### Step 4 — Recently Active Captured Queries (Query Store)

Query Store state: {{READ_WRITE / READ_ONLY / READ_CAPTURE_SECONDARY / OFF / ERROR}}
| Query ID | Plan ID | Executions | Recorded CPU (ms) | CPU/Exec (ms) | Last Exec | Object |
|----------|---------|------------|-------------------|---------------|-----------|--------|
{{Top {{TopN}} rows, if any. The CPU totals can include executions earlier
than the lookback due to runtime-stats interval aggregation. No rows does not
rule out high instance CPU or uncaptured workload.}}

---
### Step 5 — Memory-Grant Waits and Reduced Grants

{{If no rows returned from Step 5:}}
"No waiting or reduced memory grant was visible in this snapshot; past waits and spills are not ruled out."

{{If rows returned:}}

| Session | Request | CPU (ms) | Wait Type | Requested KB | Granted KB | Required KB | Max Used KB | Grant Wait (ms) | Object |
|---------|---------|----------|-----------|-------------|------------|-------------|-------------|-----------------|--------|
{{One row per request. A NULL grant means the request is waiting. Granted < Requested is a
reduced grant and possible spill risk; confirm spills in plan XML.}}

{{For each request with grant_time IS NULL:}}
"Session {{session_id}}, request {{request_id}} is waiting for a memory grant after
{{grant_wait_time_ms}} ms."

{{For each request with granted_memory_kb < requested_memory_kb:}}
"Session {{session_id}}, request {{request_id}} requested {{requested_memory_kb}} KB and
received {{granted_memory_kb}} KB. Check Sort and Hash Match operators for actual spills."

---
### Step 6 — Plan Smell Detection

{{If no rows returned from Step 6:}}
"No checked plan smells were detected in available plans for visible active requests.
Unavailable plans and requests outside this snapshot are not ruled out."

{{If rows returned:}}

| Session | Request | CPU (ms) | Wait Type | Implicit Conv | Spill | Missing Idx | Key Lookup | Scalar UDF | Object |
|---------|---------|----------|-----------|:---:|:---:|:---:|:---:|:---:|--------|
{{One row per session. Mark each flag column as ✓ (1) or blank (0).}}

{{For each session, list the detected smells and their recommended fixes using `references/plan-smell-reference.md`.}}

---
### Step 7 — Targeted Query Text and Plan Analysis

{{For database-scoped Query Store, retrieve SQL text and plan only from its
Step 7 query using observed query_id and plan_id. Do not use the server-DMV
retrieval query or assert that plan-cache and Query Store results are equivalent.}}

{{If Step 7 was skipped because no workload-query signal was present:}}
"Step 7 skipped — no query was captured or visible that warrants targeted analysis.
This does not rule out uncaptured CPU-intensive workload or pressure outside the
selected window."

{{Otherwise, for each analyzed (query_hash, query_plan_hash) pair, emit a block:}}

#### Query {{n}} — `query_hash` {{query_hash}}
- **Source step(s)**: {{e.g. "Step 3 (active) + Step 4 (historical)"}}
- **Object**: {{database_name}}.{{object_name}}
- **Executions / CPU per exec**: {{execution_count}} / {{worker_time_per_exec_ms}} ms
- **Plan availability**: {{"cached plan retrieved" | "Query Store plan retrieved" | "in-flight plan retrieved" | "plan unavailable — text-only analysis"}}

**Statement (truncated to ~40 lines if long):**
```sql
{{statement_text}}
```

**Findings:**
- {{Bullet list of concrete issues found in the text and plan, e.g. "Implicit conversion on dbo.Orders.CustomerId (varchar) compared to N'…' literal — forces index scan."}}

**Recommended changes:**
1. {{Concrete, actionable change — e.g. DDL for a covering index, a rewritten predicate, an UPDATE STATISTICS command, a MAXDOP hint to test.}}
2. {{…}}

**Validation:** {{How to confirm the change helped — e.g. "Re-run Step 4 after deployment; expect worker_time_per_exec_ms to drop below X."}}

---
### Root Cause Assessment

{{Use the decision tree only for live wait evidence. For Query Store-only evidence,
describe identified captured CPU consumers; without a direct pressure metric or
live waits, instance CPU root cause remains unconfirmed.}}

---

### Recommended Next Steps

{{Based on the root cause found, use the prescriptive guidance in the parent SKILL.md.}}
```
