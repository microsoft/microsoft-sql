# HA Assessment — Remediation Guide

Read this file when any assessment step returns FAIL or WARNING and the user wants
remediation guidance. Organized by step number.

The **HA Posture Decision Tree** section below is consulted first, based on the
`ha_posture` classification from Step 1.

---

## HA Posture Decision Tree — Guidance & Best Practices

Use the branch that matches the `ha_posture` value from the Step 1 classification query.

### Branch A — No HA Enabled

**What it means:** `IsHadrEnabled = 0` (Always On feature off), or it is on but no Availability Group exists. The instance has no AG-based redundancy — an OS, hardware, or storage failure causes an outage with no automatic failover and potential data loss.

**Guide the customer to enable HA (do not change anything automatically — advise only):**
1. Stand up the cluster foundation: a **Windows Server Failover Cluster (WSFC)** across the nodes (or Pacemaker/Corosync for Linux). Validate quorum and add a witness (cloud witness for Azure IaaS, file-share witness on-prem).
2. **Enable Always On Availability Groups** on each instance — SQL Server Configuration Manager → *Always On High Availability* tab (or `Enable-SqlAlwaysOn`) — then restart the SQL Server service.
3. Create an AG with at least one **synchronous-commit** secondary configured for **automatic failover**, set databases to **FULL** recovery, and create a **listener** for transparent client redirection.

**Best practices:** two or more synchronous replicas for automatic failover; dedicated network for AG traffic; matched edition/patch level across replicas; test a planned and an unplanned failover before go-live.

