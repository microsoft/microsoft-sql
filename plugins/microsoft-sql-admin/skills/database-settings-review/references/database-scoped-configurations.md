# Database Scoped Configuration Analysis

## Collect every setting

Do not filter this query. Every returned row must be represented in the analysis.

```sql
IF OBJECT_ID(N'sys.database_scoped_configurations') IS NULL
BEGIN
    SELECT N'Unavailable - sys.database_scoped_configurations is not exposed' AS availability;
END
ELSE IF COL_LENGTH(N'sys.database_scoped_configurations', N'is_value_default') IS NOT NULL
BEGIN
    EXEC sys.sp_executesql N'
        SELECT
              configuration_id
            , name
            , value
            , value_for_secondary
            , is_value_default
        FROM sys.database_scoped_configurations
        ORDER BY name
        OPTION (MAXDOP 1);';
END
ELSE
BEGIN
    EXEC sys.sp_executesql N'
        SELECT
              configuration_id
            , name
            , value
            , value_for_secondary
            , CAST(NULL AS bit) AS is_value_default
        FROM sys.database_scoped_configurations
        ORDER BY name
        OPTION (MAXDOP 1);';
END;
```

## Required analysis

For each returned row, report:

- setting name;
- primary value;
- secondary value when populated;
- whether the value is default when that metadata is available;
- classification: `Review`, `Informational`, or `No finding`;
- evidence-based interpretation.

Never treat a zero value uniformly. Its meaning is setting-specific.

## Complete setting interpretation

Apply these rules only when the setting is returned. A missing row means `Unavailable/not exposed
on this version or platform`, not `OFF`. When `is_value_default = 0`, identify the override even
when its current value is otherwise reasonable.

