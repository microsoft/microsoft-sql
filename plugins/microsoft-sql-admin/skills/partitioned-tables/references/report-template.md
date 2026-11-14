## Report Template

Present results in this exact format:

```
## Partitioned Tables Analysis Report
Server: {{server name}}
Database: {{database name}}
Date: {{current date in YYYY-MM-DD format}}
Table: [{{SchemaName}}].[{{TableName}}]
Parameters: FutureMonths={{FutureMonths}}, ScanMode={{ScanMode}}, MinPageCount={{MinPageCount}}

---

### Platform
{{engine_type}} (Edition: {{sql_edition}}, Version: {{sql_version}})

---

### Partitioned Tables in Database

| Schema | Table | Next Step |
|--------|-------|-----------|
{{from Step 2}}

---

### Partition Distribution for [{{SchemaName}}].[{{TableName}}]

| Partition # | Boundary | Row Count | % of Total | Skew% | Skew Status | Size (MB) | Action |
|-------------|----------|-----------|------------|-------|-------------|-----------|--------|
{{from Step 4}}

---

### Fragmentation Summary

| Index | Partition # | Frag% | Pages | Recommendation |
|-------|-------------|-------|-------|----------------|
{{from Step 5 — only partitions needing action}}

---

### Boundary Health

{{Summary of boundary health from Step 6. Flag missing future partitions.}}

---

### Skew and Hot Partition Assessment

{{Summary from Step 8 — highlight any HIGH SKEW or hot partitions}}

---

### Partition Elimination Status

{{From Step 10 — are current queries achieving partition elimination?}}

---

### Recommended Actions

{{Prioritized list:}}
1. {{Highest priority finding and action}}
2. {{Next priority}}
...
```
