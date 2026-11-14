# Plan Cache Analysis — SQL Queries
Run all queries with the SQL query tool. Replace {{parameter}} placeholders with values from the skill parameters.

### Step 0: Detect Platform and Capabilities

> Run with the SQL query tool — determines the SQL Server engine edition to route subsequent queries to platform-appropriate DMVs.

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
| `is_unsupported_platform = 1` (engine edition 6 or 11) | **Stop here** — this skill is not designed for Azure Synapse Dedicated SQL Pool (edition 6) or Azure Synapse Serverless SQL Pool / Microsoft Fabric Warehouse (edition 11). Plan cache DMVs behave differently in these environments. |
| `engine_edition = 12` (Fabric SQL Database) | Behaves like Azure SQL Database — proceed with all steps. |
| `engine_edition = 9` (Azure SQL Edge) | Proceed — DMV behavior is similar to SQL Server on-prem. |

---

### Step 1: Plan Cache Bloat Overview

> Run with the SQL query tool — retrieves plan cache composition grouped by object type, highlighting single-use plan counts and memory consumption.

```sql
SELECT
    objtype AS [CacheType],
    COUNT_BIG(*) AS [Total Plans],
    SUM(CAST(size_in_bytes AS DECIMAL(18,2)))/1024/1024 AS [Total MBs],
    AVG(usecounts) AS [Avg Use Count],
    SUM(CASE WHEN usecounts = 1 THEN 1 ELSE 0 END) AS [Plans Used Once],
    SUM(CASE WHEN usecounts = 1 THEN CAST(size_in_bytes AS DECIMAL(18,2)) ELSE 0 END)/1024/1024 AS [MBs Used Once]
FROM sys.dm_exec_cached_plans
GROUP BY objtype
ORDER BY [Total MBs] DESC
OPTION (MAXDOP 1);
```

**What to do:**

| Finding | Recommendation |
|---------|----------------|
| Plans Used Once > 50% of Total Plans | Enable `optimize for ad hoc workloads` to stub initial plans |
| MBs Used Once > 25% of Total MBs | Review for parameterization opportunities — convert ad hoc to sp_executesql |
| Ad-hoc plans dominating cache | Consider forced parameterization (test thoroughly — significant behavioral change) |

---

### Step 2: Plan Cache Contents Detail

> Run with the SQL query tool — inspects the top cached plans by size, classifying each with a recommendation based on type, use count, and size.

```sql
SELECT TOP ({{TopN}})
    cp.cacheobjtype,
    cp.objtype,
    cp.usecounts,
    cp.size_in_bytes / 1024.0 AS size_kb,
    DB_NAME(st.dbid) AS database_name,
    st.text AS sql_text,
    cp.plan_handle,
    CASE
        WHEN cp.objtype = 'Adhoc' AND cp.usecounts = 1
            THEN 'Single-use ad hoc — parameterize with sp_executesql or stored procedure'
        WHEN cp.objtype = 'Adhoc' AND cp.usecounts <= 3
            THEN 'Low reuse ad hoc — review for parameterization opportunity'
        WHEN cp.objtype = 'Prepared' AND cp.usecounts = 1
            THEN 'Single-use prepared — check for over-parameterization or plan eviction'
        WHEN cp.size_in_bytes > 1048576
            THEN 'Large plan (>1 MB) — review query complexity or consider simplifying'
        ELSE 'OK'
    END AS Recommendation
FROM sys.dm_exec_cached_plans AS cp
CROSS APPLY sys.dm_exec_sql_text(cp.plan_handle) AS st
ORDER BY cp.size_in_bytes DESC
OPTION (MAXDOP 1);
```

**What to do:**

| Finding | Recommendation |
|---------|----------------|
| Single-use ad hoc plans | Parameterize with sp_executesql or convert to stored procedures |
| Low reuse ad hoc (usecounts ≤ 3) | Review for parameterization opportunity |
| Large plan (> 1 MB) | Review query complexity — consider simplifying or breaking into smaller queries |
| Single-use prepared plans | Check for over-parameterization or plan eviction pressure |

---

### Step 3: Platform-Aware Bloat Summary

> Run with the SQL query tool — aggregates plan cache stats by object type with platform-aware scoping (Azure SQL DB vs SQL Server/MI), producing bloat verdicts and next-step recommendations.

