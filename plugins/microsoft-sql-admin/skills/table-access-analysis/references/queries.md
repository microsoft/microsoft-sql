# Table Access Analysis — SQL Queries
Run all queries with the SQL query tool. Replace {{parameter}} placeholders with values from the skill parameters.

### Step 1: Detect Platform and Capabilities

> Execute with the SQL query tool — determines the SQL Server engine edition to route subsequent queries to platform-appropriate DMVs.

```sql
DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

SELECT
      CAST(SERVERPROPERTY('Edition') AS NVARCHAR(128))           AS sql_edition
    , CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(128))    AS sql_version
    , CASE @EngineEdition
        WHEN 1  THEN 'Personal / Desktop Engine'
        WHEN 2  THEN 'Standard'
        WHEN 3  THEN 'Enterprise'
        WHEN 4  THEN 'Express'
        WHEN 5  THEN 'Azure SQL Database'
        WHEN 6  THEN 'Azure Synapse Analytics (Dedicated SQL Pool)'
        WHEN 8  THEN 'Azure SQL Managed Instance'
        WHEN 9  THEN 'Azure SQL Edge'
        WHEN 11 THEN 'Azure Synapse Serverless SQL Pool / Microsoft Fabric (not supported by this skill)'
        WHEN 12 THEN 'Fabric SQL Database'
        ELSE         'SQL Server (on-prem / IaaS)'
      END                                                        AS engine_type
    , @EngineEdition                                             AS engine_edition
    , CASE WHEN @EngineEdition IN (6, 11) THEN 1 ELSE 0 END     AS is_unsupported_platform;
```

**What to do:**

| Finding | Recommendation |
|---------|----------------|
| `is_unsupported_platform = 1` (engine edition 6 or 11) | **Stop here** — this skill is not designed for Azure Synapse Analytics Dedicated SQL Pool (edition 6) or Azure Synapse Serverless SQL Pool / Microsoft Fabric Warehouse (edition 11). Index usage DMVs and table access patterns differ significantly in these environments. |
| `engine_edition = 12` (Fabric SQL Database) | Behaves like Azure SQL Database — proceed with all steps. |
| `engine_edition = 9` (Azure SQL Edge) | Proceed — DMV behavior is similar to SQL Server on-prem. |

---

### Step 2: Most Active Tables — Consolidated Ranking

> Execute with the SQL query tool — returns the top {{TopN}} most active tables ranked by combined read+write activity.

