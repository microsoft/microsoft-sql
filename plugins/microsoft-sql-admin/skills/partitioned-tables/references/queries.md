# Partitioned Tables Analysis — SQL Queries
Run all queries with the SQL query tool. Replace {{parameter}} placeholders with values from the skill parameters.

### Step 1: Detect Platform and Capabilities

> Run with the SQL query tool. Determines the SQL Server engine edition and version to route
subsequent queries to platform-appropriate DMVs.

> | EngineEdition | Platform | Supported | Notes |
|---|---|---|---|
| 1 | Personal / Desktop Engine | Yes | Legacy; not available in SQL Server 2005+ |
| 2 | Standard | Yes | Standard, Developer, Web, BI editions |
| 3 | Enterprise | Yes | Enterprise, Developer, Evaluation editions |
| 4 | Express | Yes | Express editions |
| 5 | Azure SQL Database | Yes | Single-database scope |
| 6 | Azure Synapse Analytics (Dedicated SQL Pool) | **No** | Partitioning behavior differs significantly — stop here |
| 8 | Azure SQL Managed Instance | Yes | Instance-wide scope |
| 9 | Azure SQL Edge | Yes | DMV behavior similar to SQL Server on-prem |
| 11 | Azure Synapse Serverless SQL Pool / Microsoft Fabric (non-SQL DB) | **No** | Partitioning DMVs not available — stop here |
| 12 | Fabric SQL Database | Yes | Behaves like Azure SQL Database |
| other | SQL Server on-prem / IaaS | Yes | Full DMV access |

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

**Interpreting results:**
- `is_unsupported_platform = 1`: **Stop here** — this skill is not designed for Azure Synapse Dedicated SQL Pool (edition 6) or Azure Synapse Serverless SQL Pool / Microsoft Fabric Warehouse (edition 11). Partitioning in these environments uses a fundamentally different distribution model.
- `engine_edition = 12` (Fabric SQL Database): Behaves like Azure SQL Database — proceed with all steps.
- `engine_edition = 9` (Azure SQL Edge): Proceed — DMV behavior is similar to SQL Server on-prem.

**What to do:**
| Finding | Recommendation |
|---------|----------------|
| `is_unsupported_platform` = 1 | Stop — this skill is not designed for Azure Synapse Dedicated SQL Pool or Azure Synapse Serverless SQL Pool / Microsoft Fabric Warehouse |
| `engine_edition` = 12 | Fabric SQL Database — proceed with all steps |
| Other editions | Proceed to Step 2 |

### Step 2: Discover Partitioned Tables

> Run with the SQL query tool. Lists every partitioned table in the current database with partition count, row count, total size, partition function, and boundary ranges.

```sql
;WITH pt AS
(
    SELECT
        t.object_id,
        SCHEMA_NAME(t.schema_id)          AS SchemaName,
        t.name                            AS TableName,
        ps.name                           AS PartitionScheme,
        pf.name                           AS PartitionFunction,
        pf.fanout                         AS PartitionCount,
        CASE pf.boundary_value_on_right
            WHEN 1 THEN 'RIGHT'
            ELSE 'LEFT'
        END                               AS BoundaryType,
        SUM(CAST(p.[rows] AS BIGINT))     AS TotalRows,
        SUM(CAST(a.total_pages AS BIGINT)) * 8 / 1024  AS TotalSizeMB
    FROM sys.tables t
    INNER JOIN sys.indexes i
        ON t.object_id = i.object_id AND i.index_id IN (0,1)
    INNER JOIN sys.partition_schemes ps
        ON i.data_space_id = ps.data_space_id
    INNER JOIN sys.partition_functions pf
        ON ps.function_id = pf.function_id
    INNER JOIN sys.partitions p
        ON i.object_id = p.object_id AND i.index_id = p.index_id
    INNER JOIN sys.allocation_units a
        ON p.partition_id = a.container_id
    GROUP BY t.object_id, t.schema_id, t.name, ps.name, pf.name, pf.fanout, pf.boundary_value_on_right
),
ranges AS
(
    SELECT
        pf.name AS PartitionFunction,
        MIN(CAST(prv.value AS NVARCHAR(100))) AS MinBoundary,
        MAX(CAST(prv.value AS NVARCHAR(100))) AS MaxBoundary
    FROM sys.partition_functions pf
    INNER JOIN sys.partition_range_values prv
        ON pf.function_id = prv.function_id
    GROUP BY pf.name
)
SELECT
    pt.SchemaName,
    pt.TableName,
    pt.PartitionScheme,
    pt.PartitionFunction,
    pt.PartitionCount,
    pt.BoundaryType,
    pt.TotalRows,
    pt.TotalSizeMB,
    r.MinBoundary,
    r.MaxBoundary,
    CASE
        WHEN pt.TotalRows = 0 THEN 'Empty partitioned table — verify if still needed'
        WHEN pt.PartitionCount <= 2 THEN 'Very few partitions — verify partition strategy'
        ELSE 'Run Steps 4+ for detailed health analysis'
    END AS Recommendation
FROM pt
LEFT JOIN ranges r ON pt.PartitionFunction = r.PartitionFunction
ORDER BY pt.TotalSizeMB DESC, pt.TotalRows DESC
OPTION (MAXDOP 1);
```

**What to do:**
| Finding | Recommendation |
|---------|----------------|
| Multiple partitioned tables found | Review sizes and partition counts. Run Steps 4+ for each table that needs analysis |
| No rows returned | Database has no partitioned tables — this skill is not applicable |
| Very large tables (GB+) with few partitions | May benefit from more granular partitioning — run Step 6 for boundary health |
| Tables sharing the same partition function | Changes to boundaries affect all tables — review together |
| Empty partitioned tables (TotalRows = 0) | Verify whether the table is still needed or if data loading is pending |

### Step 3: Check If Table Is Partitioned

> Run with the SQL query tool. Checks whether the specified table uses a partition scheme.

```sql
SELECT 
    t.name AS TableName,
    CASE 
        WHEN ps.name IS NOT NULL THEN 'YES'
        ELSE 'NO'
    END AS IsPartitioned,
    ps.name AS PartitionScheme,
    CASE
        WHEN ps.name IS NOT NULL THEN 'Run partition metadata analysis for distribution and skew'
        ELSE 'Consider partitioning if table is large and has date/range-based access patterns'
    END AS Recommendation
FROM sys.tables t
JOIN sys.indexes i 
    ON t.object_id = i.object_id 
    AND i.index_id IN (0,1)   -- heap or clustered index
LEFT JOIN sys.partition_schemes ps 
    ON i.data_space_id = ps.data_space_id
WHERE t.object_id = OBJECT_ID(QUOTENAME(N'{{SchemaName}}') + N'.' + QUOTENAME(N'{{TableName}}'))
OPTION (MAXDOP 1);
```

**What to do:**
| Finding | Recommendation |
|---------|----------------|
| `IsPartitioned` = YES | Proceed to Step 4 for full partition metadata analysis |
| `IsPartitioned` = NO | Table is not partitioned — consider partitioning if large with date/range-based access |

### Step 4: Partition Metadata and Distribution Analysis

> Run with the SQL query tool. Retrieves partition metadata, row distribution, and skew analysis for the target table.

```sql

;WITH PartitionInfo AS
(
    SELECT 
        t.name                          AS TableName,
        i.name                          AS IndexName,
        i.type_desc                     AS IndexType,
        p.partition_number              AS PartitionNumber,
        ps.name                         AS PartitionScheme,
        pf.name                         AS PartitionFunction,
        c.name                          AS PartitionColumn,
        TYPE_NAME(c.user_type_id)       AS ColumnDataType,
        p.[rows]                        AS [RowCount],
        ds.row_count                    AS RowCountDMV,
        CAST(ds.reserved_page_count * 8.0 / 1024 AS DECIMAL(18,2)) AS ReservedMB,
        CAST(ds.used_page_count    * 8.0 / 1024 AS DECIMAL(18,2)) AS UsedMB,
        prv.value                       AS RangeBoundary
    FROM sys.tables t
    JOIN sys.indexes i 
        ON t.object_id = i.object_id 
        AND i.index_id IN (0, 1)
    JOIN sys.partitions p 
        ON i.object_id = p.object_id 
        AND i.index_id = p.index_id
    JOIN sys.dm_db_partition_stats ds 
        ON p.partition_id = ds.partition_id
    LEFT JOIN sys.partition_schemes ps 
        ON i.data_space_id = ps.data_space_id
    LEFT JOIN sys.partition_functions pf 
        ON ps.function_id = pf.function_id
    LEFT JOIN sys.index_columns ic 
        ON i.object_id = ic.object_id 
        AND i.index_id = ic.index_id 
        AND ic.partition_ordinal = 1
    LEFT JOIN sys.columns c 
        ON ic.object_id = c.object_id 
        AND ic.column_id = c.column_id
    LEFT JOIN sys.partition_range_values prv 
        ON pf.function_id = prv.function_id 
        AND prv.boundary_id = CASE pf.boundary_value_on_right
            WHEN 0 THEN p.partition_number
            ELSE p.partition_number - 1
        END
    WHERE t.object_id = OBJECT_ID(QUOTENAME(N'{{SchemaName}}') + N'.' + QUOTENAME(N'{{TableName}}'))
)
SELECT 
    TableName,
    IndexName,
    IndexType,
    PartitionScheme,
    PartitionFunction,
    PartitionColumn,
    ColumnDataType,
    PartitionNumber,
    RangeBoundary,
    [RowCount],
    RowCountDMV,
    ReservedMB,
    UsedMB,

    -- ── Distribution Analysis ──
    SUM([RowCount]) OVER ()                                     AS TotalRows,
    CAST(
        CASE WHEN SUM([RowCount]) OVER () = 0 THEN 0
             ELSE [RowCount] * 100.0 / SUM([RowCount]) OVER ()
        END AS DECIMAL(8,2))                                    AS PctOfTotal,

    AVG([RowCount]) OVER ()                                     AS AvgRowsPerPartition,

    -- ── Skew Detection ──
    CAST(
        CASE WHEN AVG([RowCount]) OVER () = 0 THEN 0
             ELSE ABS([RowCount] - AVG([RowCount]) OVER ()) * 100.0 
                  / AVG([RowCount]) OVER ()
        END AS DECIMAL(8,2))                                    AS SkewPct,

    CASE 
        WHEN AVG([RowCount]) OVER () = 0 THEN 'EMPTY'
        WHEN ABS([RowCount] - AVG([RowCount]) OVER ()) * 100.0 
             / AVG([RowCount]) OVER () > 50 THEN 'HIGH SKEW'
        WHEN ABS([RowCount] - AVG([RowCount]) OVER ()) * 100.0 
             / AVG([RowCount]) OVER () > 25 THEN 'MODERATE SKEW'
        ELSE 'BALANCED'
    END                                                         AS SkewStatus,

    -- ── Empty Partition Flag ──
    CASE WHEN [RowCount] = 0 THEN 'EMPTY' ELSE '' END          AS EmptyFlag,

    -- ── Action Recommendation ──
    CASE 
        WHEN [RowCount] = 0 THEN 'Candidate for partition merge'
        WHEN AVG([RowCount]) OVER () > 0
             AND ABS([RowCount] - AVG([RowCount]) OVER ()) * 100.0 
                  / AVG([RowCount]) OVER () > 50 THEN 'Consider re-evaluating partition boundaries'
        ELSE 'No action needed'
    END                                                         AS Action

FROM PartitionInfo
ORDER BY PartitionNumber
OPTION (MAXDOP 1);
```