| Setting | Classification and interpretation |
|---|---|
| `ACCELERATED_PLAN_FORCING` | `OFF` is `Review`; the optimized forcing mechanism is normally preferred. Validate forced-plan behavior before changing it. |
| `ALLOW_BUILTIN_TVF_IN_ALL_COMPAT_LEVELS` | `ON` is `Review`; this preview Azure/Fabric option bypasses normal compatibility gates for selected built-in TVFs and can reduce portability. |
| `ALLOW_STALE_VECTOR_INDEX` | `ON` is `Review`; writes remain possible but vector indexes can become stale until rebuilt. Describe data-freshness and rebuild tradeoffs. |
| `ASYNC_STATS_UPDATE_WAIT_AT_LOW_PRIORITY` | `Informational`; `ON` reduces foreground blocking from async statistics updates but can postpone update completion. Correlate with `AUTO_UPDATE_STATISTICS_ASYNC`. |
| `BATCH_MODE_ADAPTIVE_JOINS` | `Informational`; `OFF` can avoid a proven regression but removes runtime join adaptation for eligible compatibility levels. |
| `BATCH_MODE_MEMORY_GRANT_FEEDBACK` | `Informational`; `OFF` prevents correction of repeated batch-mode over-grants and spills. Compatibility level still gates behavior. |
| `BATCH_MODE_ON_ROWSTORE` | `Informational`; `OFF` can stabilize a regression but removes batch-mode opportunities on rowstore at eligible compatibility levels. |
| `CE_FEEDBACK` | `Informational`; effective use requires an eligible compatibility level and Query Store in `READ_WRITE`. `OFF` removes learned CE corrections. |
| `CE_FEEDBACK_FOR_EXPRESSIONS` | `Informational`; effective use requires compatibility level 160 or later. `OFF` removes learned CE-model corrections for repeating expression patterns. |
| `DEFERRED_COMPILATION_TV` | `Informational`; `OFF` removes first-execution table-variable cardinality feedback at eligible compatibility levels. |
| `DOP_FEEDBACK` | `Informational`; effective use requires Query Store in `READ_WRITE` and an eligible platform/version. It adjusts DOP only for repeating queries. |
| `ELEVATE_ONLINE` | `Review` when not `OFF`. `WHEN_SUPPORTED` favors availability; `FAIL_UNSUPPORTED` prevents unsupported operations instead of allowing offline execution. Explain edition and operation support. |
| `ELEVATE_RESUMABLE` | `Review` when not `OFF`. Resumable-by-default operations improve interruption handling but require additional storage, monitoring, and lifecycle management. |
| `EXEC_QUERY_STATS_FOR_SCALAR_FUNCTIONS` | `Informational`; `ON` adds execution statistics for natively compiled scalar functions with monitoring overhead. |
| `FORCE_SHOWPLAN_RUNTIME_PARAMETER_COLLECTION` | `ON` is `Review`; runtime parameter capture improves diagnostics but can expose sensitive values in plans and adds collection overhead. |
| `FULLTEXT_INDEX_VERSION` | `Informational`; report the selected full-text index version and validate language/breaker compatibility before any migration. |
| `IDENTITY_CACHE` | `OFF` is `Review`; it can reduce identity gaps after unexpected restarts but can reduce insert throughput. |
| `INTERLEAVED_EXECUTION_TVF` | `Informational`; `OFF` removes compile-time cardinality correction for eligible multi-statement TVFs. |
| `ISOLATE_SECURITY_POLICY_CARDINALITY` | `Informational`; report the value and assess RLS/security-predicate plan behavior. Validate both information-isolation requirements and plan quality. |
| `GLOBAL_TEMPORARY_TABLE_AUTO_DROP` | `Informational`; `OFF` changes global temporary table cleanup behavior and can leave objects until explicitly dropped or the service restarts. |
| `LAST_QUERY_PLAN_STATS` | `ON` is `Informational`; last actual plans improve troubleshooting but consume memory and can expose runtime details to principals with DMV access. |
| `LEDGER_DIGEST_STORAGE_ENDPOINT` | `Informational`; report `Configured` or `OFF` without reproducing secrets or URL query strings. Validate endpoint access, retention, and immutability externally. |
| `LEGACY_CARDINALITY_ESTIMATION` | `ON` is `Review`; it can preserve legacy plans but prevents use of the compatibility level's newer CE model across the database. |
| `LIGHTWEIGHT_QUERY_PROFILING` | `Informational`; `ON` enables low-overhead runtime profiling used by monitoring features, with some collection overhead. |
| `MAXDOP` | A nonzero database override is `Review`. On SQL Server/MI, zero inherits the server setting; `PRIMARY` applies to secondary configuration. On Azure SQL Database, interpret with service objective and workload concurrency. |
| `MEMORY_GRANT_FEEDBACK_PERCENTILE_GRANT` | `Informational`; effective use depends on memory-grant feedback persistence and Query Store. It uses historical percentiles for variable workloads. |
| `MEMORY_GRANT_FEEDBACK_PERSISTENCE` | `Informational`; effective use requires Query Store. `OFF` prevents learned memory grants from surviving plan eviction and restart. |
| `OPTIMIZE_FOR_AD_HOC_WORKLOADS` | `Informational`; `ON` reduces cache use by single-use ad hoc plans but requires another compilation before storing the full reusable plan. |
| `OPTIMIZED_PLAN_FORCING` | `OFF` is `Review`; disabling optimized replay can increase compilation work for Query Store forced plans. |
| `OPTIMIZED_SP_EXECUTESQL` | `Informational`; `ON` serializes compilation of identical batches to reduce compilation storms but can introduce compile-lock waits. |
| `OPTIONAL_PARAMETER_OPTIMIZATION` | `Informational`; effective use requires the documented compatibility level. `OFF` removes plan variants for eligible optional predicates. |
| `PARAMETER_SENSITIVE_PLAN_OPTIMIZATION` | `Informational`; effective use requires the documented compatibility level. `OFF` removes plan variants for eligible parameter skew. |
| `PARAMETER_SNIFFING` | `OFF` is `Review`; it can stabilize some skewed workloads but disables parameter-sensitive compilation database-wide. Prefer targeted remediation when possible. |
| `PAUSED_RESUMABLE_INDEX_ABORT_DURATION_MINUTES` | `Informational`; report the timeout. Short values reduce abandoned-operation exposure; long values preserve resumability but retain resources and metadata longer. |
| `PREVIEW_FEATURES` | `ON` is `Review`; inventory the enabled preview-dependent features and state their supportability, change risk, and production suitability. |
| `QUERY_OPTIMIZER_HOTFIXES` | `Informational`; `ON` enables optimizer fixes beyond the compatibility baseline and can change plan shapes. Validate representative workloads. |
| `READABLE_SECONDARY_TEMPORARY_STATS_AUTO_CREATE` | `Informational`; report primary/secondary values. `OFF` can reduce secondary metadata work but can impair plans for readable-secondary workloads. |
| `READABLE_SECONDARY_TEMPORARY_STATS_AUTO_UPDATE` | `Informational`; report primary/secondary values. `OFF` can leave temporary secondary statistics stale for reporting workloads. |
| `ROW_MODE_MEMORY_GRANT_FEEDBACK` | `Informational`; `OFF` prevents correction of repeated row-mode over-grants and spills at eligible compatibility levels. |
| `TSQL_SCALAR_UDF_INLINING` | `Informational`; `OFF` avoids inlining regressions but removes set-based optimization opportunities for eligible scalar UDFs. |
| `TIME_ZONE` | `Informational`; preserve the exact catalog value but treat this as catalog-only when the public `ALTER DATABASE SCOPED CONFIGURATION` syntax does not document it. Do not infer a configurable local clock or recommend changing it. |
| `VERBOSE_TRUNCATION_WARNINGS` | `Informational`; `ON` provides column/value context for truncation errors. Compatibility level can affect behavior. Consider data sensitivity in error logging. |
| `XTP_PROCEDURE_EXECUTION_STATISTICS` | `ON` is `Informational`; adds statistics for natively compiled procedures with monitoring overhead. |
| `XTP_QUERY_EXECUTION_STATISTICS` | `ON` is `Informational`; adds statement-level statistics for natively compiled modules with greater monitoring overhead. |

## Secondary values

- Evaluate `value_for_secondary` independently when populated.
- A `NULL` `value_for_secondary` means the secondary follows `PRIMARY`; render it as `PRIMARY`
  rather than `Unavailable`.
- Differences can be intentional for reporting replicas, but must be stated explicitly.
- Do not infer that a secondary override is active unless the database participates as a readable
  secondary on the assessed platform.

`CLEAR PROCEDURE_CACHE` is an operation, not a row in
`sys.database_scoped_configurations`. Never execute it during this read-only review.

Settings added by a newer engine that are not in this matrix still require an output row. Classify
them as `Informational - interpretation unavailable`, cite the returned value, and do not guess.