```sql
;WITH usage AS
(
    SELECT
        s.database_id,
        s.object_id,
        SUM(COALESCE(s.user_seeks, 0))     AS TotalSeeks,
        SUM(COALESCE(s.user_scans, 0))     AS TotalScans,
        SUM(COALESCE(s.user_lookups, 0))   AS TotalLookups,
        SUM(COALESCE(s.user_updates, 0))   AS TotalWrites, -- per-index sum; scales with index count, not raw table writes
        SUM(COALESCE(s.user_seeks,0)
          + COALESCE(s.user_scans,0)
          + COALESCE(s.user_lookups,0))    AS TotalReads,
        MAX(s.last_user_seek)              AS LastSeek,
        MAX(s.last_user_scan)              AS LastScan,
        MAX(s.last_user_lookup)            AS LastLookup,
        MAX(s.last_user_update)            AS LastUpdate
    FROM sys.dm_db_index_usage_stats s
    WHERE s.database_id = DB_ID()
    GROUP BY s.database_id, s.object_id
),
tbl_info AS
(
    SELECT
        DB_ID()                            AS database_id,
        t.object_id,
        t.name                             AS TableName,
        OBJECT_SCHEMA_NAME(t.object_id)    AS SchemaName,
        p.row_count                        AS ApproxRowCount,
        CASE
            WHEN EXISTS (
                SELECT 1 FROM sys.indexes ix
                WHERE ix.object_id = t.object_id AND ix.index_id = 0
            ) THEN 'HEAP'
            ELSE 'CLUSTERED'
        END                                AS TableStructure
    FROM sys.tables t
    INNER JOIN (
        SELECT object_id, SUM(row_count) AS row_count
        FROM sys.dm_db_partition_stats
        WHERE index_id IN (0,1)
        GROUP BY object_id
    ) p ON p.object_id = t.object_id
    WHERE t.is_ms_shipped = 0
),
combined AS
(
    SELECT
        ti.database_id,
        ti.SchemaName,
        ti.TableName,
        ti.TableStructure,
        ti.ApproxRowCount,
        COALESCE(u.TotalReads,0)       AS TotalReads,
        COALESCE(u.TotalWrites,0)      AS TotalWrites,
        COALESCE(u.TotalReads,0)
          + COALESCE(u.TotalWrites,0)  AS TotalActivity,
        COALESCE(u.TotalScans,0)       AS TotalScans,
        CASE
            WHEN COALESCE(u.TotalReads,0) = 0 THEN 0
            ELSE CAST(COALESCE(u.TotalScans,0) * 100.0
                     / NULLIF(u.TotalReads,0) AS DECIMAL(5,1))
        END                            AS ScanPct,
        (SELECT MAX(v)
         FROM (VALUES(u.LastSeek),(u.LastScan),(u.LastLookup),(u.LastUpdate)) AS x(v)
        )                              AS LastAccessedOverall,
        u.LastScan
    FROM tbl_info ti
    LEFT JOIN usage u
        ON u.object_id = ti.object_id
       AND u.database_id = ti.database_id
)

SELECT TOP ({{TopN}})
    ROW_NUMBER() OVER (ORDER BY TotalActivity DESC) AS Rank,
    DB_NAME(database_id)                            AS DatabaseName,
    SchemaName,
    TableName,
    LastAccessedOverall,
    LastScan,
    TotalActivity,
    TotalReads,
    TotalWrites,
    TableStructure,
    ApproxRowCount,
    ScanPct AS [Scan%],

    CASE
        WHEN TotalReads = 0 AND TotalWrites = 0 THEN 'No Activity'
        WHEN TotalReads > 10000 AND TotalWrites > 10000 THEN 'HOT (Read+Write)'
        WHEN TotalReads > 10000 THEN 'Read-Heavy'
        WHEN TotalWrites > 10000 THEN 'Write-Heavy'
        WHEN TotalActivity > 1000 THEN 'Moderate'
        ELSE 'Low Activity'
    END AS [Activity Class],

    CASE
        WHEN TotalReads = 0 AND TotalWrites = 0
            THEN 'Unused since restart – archive candidate'
        WHEN ScanPct > 80 AND TotalScans > 1000 AND TableStructure = 'HEAP'
            THEN 'Add clustered index (heap + high scan %)'
        WHEN ScanPct > 80 AND TotalScans > 1000
            THEN 'Review indexes (high scan %)'
        WHEN TotalReads > 10000 AND TotalWrites > 10000
            THEN 'Optimize for both read/write workload'
        WHEN TotalReads > 10000
            THEN 'Optimize read performance (index tuning)'
        WHEN TotalWrites > 10000
            THEN 'Check write contention / over-indexing'
        ELSE 'No immediate action'
    END AS Recommendation
FROM combined
ORDER BY TotalActivity DESC
OPTION (MAXDOP 1);
```

**What to do:**

| Finding | Recommendation |
|---------|----------------|
| `Activity Class` = HOT (Read+Write) | Most performance-sensitive table — ensure optimal indexing, review locking strategy |
| `Activity Class` = Read-Heavy | Ensure covering indexes exist; consider read replicas for offloading |
| `Activity Class` = Write-Heavy | Check for over-indexing; review transaction batch sizes |
| `Scan%` > 80 with high TotalScans | Missing or ineffective indexes causing full scans — review index design |
| `TableStructure` = HEAP with high activity | Add a clustered index to improve scan and seek performance |
| `No Activity` | Unused since restart — candidate for archival or removal |

---

### Step 3: Index Usage Per Table

> Execute with the SQL query tool — returns per-index usage detail (heap, clustered, nonclustered) showing seeks, scans, lookups, and drop candidates.

