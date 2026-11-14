# Step 7 - Targeted Specialist Drill-down

## Objective

Delegate only when collected audit evidence proves a specialist signal. Do not run a specialist
merely because its checks are generally useful.

## Handoff Contract

Pass:

```text
source_check_ids
server/platform
database names
requested and effective evidence windows
sample timestamps
dominant signal and observed values
session/request/query identifiers when already captured
permission and capability limitations
redaction policy
```

Do not pass raw sensitive text unless authorized. Do not repeat the specialist's query set in this
skill.

## Routing Matrix

| Audit evidence | Specialist skill | Trigger |
|---|---|---|
| HA-RES-001 repeated runnable queues, CPU waits | `investigate-sql-cpu-pressure` | Sustained scheduler/CPU signal |
| HA-STO-003 data-file IO signal | `investigate-sql-data-io-pressure` | Repeated data-file latency/stall growth |
| HA-STO-003 log-file IO signal or HA-STO-004 log pressure | `investigate-sql-log-io-pressure` | Repeated log latency, pressure, or reuse issue |
| HA-RES-002/003 low-memory or grant pressure | `investigate-sql-memory-issues` | Low-memory flag, active grant waiters, or timeout growth |
| HA-RES-004 repeated blocking | `blocking-root-cause-analysis` | Same blocking chain appears across samples |
| HA-RES-005 dominant wait category | `wait-category-analysis` | Cumulative waits corroborated by active samples |
| HA-CRIT-003 or HA-OPS-002 unhealthy AG/MI link | `investigate-ha-issues` | Active synchronization, connectivity, or role failure |
| HA-OPS-001 backup uncertainty/risk | `backup-strategy-sqlserver` | User requests policy assessment or observed backup gap |
| HA-SEC-001/002 authentication issue | `authentication-diagnostics` | Login/authentication failure or immediate exposure |
| Query Store/workload signal captured by a specialist | `query-store-investigation`, `slow-query-investigation`, or `plan-cache-analysis` | Evidence identifies a workload-query problem |

## Decision Rules

- Multiple signals may justify multiple specialists, but order them by incident criticality and
  blast radius.
- Critical availability/integrity and HA failures precede performance drill-down.
- If evidence is only cumulative and the reset window is unknown, recommend the specialist but do
  not automatically invoke it.
- If permission gaps prevent confirmation, record `UNKNOWN` and list the permission needed; do not
  invoke a specialist that requires the same unavailable evidence.
- Include each delegated result as a concise summary with its source check IDs. The specialist owns
  root cause and detailed recommendations.