**What to do:**
| Finding | Recommendation |
|---------|----------------|
| `SkewStatus` = HIGH SKEW | Partition boundaries may need rebalancing — data is unevenly distributed |
| `SkewStatus` = MODERATE SKEW | Monitor — may be acceptable depending on access patterns |
| `EmptyFlag` = EMPTY | Candidate for partition merge — empty partitions add management overhead |
| `PctOfTotal` very high for one partition | Hot partition — most queries likely hit this partition |

### Step 5: Index Fragmentation Per Partition

> Run with the SQL query tool. Scans index fragmentation for every index and partition on the target table and provides maintenance recommendations.

```sql
  SET NOCOUNT ON;

----------------------------------------------------------------------
-- 1) Resolve OBJECT_ID once
----------------------------------------------------------------------
DECLARE @ObjectId INT = OBJECT_ID(QUOTENAME(N'{{SchemaName}}') + N'.' + QUOTENAME(N'{{TableName}}'));

IF @ObjectId IS NULL
BEGIN
    RAISERROR('Table [%s].[%s] not found in current database.', 16, 1, N'{{SchemaName}}', N'{{TableName}}');
    RETURN;
END;

----------------------------------------------------------------------
-- 2) ONE physical stats call for ALL indexes + ALL partitions (leaf, in-row)
----------------------------------------------------------------------
SELECT 
    ips.object_id,
    ips.index_id,
    ips.partition_number,
    ips.avg_fragmentation_in_percent,
    ips.page_count,
    ips.compressed_page_count
INTO #FragStats
FROM sys.dm_db_index_physical_stats(DB_ID(), @ObjectId, NULL, NULL, N'{{ScanMode}}') AS ips
WHERE ips.index_level = 0
  AND ips.alloc_unit_type_desc = 'IN_ROW_DATA'
  OPTION (MAXDOP 1);

CREATE CLUSTERED INDEX IX_FragStats ON #FragStats(index_id, partition_number);

----------------------------------------------------------------------
-- 3) Build correct RangeBoundary per partition using destination_id mapping
--    (handles RANGE LEFT/RIGHT correctly)
----------------------------------------------------------------------
SELECT
    i.index_id,
    dds.destination_id AS partition_number,
    rv.value          AS RangeBoundary
INTO #RangeMap
FROM sys.indexes AS i
LEFT JOIN sys.partition_schemes   AS ps ON i.data_space_id = ps.data_space_id
LEFT JOIN sys.partition_functions AS pf ON ps.function_id  = pf.function_id
LEFT JOIN sys.destination_data_spaces AS dds ON dds.partition_scheme_id = ps.data_space_id
LEFT JOIN sys.partition_range_values AS rv
    ON rv.function_id = pf.function_id
   AND dds.destination_id = CASE pf.boundary_value_on_right
                                WHEN 0 THEN rv.boundary_id
                                ELSE rv.boundary_id + 1
                            END
WHERE i.object_id = @ObjectId
OPTION (MAXDOP 1);

CREATE CLUSTERED INDEX IX_RangeMap ON #RangeMap(index_id, partition_number);

----------------------------------------------------------------------
-- 4) Final output (MaintenanceScript removed)
----------------------------------------------------------------------
SELECT
    t.name                                  AS TableName,
    ISNULL(i.name, N'** HEAP **')           AS IndexName,
    i.index_id                              AS IndexId,
    p.partition_number                      AS PartitionNumber,
    rm.RangeBoundary                        AS RangeBoundary,
    fs.compressed_page_count                AS CompressedPages,

    CAST(fs.avg_fragmentation_in_percent AS decimal(8,2)) AS FragPct,
    fs.page_count                           AS PageCount,

    CASE
        WHEN i.is_disabled = 1 THEN N'DISABLED INDEX - REBUILD TO ENABLE'
        WHEN fs.page_count IS NULL THEN N'NO STATS (check ScanMode / allocation)'
        WHEN fs.page_count < {{MinPageCount}} THEN CONCAT(N'SKIP (<', {{MinPageCount}}, N' pages)')
        WHEN fs.avg_fragmentation_in_percent < 5 THEN N'OK - NO ACTION'
        WHEN fs.avg_fragmentation_in_percent <= 30 THEN N'REORGANIZE'
        ELSE N'REBUILD'
    END AS MaintenanceRecommendation
FROM sys.tables AS t
JOIN sys.indexes AS i
    ON t.object_id = i.object_id
JOIN sys.partitions AS p
    ON p.object_id = i.object_id
   AND p.index_id  = i.index_id
LEFT JOIN #FragStats AS fs
    ON fs.index_id = i.index_id
   AND fs.partition_number = p.partition_number
LEFT JOIN #RangeMap AS rm
    ON rm.index_id = i.index_id
   AND rm.partition_number = p.partition_number
WHERE t.object_id = @ObjectId
ORDER BY
    i.index_id,
    p.partition_number
    OPTION (MAXDOP 1);

----------------------------------------------------------------------
-- 5) Cleanup
----------------------------------------------------------------------
DROP TABLE IF EXISTS #FragStats;
DROP TABLE IF EXISTS #RangeMap;
```

**What to do:**
| Finding | Recommendation |
|---------|----------------|
| `MaintenanceRecommendation` = REBUILD | Fragmentation > 30% — rebuild the index on this partition |
| `MaintenanceRecommendation` = REORGANIZE | Fragmentation 5-30% — reorganize the index on this partition |
| `DISABLED INDEX` | Index is disabled — rebuild to re-enable |
| `CompressedPages` > 0 | Partition uses compression — REORGANIZE preserves compression, REBUILD may need explicit compression option |

### Step 6: Partition Boundary Health Diagnostic

> Run with the SQL query tool. Analyzes partition boundaries for issues like off-by-one errors, duplicate values, inconsistent intervals, and empty partitions.