```sql
;WITH U AS
(
    SELECT
    database_id,
        object_id,
        index_id,
        user_seeks,
        user_scans,
        user_lookups,
        user_updates,
        last_user_scan,
        last_user_seek,
        last_user_lookup,
        last_user_update
    FROM sys.dm_db_index_usage_stats
    WHERE database_id = DB_ID()
)
SELECT
DB_NAME(database_id)                   AS DatabaseName,
sch.name                                  AS SchemaName,
    t.name                                    AS TableName,
    COALESCE(i.name, '(HEAP)')                AS IndexName,
    i.index_id                                AS IndexId,
    i.type_desc                               AS IndexType,
    u.last_user_scan                          AS LastScan,
    u.last_user_seek                          AS LastSeek,
    u.last_user_lookup                        AS LastLookup,
    COALESCE(u.user_seeks,0)
      + COALESCE(u.user_scans,0)
      + COALESCE(u.user_lookups,0)            AS TotalReads,
    COALESCE(u.user_updates,0)                AS UserUpdates,
    COALESCE(u.user_scans,0)                  AS UserScans,
    COALESCE(u.user_seeks,0)                  AS UserSeek,
    u.last_user_update                        AS LastUpdate,

    CASE
        WHEN i.index_id > 1
             AND COALESCE(u.user_seeks,0) + COALESCE(u.user_scans,0) + COALESCE(u.user_lookups,0) = 0
             AND COALESCE(u.user_updates,0) > 0
            THEN 'Drop candidate (unused index with maintenance overhead)'
        WHEN COALESCE(u.user_seeks,0) = 0
             AND COALESCE(u.user_scans,0) > 0
            THEN 'Review index design (scans only, no seeks)'
        WHEN COALESCE(u.user_lookups,0) > 1000
            THEN 'Consider covering index (high key lookups)'
        ELSE 'OK'
    END                                       AS Recommendation
FROM sys.tables   AS t
JOIN sys.schemas  AS sch ON sch.schema_id = t.schema_id
JOIN sys.indexes  AS i   ON i.object_id = t.object_id
LEFT JOIN U       AS u   ON u.object_id = i.object_id AND u.index_id = i.index_id
WHERE
    t.is_ms_shipped = 0
    AND i.is_hypothetical = 0
ORDER BY
    TotalReads DESC,
    sch.name,
    t.name,
    i.index_id
OFFSET 0 ROWS FETCH NEXT 500 ROWS ONLY
OPTION (MAXDOP 1);
```

**What to do:**

| Finding | Recommendation |
|---------|----------------|
| `Recommendation` = Drop candidate | Index has maintenance overhead but no reads — validate and consider dropping |
| Scans only, no seeks | Index design may not match query predicates — review WHERE/JOIN columns |
| High key lookups (> 1000) | Add included columns to make the index covering |

---

### Step 4: Unaccessed Tables Since Last Restart

> Execute with the SQL query tool — returns tables with zero access (seeks, scans, lookups, updates) since the last SQL Server restart — candidates for archival or removal.

```sql
SELECT
    OBJECT_SCHEMA_NAME(t.object_id)          AS SchemaName,
    t.name                                   AS TableName,
    p.row_count                              AS ApproxRowCount,
    (SELECT sqlserver_start_time
       FROM sys.dm_os_sys_info)              AS ServerStartedAt,
    CASE
        WHEN p.row_count = 0
            THEN 'Empty table — review for removal'
        WHEN p.row_count > 10000
            THEN 'Large unused table — verify if accessed by ETL/batch jobs not captured by DMVs'
        ELSE 'Review for archival or removal; check if referenced by stored procedures'
    END                                      AS Recommendation
FROM sys.tables AS t
INNER JOIN (
    SELECT object_id, SUM(row_count) AS row_count
    FROM sys.dm_db_partition_stats
    WHERE index_id IN (0, 1)
    GROUP BY object_id
) AS p ON p.object_id = t.object_id
WHERE t.is_ms_shipped = 0
    AND NOT EXISTS (
        SELECT 1
        FROM sys.dm_db_index_usage_stats AS s
        WHERE s.object_id  = t.object_id
          AND s.database_id = DB_ID()
          AND (
                s.user_seeks   > 0
             OR s.user_scans   > 0
             OR s.user_lookups > 0
             OR s.user_updates > 0
          )
    )
ORDER BY
    p.row_count DESC,
    SchemaName,
    TableName
    OPTION (MAXDOP 1);
```

