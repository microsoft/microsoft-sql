# Wait Category Analysis — Report Template

## Report Template

Present results in this exact format:

```
## Wait Category Analysis
Server: {{server name}}
Database: {{database name}}
Date: {{current date in YYYY-MM-DD format}}
Lookback: {{LookbackMinutes}} minutes
Snapshot Duration: {{SnapshotDurationSeconds}} seconds

---

## Server Level Wait Category Overview ({{SnapshotDurationSeconds}}-second snapshot)

|Wait Type| Wait Percentage (%)  | Total Wait Time (sec) | Average Wait Time (sec) | Wait Count |Assessment|
|---------|----------------------|-----------------------|-------------------------|------------|----------|
{{one row per wait type, sorted by Wait Percentage descending}}
{{Assessment column: Explain what this wait type means and how it could be contributing to slowness. For each wait type, look at the [Wait Stats Auxiliary Mapping Table](root-cause-guide.md#wait-stats-auxiliary-mapping-table) }}

## Database Level Wait Category Overview ({{SnapshotDurationSeconds}}-second snapshot)

{{if platform is Azure SQL Database or Fabric, and database level wait stats are available, show the same table as server level but for database waits. If not available, state: "Database level wait statistics are not available on this platform.", else do not show this section at all.}}

|Wait Type| Wait Percentage (%)  | Total Wait Time (sec) | Average Wait Time (sec) | Assessment|
|---------|----------------------|-----------------------|-------------------------|-----------|
{{one row per wait type, sorted by Wait Percentage descending}}
{{Assessment column: Explain what this wait type means and how it could be contributing to slowness. For each wait type, look at the [Wait Stats Auxiliary Mapping Table](root-cause-guide.md#wait-stats-auxiliary-mapping-table) }}

### Query Store Wait Category Summary

{{If Query Store is available, show the breakdown of wait categories across all queries, aggregated by category. This should help identify the dominant wait category affecting the most queries.}}

| Wait Category | Total Wait Time (ms) | # Queries Affected | Assessment |
|---------------|----------------------|--------------------|------------|
{{one row per wait category, aggregated across all queries, sorted by total wait time descending}}
{{Assessment column: Explain what the wait category means and how it could be causing slowness. Use the [Wait Stats Auxiliary Mapping Table](root-cause-guide.md#wait-stats-auxiliary-mapping-table) and the Root Cause Decision Tree below to map the category to common root causes.}}

> **Note:** Query Store exposes wait *categories* (e.g., Lock, CPU, Network I/O), not individual wait types. Individual wait types are only available from the DMV snapshots in Steps 2/3. Do not infer or fabricate wait type names from category data.

---

### Affected Queries Detail

{{For each of the top 5 most affected queries by total wait time:}}
#### Query Hash: {{query_hash}}
- **Dominant Wait Category**: {{wait category with highest wait time for this query}}
- **Total Wait Time**: {{total_wait_time}} ms
- **Wait Breakdown**: {{markdown table with each wait category and its percentage of this query's total waits}}
- **Query ID**: {{query_id}}
- **Parameterization Type**: {{query_parameterization_type_desc}}
- **Plan Count**: {{plan_count}} {{if > 1, note: "Multiple plans detected — possible plan regression or parameter sniffing. Consider running the `query-store-volatile-historical-slow-queries-comparison` skill (Step 1) to investigate further."}}

---

### Primary Root Cause

{{Based on the dominant wait category, state the root cause using the decision tree below}}

```