```sql
SET NOCOUNT ON;

----------------------------------------------------------------------
-- 1. Resolve object & validate
----------------------------------------------------------------------
DECLARE @ObjectId INT = OBJECT_ID(QUOTENAME(N'{{SchemaName}}') + N'.' + QUOTENAME(N'{{TableName}}'));

IF @ObjectId IS NULL
BEGIN
    RAISERROR('Table [%s].[%s] not found in current database.', 16, 1, N'{{SchemaName}}', N'{{TableName}}');
    RETURN;
END

----------------------------------------------------------------------
-- 2. Materialize boundaries into temp table with explicit CAST
--    (eliminates all sql_variant implicit conversion errors)
----------------------------------------------------------------------
SELECT 
    pf.name                             AS PartitionFunction,
    pf.function_id                      AS FunctionId,
    pf.fanout                           AS TotalPartitions,
    pf.boundary_value_on_right          AS IsRightBound,
    pc.name                             AS PartitionColumn,
    TYPE_NAME(pc.user_type_id)          AS ColumnDataType,
    t.name                              AS TableName,
    i.index_id                          AS IndexId
INTO #PartMeta
FROM sys.tables t
JOIN sys.indexes i 
    ON t.object_id = i.object_id AND i.index_id IN (0, 1)
JOIN sys.partition_schemes ps 
    ON i.data_space_id = ps.data_space_id
JOIN sys.partition_functions pf 
    ON ps.function_id = pf.function_id
JOIN sys.index_columns ic 
    ON i.object_id = ic.object_id 
    AND i.index_id = ic.index_id 
    AND ic.partition_ordinal = 1
JOIN sys.columns pc 
    ON ic.object_id = pc.object_id 
    AND ic.column_id = pc.column_id
WHERE t.object_id = @ObjectId
OPTION (MAXDOP 1);

----------------------------------------------------------------------
-- 3. Materialize boundary values with EXPLICIT casts out of sql_variant
----------------------------------------------------------------------
SELECT 
    prv.boundary_id,
    prv.value                                           AS BoundaryValueRaw,
    CONVERT(NVARCHAR(50), prv.value, 121)               AS BoundaryValueStr,

    -- Safe datetime2 cast (NULL for non-date types)
    CASE 
        WHEN SQL_VARIANT_PROPERTY(prv.value, 'BaseType') 
             IN ('date','datetime','datetime2','smalldatetime','datetimeoffset')
        THEN CAST(CAST(prv.value AS DATETIME2) AS DATETIME2)
        ELSE NULL
    END                                                 AS BoundaryAsDatetime2,

    -- Safe bigint cast (NULL for non-numeric types)
    CASE 
        WHEN SQL_VARIANT_PROPERTY(prv.value, 'BaseType') 
             IN ('int','bigint','smallint','tinyint')
        THEN CAST(CAST(prv.value AS BIGINT) AS BIGINT)
        ELSE NULL
    END                                                 AS BoundaryAsBigint

INTO #Boundaries
FROM sys.partition_range_values prv
WHERE prv.function_id = (SELECT TOP 1 FunctionId FROM #PartMeta)
OPTION (MAXDOP 1);

----------------------------------------------------------------------
-- 4. Add LAG/LEAD on materialized (properly typed) columns
----------------------------------------------------------------------
SELECT 
    b.boundary_id,
    b.BoundaryValueRaw,
    b.BoundaryValueStr,
    b.BoundaryAsDatetime2,
    b.BoundaryAsBigint,

    LAG(b.BoundaryAsDatetime2)  OVER (ORDER BY b.boundary_id) AS PrevBoundaryDt,
    LEAD(b.BoundaryAsDatetime2) OVER (ORDER BY b.boundary_id) AS NextBoundaryDt,

    LAG(b.BoundaryAsBigint)     OVER (ORDER BY b.boundary_id) AS PrevBoundaryInt,
    LEAD(b.BoundaryAsBigint)    OVER (ORDER BY b.boundary_id) AS NextBoundaryInt

INTO #BoundaryWithNeighbors
FROM #Boundaries b
OPTION (MAXDOP 1);

----------------------------------------------------------------------
-- 5. Join with partition row counts + run diagnostics
----------------------------------------------------------------------
SELECT 
    pm.TableName,
    pm.PartitionFunction,
    pm.PartitionColumn,
    pm.ColumnDataType,
    pm.TotalPartitions,
    CASE WHEN pm.IsRightBound = 1 
         THEN 'RIGHT (boundary belongs to RIGHT partition)' 
         ELSE 'LEFT (boundary belongs to LEFT partition)' 
    END                                     AS BoundaryType,
    bn.BoundaryValueStr                     AS BoundaryValue,
    bn.boundary_id                          AS BoundaryId,

    -- Map boundary to partition number
    CASE WHEN pm.IsRightBound = 1 THEN bn.boundary_id + 1 ELSE bn.boundary_id END
                                            AS PartitionNumber,

    ISNULL(p.[rows], 0)                     AS [RowCount],

    -- ══════════════════════════════════════════════
    -- ISSUE DETECTION
    -- ══════════════════════════════════════════════

    CASE 
        --------------------------------------------------
        -- A. Empty partition
        --------------------------------------------------
        WHEN p.[rows] = 0 
            THEN 'EMPTY PARTITION - candidate for merge'

        --------------------------------------------------
        -- B. Date off-by-1: RIGHT boundary non-midnight
        --------------------------------------------------
        WHEN pm.ColumnDataType IN ('date','datetime','datetime2','smalldatetime','datetimeoffset')
             AND pm.IsRightBound = 1
             AND bn.BoundaryAsDatetime2 IS NOT NULL
             AND CAST(bn.BoundaryAsDatetime2 AS TIME) <> '00:00:00'
            THEN 'POSSIBLE OFF-BY-1: RIGHT boundary has non-midnight time ['
                 + CONVERT(NVARCHAR(30), bn.BoundaryAsDatetime2, 121) + ']'

        --------------------------------------------------
        -- C. Date off-by-1: LEFT boundary at 23:59:59
        --------------------------------------------------
        WHEN pm.ColumnDataType IN ('date','datetime','datetime2','smalldatetime','datetimeoffset')
             AND pm.IsRightBound = 0
             AND bn.BoundaryAsDatetime2 IS NOT NULL
             AND CAST(bn.BoundaryAsDatetime2 AS TIME) >= '23:59:59'
            THEN 'POSSIBLE OFF-BY-1: LEFT boundary at 23:59:59 — may miss sub-second rows'

        --------------------------------------------------
        -- D. Duplicate boundary value
        --------------------------------------------------
        WHEN bn.BoundaryValueStr = LAG(bn.BoundaryValueStr) 
                                       OVER (ORDER BY bn.boundary_id)
            THEN 'DUPLICATE BOUNDARY VALUE - creates zero-width partition'

        --------------------------------------------------
        -- E. Inconsistent date interval
        --------------------------------------------------
        WHEN pm.ColumnDataType IN ('date','datetime','datetime2','smalldatetime','datetimeoffset')
             AND bn.PrevBoundaryDt IS NOT NULL
             AND bn.NextBoundaryDt IS NOT NULL
             AND DATEDIFF(DAY, bn.PrevBoundaryDt, bn.BoundaryAsDatetime2) 
                 <> DATEDIFF(DAY, bn.BoundaryAsDatetime2, bn.NextBoundaryDt)
             AND NOT (
                 -- Tolerate month-aligned boundaries (28-31 day gaps are normal for monthly partitions)
                 DATEDIFF(MONTH, bn.PrevBoundaryDt, bn.BoundaryAsDatetime2) = 
                 DATEDIFF(MONTH, bn.BoundaryAsDatetime2, bn.NextBoundaryDt)
                 AND DATEPART(DAY, bn.PrevBoundaryDt) = DATEPART(DAY, bn.BoundaryAsDatetime2)
             )
            THEN 'INCONSISTENT INTERVAL: prev gap = ' 
                 + CAST(DATEDIFF(DAY, bn.PrevBoundaryDt, bn.BoundaryAsDatetime2) AS VARCHAR(10)) 
                 + ' days, next gap = ' 
                 + CAST(DATEDIFF(DAY, bn.BoundaryAsDatetime2, bn.NextBoundaryDt) AS VARCHAR(10)) 
                 + ' days'

        --------------------------------------------------
        -- F. Inconsistent integer interval
        --------------------------------------------------
        WHEN pm.ColumnDataType IN ('int','bigint','smallint','tinyint')
             AND bn.PrevBoundaryInt IS NOT NULL
             AND bn.NextBoundaryInt IS NOT NULL
             AND (bn.BoundaryAsBigint - bn.PrevBoundaryInt)
                 <> (bn.NextBoundaryInt - bn.BoundaryAsBigint)
            THEN 'INCONSISTENT INTERVAL: prev gap = ' 
                 + CAST(bn.BoundaryAsBigint - bn.PrevBoundaryInt AS VARCHAR(20)) 
                 + ', next gap = ' 
                 + CAST(bn.NextBoundaryInt - bn.BoundaryAsBigint AS VARCHAR(20))

        ELSE 'OK'
    END                                     AS Issue,

    -- ══════════════════════════════════════════
    -- RECOMMENDATION
    -- ══════════════════════════════════════════
    CASE 
        WHEN p.[rows] = 0 
            THEN 'Run ALTER PARTITION FUNCTION ... MERGE RANGE to remove empty partition'
        WHEN pm.ColumnDataType IN ('date','datetime','datetime2','smalldatetime','datetimeoffset')
             AND pm.IsRightBound = 1
             AND bn.BoundaryAsDatetime2 IS NOT NULL
             AND CAST(bn.BoundaryAsDatetime2 AS TIME) <> '00:00:00'
            THEN 'Recreate boundary at midnight (e.g. 2024-01-01 00:00:00) to avoid off-by-one data placement'
        WHEN pm.ColumnDataType IN ('date','datetime','datetime2','smalldatetime','datetimeoffset')
             AND pm.IsRightBound = 0
             AND bn.BoundaryAsDatetime2 IS NOT NULL
             AND CAST(bn.BoundaryAsDatetime2 AS TIME) >= '23:59:59'
            THEN 'Adjust LEFT boundary to use clean date value (avoid 23:59:59 pattern)'
        WHEN bn.BoundaryValueStr = LAG(bn.BoundaryValueStr) 
                                       OVER (ORDER BY bn.boundary_id)
            THEN 'Remove duplicate boundary — MERGE one of the zero-width partitions'
        WHEN pm.ColumnDataType IN ('date','datetime','datetime2','smalldatetime','datetimeoffset')
             AND bn.PrevBoundaryDt IS NOT NULL
             AND bn.NextBoundaryDt IS NOT NULL
             AND DATEDIFF(DAY, bn.PrevBoundaryDt, bn.BoundaryAsDatetime2) 
                 <> DATEDIFF(DAY, bn.BoundaryAsDatetime2, bn.NextBoundaryDt)
             AND NOT (
                 DATEDIFF(MONTH, bn.PrevBoundaryDt, bn.BoundaryAsDatetime2) = 
                 DATEDIFF(MONTH, bn.BoundaryAsDatetime2, bn.NextBoundaryDt)
                 AND DATEPART(DAY, bn.PrevBoundaryDt) = DATEPART(DAY, bn.BoundaryAsDatetime2)
             )
            THEN 'Investigate inconsistent interval — may cause uneven data distribution'
        WHEN pm.ColumnDataType IN ('int','bigint','smallint','tinyint')
             AND bn.PrevBoundaryInt IS NOT NULL
             AND bn.NextBoundaryInt IS NOT NULL
             AND (bn.BoundaryAsBigint - bn.PrevBoundaryInt)
                 <> (bn.NextBoundaryInt - bn.BoundaryAsBigint)
            THEN 'Investigate inconsistent interval — may cause uneven data distribution'
        ELSE 'No action needed'
    END                                     AS Recommendation

FROM #PartMeta pm
CROSS JOIN #BoundaryWithNeighbors bn
JOIN sys.partitions p 
    ON p.object_id = @ObjectId 
    AND p.index_id = pm.IndexId
    AND p.partition_number = CASE WHEN pm.IsRightBound = 1 THEN bn.boundary_id + 1 ELSE bn.boundary_id END
ORDER BY bn.boundary_id
OPTION (MAXDOP 1);

----------------------------------------------------------------------
-- 6. Cleanup
----------------------------------------------------------------------
DROP TABLE IF EXISTS #PartMeta;
DROP TABLE IF EXISTS #Boundaries;
DROP TABLE IF EXISTS #BoundaryWithNeighbors;
```

