# HA Assessment — Report Template

Read this file before presenting the final assessment report. Use the template below,
adapting sections based on the platform routing from Step 1.

```
## HA Environment Assessment Report
Instance:   {{server_name}}
Platform:   {{edition}} (Engine Edition {{engine_edition}})
Date:       {{current date in YYYY-MM-DD format}}
Scope:      {{AGName or 'All Availability Groups'}}

---

### Step 1 — Platform & HA Capability

Platform: {{edition}}
HA Enabled: {{is_hadr_enabled}}
Assessment: {{ha_capability_assessment}}

---

### Step 2 — Cluster Health Assessment
{{Skip if Azure SQL DB / MI / Fabric}}

| Check | Result | Details |
|-------|--------|---------|
| Quorum Configured | {{PASS/FAIL/WARNING}} | {{quorum_type_desc}} — {{quorum_state_desc}} |
| All Members Online | {{PASS/FAIL}} | {{count}} of {{total}} members UP |
| Vote Count | {{PASS/WARNING}} | {{total_votes}} votes ({{odd/even}}) |
| Witness Configured | {{PASS/WARNING/FAIL}} | {{witness type or 'None'}} |

---

### Step 3 — AG Configuration Assessment

{{For each AG:}}
#### {{ag_name}}

| Setting | Value | Assessment |
|---------|-------|------------|
| AG Sync Health | {{synchronization_health_desc}} | {{ag_health_assessment}} |
| Failure Condition Level | {{level}} | {{failure_level_assessment}} |
| Health Check Timeout | {{timeout}} ms | {{health_timeout_assessment}} |
| DB Failover (2016+) | {{db_failover}} | {{PASS/WARNING}} |
| Backup Preference | {{preference}} | {{assessment}} |

| Replica | Mode | Failover | Session Timeout | Assessment |
|---------|------|----------|-----------------|------------|
{{For each replica: server, mode, failover_mode, session_timeout, combined assessments}}

---

### Step 4 — Failover Readiness

| Replica | Role | Connected | Sync Health | DBs Synced | DBs Not Synced | Max Log Send (KB) | Max Redo (KB) | Est. Redo (sec) | DBs Not Failover-Ready | Readiness |
|---------|------|-----------|-------------|------------|----------------|-------------------|---------------|-----------------|------------------------|-----------|
{{For each replica row}}

---

### Step 5 — Listener & Connectivity

{{If no listeners found:}}
⚠️ FAIL: No AG listener configured. Applications connecting to node names will break on failover.

{{If listeners found:}}
| Listener | Port | AG | IP Address | IP State | DHCP | Assessment |
|----------|------|----|------------|----------|------|------------|
{{For each listener row}}

---

### Step 6 — Endpoint Security
{{Skip if Azure SQL DB / MI / Fabric}}

| Endpoint | State | Port | Auth | Assessment |
|----------|-------|------|------|------------|
{{For each endpoint row}}

---

### Step 8 — Database-Level Configuration

| AG | Database | Sync State | Suspended | Recovery Model | Auto Close | Auto Shrink | Page Verify | Issues |
|----|----------|------------|-----------|----------------|------------|-------------|-------------|--------|
{{For each database row — list any non-PASS assessments in Issues column}}

---

### Step 9 — Backup Configuration

| AG | Database | Backup Pref | Last Full | Last Log | Full Assessment | Log Assessment |
|----|----------|-------------|-----------|----------|-----------------|----------------|
{{For each database row}}

---

### Step 10 — Azure Platform HA
{{Skip if On-Prem / IaaS}}

Service Tier: {{edition}} — {{service_objective}}
HA Assessment: {{ha_tier_assessment}}

{{If geo-replication configured:}}
| Partner | Database | State | Role | Lag (sec) | Assessment |
|---------|----------|-------|------|-----------|------------|
{{For each geo-replication link}}

{{If MI failover group configured:}}
| Failover Group | Partner | Role | State | Assessment |
|----------------|---------|------|-------|------------|
{{For each failover group}}

---

### Step 11 — Connection Resiliency

| Setting | Current Value | Assessment |
|---------|---------------|------------|
{{For each configuration row}}

Application-side recommendations:
- ConnectRetryCount=3, ConnectRetryInterval=10
- MultiSubnetFailover=true for AG listeners
- Connection Timeout ≥ 30s
- Retry logic with exponential backoff for transient errors (40613, 40197, 40501)

---

### Step 12 — Overall Health Scorecard

| Check Category | Result | Issues Found |
|----------------|--------|-------------|
{{For each scorecard row}}

**Summary:**
- Total PASS: {{count}}
- Total WARNING: {{count}}
- Total FAIL: {{count}}

{{Use decision tree from SKILL.md for final assessment}}
```
