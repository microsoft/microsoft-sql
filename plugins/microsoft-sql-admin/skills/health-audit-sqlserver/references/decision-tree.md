# Health Classification and Decision Tree

## Per-Check Status

1. Capability absent on the detected platform: `NOT_APPLICABLE`.
2. Permission, retention, database access, or visibility prevents a conclusion: `UNKNOWN`.
3. Query failed after eligibility was proven: `ERROR`.
4. Evidence confirms an active outage, integrity/recovery risk, severe HA failure, or repeated
   service disruption: `FAIL` with `CRITICAL` severity.
5. Evidence confirms an operational failure or sustained resource pressure: `FAIL` with `HIGH` or
   `MEDIUM` severity.
6. Evidence is abnormal but contextual requirements or sustained behavior are unproven: `WARN`.
7. Evidence is descriptive or a routing/coverage note: `INFO`.
8. All required evidence was visible and the deterministic condition passed: `PASS`.

Never convert an empty result to `PASS` until permission, object capability, scope, and time
coverage are proven.

## Overall Health State

Evaluate in this order:

```text
CRITICAL
  Active outage, integrity/recovery risk, severe HA failure, or repeated dump/severe-error evidence.

UNHEALTHY
  Confirmed operational failure, failed recoverability control, sustained resource pressure,
  recurring critical job failure, or active blocking/worker exhaustion.

DEGRADED
  Warning trend, intermittent pressure, partial resilience, capacity concern, or non-critical
  operational failure.

AT_RISK
  No active incident, but an observed configuration/exposure materially increases future failure
  likelihood.

HEALTHY_WITH_LIMITATIONS
  No detected unhealthy condition, but mandatory coverage contains UNKNOWN, ERROR, or material
  skipped checks.

HEALTHY
  All mandatory eligible checks passed with adequate permission, scope, evidence windows, and no
  unresolved errors.

UNKNOWN
  Platform, connection, or essential visibility is insufficient to characterize health.
```

The highest applicable state wins. `AT_RISK` must not override an active `DEGRADED`,
`UNHEALTHY`, or `CRITICAL` condition.

## Prioritization

Rank findings by:

1. Immediate data loss, corruption, outage, or failover risk
2. Blast radius
3. Confirmed active impact
4. Confidence and evidence freshness
5. Recoverability and time sensitivity
6. Operational effort

Keep active incidents separate from durable risk and optional improvements.

## Recommendation Rules

- Cite the source `HA-*` check ID and observed evidence.
- Recommend diagnostic or verification actions before configuration changes.
- Never recommend repair, failover, kill, shrink, cache clearing, index rebuild, or server
  reconfiguration as an automatic audit action.
- State requirements that are still needed, such as RPO/RTO, maintenance policy, approved
  principals, or external Azure metadata.
- For delegated findings, attribute root-cause conclusions to the specialist result.