**What to do:**
| Finding | Recommendation |
|---------|----------------|
| Missing future boundaries | Add partition boundaries for upcoming periods to prevent insert failures |
| Uneven boundary intervals | Review partition function — inconsistent intervals cause uneven data distribution |
| Last boundary in the past | Urgent: add future boundaries before the next period's data arrives |

### Step 7: Generate Missing Partition Fix Script

> Run with the SQL query tool. Detects missing future partition boundaries and generates ALTER PARTITION FUNCTION ... SPLIT RANGE statements.

```sql

SET NOCOUNT ON;

DECLARE @BatchSize     INT          = 50;

----------------------------------------------------------------------
-- 1. Resolve OBJECT_ID once
----------------------------------------------------------------------
DECLARE @ObjectId INT = OBJECT_ID(QUOTENAME(N'{{SchemaName}}') + N'.' + QUOTENAME(N'{{TableName}}'));

IF @ObjectId IS NULL
BEGIN
    RAISERROR('Table [%s].[%s] not found in current database.', 16, 1, N'{{SchemaName}}', N'{{TableName}}');
    RETURN;
END

----------------------------------------------------------------------
-- 2. Gather all metadata in ONE query
----------------------------------------------------------------------
DECLARE @PFName         SYSNAME;
DECLARE @PSName         SYSNAME;
DECLARE @FunctionId     INT;
DECLARE @ColumnDataType SYSNAME;
DECLARE @IsRightBound   BIT;

SELECT TOP 1
    @PFName         = pf.name,
    @PSName         = ps.name,
    @FunctionId     = pf.function_id,
    @ColumnDataType = TYPE_NAME(pc.user_type_id),
    @IsRightBound   = pf.boundary_value_on_right
FROM sys.tables t
JOIN sys.indexes i          ON t.object_id = i.object_id AND i.index_id IN (0,1)
JOIN sys.partition_schemes ps ON i.data_space_id = ps.data_space_id
JOIN sys.partition_functions pf ON ps.function_id = pf.function_id
JOIN sys.index_columns ic   ON i.object_id = ic.object_id 
                            AND i.index_id = ic.index_id 
                            AND ic.partition_ordinal = 1
JOIN sys.columns pc         ON ic.object_id = pc.object_id 
                            AND ic.column_id = pc.column_id
WHERE t.object_id = @ObjectId
OPTION (MAXDOP 1);

IF @PFName IS NULL
BEGIN
    RETURN;
END

----------------------------------------------------------------------
-- 3. Get last two boundaries (single scan)
----------------------------------------------------------------------
DECLARE @LastBoundaryDt    DATETIME2;
DECLARE @SecondLastDt      DATETIME2;
DECLARE @IntervalDays      INT;
DECLARE @IsMonthlyInterval BIT = 0;
DECLARE @IntervalMonths    INT = 1;

IF @ColumnDataType NOT IN ('date','datetime','datetime2','smalldatetime','datetimeoffset')
BEGIN
    RETURN;
END

;WITH RankedBoundaries AS
(
    SELECT 
        CAST(CAST(prv.value AS DATETIME2) AS DATETIME2) AS BoundaryDt,
        ROW_NUMBER() OVER (ORDER BY prv.boundary_id DESC) AS rn
    FROM sys.partition_range_values prv
    WHERE prv.function_id = @FunctionId
)
SELECT 
    @LastBoundaryDt  = MAX(CASE WHEN rn = 1 THEN BoundaryDt END),
    @SecondLastDt    = MAX(CASE WHEN rn = 2 THEN BoundaryDt END)
FROM RankedBoundaries
WHERE rn <= 2
OPTION (MAXDOP 1);

IF @LastBoundaryDt IS NULL
BEGIN
    PRINT '-- No boundary values found for partition function [' + @PFName + '].';
    RETURN;
END

SET @IntervalDays = DATEDIFF(DAY, @SecondLastDt, @LastBoundaryDt);

-- Detect monthly intervals: both boundaries land on the same day-of-month
-- and the month gap is consistent (avoids drift from 28-31 day arithmetic)
IF @SecondLastDt IS NOT NULL
   AND DATEPART(DAY, @SecondLastDt) = DATEPART(DAY, @LastBoundaryDt)
   AND DATEDIFF(MONTH, @SecondLastDt, @LastBoundaryDt) >= 1
BEGIN
    SET @IsMonthlyInterval = 1;
    SET @IntervalMonths = DATEDIFF(MONTH, @SecondLastDt, @LastBoundaryDt);
END

IF @IntervalDays IS NULL OR @IntervalDays <= 0
BEGIN
    PRINT '-- ERROR: Detected interval is ' + ISNULL(CAST(@IntervalDays AS VARCHAR(10)), 'NULL') + ' days.';
    PRINT '-- Cannot auto-generate. Check boundary values manually.';
    RETURN;
END

----------------------------------------------------------------------
-- 4. Check if future partitions already exist
----------------------------------------------------------------------
DECLARE @EndDate DATE = DATEADD(MONTH, {{FutureMonths}}, GETDATE());

IF CAST(@LastBoundaryDt AS DATE) >= @EndDate
BEGIN
    RETURN;
END

----------------------------------------------------------------------
-- 5. Safety check: last partition row count
----------------------------------------------------------------------
DECLARE @LastPartRows    BIGINT;
DECLARE @TotalPartitions INT;

SELECT @TotalPartitions = fanout 
FROM sys.partition_functions 
WHERE function_id = @FunctionId
OPTION (MAXDOP 1);

SELECT @LastPartRows = p.[rows]
FROM sys.partitions p
WHERE p.object_id = @ObjectId 
  AND p.index_id IN (0,1)
  AND p.partition_number = @TotalPartitions
  OPTION (MAXDOP 1);

----------------------------------------------------------------------
-- 6. Generate boundaries (set-based, no WHILE loop)
----------------------------------------------------------------------
DECLARE @StartDate DATE = CASE 
    WHEN @IsMonthlyInterval = 1 
    THEN DATEADD(MONTH, @IntervalMonths, CAST(@LastBoundaryDt AS DATE))
    ELSE DATEADD(DAY, @IntervalDays, CAST(@LastBoundaryDt AS DATE))
END;

;WITH DateSequence AS
(
    SELECT 
        1 AS SeqNum,
        @StartDate AS BoundaryDate
    UNION ALL
    SELECT 
        SeqNum + 1,
        CASE 
            WHEN @IsMonthlyInterval = 1 
            THEN DATEADD(MONTH, @IntervalMonths, BoundaryDate)
            ELSE DATEADD(DAY, @IntervalDays, BoundaryDate)
        END
    FROM DateSequence
    WHERE BoundaryDate < @EndDate
      AND SeqNum < 1000
)
SELECT 
    SeqNum,
    BoundaryDate,
    CONVERT(VARCHAR(30), BoundaryDate, 121) AS BoundaryStr
INTO #NewBoundaries
FROM DateSequence
WHERE BoundaryDate <= @EndDate
OPTION (MAXDOP 1, MAXRECURSION 1000);

----------------------------------------------------------------------
-- 7. Pre-calculate count into variable (avoids subquery errors)
----------------------------------------------------------------------
DECLARE @NewBoundaryCount INT;
SELECT @NewBoundaryCount = COUNT(*) FROM #NewBoundaries
OPTION (MAXDOP 1);

IF @NewBoundaryCount = 0
BEGIN
    DROP TABLE IF EXISTS #NewBoundaries;
    RETURN;
END

----------------------------------------------------------------------
-- 8. Generate SPLIT statements (set-based, batched)
----------------------------------------------------------------------
DECLARE @sql NVARCHAR(MAX);

SELECT @sql = STRING_AGG(
    CAST(
    CASE 
        WHEN (SeqNum - 1) % @BatchSize = 0 
        THEN 
            CHAR(13) + CHAR(10) 
            + '-- ================================================================' + CHAR(13) + CHAR(10)
            + '-- BATCH ' + CAST((SeqNum - 1) / @BatchSize + 1 AS VARCHAR(10)) 
            + ' (boundaries ' + CAST(SeqNum AS VARCHAR(10)) 
            + ' - ' + CAST(
                CASE WHEN SeqNum + @BatchSize - 1 > @NewBoundaryCount
                     THEN @NewBoundaryCount
                     ELSE SeqNum + @BatchSize - 1
                END AS VARCHAR(10))
            + ')' + CHAR(13) + CHAR(10)
            + '-- ================================================================' + CHAR(13) + CHAR(10)
        ELSE ''
    END
    + 'ALTER PARTITION SCHEME ' + QUOTENAME(@PSName) + ' NEXT USED [PRIMARY];' + CHAR(13) + CHAR(10)
    + 'ALTER PARTITION FUNCTION ' + QUOTENAME(@PFName) + '() SPLIT RANGE ('''
    + BoundaryStr + ''');' + CHAR(13) + CHAR(10)
    + 'GO' + CHAR(13) + CHAR(10)
    AS NVARCHAR(MAX)), '' ) WITHIN GROUP (ORDER BY SeqNum)
FROM #NewBoundaries
OPTION (MAXDOP 1);

----------------------------------------------------------------------
-- 9. Output generated script
----------------------------------------------------------------------
SELECT @sql AS GeneratedScript, @NewBoundaryCount AS BoundariesGenerated, @TotalPartitions + @NewBoundaryCount AS NewTotalPartitions;

-- 10. Cleanup
----------------------------------------------------------------------
DROP TABLE IF EXISTS #NewBoundaries;
```

