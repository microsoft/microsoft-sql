# Database Settings Review Report

Use every numbered section below. Write `None` when a finding category is empty and `Unavailable`
when metadata is unsupported or inaccessible. Keep facts distinct from recommendations.

```text
# Database Settings Review

## 1. Executive Summary

Database: {{database_name}}
Platform: {{platform}}
Overall posture: {{highest finding level and concise summary}}

## 2. Platform Detection

| Property | Observed value |
|---|---|
| Engine edition | {{engine_edition}} |
| Platform | {{platform}} |
| Edition | {{edition}} |
| Product version / level | {{product_version}} / {{product_level}} |
| Database | {{database_name}} |

## 3. High Findings

| Finding | Fact and evidence | Impact |
|---|---|---|
{{high findings or None}}

## 4. Medium Findings

| Finding | Fact and evidence | Impact |
|---|---|---|
{{medium findings or None}}

## 5. Review Findings

| Finding | Fact and evidence | Why review is needed |
|---|---|---|
{{review findings or None}}

## 6. Informational Findings

| Setting or feature | Observed state | Scope |
|---|---|---|
{{informational findings}}

## 7. Database Scoped Configuration Analysis

| Setting | Primary value | Secondary value | Default | Classification | Interpretation |
|---|---:|---:|---|---|---|
{{every row returned by sys.database_scoped_configurations}}

## 8. Query Store Analysis

{{state, storage percentage, capture, cleanup, retention, readonly reason, and tradeoffs}}

### Automatic tuning

| Option | Desired | Actual | Reason |
|---|---|---|---|
{{all automatic tuning rows or Unavailable}}

## 9. Security Analysis

{{TRUSTWORTHY, TDE, Always Encrypted, Dynamic Data Masking, Row-Level Security, ledger,
containment, and security limitations. State that inventory does not prove compliance.}}

## 10. Feature Inventory

| Feature | Observed state/count | Interpretation |
|---|---|---|
| In-Memory OLTP | {{value}} | {{interpretation}} |
| Temporal tables | {{value}} | {{interpretation}} |
| Ledger tables | {{value}} | {{interpretation}} |
| CDC | {{value}} | {{interpretation}} |
| Change Tracking | {{value}} | {{interpretation}} |
| ADR | {{value}} | {{interpretation}} |
| Service Broker | {{value}} | {{interpretation}} |
| RCSI / Snapshot Isolation | {{value}} | {{interpretation}} |

## 11. Recommendations

{{Prioritized recommendations. For each: evidence, benefit, tradeoff, prerequisite, and validation
approach. Do not include change commands.}}

## 12. Evidence Collected

| Evidence source | Status | Notes |
|---|---|---|
| Platform and database properties | {{Collected/Unavailable}} | {{notes}} |
| Database scoped configurations | {{Collected/Unavailable}} | {{row count}} |
| Query Store | {{Collected/Unavailable}} | {{notes}} |
| Automatic tuning | {{Collected/Unavailable}} | {{notes}} |
| Database files | {{Collected/Unavailable}} | {{file count}} |
| Feature and security catalogs | {{Collected/Unavailable}} | {{notes}} |
| Server configurations | {{Collected/Unavailable/Not applicable}} | {{notes}} |
```
