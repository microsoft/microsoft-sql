## Report Template

Present results in this exact format:

```
## Plan Cache Analysis Report
Server: {{server name}}
Database: {{database name}}
Date: {{current date in YYYY-MM-DD format}}
Parameters: TopN={{TopN}}, DatabaseName={{DatabaseName}}, MinExecutionCount={{MinExecutionCount}}

---

### Plan Cache Composition

| Cache Type | Total Plans | Total MBs | Avg Use Count | Plans Used Once | MBs Used Once |
|------------|-------------|-----------|---------------|-----------------|---------------|
{{one row per cache type from Step 1}}

---

### Bloat Assessment

{{Summarize: single-use percentage, memory consumed by single-use plans, optimize for ad hoc status}}

---

### Top Single-Use Offenders

{{Top 5 largest single-use ad hoc plans with SQL text and recommendations}}

---

### Parameter Sniffing Suspects

{{If any HIGH/POSSIBLE suspects found, list them with statement text and recommendation}}
{{If none: "No parameter sniffing suspects detected based on plan cache heuristics."}}

---

### SET Option Analysis

{{If inconsistent SET options found: list the problematic options and affected plans}}
{{If clean: "SET options are consistent across cached plans."}}

---

### Configuration Check

| Setting | Status | Action |
|---------|--------|--------|
| optimize for ad hoc workloads | {{ON/OFF}} | {{recommendation}} |

---

### Recommended Actions

{{Prioritized list of actions based on findings:}}
1. {{Highest priority finding and action}}
2. {{Next priority}}
...
```
