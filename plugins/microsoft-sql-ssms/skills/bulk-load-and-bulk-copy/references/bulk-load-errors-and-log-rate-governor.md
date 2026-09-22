# Bulk load errors and the log rate governor

## Contents

- [Environment](#environment)
- [The local path refusal, Msg 12713](#the-local-path-refusal-msg-12713)
- [Proving the refusal is about the platform, not the path](#proving-the-refusal-is-about-the-platform-not-the-path)
- [The Blob path, credential and data source errors](#the-blob-path-credential-and-data-source-errors)
- [WITH options do not change the outcome](#with-options-do-not-change-the-outcome)
- [bcp: present, but its certificate-trust flags failed silently](#bcp-present-but-its-certificate-trust-flags-failed-silently)
- [Recovery model: accepted here, do not assume it elsewhere](#recovery-model-accepted-here-do-not-assume-it-elsewhere)
- [The transaction log rate governor](#the-transaction-log-rate-governor)
- [Platform limits and permissions from Microsoft Learn](#platform-limits-and-permissions-from-microsoft-learn)

## Environment

Measured on 2026-08-29 against a live engine reporting `SERVERPROPERTY('EngineEdition')` 5,
`SERVERPROPERTY('Edition')` `SQL Azure`, `SERVERPROPERTY('ProductVersion')` 12.0.2000.8. The
client tools were `/opt/mssql-tools18/bin/sqlcmd` and `/opt/mssql-tools18/bin/bcp`, both from the
`mssql-tools18` package, bcp reporting version 18.6.0002.1.

## The local path refusal, Msg 12713

```sql
BULK INSERT dbo.t1 FROM '/tmp/data.csv' WITH (FIELDTERMINATOR=',', ROWTERMINATOR='\n');
```

fails with:

```
Msg 12713, Level 16, State 1, Server SQL Azure, Line 1
OPENROWSET is not allowed to read local files. Path: '/tmp/data.csv'.
```

The message names `OPENROWSET`, not `BULK INSERT`, even though the statement that failed was
`BULK INSERT`. That is a real clue, not a mismatch: `BULK INSERT` is implemented on top of the same
`OPENROWSET(BULK ...)` machinery, and the error surfaces from that shared layer. An agent that only
pattern-matches on the statement it wrote will not recognise the error as belonging to it.

Calling `OPENROWSET(BULK ...)` directly against the same path produces the identical message:

```sql
SELECT * FROM OPENROWSET(BULK '/tmp/data.csv', SINGLE_CLOB) AS x;
```
```
Msg 12713, Level 16, State 1, Server SQL Azure, Line 1
OPENROWSET is not allowed to read local files. Path: '/tmp/data.csv'.
```

## Proving the refusal is about the platform, not the path

The same `BULK INSERT` against a path that does not exist on disk (`/tmp/does_not_exist.csv`,
never created) produced the exact same Msg 12713, with the nonexistent path substituted into the
same message text. If the engine were opening the file and then failing, a missing file would
raise a different, file-system-flavoured error. It does not: the refusal happens before the file
is touched at all. It is a property of the platform, not of the argument. This is worth stating
explicitly to an agent, because the message text alone does not say so, and an agent's first
instinct on seeing a file-not-opened-sounding error is to check the path.

## The Blob path, credential and data source errors

An ad hoc `https://` URL with no matching credential object:

```sql
SELECT * FROM OPENROWSET(BULK 'https://example.blob.core.windows.net/container/data.csv',
  SINGLE_CLOB) AS x;
```
```
Msg 15151, Level 16, State 1, Server SQL Azure, Line 1
Cannot find the CREDENTIAL 'https://example.blob.core.windows.net/container/data.csv', because it
does not exist or you do not have permission.
```

The message names the full URL as if it were the credential's own name, because a scoped
credential for the ad hoc URL form is created with the container URL as its name. `BULK INSERT`
against the same URL fails with the identical Msg 15151, again through the shared `OPENROWSET`
layer.

An `EXTERNAL DATA SOURCE` can be created and referenced without a credential attached (anonymous
or public-container access):

```sql
CREATE EXTERNAL DATA SOURCE MyBlob
  WITH (TYPE = BLOB_STORAGE, LOCATION = 'https://example.blob.core.windows.net/container');
```

succeeds with no error. Loading through it:

```sql
BULK INSERT dbo.t1 FROM 'data.csv' WITH (DATA_SOURCE = 'MyBlob', FIELDTERMINATOR=',',
  ROWTERMINATOR='\n');

SELECT * FROM OPENROWSET(BULK 'data.csv', DATA_SOURCE = 'MyBlob', SINGLE_CLOB) AS x;
```

both fail identically, once the host name does not resolve to a reachable endpoint:

```
Msg 4861, Level 16, State 1, Server SQL Azure, Line 1
Cannot bulk load because the file "data.csv" could not be opened. Operating system error code
12007(failed to retrieve text for this error. Reason: 15105).
```

Operating system error 12007 is a name-resolution failure, not a permission or syntax error: the
statement got past parsing, past credential resolution, and reached the network layer trying to
resolve a host, on both `BULK INSERT` and `OPENROWSET(BULK ...)`. This is the strongest evidence
that the `DATA_SOURCE` form of both statements is genuinely wired to Blob Storage on this
platform, and that a syntactically correct load against a real, reachable storage account with a
valid credential is the expected success path. That last step, an actual load against a real
storage account, was not run in this session: no Azure Blob Storage account was available to the
authoring environment. Everything up to and including the network attempt was verified; a
successful end-to-end transfer was not.

## WITH options do not change the outcome

```sql
BULK INSERT dbo.t1 FROM '/tmp/data.csv'
  WITH (FIELDTERMINATOR=',', ROWTERMINATOR='\n', TABLOCK, BATCHSIZE=1000);
```

still fails with the same Msg 12713. Neither `TABLOCK` nor `BATCHSIZE` bypass the local-path
refusal; they are irrelevant to it. Do not suggest either as a workaround for the error.

## bcp: present, but its certificate-trust flags failed silently

`bcp` ships in the image and runs (`bcp -v` prints its banner, exit 0). Getting it to actually
connect to this engine was not achieved in this session, and the failure mode is worth recording
because it is silent in a way that wastes an agent's time.

The engine presents a self-signed certificate, the same one `sqlcmd` accepts via its own `-C`
flag. Against `bcp`, three different ways of asking the client to trust that certificate were
tried:

- `-u` (trust server certificate)
- `-Yo` (optional encryption)
- an ODBC DSN (`ODBCINI` pointed at a user-writable file) carrying `TrustServerCertificate=yes`

All three produced **zero bytes of output on stdout and stderr, and exit code 1**. No SQLState, no
native error, no message at all, confirmed by piping through `xxd`.

By contrast, the paths that do **not** ask the client to trust the certificate produced real,
diagnosable errors:

- no `-Y` flag at all: `SSL Provider: [error:0A000086:SSL routines::certificate verify
  failed:self-signed certificate]`
- `-Ys` (encryption mandatory, no `-u`): `TCP Provider: Error code 0x2746`

So the two informative failures are the ones where the client refuses the certificate, and the
three silent failures are every attempt tried to make the client accept it. This looks like a
defect in this build's certificate-trust handling rather than a documented behaviour, and it
should not be presented to a user as expected. What follows from it for this skill: **`bcp`'s
data-transfer behaviour itself, batch size handling, row counts, native versus character mode,
against this engine was not verified**, because no attempt reached a connected state. Treat any
`bcp` guidance in the skill body as based on the tool's documented flags and on how `bcp` behaves
against SQL Server generally, not as measured against this platform.

## Recovery model: accepted here, and beside the point

`ALTER DATABASE dq_bulkload SET RECOVERY BULK_LOGGED` was accepted with no error on this engine,
and `sys.databases.recovery_model_desc` reported `BULK_LOGGED` afterward, measured 2026-08-29 on
the local container only. Whether the cloud service accepts or silently ignores the same statement
was not checked and is not claimed either way, because it does not matter: the `BULK INSERT` page's
"Log behavior" section states flatly that "Minimal logging isn't supported in Azure SQL Database"
(fetched 2026-09-03), and the log rate governor below applies regardless of recovery model. That is
why this skill builds no advice on recovery model at all.

## The transaction log rate governor

Verified against Microsoft Learn, "Resource Management - Azure SQL Database"
(`resource-limits-logical-server`, section "Transaction log rate governance"), fetched
2026-08-29. Quoting the operative sentence: "Transaction log rate governance is a process in Azure
SQL Database used to limit high ingestion rates for workloads such as bulk insert, SELECT INTO,
and index builds. These limits are tracked and enforced at the subsecond level to the rate of log
record generation, limiting throughput regardless of how many IOs can be issued against data
files."

The wait types it documents, from `sys.dm_exec_requests` and `sys.dm_os_wait_stats`:

| Wait type | Meaning |
|---|---|
| `LOG_RATE_GOVERNOR` | Database-level limiting |
| `POOL_LOG_RATE_GOVERNOR` | Elastic pool-level limiting |
| `INSTANCE_LOG_RATE_GOVERNOR` | Instance-level limiting |
| `HADR_THROTTLE_LOG_RATE_SEND_RECV_QUEUE_SIZE` | Replica feedback, Premium/Business Critical replication falling behind |
| `HADR_THROTTLE_LOG_RATE_LOG_SIZE` | Feedback control avoiding an out-of-log-space condition |
| `HADR_THROTTLE_LOG_RATE_MISMATCHED_SLO` | Geo-replication feedback, avoiding secondary unavailability |

The cap itself is readable per database. `sys.dm_user_db_resource_governance` documents
`primary_max_log_rate` as "Maximum log rate in bytes per second at user workload group level", and
`pool_max_log_rate` and `instance_max_log_rate` as the pool and instance equivalents. Learn's own
example query selects `database_name, primary_group_id, primary_max_log_rate, primary_group_max_io,
pool_max_io` from that view, returning one row for a single database and one row per database in an
elastic pool. Reading the view needs `VIEW DATABASE STATE`, or membership in
`##MS_ServerStateReader##` on Basic, S0, S1 and pooled databases. Fetched 2026-09-03, not measured.

The same page's mitigation list: scale up to a higher service level or a different tier (Hyperscale
publishes an explicit per-database log rate, 150 MiB/s on premium-series hardware, 100 MiB/s on
other hardware); load transient staging data into `tempdb`, which is minimally logged there; for
analytic loads, target a table with a clustered columnstore index or data compression to reduce the
log volume the load generates. None of this was independently measured against a running load in
this session, since the container used has one fixed compute size and no elastic pool to compare
against; it is carried here from the Learn page directly and dated as such.

## Platform limits and permissions from Microsoft Learn

Fetched 2026-09-03 from the `BULK INSERT (Transact-SQL)` page and not independently measured. These
are the parts that differ from SQL Server and are therefore the parts an agent gets wrong.

| Aspect | Azure SQL Database |
|---|---|
| Data source | Azure Storage only. No local path, no UNC path |
| Source authentication | Microsoft Entra ID, SAS token, or managed identity |
| Unsupported options | `*` wildcards in the path, `FORMAT = 'PARQUET'` |
| Permissions on the target | `INSERT` and `ADMINISTER DATABASE BULK OPERATIONS`, plus `ALTER TABLE` when constraints, triggers or `KEEPIDENTITY` are involved |
| Minimal logging | Not supported |

Three defaults that make a bad load look like a good one:

- `MAXERRORS` defaults to 10. Rows that fail conversion are skipped and counted, and the statement
  still succeeds. `bcp`'s `-m` has the same default.
- `ERRORFILE` on Azure SQL Database should be accompanied by `ERRORFILE_DATA_SOURCE`, or the import
  "might fail with permissions error". The named file must not already exist in the container.
- `FIRSTROW` is 1-based and, in Learn's words, "isn't intended to skip column headers. The
  `BULK INSERT` statement doesn't support skipping headers." Skipped rows are scanned for field
  terminators only, not validated. `bcp`'s `-F` is the flag that does skip a header row.

A format file caps out at 1,024 fields, and exceeding it raises error 4822. `bcp` has no such
limit.