```sql
-- Set @DatabaseName to N'YourDB' to scope to a specific database, or leave NULL for all/current
DECLARE @DatabaseName sysname = N'{{DatabaseName}}';
DECLARE @EngineEdition int = CAST(SERVERPROPERTY('EngineEdition') AS int);

DECLARE @EffectiveDbId int =
    CASE 
        WHEN @EngineEdition = 5 THEN DB_ID() 
        WHEN @DatabaseName IS NULL THEN NULL
        ELSE DB_ID(@DatabaseName)
    END;

;WITH base AS
(
    SELECT TOP ({{TopN}})
        @@SERVERNAME AS instance_name,
        @EngineEdition AS engine_edition,
        cp.objtype,
        cp.usecounts,
        cp.size_in_bytes,
        st.dbid
    FROM sys.dm_exec_cached_plans AS cp
    CROSS APPLY sys.dm_exec_sql_text(cp.plan_handle) AS st
    WHERE cp.objtype IN ('Adhoc','Prepared')
      AND (
            @EffectiveDbId IS NULL 
            OR st.dbid = @EffectiveDbId
          )
    ORDER BY cp.size_in_bytes DESC
),
agg AS
(
    SELECT
        instance_name,
        engine_edition,
        objtype,
        COUNT_BIG(*) AS plan_count,
        SUM(CAST(size_in_bytes AS BIGINT)) / 1024.0 / 1024.0 AS total_mb,
        SUM(CASE WHEN usecounts = 1 THEN 1 ELSE 0 END) AS single_use_plans,
        SUM(CASE WHEN usecounts = 1 THEN CAST(size_in_bytes AS BIGINT) ELSE 0 END) / 1024.0 / 1024.0 AS single_use_mb,
        CAST(100.0 * SUM(CASE WHEN usecounts = 1 THEN 1 ELSE 0 END) / NULLIF(COUNT_BIG(*),0) AS decimal(6,2)) AS single_use_pct
    FROM base
    GROUP BY instance_name, engine_edition, objtype
),
tot AS
(
    SELECT
        instance_name,
        engine_edition,
        SUM(CAST(plan_count AS BIGINT)) AS total_plans,
        SUM(total_mb) AS total_mb,
        SUM(CAST(single_use_plans AS BIGINT)) AS total_single_use_plans,
        SUM(single_use_mb) AS total_single_use_mb,
        SUM(CASE WHEN objtype='Adhoc' THEN plan_count ELSE 0 END) AS adhoc_plans,
        SUM(CASE WHEN objtype='Adhoc' THEN single_use_plans ELSE 0 END) AS adhoc_single_use
    FROM agg
    GROUP BY instance_name, engine_edition
)
SELECT
    a.instance_name,
    a.engine_edition,
    scope_note =
        CASE 
            WHEN a.engine_edition = 5 THEN 'Azure SQL Database: DMV rows are containment-filtered; scope is effectively current database.'
            ELSE 'SQL Server/MI: DMV rows are instance-wide; optional DB filter uses dm_exec_sql_text.dbid when available.'
        END,
    a.objtype,
    a.plan_count,
    a.total_mb,
    a.single_use_plans,
    a.single_use_mb,
    a.single_use_pct,
    recommendations =
        CONCAT(
            CASE 
                WHEN a.objtype = 'Adhoc' AND a.single_use_pct >= 70
                    THEN 'usecounts=1 dominates Adhoc: plan created and never reused → strong indicator of unparameterized/dynamic SQL. '
                WHEN a.objtype = 'Adhoc' AND a.single_use_pct >= 30
                    THEN 'Adhoc has moderate single-use: review parameterization & literal-driven dynamic SQL patterns. '
                WHEN a.objtype = 'Adhoc'
                    THEN 'Adhoc present: monitor whether it dominates cache over time. '
                ELSE ''
            END,
            CASE
                WHEN a.single_use_plans > 0 AND a.single_use_mb >= 128
                    THEN 'Single-use plans consume meaningful memory → plan cache bloat risk / memory pressure. '
                WHEN a.single_use_plans > 0 AND a.single_use_mb >= 32
                    THEN 'Single-use plans have non-trivial memory footprint. '
                WHEN a.single_use_plans > 0
                    THEN 'Some single-use plans exist; validate whether expected. '
                ELSE ''
            END,
            CASE
                WHEN (t.total_single_use_plans * 1.0 / NULLIF(t.total_plans,0)) >= 0.50
                     AND t.total_single_use_mb >= 128
                     AND (t.adhoc_single_use * 1.0 / NULLIF(t.adhoc_plans,0)) >= 0.50
                    THEN 'Overall verdict: high single-use ratio + Adhoc-heavy + non-trivial memory → consistent with classic plan cache bloat. '
                ELSE ''
            END,
            'Next steps: identify top single-use Adhoc statements by size and enforce parameterization where feasible.'
        )
FROM agg AS a
JOIN tot AS t
  ON t.instance_name = a.instance_name
 AND t.engine_edition = a.engine_edition
ORDER BY a.total_mb DESC
OPTION (MAXDOP 1);
```

