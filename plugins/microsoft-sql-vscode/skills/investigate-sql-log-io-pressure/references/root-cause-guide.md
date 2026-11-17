# Log IO Pressure — Root Cause Decision Tree

Use the findings from all investigation steps to determine the root cause and next steps.

---

## `WRITELOG` dominant + high log write latency (Step 3)

**Root cause: Log file IO bottleneck — storage cannot flush log records fast enough.**

Next steps:
1. On-premises: move the log file to a dedicated fast drive (SSD/NVMe). Do not share with data files.
2. Azure SQL: the log throughput governance limit is being hit — scale up the service tier or move to Hyperscale (which has significantly higher log rates).
3. Check `avg_bytes_per_write` — if very small, the workload is doing many tiny commits. Batch operations.
4. Ensure the log file is pre-sized appropriately to avoid auto-growth during pressure.

---

## `WRITELOG` dominant + normal latency but high frequency

**Root cause: Excessive log flush frequency — too many small commits.**

Next steps:
1. Batch small DML operations into explicit transactions (e.g., process 1000–5000 rows per batch).
2. Review application connection patterns — ORM frameworks often auto-commit each statement.
3. Use `SET IMPLICIT_TRANSACTIONS OFF` if implicit transactions are causing unnecessary commits.
4. Check Step 5 for queries with high execution count and moderate writes per execution.

---

## Log space > 80% used (Step 4a) + truncation holdup

**Root cause: Log cannot be truncated — space is being held.**

Next steps:
1. If `LOG_BACKUP`: **On-prem/MI:** take a transaction log backup immediately and schedule more frequent backups. **Azure SQL DB/Fabric:** backups are service-managed — if this persists, check for service health issues.
2. If `ACTIVE_TRANSACTION`: identify the blocking transaction from Step 4c. Resolve or terminate if safe.
3. If `REPLICATION`: check replication subscriber latency and log reader agent health.
4. If `AVAILABILITY_REPLICA`: check AG secondary synchronization state and network latency.

---

## Excessive VLFs (> 1000) in Step 4b

**Root cause: Log file fragmentation — many small VLFs from auto-growth events.**

Next steps:
1. **On-prem/MI:** Shrink the log file: `DBCC SHRINKFILE(log_file_name, 1)`, then regrow with fixed increments: `ALTER DATABASE [dbname] MODIFY FILE (NAME = log_file_name, SIZE = 8192MB, FILEGROWTH = 1024MB)`. Avoid percentage-based auto-growth for log files.
2. **Azure SQL DB/Fabric:** The transaction log file is service-managed — `ALTER DATABASE … MODIFY FILE` for the log is not supported. Excessive VLFs are generally not customer-actionable; if VLF fragmentation correlates with performance degradation, scale up the compute tier or open a support ticket with Microsoft.
3. Monitor after any changes to ensure VLF count stays reasonable.

---

## Large single transactions generating massive log (Step 2/5)

**Root cause: Unbatched bulk operations — single transactions generating GB of log.**

Next steps:
1. Break large INSERT/UPDATE/DELETE operations into smaller batches (5K–10K rows per transaction).
2. For large data loads: use BULK INSERT or bcp with TABLOCK hint in SIMPLE or BULK_LOGGED recovery model.
3. Consider switch-partition operations for large table rebuilds instead of DELETE + INSERT.
4. If using FULL recovery model, ensure log backups run frequently during bulk operations.
