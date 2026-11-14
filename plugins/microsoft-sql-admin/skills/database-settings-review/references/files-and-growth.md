# Database Files and Growth

## File inventory

```sql
SELECT
      df.file_id
    , df.name AS logical_file_name
    , df.type_desc
    , df.state_desc
    , df.physical_name
    , CONVERT(decimal(19,2), df.size / 128.0) AS size_mb
    , CONVERT(decimal(19,2),
        CASE WHEN FILEPROPERTY(df.name, N'SpaceUsed') IS NULL THEN NULL
             ELSE FILEPROPERTY(df.name, N'SpaceUsed') / 128.0 END) AS used_mb
    , CASE
          WHEN df.max_size = -1 THEN N'UNLIMITED'
          WHEN df.max_size = 0 THEN N'NO_GROWTH'
          ELSE CONVERT(nvarchar(30), CONVERT(decimal(19,2), df.max_size / 128.0)) + N' MB'
      END AS max_size
    , df.growth AS growth_value
    , df.is_percent_growth
    , CASE
          WHEN df.is_percent_growth = 1
              THEN CONVERT(nvarchar(30), df.growth) + N'%'
          ELSE CONVERT(nvarchar(30), CONVERT(decimal(19,2), df.growth / 128.0)) + N' MB'
      END AS growth_increment
FROM sys.database_files AS df
ORDER BY df.type, df.file_id
OPTION (MAXDOP 1);
```

## Classification

- Any `is_percent_growth = 1`: **Medium** because increments become unpredictable as files grow.
- `growth_value = 0`: **Review** because the file cannot autogrow.
- Very small fixed growth, unlimited growth, uneven file sizing, or low free space are contextual
  review items, not automatic defects.
- Azure SQL Database file paths and capacity are platform managed; do not apply filesystem advice.

Prefer predictable fixed growth where the platform permits it, but explain the tradeoff: larger
increments reduce frequent growth events while requiring sufficient storage headroom. Never
recommend shrinking files solely because free space exists.