**What to do:**

| Finding | Recommendation |
|---------|----------------|
| Empty table (0 rows) | Review for removal unless used as staging/landing |
| Large unused table (> 10K rows) | Verify not accessed by ETL/batch jobs outside DMV tracking window |
| Small unused table | Low priority — review for archival during housekeeping |

---

### Step 5: Hot-Spot Tables (High Reads and Writes)

> Execute with the SQL query tool — returns tables with high reads AND writes — typically the most performance-sensitive objects.

```sql
;WITH agg AS
(
    SELECT
        s.database_id,
        s.object_id,
        SUM(COALESCE(s.user_seeks, 0)
          + COALESCE(s.user_scans, 0)
          + COALESCE(s.user_lookups, 0))     AS TotalReads,
        SUM(COALESCE(s.user_updates, 0))     AS TotalWrites -- per-index sum; scales with index count, not raw table writes
    FROM sys.dm_db_index_usage_stats AS s
    WHERE s.database_id = DB_ID()   -- keep current DB scope
    GROUP BY s.database_id, s.object_id
)
SELECT
    DB_NAME(a.database_id)                   AS DatabaseName,
    sch.name                                 AS SchemaName,
    t.name                                   AS TableName,
    a.TotalReads,
    a.TotalWrites,
    a.TotalReads + a.TotalWrites             AS CombinedActivity,
    CASE
        WHEN a.TotalWrites = 0 THEN NULL
        ELSE CAST(a.TotalReads * 1.0 / a.TotalWrites AS DECIMAL(12,2))
    END                                      AS ReadWriteRatio,
    CASE
        WHEN a.TotalReads  > 1000 AND a.TotalWrites > 1000 THEN ' HOT (Read+Write)'
        WHEN a.TotalReads  > 1000                           THEN 'Read-Heavy'
        WHEN a.TotalWrites > 1000                           THEN 'Write-Heavy'
        ELSE 'Low Activity'
    END                                      AS ActivityClass,
    CASE
        WHEN a.TotalReads > 1000 AND a.TotalWrites > 1000
            THEN 'Optimize for both workloads; review locking strategy and isolation level'
        WHEN a.TotalReads > 1000
            THEN 'Ensure covering indexes; consider read replicas for offloading'
        WHEN a.TotalWrites > 1000
            THEN 'Check for over-indexing; review transaction size and batch patterns'
        ELSE 'No immediate action'
    END                                      AS Recommendation
FROM agg AS a
JOIN sys.tables  AS t   ON t.object_id = a.object_id
JOIN sys.schemas AS sch ON sch.schema_id = t.schema_id
WHERE t.is_ms_shipped = 0
ORDER BY CombinedActivity DESC
OPTION (MAXDOP 1, RECOMPILE);
```

**What to do:**

| Finding | Recommendation |
|---------|----------------|
| ReadWriteRatio close to 1.0 | Balanced workload — review isolation level (consider RCSI to reduce blocking) |
| ReadWriteRatio >> 1.0 | Read-dominated — optimize with covering indexes and read replicas |
| ReadWriteRatio << 1.0 | Write-dominated — check for over-indexing increasing write overhead |

---

### Step 6: Scan-Only Tables (Zero Seeks)

> Execute with the SQL query tool — returns tables where all access is via scans (zero seeks across all indexes) — strong signal for missing or poorly designed indexes.