### Step 8: Partition Skew and Hot Partition Diagnostic

> Run with the SQL query tool. Identifies partition skew, hot partitions, and empty waste with statistical analysis and actionable recommendations.

```sql
SET NOCOUNT ON;

----------------------------------------------------------------------
-- 1. Resolve object once
----------------------------------------------------------------------
DECLARE @ObjectId INT = OBJECT_ID(QUOTENAME(N'{{SchemaName}}') + N'.' + QUOTENAME(N'{{TableName}}'));

IF @ObjectId IS NULL
BEGIN
    RAISERROR('Table not found', 16, 1);
    RETURN;
END

----------------------------------------------------------------------
-- 2. Single scan → materialize partition data
----------------------------------------------------------------------
SELECT 
    p.partition_number                  AS PartitionNumber,
    p.[rows]                            AS [RowCount],
    ds.reserved_page_count,
    ds.used_page_count,
    CAST(ds.reserved_page_count * 8.0 / 1024 AS DECIMAL(18,2)) AS ReservedMB
INTO #P
FROM sys.partitions p
JOIN sys.dm_db_partition_stats ds 
    ON p.partition_id = ds.partition_id
WHERE p.object_id = @ObjectId
  AND p.index_id IN (0,1)
  OPTION (MAXDOP 1);

-- ✅ Add index for faster aggregation (BIG win for large tables)
CREATE CLUSTERED INDEX IX_P ON #P(PartitionNumber);

----------------------------------------------------------------------
-- 3. Pre-aggregate ONCE (no repeated scans)
----------------------------------------------------------------------
DECLARE 
    @TotalRows        BIGINT,
    @TotalPartitions  INT,
    @AvgRows          FLOAT,
    @StdDevRows       FLOAT,
    @MinRows          BIGINT,
    @MaxRows          BIGINT,
    @EmptyCount       INT;

SELECT 
    @TotalRows       = SUM([RowCount]),
    @TotalPartitions = COUNT(*),
    @AvgRows         = AVG(CAST([RowCount] AS FLOAT)),
    @StdDevRows      = STDEV(CAST([RowCount] AS FLOAT)),
    @MinRows         = MIN([RowCount]),
    @MaxRows         = MAX([RowCount]),
    @EmptyCount      = SUM(CASE WHEN [RowCount] = 0 THEN 1 ELSE 0 END)
FROM #P
OPTION (MAXDOP 1);

----------------------------------------------------------------------
-- 4. Compute skew metrics (cheap math, no scans)
----------------------------------------------------------------------
DECLARE @CV DECIMAL(10,2) =
    CASE WHEN @AvgRows = 0 THEN 0
         ELSE @StdDevRows * 100.0 / @AvgRows END;

DECLARE @MaxToAvg DECIMAL(10,2) =
    CASE WHEN @AvgRows = 0 THEN 0
         ELSE @MaxRows * 1.0 / @AvgRows END;

----------------------------------------------------------------------
-- 5. FAST classification (no window functions)
----------------------------------------------------------------------
SELECT 
    PartitionNumber,
    [RowCount],
    ReservedMB,

    -- % of total
    CASE WHEN @TotalRows = 0 THEN 0
         ELSE CAST([RowCount] * 100.0 / @TotalRows AS DECIMAL(8,2))
    END AS PctOfTotal,

    -- Heat classification (fast math, no OVER())
    CASE 
        WHEN [RowCount] = 0 THEN 'EMPTY'
        WHEN [RowCount] > @AvgRows * 5 THEN 'EXTREME HOT'
        WHEN [RowCount] > @AvgRows * 3 THEN 'HOT'
        WHEN [RowCount] > @AvgRows * 1.5 THEN 'WARM'
        WHEN [RowCount] < @AvgRows * 0.1 AND [RowCount] > 0 THEN 'NEARLY EMPTY'
        WHEN [RowCount] < @AvgRows * 0.25 THEN 'COLD'
        ELSE 'BALANCED'
    END AS HeatStatus,

    -- Action
    CASE 
        WHEN [RowCount] = 0 THEN 'MERGE'
        WHEN [RowCount] > @AvgRows * 5 THEN 'SPLIT (URGENT)'
        WHEN [RowCount] > @AvgRows * 3 THEN 'SPLIT'
        WHEN [RowCount] < @AvgRows * 0.1 AND [RowCount] > 0 THEN 'MERGE'
        ELSE 'OK'
    END AS Action

FROM #P
ORDER BY PartitionNumber
OPTION (MAXDOP 1);

----------------------------------------------------------------------
-- 6. Lightweight summary (NO expensive percentile scans)
----------------------------------------------------------------------
SELECT 
    @TotalPartitions        AS TotalPartitions,
    @TotalRows              AS TotalRows,
    @AvgRows                AS AvgRows,
    @MinRows                AS MinRows,
    @MaxRows                AS MaxRows,
    @EmptyCount             AS EmptyPartitions,
    CAST(@StdDevRows AS DECIMAL(18,2)) AS StdDev,
    @CV                     AS CoefficientOfVariation,
    @MaxToAvg               AS MaxToAvgRatio,

    CASE 
        WHEN @CV > 150 THEN 'CRITICAL SKEW'
        WHEN @CV > 100 THEN 'HIGH SKEW'
        WHEN @CV > 50  THEN 'MODERATE SKEW'
        ELSE 'BALANCED'
    END AS SkewVerdict;

----------------------------------------------------------------------
-- 7. Top hot partitions (optimized TOP instead of window)
----------------------------------------------------------------------
SELECT TOP 10
    PartitionNumber,
    [RowCount],
    CAST([RowCount] * 100.0 / NULLIF(@TotalRows,0) AS DECIMAL(8,2)) AS PctOfTotal,
    CAST([RowCount] / NULLIF(@AvgRows,0) AS DECIMAL(8,2)) AS TimesAvg
FROM #P
WHERE [RowCount] > 0
ORDER BY [RowCount] DESC
OPTION (MAXDOP 1);

----------------------------------------------------------------------
-- 8. Cleanup
----------------------------------------------------------------------
DROP TABLE IF EXISTS #P;
```

**What to do:**
| Finding | Recommendation |
|---------|----------------|
| Hot partition detected | Consider splitting the hot partition or adjusting boundaries |
| High skew across partitions | Re-evaluate partition function boundaries for better balance |
| Empty waste partitions | Merge empty partitions to reduce metadata overhead |

### Step 9: Missing Index with Partition Alignment Analysis

> Run with the SQL query tool. Analyzes missing index suggestions from the DMV, checks partition alignment of existing indexes, and generates aligned CREATE INDEX scripts.

