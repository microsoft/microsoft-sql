# Azure SQL DB / MI / Fabric Queries

Run each query with the SQL query tool. SQL CASE columns produce inline PASS/FAIL/WARNING verdicts.

---

## Step 10: Platform HA Assessment

### Service Tier Assessment (Azure SQL DB edition 5 and MI edition 8)

> **Guard:** `DATABASEPROPERTYEX(..., 'ServiceObjective'/'Edition')` is only populated on Azure SQL Database (edition 5) and Fabric (edition 12). On Managed Instance (edition 8) both return NULL, so the tier is read from the MI-supported source `sys.server_resource_stats.sku` instead.

```sql
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

IF @EngineEdition = 8   -- Azure SQL Managed Instance
BEGIN
    SELECT TOP (1)
        DB_NAME() AS database_name,
        s.sku AS service_objective,
        CASE
            WHEN s.sku LIKE 'BC[_]%' THEN 'Business Critical'
            WHEN s.sku LIKE 'GP[_]%' THEN 'General Purpose'
            ELSE s.sku
        END AS edition,
        CAST(NULL AS NVARCHAR(60)) AS state_desc,
        CASE
            WHEN s.sku LIKE 'BC[_]%'
                THEN 'PASS: Business Critical tier — local HA replicas with automatic failover'
            WHEN s.sku LIKE 'GP[_]%'
                THEN 'INFO: General Purpose — remote storage HA, no local read replicas'
            ELSE 'INFO: ' + ISNULL(s.sku, 'Unknown') + ' tier'
        END AS ha_tier_assessment
    FROM sys.server_resource_stats s
    ORDER BY s.end_time DESC
    OPTION (MAXDOP 1);
END
ELSE   -- Azure SQL Database (edition 5) / Fabric (edition 12)
BEGIN
    SELECT
        d.name AS database_name,
        CAST(DATABASEPROPERTYEX(d.name, 'ServiceObjective') AS VARCHAR(128)) AS service_objective,
        CAST(DATABASEPROPERTYEX(d.name, 'Edition') AS VARCHAR(50)) AS edition,
        d.state_desc,
        CASE
            WHEN CAST(DATABASEPROPERTYEX(d.name, 'Edition') AS VARCHAR(50)) = 'Business Critical'
                THEN 'PASS: Business Critical tier — local HA replicas with automatic failover'
            WHEN CAST(DATABASEPROPERTYEX(d.name, 'Edition') AS VARCHAR(50)) = 'Premium'
                THEN 'PASS: Premium tier — local HA replicas with automatic failover'
            WHEN CAST(DATABASEPROPERTYEX(d.name, 'Edition') AS VARCHAR(50)) IN ('General Purpose', 'Standard')
                THEN 'INFO: GP/Standard — remote storage HA, no local read replicas'
            WHEN CAST(DATABASEPROPERTYEX(d.name, 'Edition') AS VARCHAR(50)) = 'Hyperscale'
                THEN 'INFO: Hyperscale — page server architecture, configurable read replicas'
            ELSE 'INFO: ' + ISNULL(CAST(DATABASEPROPERTYEX(d.name, 'Edition') AS VARCHAR(50)), 'Unknown')
                 + ' tier'
        END AS ha_tier_assessment
    FROM sys.databases d
    WHERE d.database_id = DB_ID()
    OPTION (MAXDOP 1);
END
```

### Geo-Replication (Azure SQL DB edition 5 only)

> **Guard:** Skip on Fabric (edition 12) — `sys.dm_geo_replication_link_status` does not exist.

```sql
IF OBJECT_ID('sys.dm_geo_replication_link_status') IS NOT NULL
BEGIN
    SELECT
        link_guid,
        partner_server,
        partner_database,
        replication_state_desc,
        role_desc,
        secondary_allow_connections_desc,
        last_replication,
        replication_lag_sec,
        CASE WHEN replication_state_desc = 'SUSPENDED'
             THEN 'FAIL: Geo-replication suspended'
             WHEN replication_state_desc = 'CATCH_UP' AND replication_lag_sec > 30
             THEN 'WARNING: Geo-replication lagging > 30s'
             WHEN replication_state_desc <> 'CATCH_UP'
             THEN 'WARNING: Geo-replication in-progress/not failover-ready (' + replication_state_desc + ')'
             ELSE 'PASS' END AS geo_replication_assessment
    FROM sys.dm_geo_replication_link_status
    OPTION (MAXDOP 1);
END
ELSE
    SELECT 'INFO: Geo-replication DMV not available on this platform' AS geo_replication_assessment;
```

### Failover Groups (Azure SQL MI edition 8 only)

```sql
SELECT
    link_guid,
    partner_server,
    partner_database,
    last_replication,
    replication_lag_sec,
    replication_state,
    replication_state_desc,
    role,
    role_desc,
    secondary_allow_connections,
    secondary_allow_connections_desc,
    last_commit,
    CASE WHEN replication_state_desc = 'SUSPENDED'
         THEN 'FAIL: Failover group replication suspended'
         WHEN replication_state_desc = 'CATCH_UP' AND replication_lag_sec > 30
         THEN 'WARNING: Failover group replication lagging > 30s'
         WHEN replication_state_desc <> 'CATCH_UP'
         THEN 'WARNING: Failover group replication not healthy'
         ELSE 'PASS' END AS failover_group_assessment
FROM sys.dm_geo_replication_link_status
OPTION (MAXDOP 1);
```

---

## Step 11: Connection Resiliency (all platforms)

```sql
SELECT
    name AS setting_name,
    CAST(value_in_use AS INT) AS current_value,
    CASE
        WHEN name = 'remote login timeout (s)' AND CAST(value_in_use AS INT) < 10
            THEN 'WARNING: Low remote login timeout may cause connection failures during failover'
        WHEN name = 'remote query timeout (s)' AND CAST(value_in_use AS INT) = 0
            THEN 'INFO: No remote query timeout — queries wait indefinitely'
        ELSE 'PASS'
    END AS assessment
FROM sys.configurations
WHERE name IN (
    'remote login timeout (s)',
    'remote query timeout (s)',
    'cost threshold for parallelism',
    'max degree of parallelism'
)
ORDER BY name
OPTION (MAXDOP 1);
```

**Note:** Also recommend in report: `ConnectRetryCount=3`, `MultiSubnetFailover=true`, `Connection Timeout ≥ 30s`, retry logic for transient errors (40613, 40197, 40501).