**What to do:**

| Finding | Recommendation |
|---------|----------------|
| `single_use_pct` ≥ 70% for Adhoc | Strong indicator of unparameterized/dynamic SQL — plan cache bloat confirmed |
| `single_use_mb` ≥ 128 MB | Plan cache bloat consuming significant memory — prioritize remediation |
| Overall verdict: classic plan cache bloat | Enable optimize for ad hoc workloads + enforce parameterization for top offenders |

---

### Step 4: Top Single-Use Ad Hoc Plans

> Run with the SQL query tool — returns the top single-use ad hoc plans ranked by memory consumption, with pattern-based recommendations for each.

```sql
-- Set @DatabaseName to N'YourDB' to scope to a specific database, or leave NULL for all/current
DECLARE @DatabaseName sysname = N'{{DatabaseName}}';
DECLARE @EngineEdition int = CAST(SERVERPROPERTY('EngineEdition') AS int);

DECLARE @EffectiveDbId int =
    CASE 
        WHEN @EngineEdition = 5 THEN DB_ID()
        WHEN @DatabaseName IS NULL THEN NULL
        ELSE DB_ID(@DatabaseName)
    END;

SELECT TOP ({{TopN}})
    @@SERVERNAME AS instance_name,
    @EngineEdition AS engine_edition,
    cp.usecounts,
    cp.size_in_bytes / 1024.0 AS size_kb,
    DB_NAME(st.dbid) AS database_name,
    st.text AS sql_text,
    CASE
        WHEN st.text LIKE '%sp_executesql%'
            THEN 'Review sp_executesql usage — may have non-parameterized fragments'
        WHEN st.text LIKE '%+%+%'
            THEN 'Possible string concatenation in SQL — parameterize with sp_executesql'
        WHEN cp.size_in_bytes > 1048576
            THEN 'Large plan (>1 MB) — consider using stored procedures for this pattern'
        ELSE 'Parameterize this query pattern using sp_executesql or stored procedures'
    END AS Recommendation
FROM sys.dm_exec_cached_plans AS cp
CROSS APPLY sys.dm_exec_sql_text(cp.plan_handle) AS st
WHERE cp.objtype = 'Adhoc'
  AND cp.usecounts = 1
  AND (@EffectiveDbId IS NULL OR st.dbid = @EffectiveDbId)
ORDER BY cp.size_in_bytes DESC
OPTION (MAXDOP 1);
```

**What to do:**

| Finding | Recommendation |
|---------|----------------|
| Patterns with string concatenation (`+`) | Replace with parameterized sp_executesql calls |
| sp_executesql with non-parameterized fragments | Review the dynamic SQL construction for parameterization gaps |
| Large plans (> 1 MB) | Convert to stored procedures for better plan reuse |

---

### Step 5: Parameter Sniffing Detection

> Run with the SQL query tool — identifies queries with high max/min elapsed-time variance that may indicate parameter-sensitive plan behavior, using CPU and logical-read variance as supporting signals.

