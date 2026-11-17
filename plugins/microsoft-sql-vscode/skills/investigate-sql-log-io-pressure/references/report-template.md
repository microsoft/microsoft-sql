# Log IO Pressure Investigation — Report Template

Use this template to present the final investigation results. Adapt sections based on which steps returned data.

```
## Log IO Pressure Investigation Report
Database:   {{database name}}
Date:       {{current date in YYYY-MM-DD format}}
Data Source: sys.dm_db_resource_stats, sys.dm_exec_requests, sys.dm_tran_database_transactions,
             sys.dm_io_virtual_file_stats, sys.dm_db_log_space_usage, sys.dm_db_log_stats
Parameters: TopN={{TopN}}, LogIoThreshold={{LogIoThreshold}}%,
            ConfirmLookback={{ConfirmLookbackMinutes}}m, HistoryLookback={{HistoryLookbackHours}}h

---

### Step 1 — Log IO Pressure Confirmation

{{Include log_io_assessment from Step 1.}}
{{If no pressure confirmed, note to skip Step 2 and proceed to structural analysis.}}

---

### Step 2 — Active Log IO Consumers

| Session | Status | Writes | Log MB Used | Log MB Reserved | Txn Duration (sec) | Wait Type | Wait (ms) | Object | Query Hash |
|---------|--------|--------|-------------|-----------------|---------------------|-----------|-----------|--------|------------|
{{Top rows. Flag log_mb_used > 10 as ⚠ significant. Flag txn_duration_sec > 300 as ⚠ long-running.}}

---

### Step 3 — Log File Latency

| File Name | Type | Log Writes | Total MB Written | Avg Write Latency (ms) | Avg Bytes/Write | Total Write Stall (ms) |
|-----------|------|------------|-----------------|------------------------|-----------------|------------------------|
{{Flag avg_log_write_latency_ms > 5 as ⚠ slow. Note Azure SQL log rate context if applicable.}}

---

### Step 4 — Transaction Log Health

#### Log Space
| Total Log (MB) | Used (MB) | Used % | Since Last Backup (MB) |
|----------------|-----------|--------|------------------------|

#### VLF Health
| Total VLFs | Active VLFs | Active Log (MB) | Truncation Holdup | Assessment |
|------------|-------------|------------------|-------------------|------------|
{{Flag total_vlf_count > 200 as ⚠.}}

#### Long-Running Transactions
| Session | Login | Txn Duration (sec) | Log MB Used | Transaction State | Query Hash |
|---------|-------|--------------------|-------------|-------------------|------------|
{{Flag txn_duration_sec > 300 as ⚠.}}

---

### Step 5 — Historical Write-Heavy Queries

| Executions | Total Logical Writes | Writes/Exec | Max Writes | Total CPU (ms) | Last Exec | Object | Query Hash |
|------------|---------------------|-------------|------------|----------------|-----------|--------|------------|
{{Top rows. Flag Writes/Exec > 1000 as ⚠ write-heavy.}}

---

### Root Cause Assessment

{{Use references/root-cause-guide.md to determine the root cause.}}

---

### Recommended Next Steps

{{Based on root cause, provide specific actions.}}
```