```sql
SET NOCOUNT ON;

----------------------------------------------------------------------
-- 1. Resolve & validate
----------------------------------------------------------------------
DECLARE @ObjectId INT = OBJECT_ID(QUOTENAME(N'{{SchemaName}}') + N'.' + QUOTENAME(N'{{TableName}}'));

IF @ObjectId IS NULL
BEGIN
    RAISERROR('Table [%s].[%s] not found in current database.', 16, 1, N'{{SchemaName}}', N'{{TableName}}');
    RETURN;
END

----------------------------------------------------------------------
-- 2. Get partition metadata (single catalog scan → variables)
----------------------------------------------------------------------
DECLARE @PartitionColumn  SYSNAME;
DECLARE @PartColQuoted    SYSNAME;       -- pre-built: [ColName]
DECLARE @PartitionScheme  SYSNAME;
DECLARE @PartitionFunc    SYSNAME;
DECLARE @ColumnDataType   SYSNAME;
DECLARE @IsPartitioned    BIT = 0;

SELECT TOP 1
    @PartitionColumn = pc.name,
    @PartColQuoted   = QUOTENAME(pc.name),
    @PartitionScheme = ps.name,
    @PartitionFunc   = pf.name,
    @ColumnDataType  = TYPE_NAME(pc.user_type_id),
    @IsPartitioned   = 1
FROM sys.tables t
JOIN sys.indexes i          ON t.object_id = i.object_id AND i.index_id IN (0,1)
JOIN sys.partition_schemes ps ON i.data_space_id = ps.data_space_id
JOIN sys.partition_functions pf ON ps.function_id = pf.function_id
JOIN sys.index_columns ic   ON i.object_id = ic.object_id 
                            AND i.index_id = ic.index_id 
                            AND ic.partition_ordinal = 1
JOIN sys.columns pc         ON ic.object_id = pc.object_id 
                            AND ic.column_id = pc.column_id
WHERE t.object_id = @ObjectId
OPTION (MAXDOP 1);

----------------------------------------------------------------------
-- 3. Pre-build index column strings (ONE pass, no correlated subqueries)
----------------------------------------------------------------------

-- 3a. Flatten all index columns into a single temp table
SELECT 
    ic.index_id,
    ic.is_included_column,
    ic.key_ordinal,
    c.name                              AS ColName,
    c.column_id
INTO #IdxCols
FROM sys.index_columns ic
JOIN sys.columns c ON ic.object_id = c.object_id AND ic.column_id = c.column_id
WHERE ic.object_id = @ObjectId
OPTION (MAXDOP 1);

-- 3b. Aggregate key + include columns per index using FOR XML (one scan each)
SELECT 
    i.index_id,
    i.name                              AS IndexName,
    i.type_desc                         AS IndexType,
    i.is_unique                         AS IsUnique,
    i.is_primary_key                    AS IsPK,
    i.is_disabled                       AS IsDisabled,
    i.has_filter                        AS HasFilter,

    -- Key columns (pre-joined, no correlated subquery)
    kc.KeyColumns,

    -- Include columns
    inc.IncludeColumns,

    -- Partition column checks (single EXISTS on pre-built #IdxCols)
    CASE WHEN EXISTS (
        SELECT 1 FROM #IdxCols x 
        WHERE x.index_id = i.index_id AND x.ColName = @PartitionColumn
    ) THEN 1 ELSE 0 END                    AS ContainsPartitionCol,

    -- Alignment check
    CASE WHEN ps.name IS NOT NULL THEN 1 ELSE 0 END AS IsAligned

INTO #ExistingIndexes
FROM sys.indexes i
LEFT JOIN sys.partition_schemes ps 
    ON i.data_space_id = ps.data_space_id
-- Key columns aggregation
CROSS APPLY (
    SELECT STUFF((
        SELECT ', ' + x.ColName
        FROM #IdxCols x
        WHERE x.index_id = i.index_id AND x.is_included_column = 0
        ORDER BY x.key_ordinal
        FOR XML PATH(''), TYPE
    ).value('.','NVARCHAR(MAX)'), 1, 2, '')
) kc(KeyColumns)
-- Include columns aggregation
CROSS APPLY (
    SELECT STUFF((
        SELECT ', ' + x.ColName
        FROM #IdxCols x
        WHERE x.index_id = i.index_id AND x.is_included_column = 1
        ORDER BY x.ColName
        FOR XML PATH(''), TYPE
    ).value('.','NVARCHAR(MAX)'), 1, 2, '')
) inc(IncludeColumns)
WHERE i.object_id = @ObjectId
  AND i.type > 0
  OPTION (MAXDOP 1);

----------------------------------------------------------------------
-- 4. Missing index analysis (single DMV scan)
----------------------------------------------------------------------
SELECT 
    mid.index_handle,
    migs.unique_compiles                    AS UniqueCompiles,
    migs.user_seeks                         AS UserSeeks,
    migs.user_scans                         AS UserScans,
    migs.last_user_seek                     AS LastUserSeek,
    migs.last_user_scan                     AS LastUserScan,
    migs.avg_total_user_cost                AS AvgTotalUserCost,
    migs.avg_user_impact                    AS AvgUserImpact,

    -- Impact Score
    CAST(
        migs.user_seeks * migs.avg_total_user_cost * (migs.avg_user_impact / 100.0)
    AS DECIMAL(18,2))                       AS ImpactScore,

    -- Columns
    mid.equality_columns                    AS EqualityColumns,
    mid.inequality_columns                  AS InequalityColumns,
    mid.included_columns                    AS IncludedColumns,

    -- Pre-build proposed key columns (reused in overlap + CREATE script)
    ISNULL(mid.equality_columns, '') 
    + CASE WHEN mid.equality_columns IS NOT NULL 
            AND mid.inequality_columns IS NOT NULL 
           THEN ', ' ELSE '' END
    + ISNULL(mid.inequality_columns, '')    AS ProposedKeyColumns,

    -- Partition column checks (all computed inline, no subqueries)
    CASE WHEN mid.equality_columns LIKE '%' + @PartColQuoted + '%'
              OR mid.equality_columns LIKE '%' + @PartitionColumn + '%'
         THEN 1 ELSE 0 END                 AS PartColInEquality,

    CASE WHEN mid.inequality_columns LIKE '%' + @PartColQuoted + '%'
              OR mid.inequality_columns LIKE '%' + @PartitionColumn + '%'
         THEN 1 ELSE 0 END                 AS PartColInInequality,

    CASE WHEN mid.included_columns LIKE '%' + @PartColQuoted + '%'
              OR mid.included_columns LIKE '%' + @PartitionColumn + '%'
         THEN 1 ELSE 0 END                 AS PartColInInclude,

    CASE WHEN (ISNULL(mid.equality_columns, '')  
             + ISNULL(mid.inequality_columns, '') 
             + ISNULL(mid.included_columns, ''))
              LIKE '%' + @PartitionColumn + '%'
         THEN 1 ELSE 0 END                 AS PartColPresent

INTO #MissingRaw
FROM sys.dm_db_missing_index_details mid
JOIN sys.dm_db_missing_index_groups mig 
    ON mid.index_handle = mig.index_handle
JOIN sys.dm_db_missing_index_group_stats migs 
    ON mig.index_group_handle = migs.group_handle
WHERE mid.object_id = @ObjectId
  AND mid.database_id = DB_ID()
  AND migs.user_seeks * migs.avg_total_user_cost * (migs.avg_user_impact / 100.0) > 0
  OPTION (MAXDOP 1);

----------------------------------------------------------------------
-- 5. Overlap detection via LEFT JOIN (replaces correlated subquery)
----------------------------------------------------------------------
SELECT 
    mr.*,

    -- Overlap: find first existing index whose key starts with proposed equality
    ov.IndexName                            AS OverlappingIndex

INTO #MissingFinal
FROM #MissingRaw mr
LEFT JOIN (
    -- Deduplicate: one overlap match per proposed key
    SELECT 
        ei.KeyColumns,
        MIN(ei.IndexName) AS IndexName     -- pick first match
    FROM #ExistingIndexes ei
    WHERE ei.KeyColumns IS NOT NULL
    GROUP BY ei.KeyColumns
) ov 
    ON ov.KeyColumns = mr.ProposedKeyColumns
    OR (mr.EqualityColumns IS NOT NULL 
        AND ov.KeyColumns LIKE mr.EqualityColumns + '%')
        OPTION (MAXDOP 1);

----------------------------------------------------------------------
-- 6. Pre-compute all summary counts (ONE scan of #MissingFinal)
----------------------------------------------------------------------
DECLARE @MissingCount     INT;
DECLARE @AlignedCount     INT;
DECLARE @NotAlignedCount  INT;
DECLARE @OverlapCount     INT;

SELECT 
    @MissingCount    = COUNT(*),
    @AlignedCount    = SUM(CASE WHEN PartColPresent = 1 OR @IsPartitioned = 0 
                                THEN 1 ELSE 0 END),
    @NotAlignedCount = SUM(CASE WHEN PartColPresent = 0 AND @IsPartitioned = 1 
                                THEN 1 ELSE 0 END),
    @OverlapCount    = SUM(CASE WHEN OverlappingIndex IS NOT NULL 
                                THEN 1 ELSE 0 END)
FROM #MissingFinal
OPTION (MAXDOP 1);

-- Existing index summary (ONE scan of #ExistingIndexes)
DECLARE @TotalIndexes       INT;
DECLARE @AlignedIndexes     INT;
DECLARE @NonAlignedIndexes  INT;
DECLARE @WithPartCol        INT;
DECLARE @WithoutPartCol     INT;
DECLARE @DisabledIndexes    INT;

SELECT 
    @TotalIndexes      = COUNT(*),
    @AlignedIndexes    = SUM(CASE WHEN IsAligned = 1 THEN 1 ELSE 0 END),
    @NonAlignedIndexes = SUM(CASE WHEN IsAligned = 0 THEN 1 ELSE 0 END),
    @WithPartCol       = SUM(CASE WHEN ContainsPartitionCol = 1 THEN 1 ELSE 0 END),
    @WithoutPartCol    = SUM(CASE WHEN ContainsPartitionCol = 0 THEN 1 ELSE 0 END),
    @DisabledIndexes   = SUM(CASE WHEN IsDisabled = 1 THEN 1 ELSE 0 END)
FROM #ExistingIndexes
OPTION (MAXDOP 1);

----------------------------------------------------------------------
-- 8. REPORT 2: Missing Index Detail (single scan of #MissingFinal)
----------------------------------------------------------------------
SELECT 
    ROW_NUMBER() OVER (ORDER BY mf.ImpactScore DESC) AS [Rank],

    -- Impact
    mf.ImpactScore,
    mf.UserSeeks,
    mf.UserScans,
    mf.UniqueCompiles,
    CAST(mf.AvgTotalUserCost AS DECIMAL(12,2))  AS AvgCost,
    CAST(mf.AvgUserImpact AS DECIMAL(8,2))      AS AvgImpactPct,
    mf.LastUserSeek,

    -- Columns
    mf.EqualityColumns,
    mf.InequalityColumns,
    mf.IncludedColumns,

    -- Alignment Status
    CASE 
        WHEN @IsPartitioned = 0         THEN 'N/A (not partitioned)'
        WHEN mf.PartColInEquality = 1   THEN 'ALIGNED — partition col in EQUALITY (optimal)'
        WHEN mf.PartColInInequality = 1 THEN 'ALIGNED — partition col in INEQUALITY (good)'
        WHEN mf.PartColInInclude = 1    THEN 'ALIGNED — partition col in INCLUDE (acceptable)'
        ELSE 'NOT ALIGNED — partition col ' + @PartColQuoted + ' missing!'
    END                                     AS AlignmentStatus,

    -- Risk
    CASE 
        WHEN @IsPartitioned = 0             THEN 'N/A'
        WHEN mf.PartColPresent = 1          THEN 'LOW'
        WHEN mf.UserSeeks > 10000           THEN 'HIGH'
        WHEN mf.UserSeeks > 1000            THEN 'MEDIUM'
        ELSE 'LOW — infrequent use'
    END                                     AS AlignmentRisk,

    -- Overlap
    CASE 
        WHEN mf.OverlappingIndex IS NOT NULL 
        THEN 'OVERLAP with [' + mf.OverlappingIndex + ']'
        ELSE 'No overlap'
    END                                     AS OverlapStatus

FROM #MissingFinal mf
ORDER BY mf.ImpactScore DESC
OPTION (MAXDOP 1);

----------------------------------------------------------------------
-- 9. REPORT 3: Existing Non-Aligned + Partition Elimination
--    (COMBINED into single scan of #ExistingIndexes)
----------------------------------------------------------------------
IF @IsPartitioned = 1
BEGIN
    SELECT 
        ei.IndexName,
        ei.IndexType,
        ei.IsUnique,
        ei.IsPK,
        ei.IsDisabled,
        ei.KeyColumns,
        ei.IncludeColumns,
        ei.ContainsPartitionCol,
        ei.IsAligned,

        -- Alignment Status
        CASE 
            WHEN ei.IsAligned = 0 AND ei.ContainsPartitionCol = 0
                THEN 'CRITICAL — Not aligned AND missing partition col. Blocks SWITCH.'
            WHEN ei.IsAligned = 0 AND ei.ContainsPartitionCol = 1
                THEN 'WARNING — Contains partition col but NOT on partition scheme.'
            WHEN ei.IsAligned = 1 AND ei.ContainsPartitionCol = 0
                THEN 'REVIEW — Aligned but partition col not in key/include.'
            ELSE 'OK — Aligned with partition column.'
        END                                 AS AlignmentStatus,

        -- Partition Elimination Capability
        CASE 
            WHEN ei.IsAligned = 1 AND ei.ContainsPartitionCol = 1
                 AND ei.KeyColumns LIKE '%' + @PartitionColumn + '%'
                THEN 'OPTIMAL — Partition col in key + aligned'
            WHEN ei.IsAligned = 1 AND ei.ContainsPartitionCol = 1
                THEN 'GOOD — Partition col in include + aligned'
            WHEN ei.IsAligned = 1 AND ei.ContainsPartitionCol = 0
                THEN 'PARTIAL — Aligned but partition col not in index'
            WHEN ei.IsAligned = 0
                THEN 'NONE — Non-aligned. Full index scan always.'
            ELSE 'UNKNOWN'
        END                                 AS EliminationCapability,

        -- Recommendation
        CASE 
            WHEN ei.IsAligned = 0
                THEN 'Recreate ON ' + QUOTENAME(@PartitionScheme) 
                     + '(' + @PartColQuoted + ')'
            WHEN ei.ContainsPartitionCol = 0
                THEN 'Add ' + @PartColQuoted + ' to INCLUDE'
            ELSE 'No change needed'
        END                                 AS Recommendation,

        -- Sort priority
        CASE WHEN ei.IsAligned = 0 AND ei.ContainsPartitionCol = 0 THEN 1
             WHEN ei.IsAligned = 0 THEN 2
             WHEN ei.ContainsPartitionCol = 0 THEN 3
             ELSE 4
        END                                 AS SortPriority

    FROM #ExistingIndexes ei
    ORDER BY 
        CASE WHEN ei.IsAligned = 0 AND ei.ContainsPartitionCol = 0 THEN 1
             WHEN ei.IsAligned = 0 THEN 2
             WHEN ei.ContainsPartitionCol = 0 THEN 3
             ELSE 4
        END
        OPTION (MAXDOP 1);
END

----------------------------------------------------------------------
-- 10. REPORT 4: Alignment Scorecard (pure variables, zero table access)
----------------------------------------------------------------------
IF @IsPartitioned = 1
BEGIN
    SELECT 
        'INDEX ALIGNMENT SCORECARD'         AS ReportSection,
        @TotalIndexes                       AS TotalIndexes,
        @AlignedIndexes                     AS AlignedIndexes,
        @NonAlignedIndexes                  AS NonAlignedIndexes,
        @WithPartCol                        AS ContainsPartitionCol,
        @WithoutPartCol                     AS MissingPartitionCol,
        @DisabledIndexes                    AS DisabledIndexes,

        CASE WHEN @TotalIndexes = 0 THEN 100
             ELSE CAST(@AlignedIndexes * 100.0 / @TotalIndexes AS DECIMAL(8,2))
        END                                 AS AlignmentScorePct,

        CASE 
            WHEN @NonAlignedIndexes = 0 
                THEN 'YES — All indexes aligned. SWITCH supported.'
            ELSE 'NO — ' + CAST(@NonAlignedIndexes AS VARCHAR(10)) 
                 + ' non-aligned index(es) BLOCK partition SWITCH.'
        END                                 AS SwitchReady,

        CASE 
            WHEN @NonAlignedIndexes = 0 AND @WithoutPartCol = 0 
                THEN 'EXCELLENT'
            WHEN @NonAlignedIndexes = 0 
                THEN 'GOOD — All aligned, some missing partition col in key/include'
            WHEN @NonAlignedIndexes <= 2 
                THEN 'FAIR — Fix non-aligned indexes before using SWITCH'
            ELSE 'POOR — Multiple non-aligned indexes. High maintenance overhead.'
        END                                 AS OverallHealth,

        CASE 
            WHEN @NonAlignedIndexes > 0 
                THEN 'Recreate ' + CAST(@NonAlignedIndexes AS VARCHAR(10)) 
                     + ' index(es) ON ' + QUOTENAME(@PartitionScheme) 
                     + '(' + @PartColQuoted + ')'
            WHEN @WithoutPartCol > 0 
                THEN 'Add ' + @PartColQuoted + ' to INCLUDE of ' 
                     + CAST(@WithoutPartCol AS VARCHAR(10)) + ' index(es)'
            ELSE 'No action needed.'
        END                                 AS RecommendedAction;
END

----------------------------------------------------------------------
-- 11. Cleanup
----------------------------------------------------------------------
DROP TABLE IF EXISTS #IdxCols;
DROP TABLE IF EXISTS #ExistingIndexes;
DROP TABLE IF EXISTS #MissingRaw;
DROP TABLE IF EXISTS #MissingFinal;
```