**Documentation:**
- [Overview of Always On availability groups](https://learn.microsoft.com/sql/database-engine/availability-groups/windows/overview-of-always-on-availability-groups-sql-server)
- [Prerequisites, restrictions, and recommendations](https://learn.microsoft.com/sql/database-engine/availability-groups/windows/prereqs-restrictions-recommendations-always-on-availability)
- [Enable or disable the Always On AG feature](https://learn.microsoft.com/sql/database-engine/availability-groups/windows/enable-and-disable-always-on-availability-groups-sql-server)
- [Windows Server Failover Clustering (WSFC) with SQL Server](https://learn.microsoft.com/sql/sql-server/failover-clusters/windows/windows-server-failover-clustering-wsfc-with-sql-server)

### Branch B — Basic Availability Group

**What it means:** `basic_features = 1` — a Basic AG (Standard Edition, SQL Server 2016+). It provides failover for a **single database** but has hard limitations: exactly **2 replicas** (1 primary, 1 secondary), **no readable secondary**, **no backups on the secondary**, no read-only routing, and you cannot add replicas or upgrade it in place to an advanced AG.

**Most common things to evaluate:**
- Both replicas are **synchronous-commit** with **automatic failover** (`availability_mode_desc`, `failover_mode_desc`).
- The protected database uses **FULL** recovery model and data movement is not suspended.
- The mirroring **endpoint is STARTED** and encrypted on both replicas (Step 6).
- **Quorum/witness** is configured so a single node loss does not lose quorum (Step 2).
- Replicas are on the **same edition and patch level**.
- Confirm the application does **not** depend on a readable secondary or secondary backups (unsupported on Basic AG).

**Best practices:** monitor synchronization health; keep replicas patched in lockstep; plan a migration to an **advanced AG on Enterprise Edition** if you need read-scale, multiple databases per AG, or more than two replicas.

**Documentation:**
- [Basic availability groups](https://learn.microsoft.com/sql/database-engine/availability-groups/windows/basic-availability-groups-always-on-availability-groups)

### Branch C — Advanced (Full) Availability Group

**What it means:** `basic_features = 0` — a full AG (Enterprise Edition, or an MI-link AG). Run the full AG steps (2–9, 12–13); this branch is the best-practice checklist to apply to their results.

**Most common things to evaluate:**
- **Failover readiness:** at least one synchronous-commit secondary set to automatic failover; flag any asynchronous-commit replica configured for automatic failover (invalid). Confirm `is_failover_ready = 1` for every database via `sys.dm_hadr_database_replica_cluster_states`. (Steps 3–4)
- **AG-level health:** `sys.dm_hadr_availability_group_states.synchronization_health_desc` reports HEALTHY / PARTIALLY_HEALTHY / NOT_HEALTHY for the whole group. (Step 3)
- **Listener & connectivity:** a listener exists; multi-subnet deployments set `MultiSubnetFailover=true`. (Step 5)
- **Endpoints:** `DATABASE_MIRRORING` endpoint STARTED and encrypted on every replica. (Step 6)
- **Database health:** `DB_FAILOVER` ON, FULL recovery, data movement not suspended, `AUTO_CLOSE`/`AUTO_SHRINK` OFF, `PAGE_VERIFY = CHECKSUM`. (Step 8)
- **Commit quorum:** `required_synchronized_secondaries_to_commit` set so a secondary loss does not take the primary offline unexpectedly. (Step 3)
- **Sync lag:** `log_send_queue` (un-sent log = RPO / data-loss exposure) and `redo_queue` (un-applied log = RTO) within the RPO/RTO target. (Step 4)
- **Flexible failover policy:** `failure_condition_level` and `health_check_timeout` tuned to avoid both false and missed failovers. (Step 3)
- **Storage integrity:** no automatic page-repair events in `sys.dm_hadr_auto_page_repair` (any rows indicate page corruption repaired from a replica). (Step 8)
- **Automatic seeding:** no failed or stalled seeding operations in `sys.dm_hadr_automatic_seeding` for replicas being added. (Step 4)
- **Backups:** healthy recent backups honoring `automated_backup_preference`. (Step 9)
- **Quorum/witness** health at the WSFC layer. (Step 2)

**Best practices:** tune the flexible failover policy; continuously monitor lag; rehearse planned and unplanned failovers on a schedule; keep all replicas on identical edition/patch levels.

**Documentation:**
- [Overview of Always On availability groups](https://learn.microsoft.com/sql/database-engine/availability-groups/windows/overview-of-always-on-availability-groups-sql-server)
- [Configure a flexible automatic failover policy](https://learn.microsoft.com/sql/database-engine/availability-groups/windows/configure-flexible-automatic-failover-policy)
- [Monitor availability groups with Transact-SQL](https://learn.microsoft.com/sql/database-engine/availability-groups/windows/monitor-availability-groups-transact-sql)
- [Always On availability groups DMVs and functions](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-views/always-on-availability-groups-dynamic-management-views-functions)
- [Initialize an availability group using automatic seeding](https://learn.microsoft.com/sql/database-engine/availability-groups/windows/automatically-initialize-always-on-availability-group)
- [Windows Server Failover Clustering (WSFC) with SQL Server](https://learn.microsoft.com/sql/sql-server/failover-clusters/windows/windows-server-failover-clustering-wsfc-with-sql-server)

---

## Step 2 — Windows Server Failover Cluster Health

| Check | Pass | Warning | Fail |
|-------|------|---------|------|
| Quorum configured | `quorum_type_desc` ≠ `UNKNOWN` | N/A | No quorum / `UNKNOWN` |
| All members online | All `member_state_desc` = `UP` | N/A | Any member `OFFLINE` or `ERROR` |
| Odd number of votes | Total votes is odd | Even votes (risk of split-brain) | Zero votes |
| Witness resource configured | File share witness, cloud witness, or disk witness configured | N/A | No witness resource configured (always configure a witness on WS2012+) |

| Finding | Action |
|---------|--------|
| Quorum is `UNKNOWN` or not configured | Configure quorum immediately — cluster cannot survive node failures without quorum |
| Any member `OFFLINE` | Investigate node health; a down member reduces fault tolerance |
| Even number of votes | Add a witness resource (file share witness for on-prem, cloud witness for Azure IaaS) to break ties |
| No witness resource configured | **Critical:** Always configure a witness resource on WS2012+ — use cloud witness for Azure IaaS, file share witness for on-prem. Without a witness resource, losing a node risks losing quorum |
| Multi-subnet detected | Verify `MultiSubnetFailover=true` in application connection strings |

**Azure IaaS best-practice cluster settings** (verify via PowerShell `Get-Cluster` or Failover Cluster Manager):

| Setting | Recommended Value | Notes |
|---------|-------------------|-------|
| SameSubnetDelay | 1 second | Heartbeat interval within subnet |
| SameSubnetThreshold | 40 heartbeats | Missed heartbeats before declaring node down |
| CrossSubnetDelay | 1 second | Heartbeat interval across subnets |
| CrossSubnetThreshold | 40 heartbeats | Missed heartbeats across subnets |
| Lease timeout | Start at 40s, max 80s | Must be < (2 × SameSubnetThreshold × SameSubnetDelay) |

---

## Step 3 — AG Configuration

| Check | Pass | Warning | Fail |
|-------|------|---------|------|
| `db_failover` enabled (SQL 2016+) | `db_failover` = 1 | `db_failover` = 0 — database-level health detection not enabled | N/A |
| Automatic failover partner exists | At least one synchronous replica with `AUTOMATIC` failover | No automatic failover partner when HA is required | N/A |
| All replicas `MANUAL` failover | N/A | All replicas set to `MANUAL` — no automatic failover configured | N/A |
| Async + Automatic combo | N/A | N/A | `ASYNCHRONOUS_COMMIT` with `AUTOMATIC` failover — invalid configuration |
| Failure condition level | Level 2–3 (balanced) | Level 1 (too lenient) or 4–5 (too aggressive) | N/A |

| Finding | Action |
|---------|--------|
| `failure_condition_level` = 1 | Consider raising to level 3 (default) for better failure detection |
| `failure_condition_level` > 3 | Lower to 3 unless you have specific requirements — levels 4–5 can trigger unnecessary failovers |
| `health_check_timeout` < 30000 | Increase to at least 30000 ms to avoid false failovers during transient load spikes |
| `session_timeout` < 10 | Increase to at least 10 seconds — low values cause false disconnects in high-latency networks |
| `db_failover` = 0 | Enable with `ALTER AVAILABILITY GROUP ... SET (DB_FAILOVER = ON)` for database-level health detection |
| No automatic failover replica | Add at least one synchronous-commit replica with automatic failover for HA |
| Async + Automatic | Fix immediately — change to either synchronous+automatic or async+manual |

---

## Step 4 — Failover Readiness

| Finding | Action |
|---------|--------|
| Replica not connected | Check network connectivity, endpoint state (Step 6), and Windows Firewall rules |
| Replica not healthy | Check `sys.dm_hadr_database_replica_states` for suspended databases; resolve before failover |
| Async + Manual | Acceptable for DR replicas; if this is the only secondary, consider switching to synchronous for HA |
| Not all databases synchronized | Identify which databases are lagging — check redo/log-send queues; resolve data movement issues |
| Estimated redo > 5 min | Redo queue is large — investigate I/O bottleneck on secondary or high transaction volume on primary |
| PASS: Ready for failover | Replica can be failed over without data loss (if synchronous) and within acceptable RTO |

---

## Step 5 — Listener & Connectivity

| Finding | Action |
|---------|--------|
| No listener configured (empty result set) | **FAIL for production.** Create an AG listener — applications connecting directly to node names will break on failover |
| Listener IP not ONLINE | Check DNS registration, cluster resource state, and IP conflicts |
| Using DHCP | Switch to a static IP — DHCP lease expiry can cause listener outages |
| Non-standard port | Verify all applications include the port in connection strings |
| Multi-subnet listener IPs | Ensure `MultiSubnetFailover=true` is set in all application connection strings |
| Azure IaaS | DNN (Distributed Network Name) is preferred over VNN + Load Balancer for SQL Server 2019 CU8+ |
| DNS resolution | Verify applications resolve the listener DNS name, not individual node names |

**Best practices & how to work with listeners:**
- **Always create a listener for production AGs.** It provides a single virtual network name (VNN) that clients connect to; the listener automatically redirects to the current primary after a failover, so applications never hard-code node names.
- **Point applications at the listener, not replicas.** Use `Server=<listener_dns_name>,<port>` in connection strings. Add `MultiSubnetFailover=True` so the client connects in parallel across subnets and reconnects quickly after failover (essential for multi-subnet/DR topologies).
- **Use a static IP per subnet** (not DHCP), and open the listener port in the firewall on all nodes. For **VNN listeners**, the standard port `1433` is fine unless there is a reason not to. For **DNN listeners** (see the Azure SQL VMs note below), use a **dedicated port that is unique across every replica** and **avoid `1433`**, since SQL Server commonly already listens on it.
- **Read-only routing:** to offload read-intent workloads to a readable secondary, configure `read_only_routing_url` per replica and a `READ_ONLY_ROUTING_LIST`, then have read clients connect with `ApplicationIntent=ReadOnly` to the listener.
- **Azure SQL VMs:** prefer a **Distributed Network Name (DNN)** listener over the VNN + internal Load Balancer model on SQL Server 2019 CU8+ / 2022 — it removes the load-balancer dependency and lowers failover latency.
- **Create a listener** (example — one static IP per subnet):
  ```
  ALTER AVAILABILITY GROUP [MyAG]
      ADD LISTENER 'MyAGListener' (
          WITH IP ( ('10.0.1.10', '255.255.255.0'), ('10.0.2.10', '255.255.255.0') ),
          PORT = 1433 );
  ```

**Documentation:**
- [Configure an availability group listener](https://learn.microsoft.com/sql/database-engine/availability-groups/windows/create-or-configure-an-availability-group-listener-sql-server)
- [Listeners, client connectivity, and application failover](https://learn.microsoft.com/sql/database-engine/availability-groups/windows/listeners-client-connectivity-application-failover)
- [Configure a DNN listener for SQL Server on Azure VMs](https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/availability-group-distributed-network-name-dnn-listener-configure)

---

## Step 6 — Endpoint Security

| Finding | Action |
|---------|--------|
| Endpoint not `STARTED` | Start with `ALTER ENDPOINT [name] STATE = STARTED` — AG cannot communicate without it |
| NTLM-only authentication | Use `NEGOTIATE` (Kerberos preferred, NTLM fallback) or `CERTIFICATE` for cross-domain scenarios |
| No mirroring endpoint found (empty result) | Create one — AG replicas require a `DATABASE_MIRRORING` endpoint for communication |
| Non-standard port | Ensure firewall rules allow traffic on the configured port between all replicas |
| `certificate_id` is 0 / NULL | If using certificate auth, ensure certificates are properly configured and not expired |

---

## Step 8 — Database-Level Configuration

| Finding | Action |
|---------|--------|
| Data movement suspended | Resume with `ALTER DATABASE [db] SET HADR RESUME`. Investigate the suspend reason first |
| Recovery model ≠ FULL | **Critical:** AG requires FULL recovery model. Change with `ALTER DATABASE [db] SET RECOVERY FULL` |
| AUTO_CLOSE = ON | Disable with `ALTER DATABASE [db] SET AUTO_CLOSE OFF` — causes unnecessary database restarts |
| AUTO_SHRINK = ON | Disable with `ALTER DATABASE [db] SET AUTO_SHRINK OFF` — causes fragmentation and transaction log growth spikes |
| PAGE_VERIFY ≠ CHECKSUM | Set to CHECKSUM with `ALTER DATABASE [db] SET PAGE_VERIFY CHECKSUM` for data integrity validation |

---

## Step 9 — Backup Configuration

| Finding | Action |
|---------|--------|
| No full backup found | Take a full backup immediately — without one the database cannot be restored and log chain is broken |
| Last full backup > 7 days ago | Review backup schedule — weekly full backups are a common baseline; adjust to your RPO |
| No log backup found | Set up regular log backups — without them, the transaction log will grow unbounded |
| Last log backup > 60 min ago | Check backup job health; log backups every 15–30 min is typical for production |
| Backup preference = `PRIMARY` | Consider `SECONDARY` or `PREFER_SECONDARY` to offload backup I/O from the primary |

---

## Step 10 — Azure Platform HA

| Finding | Action |
|---------|--------|
| GP/Standard tier | Consider Business Critical or Premium for local HA replicas and readable secondaries |
| No geo-replication configured (empty result) | For cross-region DR, set up active geo-replication or auto-failover groups |
| Geo-replication lagging > 30s | Check source database workload and network latency between regions |
| Geo-replication suspended | Investigate the cause — may require manual reseed or re-establishment of the link |
| MI failover group not SEEDED | Check data synchronization status; the failover group may still be seeding |

---

## Step 11 — Connection Resiliency

**Application-side connection resiliency best practices** (not queryable via T-SQL — document in report):

| Setting | Recommended Value | Notes |
|---------|-------------------|-------|
| `ConnectRetryCount` | 3 | Number of reconnection attempts after initial connection failure |
| `ConnectRetryInterval` | 10 seconds | Interval between reconnection attempts |
| `MultiSubnetFailover` | `true` | Required for AG listeners — enables parallel IP connection attempts |
| `Connection Timeout` | ≥ 30 seconds | Minimum for HA environments to allow failover completion |
| Retry logic | Exponential backoff | Handle transient errors: 40613, 40197, 40501, 49918, 49919, 49920 |

| Finding | Action |
|---------|--------|
| Remote login timeout < 10s | Increase with `EXEC sp_configure 'remote login timeout (s)', 20; RECONFIGURE;` |
| Applications not using `MultiSubnetFailover=true` | Update connection strings — without it, failover to a different subnet takes longer |
| No application-level retry logic | Implement retry with exponential backoff for transient error codes |
| Connection timeout < 30s | Increase to at least 30s to accommodate failover switchover time |

---

## Step 13 — Distributed & Contained AG

### Distributed Availability Groups

| Finding | Action |
|---------|--------|
| No ENDPOINT_URL on replica | Each underlying AG in a distributed AG **must** have a listener configured. Create a listener with `ALTER AVAILABILITY GROUP ... ADD LISTENER` on the underlying AG |
| Forwarder disconnected | Verify network connectivity between the two WSFCs/clusters. Check endpoint certificates if cross-domain. Validate listener DNS resolution from both sites |
| Forwarder lag > 5 minutes | Investigate network bandwidth between sites. Consider switching to asynchronous mode if latency is expected. Check `log_send_queue_size` for send backlog |
| Forwarder lag > 1 minute | Monitor trend — may indicate growing bandwidth constraint or IO bottleneck on forwarder. Review `redo_queue_size` on forwarder secondaries |
| Availability mode mismatch | Microsoft recommends both underlying AGs use the same availability mode. Mismatch (one SYNCHRONOUS, one ASYNCHRONOUS) introduces synchronization latency. Align with `ALTER AVAILABILITY GROUP ... MODIFY REPLICA ON ... WITH (AVAILABILITY_MODE = ...)` |
| Automatic failover configured | Distributed AGs only support manual failover (`FORCE_FAILOVER_ALLOW_DATA_LOSS` in SQL 2016, planned manual in SQL 2017+). Automatic failover setting is invalid and will not trigger |

**Distributed AG failover best practices:**
1. Verify forwarder is caught up: `last_hardened_lsn` should match or be close to `last_commit_lsn`
2. Stop application traffic to the primary AG
3. Change distributed AG to synchronous if currently asynchronous: `ALTER AVAILABILITY GROUP [DAG] MODIFY AVAILABILITY GROUP ON 'AG2' WITH (AVAILABILITY_MODE = SYNCHRONOUS_COMMIT)`
4. Wait for `synchronization_state_desc = 'SYNCHRONIZED'`
5. Execute planned failover: `ALTER AVAILABILITY GROUP [DAG] FAILOVER`
6. For disaster (primary unavailable): `ALTER AVAILABILITY GROUP [DAG] FORCE_FAILOVER_ALLOW_DATA_LOSS` — accept potential data loss

**Patching/upgrade order for distributed AGs:**
1. Patch secondary replicas in the secondary AG first
2. Patch secondary replicas in the primary AG
3. Failover the primary AG to a patched replica, then patch the old primary

### Contained Availability Groups (SQL 2022+)

| Finding | Action |
|---------|--------|
| System databases not synchronized | Check `master` and `msdb` sync state in `sys.dm_hadr_database_replica_states`. Contained AG logins, jobs, and linked servers reside in the contained `master`/`msdb` — if not synchronized, failover causes inconsistencies |
| Contained AG with distributed AG (SQL 2025+) | Ensure the contained AG was created with `AUTOSEEDING_SYSTEM_DATABASES` clause if used as a forwarder in a distributed AG |

**Contained AG best practices:**
- Create logins, SQL Agent jobs, and linked servers within the contained AG context (connect via listener) so they replicate to all replicas
- Do NOT create instance-level objects on individual replicas — they won't fail over
- Monitor system database sizes — `master`/`msdb` within the contained AG grow independently from the instance-level databases
- For distributed contained AGs (SQL 2025): use `CREATE AVAILABILITY GROUP ... WITH (CONTAINED, AUTOSEEDING_SYSTEM_DATABASES)` on the forwarder side