```sql
DECLARE @MinExecCount bigint = {{MinExecutionCount}};
DECLARE @HighRatio decimal(18,2) = 20.0;        -- strong variance threshold
DECLARE @MediumRatio decimal(18,2) = 10.0;      -- moderate variance threshold
DECLARE @MinMaxMs decimal(18,2) = 50.0;         -- ignore tiny queries (noise)
-- Set @DatabaseName to N'YourDB' to scope to a specific database, or leave NULL for all/current
DECLARE @DatabaseName sysname = N'{{DatabaseName}}';

DECLARE @EngineEdition int = CAST(SERVERPROPERTY('EngineEdition') AS int);  
DECLARE @EffectiveDbId int =
    CASE
        WHEN @EngineEdition = 5 THEN DB_ID()      
        WHEN @DatabaseName IS NULL THEN NULL
        ELSE DB_ID(@DatabaseName)
    END;

;WITH d AS
(
    SELECT
        DB_NAME(st.dbid) AS database_name,
        qs.execution_count,
        CAST((qs.max_elapsed_time * 1.0) / NULLIF(qs.min_elapsed_time,0) AS decimal(18,2)) AS max_to_min_ratio,

        SUBSTRING(st.text,
                  (qs.statement_start_offset/2) + 1,
                  ((CASE qs.statement_end_offset WHEN -1 THEN DATALENGTH(st.text)
                     ELSE qs.statement_end_offset END - qs.statement_start_offset)/2) + 1) AS statement_text,

        recommendation =
            CASE
                WHEN qs.execution_count >= @MinExecCount
                 AND (qs.max_elapsed_time/1000.0) >= @MinMaxMs
                 AND ((qs.max_elapsed_time * 1.0) / NULLIF(qs.min_elapsed_time,0)) >= @HighRatio
                 AND (
                        (qs.max_logical_reads * 1.0 / NULLIF(qs.min_logical_reads,0)) >= 5
                      OR (qs.max_worker_time * 1.0 / NULLIF(qs.min_worker_time,0)) >= 5
                     )
                    THEN 'HIGH suspicion of parameter-sensitive behavior (possible parameter sniffing): very high duration variance with CPU/reads variance. Confirm via Query Store (multiple plans) or plan comparison.'
                WHEN qs.execution_count >= @MinExecCount
                 AND (qs.max_elapsed_time/1000.0) >= @MinMaxMs
                 AND ((qs.max_elapsed_time * 1.0) / NULLIF(qs.min_elapsed_time,0)) >= @MediumRatio
                    THEN 'POSSIBLE parameter-sensitive behavior: moderate/high duration variance. Could also be blocking, tempdb spills, memory pressure. Validate with Query Store or capture plans.'
                ELSE 'Unlikely parameter sniffing from this heuristic alone (variance not high enough).'
            END,

        why_this_is_only_a_heuristic =
            'sys.dm_exec_query_stats aggregates stats per cached plan; high max/min spread can be caused by multiple factors. Use Query Store or plan comparison to confirm.',

        qs.max_elapsed_time
    FROM sys.dm_exec_query_stats AS qs                    
    CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
    WHERE qs.execution_count >= @MinExecCount
      AND (qs.max_elapsed_time/1000.0) >= @MinMaxMs
      AND (
            @EffectiveDbId IS NULL
            OR st.dbid = @EffectiveDbId
            OR (@EngineEdition <> 5 AND st.dbid IS NULL) 
          )
)
SELECT TOP ({{TopN}})
    database_name,
    execution_count,
    max_to_min_ratio,
    statement_text,
    recommendation,
    why_this_is_only_a_heuristic
FROM d
ORDER BY max_to_min_ratio DESC, max_elapsed_time DESC
OPTION (MAXDOP 1);
```

**What to do:**

| Finding | Recommendation |
|---------|----------------|
| HIGH suspicion | Confirm via Query Store (multiple plans). Consider OPTIMIZE FOR UNKNOWN or plan guides |
| POSSIBLE suspicion | Validate with Query Store or plan comparison. Could also be blocking/tempdb spills |
| Moderate/high ratio but no reads/CPU variance | Likely not parameter sniffing — investigate other causes (blocking, memory) |

---

### Step 6: SET Option Analysis

> Run with the SQL query tool — examines the SET options compiled into the top 200 cached plans (by size) to detect plan cache pollution from inconsistent connection settings.

