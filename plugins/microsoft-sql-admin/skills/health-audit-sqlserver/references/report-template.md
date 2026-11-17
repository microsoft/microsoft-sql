# SQL Server Health Audit Report Template

Do not expose these instructions. Omit empty optional sections, but never omit coverage
limitations.

```markdown
# SQL Server Health Audit

**Overall health:** {{CRITICAL | UNHEALTHY | DEGRADED | AT_RISK |
HEALTHY_WITH_LIMITATIONS | HEALTHY | UNKNOWN}}
**Server:** {{redacted or server name}}
**Platform:** {{SQL Server | SQL Server on Azure VM | Azure SQL Managed Instance | unknown}}
**Hosting certainty:** {{confirmed | user-supplied | inferred-vm | unknown}}
**Installed build:** {{version, edition, update level; do not claim current patch status}}
**Audit time (UTC):** {{timestamp}}
**Requested/effective lookback:** {{windows}}
**Scope:** {{database scope}}

## Executive Summary

{{Three to five sentences: current health, highest-impact issue, blast radius, confidence, and
whether action is urgent. Separate active incidents from durable risk.}}

## Immediate Actions

| Priority | Check | Scope | Evidence | Action | Verification |
|---|---|---|---|---|---|
| {{P0/P1/P2}} | {{HA-*}} | {{scope}} | {{concise evidence}} | {{safe next action}} | {{how to verify}} |

## Active Health Findings

| Severity | Status | Check | Category | Scope | Finding | Confidence |
|---|---|---|---|---|---|---|
| {{severity}} | {{FAIL/WARN/INFO}} | {{HA-*}} | {{category}} | {{scope}} | {{evidence-backed finding}} | {{confidence}} |

## Resource and Operational Snapshot

| Area | Assessment | Evidence window | Key evidence | Specialist route |
|---|---|---|---|---|
| CPU/schedulers | {{state}} | {{window}} | {{samples}} | {{skill or none}} |
| Memory/grants | {{state}} | {{window}} | {{samples}} | {{skill or none}} |
| Blocking/workers | {{state}} | {{window}} | {{samples}} | {{skill or none}} |
| Storage/log/tempdb | {{state}} | {{window}} | {{evidence}} | {{skill or none}} |
| Backup/HA/Agent | {{state}} | {{window}} | {{evidence}} | {{skill or none}} |
| Security exposure | {{state}} | point-in-time | {{redacted evidence}} | {{skill or none}} |

## Durable Risks and Policy Questions

{{List observations that require RPO/RTO, criticality, access policy, maintenance policy, or
external Azure metadata before they can be judged. Do not present them as active incidents.}}

## Delegated Investigations

| Specialist | Source checks | Scope | Trigger | Result |
|---|---|---|---|---|
| {{skill}} | {{HA-* IDs}} | {{scope}} | {{captured signal}} | {{concise specialist summary}} |

## Coverage

| Outcome | Count | Details |
|---|---:|---|
| PASS | {{n}} | {{mandatory checks covered}} |
| FAIL | {{n}} | {{IDs}} |
| WARN | {{n}} | {{IDs}} |
| INFO | {{n}} | {{IDs}} |
| UNKNOWN | {{n}} | {{permissions/retention/access gaps}} |
| ERROR | {{n}} | {{failed checks and errors}} |
| NOT_APPLICABLE | {{n}} | {{platform/capability reasons}} |
| Deferred/skipped | {{n}} | {{cost, privilege, sensitivity, CriticalOnly reasons}} |

## Environment and Evidence Limits

- {{Uptime/reset boundary}}
- {{Database access limitations}}
- {{Permission limitations}}
- {{Privileged/expensive/sensitive checks disabled}}
- {{Managed Instance or Azure VM metadata boundaries}}

## Recommended Follow-up

1. {{Highest-priority verification or specialist action}}
2. {{Second action}}
3. {{Policy or monitoring action, only if required}}
```

## Report Rules

- Lead with critical findings and incomplete coverage.
- Use counts plus representative evidence; do not dump raw DMV rows.
- Redact identities, paths, addresses, job content, and log text by default.
- State `No issue detected within available evidence` rather than `healthy` when coverage is
  incomplete.
- If all mandatory checks pass with complete visibility, say `HEALTHY`; otherwise use
  `HEALTHY_WITH_LIMITATIONS` or `UNKNOWN` as defined in the decision tree.
