# HA Investigation — Report Template & Decision Tree

## Report Template

Combine results from all applicable steps into this unified report:

```
## High Availability Investigation Report
Database:   {{database name}}
Server:     {{server name}}
Date:       {{current date in YYYY-MM-DD format}}
Data Source: sys.dm_hadr_*, sys.availability_groups, sys.availability_replicas
Parameters: AGName={{AGName}}, Lookback={{LookbackMinutes}}m,
            RedoQueueThreshold={{RedoQueueThresholdKB}}KB,
            LogSendQueueThreshold={{LogSendQueueThresholdKB}}KB

---

### 1. Platform & HA Capability

Edition:       {{sql_edition}}
Version:       {{sql_version}}
Engine Edition: {{engine_edition}} — {{ha_support_level}}
HADR Enabled:  {{is_hadr_enabled}}

{{If AG not supported or not enabled, state why and stop.}}

---

### 2. AG Configuration Summary

| AG Name | Backup Pref | Failure Level | Health Timeout | Replica | Sync Mode | Failover Mode | Session Timeout | Seeding |
|---------|-------------|---------------|----------------|---------|-----------|---------------|-----------------|---------|
{{One row per replica. Flag any misconfiguration from Step 2.}}

---

### 3. Replica Health Status

| AG Name | Replica | Role | Operational State | Connected | Sync Health | Recovery Health |
|---------|---------|------|-------------------|-----------|-------------|-----------------|
{{One row per replica. Highlight any non-HEALTHY or DISCONNECTED replicas with ⚠.}}

---

### 4. Database Synchronization Status

| AG | Replica | Database | Sync State | Sync Health | Redo Queue (KB) | Redo Rate (KB/s) | Est. Redo (sec) | Log Send Queue (KB) | Log Send Rate (KB/s) | Est. Data Loss (sec) |
|----|---------|----------|------------|-------------|-----------------|------------------|-----------------|---------------------|---------------------|---------------------|
{{One row per database per replica. Flag:}}
{{⚠ redo_queue_size > {{RedoQueueThresholdKB}} KB}}
{{⚠ log_send_queue_size > {{LogSendQueueThresholdKB}} KB}}
{{⚠ estimated_redo_completion_sec > 300}}
{{⚠ sync_state = NOT SYNCHRONIZING}}

---

### 5. HADR Wait Analysis ({{SnapshotDurationSeconds}}s Snapshot)

| Wait Type | Delta Tasks | Delta Wait (ms) | Delta Signal (ms) | Delta Resource (ms) | Avg Wait/Task (ms) |
|-----------|-------------|-----------------|--------------------|--------------------|---------------------|
{{Top waits from snapshot. Flag HADR_SYNC_COMMIT, PARALLEL_REDO_TRAN_TURN, DIRTY_PAGE_TABLE_LOCK.}}

---

### 6. Recent Failover Events (Last {{LookbackMinutes}} min)

| Time (UTC) | AG Name | Replica | Previous State | Current State |
|------------|---------|---------|----------------|---------------|
{{State change events. Flag frequent transitions.}}

{{Error log entries related to AG: lease timeouts, connection timeouts, join errors.}}

---

### 7. Recommendations & Next Steps

{{Based on findings, provide prioritized recommendations:}}
1. {{Most critical issue and action}}
2. {{Second issue and action}}
3. {{Additional recommendations}}

{{For Azure SQL DB / Fabric: Report geo-replication status from Step 12 instead of Steps 2–6.}}
```

---

## Root Cause Decision Tree and Next Steps

### Replica in RESOLVING state

State: **"A replica is stuck in RESOLVING — failover may be in progress or the AG is unable to determine roles."**

Next steps:
1. Check failover history (Step 6) for recent state transitions and lease timeouts
2. Verify cluster health (Step 10) — check quorum, node status
3. Check `failure_condition_level` (Step 2) — may be too aggressive for the environment
4. If RESOLVING persists > 5 minutes, consider forcing quorum or manual failover

### High redo queue (> {{RedoQueueThresholdKB}} KB)

State: **"The secondary redo queue is large — the secondary is unable to replay changes as fast as the primary generates them. Failover RTO will be extended."**

Next steps:
1. Check redo thread status (Step 9) — is it blocked, waiting on I/O, or contending with reader queries?
2. On SQL 2016+, consider enabling parallel redo (trace flag 3459) if using serial redo, or vice versa for insert-heavy workloads
3. Check secondary server CPU and I/O — redo is CPU and I/O intensive
4. If readable secondary is configured, reduce read workload during catch-up periods

### High log send queue (> {{LogSendQueueThresholdKB}} KB)

State: **"The log send queue is large — the primary cannot send log blocks to the secondary fast enough. Network bandwidth or flow control is the bottleneck."**

Next steps:
1. Check network bandwidth and latency between replicas (Step 8 — `send_to_receive_latency_ms`)
2. Verify endpoint is healthy and started (Step 7)
3. Check for flow control — AG may be throttling log send to prevent secondary overload
4. Consider log compression (SQL 2016+) to reduce network bandwidth requirements

### HADR_SYNC_COMMIT wait is dominant

State: **"Synchronous commit latency is the primary issue. The primary is waiting for the secondary to acknowledge log hardening, impacting transaction throughput."**

Next steps:
1. Check network latency between replicas — synchronous commit is sensitive to round-trip time
2. Check secondary log disk I/O performance — slow hardening extends commit wait
3. Review redo rate on secondary (Step 4) — if redo is slow, hardening may be delayed
4. For cross-datacenter replicas, switch to asynchronous commit mode
5. Reference: [Troubleshooting HADR_SYNC_COMMIT](https://docs.microsoft.com/en-us/archive/blogs/sql_server_team/troubleshooting-high-hadr_sync_commit-wait-type-with-always-on-availability-groups)

### Seeding stuck or failed

State: **"Automatic seeding is not completing successfully. The database cannot be added to the AG on the target replica."**

Next steps:
1. Check seeding status (Step 11) — review `failure_state_desc` and `error_code`
2. Common failures: disk full (3257), certificate missing (33111), timeout (17)
3. Verify sufficient disk space on the secondary for the database
4. If automatic seeding fails repeatedly, switch to manual seeding: backup on primary, restore WITH NORECOVERY on secondary, then join

### Azure SQL DB or Fabric — geo-replication issues

State: **"Geo-replication lag is elevated or replication is in an unexpected state."**

Next steps:
1. Check `replication_lag_sec` from Step 12 — values > 30s indicate the secondary is falling behind
2. If `replication_state_desc` = 'CATCH_UP', monitor trend — if lag is not decreasing, scale up the secondary
3. If `replication_state_desc` = 'SUSPENDED', check for connectivity issues or intentional pause
4. Consider auto-failover groups for automatic failover and connection string redirection

### Frequent failovers (> 3 in {{LookbackMinutes}} minutes)

State: **"The availability group is experiencing frequent failovers, causing application disruption and potential data issues."**

Next steps:
1. Check error log for lease timeout errors (19407) — common cause of false failovers
2. Review `health_check_timeout` and `failure_condition_level` (Step 2) — may be too aggressive
3. Check cluster health (Step 10) — unstable quorum or network partitions cause flapping
4. On VMs, check for live migration, host maintenance, or resource contention events
5. Increase `session_timeout` if network is occasionally slow (default 10s may be too low for high-latency links)
6. Consider adjusting `LeaseTimeout` registry setting if lease timeouts are the cause (default 20s)