```sql
-- Limited to TOP 200 plans (by size) to avoid expensive full-cache scan.
-- Only returns SET options that are ON for each plan.
WITH top_plans AS
(
    SELECT TOP (200)
        cp.plan_handle,
        cp.size_in_bytes
    FROM sys.dm_exec_cached_plans AS cp
    WHERE cp.cacheobjtype = 'Compiled Plan'
    ORDER BY cp.size_in_bytes DESC
),
pvt AS
(
    SELECT
        plan_handle,
        CAST([set_options] AS int) AS set_options,
        CAST([sql_handle]  AS varbinary(64)) AS sql_handle
    FROM
    (
        SELECT
            tp.plan_handle,
            epa.attribute,
            epa.value
        FROM top_plans AS tp
        OUTER APPLY sys.dm_exec_plan_attributes(tp.plan_handle) AS epa
        WHERE epa.attribute IN ('set_options','sql_handle')
    ) AS src
    PIVOT
    (
        MAX(src.value) FOR src.attribute IN ([set_options],[sql_handle])
    ) AS p
),
opt AS
(
        SELECT *
    FROM (VALUES
        (   1, 'DISABLE_DEF_CNST_CHK',    'Controls interim or deferred constraint checking.'),
        (   2, 'IMPLICIT_TRANSACTIONS',   'Controls whether transactions are started implicitly.'),
        (   4, 'CURSOR_CLOSE_ON_COMMIT',  'Controls cursor behavior after COMMIT.'),
        (   8, 'ANSI_WARNINGS',           'Controls truncation and NULL-in-aggregate warnings.'),
        (  16, 'ANSI_PADDING',            'Controls padding of fixed-length variables.'),
        (  32, 'ANSI_NULLS',              'Controls NULL handling when using equality/inequality operators.'),
        (  64, 'ARITHABORT',              'Terminates a query on overflow or divide-by-zero during execution.'),
        ( 128, 'ARITHIGNORE',             'Returns NULL on overflow or divide-by-zero.'),
        ( 256, 'QUOTED_IDENTIFIER',       'Controls interpretation of double quotes for identifiers/literals.'),
        ( 512, 'NOCOUNT',                 'Suppresses "(n rows affected)" messages.'),
        (1024, 'ANSI_NULL_DFLT_ON',       'New columns default to NULL when nullability is not specified.'),
        (2048, 'ANSI_NULL_DFLT_OFF',      'New columns default to NOT NULL when nullability is not specified.'),
        (4096, 'CONCAT_NULL_YIELDS_NULL', 'Concatenating NULL with a string yields NULL.'),
        (8192, 'NUMERIC_ROUNDABORT',      'Raises an error when loss of precision occurs in an expression.'),
        (16384,'XACT_ABORT',              'Rolls back a transaction if a statement raises a run-time error.')
    ) AS v(bit_value, set_option, indicates)
)
SELECT
    p.plan_handle,
    p.sql_handle,
    p.set_options,
    o.bit_value,
    o.set_option,
    'ON' AS option_status,
    o.indicates,
    CASE
        WHEN o.set_option IN ('ARITHABORT','ANSI_NULLS','QUOTED_IDENTIFIER')
            THEN 'Common plan cache pollution culprit -- ensure consistent SET options across all connections'
        WHEN o.set_option = 'ANSI_WARNINGS'
            THEN 'Verify consistency across application connections'
        ELSE ''
    END AS Guidance
FROM pvt AS p
CROSS JOIN opt AS o
WHERE (p.set_options & o.bit_value) = o.bit_value
ORDER BY p.set_options DESC, p.plan_handle, o.bit_value
OPTION (MAXDOP 1);
```

**What to do:**

| Finding | Recommendation |
|---------|----------------|
| ARITHABORT differs across connections | Common cause of plan cache pollution — standardize across all application connections |
| ANSI_NULLS or QUOTED_IDENTIFIER differ | Ensure consistent SET options in connection strings and stored procedures |
| Multiple distinct set_options values for same query | Plan cache pollution — each combination creates a separate cache entry |

---

### Step 7: Ad Hoc vs Prepared Summary

> Run with the SQL query tool — compares ad hoc vs prepared plan counts, memory, and single-use percentages to assess overall parameterization health.

