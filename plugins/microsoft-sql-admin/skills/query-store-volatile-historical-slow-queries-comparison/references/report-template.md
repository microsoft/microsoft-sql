# Volatile Query Investigation — Report Template

Use the per-step templates in `references/queries.md` for detailed sections.

## Header

- Database: {{database name}}
- Date: {{current date in YYYY-MM-DD format}}
- Lookback: {{LookbackMinutes}} minutes
- Query ID: {{QueryId or N/A}}

## Recommended Structure

1. Platform summary — record engine edition and whether the platform is supported.
2. Step 0 summary — record Query Store state, storage usage, and capture readiness.
3. Detailed findings — paste the relevant per-step template from `references/queries.md` for each step you executed.
4. Conclusion — summarize the most likely root cause and next actions.

## Per-Step Templates

- Step 1: Use `## Top Volatile Queries` from `references/queries.md`.
- Step 2: Use `## Query Interval Performance Comparison` from `references/queries.md`.
- Steps 3-7: Summarize findings using the interpretation guidance in `references/queries.md`.
