# Verified behaviour: the server-side bulk paths

## Contents

- [Environment](#environment)
- [The local path refusal, Msg 12713](#the-local-path-refusal-msg-12713)
- [Proving the refusal is about the platform, not the path](#proving-the-refusal-is-about-the-platform-not-the-path)
- [The Blob path, credential and data source errors](#the-blob-path-credential-and-data-source-errors)
- [WITH options do not change the outcome](#with-options-do-not-change-the-outcome)
- [bcp: present, but its certificate-trust flags failed silently](#bcp-present-but-its-certificate-trust-flags-failed-silently)
- [Recovery model: accepted here, do not assume it elsewhere](#recovery-model-accepted-here-do-not-assume-it-elsewhere)
- [The transaction log rate governor](#the-transaction-log-rate-governor)

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

## Recovery model: accepted here, do not assume it elsewhere

`ALTER DATABASE dq_bulkload SET RECOVERY BULK_LOGGED` was accepted with no error on this engine,
and `sys.databases.recovery_model_desc` reported `BULK_LOGGED` afterward. This was measured only
on the local container used for authoring. Whether the production Azure SQL Database cloud service
accepts or silently ignores the same statement was not checked in this session and is not claimed
either way. Regardless of the answer, the log rate governor below applies independently of
recovery model, which is the reason this skill does not build its advice on recovery model at all.

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

The same page's mitigation list: scale up to a higher service level or a different tier (Hyperscale
publishes an explicit per-database log rate, 150 MiB/s on premium-series hardware, 100 MiB/s on
other hardware); load transient staging data into `tempdb`, which is minimally logged there; for
analytic loads, target a table with a clustered columnstore index or data compression to reduce the
log volume the load generates. None of this was independently measured against a running load in
this session, since the container used has one fixed compute size and no elastic pool to compare
against; it is carried here from the Learn page directly and dated as such.