```sql
-- Set @DatabaseName to N'YourDB' to scope to a specific database, or leave NULL for all/current
DECLARE @DatabaseName sysname = N'{{DatabaseName}}';
DECLARE @IncludeNullDbId bit = 1;        -- Include rows where dm_exec_sql_text.dbid is NULL (safer coverage) 
DECLARE @ExcludeSystemDBs bit = 1;       -- SQL Server/MI only (when @DatabaseName is NULL): exclude dbid <= 4
DECLARE @EngineEdition int = CAST(SERVERPROPERTY('EngineEdition') AS int);  

DECLARE @EffectiveDbId int =
    CASE
        WHEN @EngineEdition = 5 THEN DB_ID()          -- Azure SQL DB: safest is current DB only 
        WHEN @DatabaseName IS NULL THEN NULL          -- SQL Server/MI: instance-wide
        ELSE DB_ID(@DatabaseName)                     -- SQL Server/MI: specific DB
    END;

;WITH base AS
(
    SELECT TOP ({{TopN}})
        cp.objtype,
        cp.usecounts,
        cp.size_in_bytes,
        st.dbid
    FROM sys.dm_exec_cached_plans AS cp
    CROSS APPLY sys.dm_exec_sql_text(cp.plan_handle) AS st
    WHERE cp.objtype IN ('Adhoc','Prepared')
      AND (
            @EffectiveDbId IS NULL
            OR st.dbid = @EffectiveDbId
            OR (@IncludeNullDbId = 1 AND st.dbid IS NULL)
          )
      AND (
            @EngineEdition = 5
            OR @ExcludeSystemDBs = 0
            OR @EffectiveDbId IS NOT NULL
            OR st.dbid > 4
          )
    ORDER BY cp.size_in_bytes DESC
)
SELECT
    'ADHOC_SINGLE_USE_SUMMARY' AS section,
    objtype,
    COUNT_BIG(*) AS plan_count,
    SUM(CAST(size_in_bytes AS BIGINT)) / 1024.0 / 1024.0 AS total_mb,
    SUM(CASE WHEN usecounts = 1 THEN 1 ELSE 0 END) AS single_use_plans,
    SUM(CASE WHEN usecounts = 1 THEN CAST(size_in_bytes AS BIGINT) ELSE 0 END) / 1024.0 / 1024.0 AS single_use_mb,
    CAST(100.0 * SUM(CASE WHEN usecounts = 1 THEN 1 ELSE 0 END) / NULLIF(COUNT_BIG(*),0) AS decimal(6,2)) AS single_use_pct,
    recommendation =
        CASE
            WHEN objtype='Adhoc'
                 AND (SUM(CASE WHEN usecounts=1 THEN 1 ELSE 0 END) * 1.0 / NULLIF(COUNT(*),0)) >= 0.50
                THEN 'Adhoc dominated by single-use: consistent with plan cache bloat (unparameterized/dynamic SQL).'
            WHEN objtype='Adhoc'
                THEN 'Adhoc present: monitor single-use % and memory footprint.'
            WHEN objtype='Prepared'
                THEN 'Prepared plans: indicates parameterized execution; generally healthier reuse.'
            ELSE ''
        END
FROM base
GROUP BY objtype
ORDER BY total_mb DESC
OPTION (MAXDOP 1);
```

**What to do:**

| Finding | Recommendation |
|---------|----------------|
| Adhoc single_use_pct ≥ 50% | Ad hoc dominated by single-use — consistent with plan cache bloat |
| Prepared plans dominant | Healthy pattern — parameterized execution enables plan reuse |

---

### Step 8: Optimize for Ad Hoc Workloads Check

> Run with the SQL query tool — checks whether `optimize for ad hoc workloads` is enabled on the current platform and provides the correct enable command.

```sql
DECLARE @EngineEdition int = CAST(SERVERPROPERTY('EngineEdition') AS int);

SELECT
    @@SERVERNAME AS instance_name,
    @EngineEdition AS engine_edition,
    CASE
        WHEN @EngineEdition = 5 THEN 'Azure SQL Database (database-scoped config)'
        ELSE 'SQL Server / Azure SQL Managed Instance (server-scoped config)'
    END AS platform;

IF @EngineEdition = 5
BEGIN
    /* Azure SQL Database: database-scoped configuration */
    SELECT
        configuration_id,
        name,
        value,
        value_for_secondary,
        CASE
            WHEN value = 0
                THEN 'OFF — Enable with: ALTER DATABASE SCOPED CONFIGURATION SET OPTIMIZE_FOR_AD_HOC_WORKLOADS = ON;'
            ELSE 'ON — No action needed'
        END AS Recommendation
    FROM sys.database_scoped_configurations
    WHERE name = N'OPTIMIZE_FOR_AD_HOC_WORKLOADS'
    OPTION (MAXDOP 1);
END
ELSE
BEGIN
    /* SQL Server / Azure SQL Managed Instance: server configuration option */
    SELECT
        name,
        value,
        value_in_use,
        is_dynamic,
        description,
        CASE
            WHEN value_in_use = 0
                THEN 'OFF — Enable with: EXEC sp_configure ''optimize for ad hoc workloads'', 1; RECONFIGURE;'
            ELSE 'ON — No action needed'
        END AS Recommendation
    FROM sys.configurations
    WHERE name = N'optimize for ad hoc workloads'
    OPTION (MAXDOP 1);
END;
```

**What to do:**

| Finding | Recommendation |
|---------|----------------|
| Setting is OFF and bloat detected | Enable immediately — SQL Server: `EXEC sp_configure 'optimize for ad hoc workloads', 1; RECONFIGURE;` / Azure SQL DB: `ALTER DATABASE SCOPED CONFIGURATION SET OPTIMIZE_FOR_AD_HOC_WORKLOADS = ON;` |
| Setting is ON | No action needed — already configured |

