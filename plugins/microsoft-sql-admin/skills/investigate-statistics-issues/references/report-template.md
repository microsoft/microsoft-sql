# Statistics Issues Investigation — Report Template

## Report Template

Combine results from all steps into this unified report:

```
## Statistics Health Investigation Report
Database:    {{database name}}
Date:        {{current date in YYYY-MM-DD format}}
Platform:    {{engine_type from Step 1}}
SQL Version: {{sql_version from Step 1}}
Compatibility Level: {{compatibility_level from Step 1}}

### Summary
- Total stale statistics found: {{count from Step 2}}
- Statistics exceeding auto-update threshold: {{count from Step 6}}
- High-impact statistics needing attention: {{count from Step 4 with staleness_since_compile issues}}
- Incremental statistics candidates: {{count of non-incremental partitioned tables from Step 9}}
- Computed column statistics needing update: {{count from Step 10}}
- Tables with stale stats AND missing indexes: {{count from Step 11}}
- Database settings issues: {{count of non-OK recommendations from Step 12}}
- Duplicate statistics found: {{count from Step 13}}
- Empty histograms: {{count from Step 14}}
- Tables with statistics bloat: {{count from Step 15}}
- Unused stale statistics: {{count from Step 16}}
- Hypothetical (DTA) objects to clean up: {{count from Step 17}}
- Missing multi-column FK statistics: {{count from Step 18}}
- Statistics needing PERSIST_SAMPLE_PERCENT: {{count from Step 19}}
- Fullscan-to-sample regressions: {{count from Step 20}}

### Recommended Actions
1. Immediate: Fix database settings flagged in Step 12 (auto_create/auto_update disabled)
2. Immediate: Update empty histograms from Step 14 — these cause 1-row estimates
3. Critical: Update statistics with modification_percent > 20%
4. Critical: Address tables flagged in Step 11 (stale stats + missing indexes)
5. High: Create missing multi-column FK statistics from Step 18
6. High: Enable PERSIST_SAMPLE_PERCENT for fullscan statistics (Step 19)
7. Review: Clean up hypothetical DTA objects from Step 17
8. Review: Drop duplicate statistics from Step 13
9. Review: Statistics on heavily-used indexes (Step 5)
10. Review: Enable incremental statistics on partitioned tables (Step 9)
11. Monitor: Statistics near auto-update threshold (Step 6)
12. Monitor: Fullscan-to-sample regressions (Step 20)
