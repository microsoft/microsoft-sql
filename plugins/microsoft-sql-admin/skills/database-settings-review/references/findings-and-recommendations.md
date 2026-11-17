# Findings and Recommendations

Apply the requested deterministic classification before adding contextual observations.

## High

- `AUTO_SHRINK ON`
- `AUTO_CLOSE ON`
- Query Store `actual_state_desc = ERROR`

## Medium

- `PAGE_VERIFY` is not `CHECKSUM`
- `TRUSTWORTHY ON`
- Query Store storage usage is greater than 90 percent
- Any database file uses percentage growth

## Review

- `LEGACY_CARDINALITY_ESTIMATION = ON`
- database-scoped `MAXDOP` is nonzero
- `PARAMETER_SNIFFING = OFF`
- `AUTO_CREATE_STATISTICS OFF`
- `AUTO_UPDATE_STATISTICS OFF`
- file autogrowth is disabled
- Query Store is read-only, with its exact reason
- configured and in-use server values differ

## Informational

- ADR
- Read Committed Snapshot Isolation
- Snapshot Isolation
- temporal tables
- CDC
- Change Tracking
- ledger
- automatic tuning
- In-Memory OLTP
- Always Encrypted
- Dynamic Data Masking
- Row-Level Security
- Service Broker
- TDE/encryption state
- compatibility level, recovery model, collation, containment, and delayed durability

## Recommendation contract

For each non-informational finding:

1. State the observed fact and exact evidence.
2. Explain the operational or security impact.
3. Describe the benefit of the likely remediation.
4. Describe tradeoffs and prerequisites.
5. Provide a validation approach, but no change command.

Do not:

- call an unavailable setting disabled;
- call an unobserved feature unused;
- recommend FULL recovery without confirmed log-backup and point-in-time recovery requirements;
- recommend disabling RCSI, snapshot isolation, Query Store, ADR, or security features solely
  because they add overhead;
- recommend shrinking files as routine maintenance;
- recommend MAXDOP without considering both database and server scope;
- turn informational inventory into a risk without evidence.