**What to do:**
| Finding | Recommendation |
|---------|----------------|
| Misaligned index detected | Index is not aligned with partition scheme — may prevent partition switching |
| Missing partition column in index | Add partition column to enable partition elimination for this index |
| Missing index recommendation | Create the suggested index aligned with the partition scheme |

### Step 10: Live Partition Elimination Check

> Run with the SQL query tool. Checks currently running queries for partition elimination in their execution plans.

```sql
-- Shows active requests and whether the plan indicates partition elimination
SELECT TOP (50)
    r.session_id,
    r.status,
    DB_NAME(r.database_id) AS database_name,
    r.cpu_time,
    r.logical_reads,
    r.reads,
    r.writes,
    SUBSTRING(t.text,
              (r.statement_start_offset/2) + 1,
              CASE WHEN r.statement_end_offset = -1
                   THEN (LEN(CONVERT(nvarchar(max), t.text)) - (r.statement_start_offset/2) + 1)
                   ELSE ((r.statement_end_offset - r.statement_start_offset)/2) + 1
              END) AS statement_text,

    CASE WHEN qp.query_plan IS NOT NULL
              AND (qp.query_plan.exist('//@Partitioned[.="1"]') = 1
                OR qp.query_plan.exist('//@Partitioned[.="true"]') = 1) THEN 1 ELSE 0 END AS HasPartitionedOperator,

    CASE WHEN qp.query_plan IS NOT NULL
              AND (qp.query_plan.exist('//*[local-name()="SeekPredicateNew"]//*[local-name()="PartitionID"]') = 1
                OR qp.query_plan.exist('//*[local-name()="SeekKeys"]//*[local-name()="PartitionID"]') = 1)
         THEN 1 ELSE 0 END AS HasPartitionIdSeek,

    CASE
        WHEN qp.query_plan IS NULL
            THEN 'Plan not available — may require higher permissions or plan is too large'
        WHEN qp.query_plan.exist('//@Partitioned[.="1"]') = 0
             AND qp.query_plan.exist('//@Partitioned[.="true"]') = 0
            THEN 'No partition operators — query may not target partitioned tables or partition elimination is not occurring'
        WHEN (qp.query_plan.exist('//@Partitioned[.="1"]') = 1
              OR qp.query_plan.exist('//@Partitioned[.="true"]') = 1)
             AND qp.query_plan.exist('//*[local-name()="SeekPredicateNew"]//*[local-name()="PartitionID"]') = 0
             AND qp.query_plan.exist('//*[local-name()="SeekKeys"]//*[local-name()="PartitionID"]') = 0
            THEN 'Partitioned scan WITHOUT elimination — add partition column to WHERE clause to enable elimination'
        WHEN qp.query_plan.exist('//*[local-name()="SeekPredicateNew"]//*[local-name()="PartitionID"]') = 1
              OR qp.query_plan.exist('//*[local-name()="SeekKeys"]//*[local-name()="PartitionID"]') = 1
            THEN 'Partition elimination active — query is efficiently targeting specific partitions'
        ELSE 'Review plan manually'
    END AS Recommendation
    , r.query_plan_hash
FROM sys.dm_exec_requests r
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) t
OUTER APPLY sys.dm_exec_query_plan(r.plan_handle) qp
WHERE r.session_id > 50
  AND r.session_id <> @@SPID
ORDER BY r.cpu_time DESC, r.logical_reads DESC
OPTION (MAXDOP 1);
```

