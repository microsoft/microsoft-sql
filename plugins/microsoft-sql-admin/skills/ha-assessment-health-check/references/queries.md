# Common Queries

## Step 1: Platform Detection and HA Capability

```sql
SELECT
    SERVERPROPERTY('Edition')             AS edition,
    SERVERPROPERTY('ProductVersion')      AS product_version,
    SERVERPROPERTY('ProductMajorVersion') AS major_version,
    SERVERPROPERTY('EngineEdition')       AS engine_edition,
    SERVERPROPERTY('IsHadrEnabled')       AS is_hadr_enabled,
    SERVERPROPERTY('MachineName')         AS machine_name,
    SERVERPROPERTY('ServerName')          AS server_name,
    CASE CAST(SERVERPROPERTY('EngineEdition') AS INT)
        WHEN 1 THEN 'Personal/Desktop — no HA support'
        WHEN 2 THEN 'Standard — limited AG support (Basic AG in 2016+)'
        WHEN 3 THEN 'Enterprise — full AG support'
        WHEN 4 THEN 'Express — no HA support'
        WHEN 5 THEN 'Azure SQL Database — platform-managed HA'
        WHEN 6 THEN 'Azure Synapse Analytics - Dedicated SQL pool — N/A for this skill'
        WHEN 8 THEN 'Azure SQL Managed Instance — MI failover groups'
        WHEN 9 THEN 'Azure SQL Edge'
        WHEN 11 THEN 'Azure Synapse serverless SQL pool / Fabric Warehouse — N/A for this skill'
        WHEN 12 THEN 'Fabric SQL Database — platform-managed HA'
        ELSE 'Unknown edition (' + CAST(SERVERPROPERTY('EngineEdition') AS VARCHAR) + ')'
    END AS ha_capability_assessment;
```

### HA Posture Classification (Engine Edition 2 = Standard, 3 = Enterprise)

> Run this second query on SQL Server (on-prem / Azure IaaS) to drive the HA Posture Decision Tree.
> It reports, using DMVs only, whether Always On is enabled and whether any AG is a Basic or an Advanced (full) AG.

```sql
-- HA posture classification — branches: no HA enabled / HADR enabled but no AG / Basic AG / Advanced (full) AG
IF CAST(SERVERPROPERTY('EngineEdition') AS INT) IN (2, 3)
BEGIN
    DECLARE @is_hadr  INT = CAST(SERVERPROPERTY('IsHadrEnabled') AS INT);
    DECLARE @ag_count INT = 0;
    DECLARE @basic_ag INT = 0;

    IF @is_hadr = 1
    BEGIN
        SELECT @ag_count = COUNT(*) FROM sys.availability_groups;

        -- basic_features column exists only on SQL Server 2016+ (ProductMajorVersion >= 13)
        IF CAST(SERVERPROPERTY('ProductMajorVersion') AS INT) >= 13
            EXEC sys.sp_executesql
                N'SELECT @c = COUNT(*) FROM sys.availability_groups WHERE basic_features = 1',
                N'@c INT OUTPUT', @basic_ag OUTPUT;
    END

    SELECT
        @is_hadr                AS is_hadr_enabled,
        @ag_count               AS ag_count,
        @basic_ag               AS basic_ag_count,
        (@ag_count - @basic_ag)  AS advanced_ag_count,
        CASE
            WHEN @is_hadr = 0
                THEN 'FAIL: Always On / HADR is NOT enabled. The instance has no AG-based high availability and is a single point of failure. Guide the customer to enable it. Decision Tree -> Branch A (No HA Enabled)'
            WHEN @ag_count = 0
                THEN 'WARNING: HADR is enabled but no Availability Group exists yet. No database is protected by replication or failover. Decision Tree -> Branch A (No HA Enabled)'
            WHEN @basic_ag > 0 AND (@ag_count - @basic_ag) = 0
                THEN 'INFO: Basic Availability Group(s) detected (Standard Edition). Evaluate Basic AG limitations and best practices. Decision Tree -> Branch B (Basic AG)'
            ELSE 'PASS: Advanced (full) Availability Group(s) detected. Apply the full AG best-practice review. Decision Tree -> Branch C (Full AG)'
        END AS ha_posture;
END
```