```sql
;WITH idx AS
(
    SELECT
        s.database_id,
        s.object_id,
        SUM(COALESCE(s.user_seeks,   0)) AS TotalSeeks,
        SUM(COALESCE(s.user_scans,   0)) AS TotalScans,
        SUM(COALESCE(s.user_lookups, 0)) AS TotalLookups,
        SUM(COALESCE(s.user_updates, 0)) AS TotalWrites -- per-index sum; scales with index count, not raw table writes
    FROM sys.dm_db_index_usage_stats AS s
    WHERE s.database_id = DB_ID()          -- current DB scope
    GROUP BY s.database_id, s.object_id
)
SELECT
    DB_NAME(x.database_id)                 AS DatabaseName,
    sch.name                               AS SchemaName,
    t.name                                 AS TableName,
    x.TotalScans,
    x.TotalLookups,
    x.TotalWrites,
    CASE WHEN h.object_id IS NOT NULL
         THEN 'Yes' ELSE 'No'
    END                                    AS IsHeap,
    CASE
        WHEN h.object_id IS NOT NULL AND x.TotalScans > 1000
            THEN 'Add clustered index (heap with heavy scans)'
        WHEN h.object_id IS NOT NULL
            THEN 'Add clustered index (heap table)'
        WHEN x.TotalScans > 1000
            THEN 'Review nonclustered indexes to enable seeks instead of scans'
        ELSE 'Candidate for index review'
    END                                    AS Recommendation
FROM idx AS x
JOIN sys.tables  AS t   ON t.object_id = x.object_id
JOIN sys.schemas AS sch ON sch.schema_id = t.schema_id
LEFT JOIN sys.indexes AS h
    ON h.object_id = x.object_id
   AND h.index_id  = 0                     -- heap indicator
WHERE
    x.TotalSeeks = 0
    AND x.TotalScans > 0
    AND t.is_ms_shipped = 0
ORDER BY x.TotalScans DESC
OPTION (MAXDOP 1);
```

**What to do:**

| Finding | Recommendation |
|---------|----------------|
| Heap with heavy scans | Add a clustered index — heaps with only scans are the strongest signal for missing indexes |
| Non-heap with only scans | Review nonclustered indexes — query predicates may not match index key columns |

---

### Step 7: Last Access Timestamps Per Table

> Execute with the SQL query tool — returns last seek/scan/lookup/update timestamps per index to identify stale or unused indexes.

```sql
WITH idx_ts AS
(
    SELECT
        s.database_id,
        s.object_id,
        s.index_id,
        MAX(s.last_user_seek)   AS LastSeek,
        MAX(s.last_user_scan)   AS LastScan,
        MAX(s.last_user_lookup) AS LastLookup,
        MAX(s.last_user_update) AS LastUpdate
    FROM sys.dm_db_index_usage_stats AS s
    WHERE s.database_id = DB_ID()          -- current database scope
    GROUP BY s.database_id, s.object_id, s.index_id
),
idx_last AS
(
    SELECT
        it.database_id,
        it.object_id,
        it.index_id,
        ca.LastReadAccess,
        it.LastUpdate
    FROM idx_ts it
    CROSS APPLY
    (
        SELECT MAX(v) AS LastReadAccess
        FROM (VALUES (it.LastSeek),(it.LastScan),(it.LastLookup)) AS x(v)
    ) ca
)
SELECT
    DB_NAME(il.database_id)                AS DatabaseName,
    sch.name                               AS SchemaName,
    t.name                                 AS TableName,
    COALESCE(i.name, '(HEAP)')             AS IndexName,
    il.LastReadAccess,
    il.LastUpdate,
    CASE
        WHEN il.LastReadAccess IS NULL AND il.LastUpdate IS NOT NULL
            THEN 'Write-only — never read since restart — drop candidate'
        WHEN il.LastReadAccess IS NULL AND il.LastUpdate IS NULL
            THEN 'No access recorded since last restart — drop candidate'
        WHEN il.LastReadAccess < DATEADD(DAY, -90, GETDATE())
            THEN 'Stale (>90 days since last read) — review for removal'
        WHEN il.LastReadAccess < DATEADD(DAY, -30, GETDATE())
            THEN 'Stale (>30 days since last read) — monitor usage'
        ELSE 'Recently read'
    END                                    AS StalenessStatus
FROM idx_last AS il
JOIN sys.indexes  AS i   ON i.object_id = il.object_id AND i.index_id = il.index_id
JOIN sys.tables   AS t   ON t.object_id = i.object_id
JOIN sys.schemas  AS sch ON sch.schema_id = t.schema_id
WHERE
    t.is_ms_shipped = 0
    AND i.is_hypothetical = 0
ORDER BY
    il.LastReadAccess DESC
OPTION (MAXDOP 1, RECOMPILE);
```

