# Incident evidence

Shared incident-analysis rules for the SQL admin investigation skills. Preserve source and time-window boundaries.

Use the supplied evidence's time window and source. Captured tables or a dossier
describe that capture; current DMVs do not replace them. Retrieve the
complete relevant rows through the configured SQL tool when the evidence is live.
Preserve query, plan, interval, session and execution-context identifiers.

Compute each interval's execution-weighted duration and CPU separately:
`SUM(count_executions * avg_value) / SUM(count_executions)`. Multiple runtime rows
can represent distinct execution groups in one interval. Compare each query with
its own baseline. Rank regressions before following the ticket's hypothesis. A
lock-bound query and a different CPU-bound query can coexist; do not transfer one
query's waits or blocking chain to another.

Build a session graph from the captured requests: each positive blocking ID gives
an edge from the blocked session to its blocker. For a complete consistent snapshot,
a positive head blocks another session and is not itself blocked. An intermediate
session can block others while also waiting; this does not make it a head. Trace
each chain to its endpoint, retaining a visited set to detect cycles. Do not invent
a head for a cycle or an incomplete chain. Verify every proposed head against the
request rows, and join the session table separately: a sleeping transaction owner
can have no active request.

For downstream impact, traverse the reverse edges and count distinct session IDs,
excluding the head. Parallel execution contexts are waiting tasks, not additional
sessions. Keep negative blocking codes outside the positive-session graph; interpret
them using the documented wait semantics rather than treating them as session IDs.

Before reporting, reconcile the head list, each query's chain, downstream list and
downstream count against the same graph. Record source rows and calculation results
so conflicting intermediate conclusions can be corrected. A failed SQL call is not
evidence for a computed result, even when the MCP response envelope is valid.

Keep diagnostic review candidates separate from actions authorized now. A read-only
investigation authorizes no session termination or plan forcing. Diagnose and propose
next evidence first; current waits alone do not establish a plan-forcing remedy.