**What to do:**
| Finding | Recommendation |
|---------|----------------|
| Queries accessing all partitions | Partition elimination not happening — check WHERE clause includes partition column |
| Single partition accessed | Partition elimination working correctly |
| Multiple but not all partitions | Partial elimination — may be acceptable depending on query range |

### Step 11: Storage Details Per Partition

> Run with the SQL query tool. Shows storage allocation and compression details for each partition of every index on the target table.

```sql
SET NOCOUNT ON;

DECLARE @ObjectId INT = OBJECT_ID(QUOTENAME(N'{{SchemaName}}') + N'.' + QUOTENAME(N'{{TableName}}'));

IF @ObjectId IS NULL
BEGIN
    RAISERROR('Table [%s].[%s] not found in current database.', 16, 1, N'{{SchemaName}}', N'{{TableName}}');
    RETURN;
END;
SELECT
    t.name                                    AS TableName,
    ISNULL(i.name, N'** HEAP **')             AS IndexName,
    i.index_id                                AS IndexId,
    p.partition_number                        AS PartitionNumber,

    CAST(dps.reserved_page_count * 8.0 / 1024.0 AS DECIMAL(18,2)) AS ReservedMB,
    CAST(dps.used_page_count     * 8.0 / 1024.0 AS DECIMAL(18,2)) AS UsedMB,

    dps.row_count                             AS [RowCount],
    p.data_compression_desc                   AS CompressionType,
    CASE
        WHEN dps.row_count = 0
            THEN 'Empty partition — candidate for merge to reduce metadata overhead'
        WHEN p.data_compression_desc = 'NONE' AND dps.reserved_page_count > 10000
            THEN 'Large uncompressed partition (>' + CAST(CAST(dps.reserved_page_count * 8.0 / 1024.0 AS INT) AS VARCHAR(10)) + ' MB) — evaluate PAGE or ROW compression'
        WHEN p.data_compression_desc = 'NONE'
            THEN 'No compression — consider enabling if read-heavy workload'
        ELSE 'OK'
    END                                       AS Recommendation
FROM sys.tables AS t
JOIN sys.indexes AS i
    ON i.object_id = t.object_id
JOIN sys.partitions AS p
    ON p.object_id = i.object_id
   AND p.index_id  = i.index_id
JOIN sys.dm_db_partition_stats AS dps
    ON dps.partition_id = p.partition_id
WHERE t.object_id = @ObjectId
ORDER BY
    i.index_id,
    p.partition_number
    OPTION (MAXDOP 1);
```

### Step 12: Hot Partitions and Indexes

> Run with the SQL query tool. Identifies hot partitions and indexes based on operational stats (reads, writes, waits) since last SQL Server restart.

```sql

DECLARE @ObjectId          int            = OBJECT_ID(QUOTENAME(N'{{SchemaName}}') + N'.' + QUOTENAME(N'{{TableName}}'));

DECLARE @HighWaitMs        bigint = 5000;        
DECLARE @HighReads         bigint = 100000;      
DECLARE @HighWrites        bigint = 100000;      
DECLARE @HighWaitPerOpMs   decimal(18,4) = 0.50; 

WITH iops AS
(
    SELECT
        database_id,
        object_id,
        index_id,
        partition_number,
        range_scan_count,
        singleton_lookup_count,
        leaf_insert_count,
        leaf_update_count,
        leaf_delete_count,
        row_lock_wait_count,
        row_lock_wait_in_ms,
        page_lock_wait_count,
        page_lock_wait_in_ms,
        page_latch_wait_count,
        page_latch_wait_in_ms,
        page_io_latch_wait_count,
        page_io_latch_wait_in_ms
    FROM sys.dm_db_index_operational_stats(DB_ID(), @ObjectId, NULL, NULL)
),
hot AS
(
    SELECT
        DB_NAME(iops.database_id) AS [database_name],
        OBJECT_SCHEMA_NAME(iops.object_id, iops.database_id) AS [schema_name],
        OBJECT_NAME(iops.object_id, iops.database_id) AS [object_name],
        i.name AS [index_name],
        iops.index_id,
        iops.partition_number,

        -- core metrics (numeric)
        (iops.range_scan_count + iops.singleton_lookup_count) AS read_ops,
        (iops.leaf_insert_count + iops.leaf_update_count + iops.leaf_delete_count) AS write_ops,

        -- signals used for recommendations
        iops.range_scan_count,
        iops.singleton_lookup_count,
        (iops.row_lock_wait_in_ms + iops.page_lock_wait_in_ms
         + iops.page_latch_wait_in_ms + iops.page_io_latch_wait_in_ms) AS wait_ms_total,
        (iops.row_lock_wait_count + iops.page_lock_wait_count
         + iops.page_latch_wait_count + iops.page_io_latch_wait_count) AS wait_count_total
    FROM iops
    JOIN sys.indexes i
      ON i.object_id = iops.object_id
     AND i.index_id  = iops.index_id
    WHERE OBJECTPROPERTY(iops.object_id, 'IsUserTable') = 1
)
SELECT TOP (50)
    [database_name],
    [schema_name],
    [object_name],
    [index_name],
    index_id,
    partition_number,

    read_ops,
    CAST(N'count of ops (range scans + singleton lookups; cumulative since last restart)' AS nvarchar(200)) AS read_ops_unit,

    write_ops,
    CAST(N'count of ops (leaf inserts + updates + deletes; cumulative since last restart)' AS nvarchar(200)) AS write_ops_unit,

    recommendations =
        LTRIM(STUFF(
            CONCAT(
                CASE
                    WHEN (read_ops + write_ops) = 0 THEN '; No activity seen (since last restart)'
                    WHEN wait_ms_total >= @HighWaitMs
                         AND (CAST(wait_ms_total AS decimal(18,4)) / NULLIF(read_ops + write_ops, 0)) >= @HighWaitPerOpMs
                    THEN '; High wait pressure per operation — investigate lock/latch/IO contention for this partition/index'
                    ELSE ''
                END,
                CASE
                    WHEN read_ops >= @HighReads AND range_scan_count > singleton_lookup_count
                    THEN '; Reads dominated by scans — validate partition elimination predicates and indexing (avoid large range scans)'
                    ELSE ''
                END,
                CASE
                    WHEN read_ops >= @HighReads AND singleton_lookup_count > range_scan_count
                    THEN '; Reads dominated by lookups — consider covering index / reduce key lookups'
                    ELSE ''
                END,
                CASE
                    WHEN write_ops >= @HighWrites AND wait_ms_total >= @HighWaitMs
                    THEN '; High writes + waits — consider batching, reduce hot-key patterns, review fillfactor/index maintenance'
                    ELSE ''
                END,
                CASE
                    WHEN read_ops >= @HighReads AND write_ops >= @HighWrites
                    THEN '; Mixed heavy read/write — review concurrency, isolation level, and hot-spot mitigation'
                    ELSE ''
                END,
                CASE
                    WHEN (read_ops + write_ops) > 0 AND wait_ms_total < @HighWaitMs
                    THEN '; No strong contention signal — monitor trend and validate “hotness” via periodic snapshots'
                    ELSE ''
                END
            ),
            1, 2, ''  -- remove leading "; "
        ))
FROM hot
ORDER BY
    CASE WHEN (read_ops + write_ops) = 0 THEN 1 ELSE 0 END,
    read_ops DESC,
    write_ops DESC
    OPTION (MAXDOP 1);
```
