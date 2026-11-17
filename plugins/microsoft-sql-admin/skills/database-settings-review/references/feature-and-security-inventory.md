# Feature and Security Inventory

Run each guarded query independently. A missing catalog surface is `Unavailable`, not disabled.

## In-Memory OLTP and temporal tables

```sql
SELECT
      COALESCE(SUM(CASE WHEN t.is_memory_optimized = 1 THEN 1 ELSE 0 END), 0)
        AS memory_optimized_table_count
    , COALESCE(SUM(CASE WHEN t.temporal_type = 2 THEN 1 ELSE 0 END), 0)
        AS system_versioned_temporal_table_count
FROM sys.tables AS t
WHERE t.is_ms_shipped = 0
OPTION (MAXDOP 1);
```

Both are informational. In-Memory OLTP requires memory and operational planning. Temporal history
requires retention and storage planning.

## Ledger tables

```sql
IF COL_LENGTH(N'sys.tables', N'ledger_type') IS NOT NULL
BEGIN
    EXEC sys.sp_executesql N'
        SELECT
              COALESCE(SUM(CASE WHEN ledger_type = 2 THEN 1 ELSE 0 END), 0)
                AS updatable_ledger_table_count
            , COALESCE(SUM(CASE WHEN ledger_type = 3 THEN 1 ELSE 0 END), 0)
                AS append_only_ledger_table_count
        FROM sys.tables
        WHERE is_ms_shipped = 0
          AND (is_dropped_ledger_table = 0 OR is_dropped_ledger_table IS NULL)
        OPTION (MAXDOP 1);';
END
ELSE
BEGIN
    SELECT N'Unavailable - ledger catalog columns are not exposed' AS availability;
END;
```

## CDC and Change Tracking

```sql
SELECT
      d.is_cdc_enabled
    , (SELECT COUNT_BIG(*)
       FROM sys.tables
       WHERE is_ms_shipped = 0
         AND is_tracked_by_cdc = 1) AS cdc_tracked_table_count
    , CASE WHEN ctd.database_id IS NULL THEN 0 ELSE 1 END AS change_tracking_enabled
    , ctd.retention_period
    , ctd.retention_period_units_desc
    , ctd.is_auto_cleanup_on
    , (SELECT COUNT_BIG(*)
       FROM sys.change_tracking_tables) AS change_tracked_table_count
FROM sys.databases AS d
LEFT JOIN sys.change_tracking_databases AS ctd
  ON ctd.database_id = d.database_id
WHERE d.database_id = DB_ID()
OPTION (MAXDOP 1);
```

CDC and Change Tracking are informational. Discuss retention, cleanup, downstream consumer lag,
and log/storage overhead before recommending changes.

## Always Encrypted

```sql
IF COL_LENGTH(N'sys.columns', N'encryption_type') IS NOT NULL
BEGIN
    EXEC sys.sp_executesql N'
        SELECT
              COUNT_BIG(*) AS encrypted_column_count
            , COUNT(DISTINCT column_encryption_key_id) AS referenced_column_encryption_key_count
        FROM sys.columns
        WHERE encryption_type IS NOT NULL
        OPTION (MAXDOP 1);';
END
ELSE
BEGIN
    SELECT N'Unavailable - Always Encrypted column metadata is not exposed' AS availability;
END;
```

Always Encrypted protects values from the database engine but adds driver, key-management, and
query limitations. Do not expose key material.

## Dynamic Data Masking

```sql
IF OBJECT_ID(N'sys.masked_columns') IS NOT NULL
BEGIN
    SELECT COUNT_BIG(*) AS masked_column_count
    FROM sys.masked_columns
    WHERE is_masked = 1
    OPTION (MAXDOP 1);
END
ELSE
BEGIN
    SELECT N'Unavailable - masking metadata is not exposed' AS availability;
END;
```

Masking limits presentation for unprivileged users; it is not encryption and does not replace
authorization.

## Row-Level Security

```sql
IF OBJECT_ID(N'sys.security_policies') IS NOT NULL
BEGIN
    SELECT
          COUNT_BIG(DISTINCT p.object_id) AS security_policy_count
        , COALESCE(SUM(CASE WHEN p.is_enabled = 1 THEN 1 ELSE 0 END), 0)
            AS enabled_security_policy_count
        , COUNT_BIG(pr.object_id) AS security_predicate_count
    FROM sys.security_policies AS p
    LEFT JOIN sys.security_predicates AS pr
      ON pr.object_id = p.object_id
    OPTION (MAXDOP 1);
END
ELSE
BEGIN
    SELECT N'Unavailable - row-level security metadata is not exposed' AS availability;
END;
```

RLS is a security boundary only when predicates and permissions are correctly designed and tested.

## Security interpretation

Use the database-properties evidence for:

- `TRUSTWORTHY ON`: **Medium**; cross-database and impersonation behavior can expand risk.
- TDE state (`is_encrypted`): informational. Absence is not automatically a defect because
  requirements and platform-managed encryption differ.
- containment, Service Broker, and broker priority: informational.
- Always Encrypted, masking, RLS, and ledger: inventory facts, not proof of complete data
  protection or compliance.