**What to do:**

| Finding | Recommendation |
|---------|----------------|
| `StalenessStatus` = Write-only | Index is maintained but never read — strong drop candidate |
| `StalenessStatus` = Stale (>90 days) | Strong drop candidate — validate with application team |
| `StalenessStatus` = Stale (>30 days) | Monitor — may be used by monthly/quarterly processes |
| `StalenessStatus` = Recently read | Active index — no action needed |

---

### Supplementary: Rowcount Details

> Execute with the SQL query tool — returns the row count for a specific table.

```sql
-- The agent substitutes {{TableName}} (schema-qualified if needed) as a quoted literal; double any embedded single quotes
DECLARE @TableName NVARCHAR(256) = N'{{TableName}}'; 
SELECT
    TableName = OBJECT_NAME(object_id),
    [RowCount]  = SUM(row_count)
FROM sys.dm_db_partition_stats
WHERE object_id = OBJECT_ID(@TableName)
  AND index_id IN (0,1)   -- Heap or Clustered only
GROUP BY object_id
OPTION (MAXDOP 1);
```

---

### Supplementary: Table Definition

> Execute with the SQL query tool — returns column definitions for a specific table.

```sql
-- The agent substitutes {{SchemaName}} and {{TableName}} as quoted literals; double any embedded single quotes
DECLARE @SchemaName SYSNAME = N'{{SchemaName}}';  
DECLARE @TableName  SYSNAME = N'{{TableName}}';   
SELECT 
    ColumnName = c.name,
    DataType   = t.name,
    MaxLength  = c.max_length,
    Precision  = c.precision,
    Scale      = c.scale,
    IsNullable = c.is_nullable,
    IsIdentity = c.is_identity
FROM sys.columns c
JOIN sys.types t 
    ON c.user_type_id = t.user_type_id
WHERE c.object_id = OBJECT_ID(
        QUOTENAME(@SchemaName) + '.' + QUOTENAME(@TableName)
)
ORDER BY c.column_id
OPTION (MAXDOP 1);
```

---

### Supplementary: Compression Details

> Execute with the SQL query tool — returns compression settings for a specific table's partitions.

```sql
-- The agent substitutes {{TableName}} (schema-qualified if needed) as a quoted literal; double any embedded single quotes
DECLARE @TableName NVARCHAR(256) = N'{{TableName}}';

IF OBJECT_ID(@TableName) IS NULL
BEGIN
    PRINT 'Invalid table name';
    RETURN;
END

SELECT
    TableName   = OBJECT_NAME(p.object_id),
    PartitionNo = p.partition_number,
    Compression = p.data_compression_desc
FROM sys.partitions p
WHERE p.object_id = OBJECT_ID(@TableName)
ORDER BY p.partition_number
OPTION (MAXDOP 1);
```

---

### Supplementary: Partition Details

> Execute with the SQL query tool — returns partition layout including index type and row distribution for a specific table.

```sql
-- The agent substitutes {{TableName}} (schema-qualified if needed) as a quoted literal; double any embedded single quotes
DECLARE @TableName NVARCHAR(256) = N'{{TableName}}'; 
SELECT
    TableName        = OBJECT_NAME(p.object_id),
    IndexName        = i.name,
    IndexType        = i.type_desc,
    PartitionNumber  = p.partition_number,
    Rows             = p.rows,
    Compression      = p.data_compression_desc
FROM sys.partitions p
JOIN sys.indexes i 
    ON p.object_id = i.object_id 
   AND p.index_id = i.index_id
WHERE p.object_id = OBJECT_ID(@TableName)
ORDER BY i.index_id, p.partition_number
OPTION (MAXDOP 1);
```
