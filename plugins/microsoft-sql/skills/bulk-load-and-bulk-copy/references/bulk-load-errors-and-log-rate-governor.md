# Bulk load errors and the log rate governor

## Contents

- [The local path refusal, Msg 12713](#the-local-path-refusal-msg-12713)
- [The refusal is about the platform, not the path](#the-refusal-is-about-the-platform-not-the-path)
- [The Blob path, credential and data source errors](#the-blob-path-credential-and-data-source-errors)
- [WITH options do not change the outcome](#with-options-do-not-change-the-outcome)
- [bcp: the certificate-trust flags fail silently](#bcp-the-certificate-trust-flags-fail-silently)
- [Recovery model: beside the point](#recovery-model-beside-the-point)
- [The transaction log rate governor](#the-transaction-log-rate-governor)
- [Platform limits and permissions from Microsoft Learn](#platform-limits-and-permissions-from-microsoft-learn)

Each statement below needs only an existing table in place of `dbo.t1`, on Azure SQL Database or
the local Azure SQL Database container (`SERVERPROPERTY('EngineEdition')` 5 on both).

## The local path refusal, Msg 12713

On Azure SQL Database, `BULK INSERT` from a filesystem path is refused:

```sql
BULK INSERT dbo.t1 FROM '/tmp/data.csv' WITH (FIELDTERMINATOR=',', ROWTERMINATOR='\n');
```

You will see:

```
Msg 12713, Level 16, State 1, Server SQL Azure, Line 1
OPENROWSET is not allowed to read local files. Path: '/tmp/data.csv'.
```

The message names `OPENROWSET`, not `BULK INSERT`, even though the statement that failed was
`BULK INSERT`. That is a real clue, not a mismatch: `BULK INSERT` is implemented on top of the same
`OPENROWSET(BULK ...)` machinery, and the error surfaces from that shared layer. If you match only
on the statement you wrote, you will not recognise the error as belonging to it.

Calling `OPENROWSET(BULK ...)` directly against the same path produces the identical message:

```sql
SELECT * FROM OPENROWSET(BULK '/tmp/data.csv', SINGLE_CLOB) AS x;
```
```
Msg 12713, Level 16, State 1, Server SQL Azure, Line 1
OPENROWSET is not allowed to read local files. Path: '/tmp/data.csv'.
```

## The refusal is about the platform, not the path

Run the same `BULK INSERT` against a path that was never created, such as
`/tmp/does_not_exist.csv`, and you get the exact same Msg 12713, with the nonexistent path
substituted into the same message text. If the engine were opening the file and then failing, a
missing file would raise a different, file-system-flavoured error. It does not: the refusal happens
before the file is touched at all. It is a property of the platform, not of the argument. The
message text alone does not say so, and the first instinct on a file-not-opened-sounding error is
to check the path, which here is wasted effort.

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
resolve a host, on both `BULK INSERT` and `OPENROWSET(BULK ...)`. So the `DATA_SOURCE` form of both
statements is wired to Blob Storage on this platform, and a syntactically correct load against a
real, reachable storage account with a valid credential is the success path.

## WITH options do not change the outcome

```sql
BULK INSERT dbo.t1 FROM '/tmp/data.csv'
  WITH (FIELDTERMINATOR=',', ROWTERMINATOR='\n', TABLOCK, BATCHSIZE=1000);
```

still fails with the same Msg 12713. Neither `TABLOCK` nor `BATCHSIZE` bypass the local-path
refusal; they are irrelevant to it. Do not suggest either as a workaround for the error.

## bcp: the certificate-trust flags fail silently

`bcp` ships in the Azure SQL Database container image and runs (`bcp -v` prints its banner, exit
0). With `bcp` 18.6 from `mssql-tools18`, against a server presenting a self-signed certificate
(the container's, which `sqlcmd` accepts via its own `-C` flag), every way of asking the client to
trust that certificate fails without a word:

- `-u` (trust server certificate)
- `-Yo` (optional encryption)
- an ODBC DSN (`ODBCINI` pointed at a user-writable file) carrying `TrustServerCertificate=yes`

Each one produces **zero bytes of output on stdout and stderr, and exit code 1**. No SQLState, no
native error, no message at all; piping the output through `xxd` shows nothing.

By contrast, the paths that do **not** ask the client to trust the certificate produce real,
diagnosable errors:

- no `-Y` flag at all: `SSL Provider: [error:0A000086:SSL routines::certificate verify
  failed:self-signed certificate]`
- `-Ys` (encryption mandatory, no `-u`): `TCP Provider: Error code 0x2746`

So the informative failures are the ones where the client refuses the certificate, and the silent
failures are every attempt to make the client accept it. This appears to be a defect in that
build's certificate-trust handling rather than a documented behaviour, and it should not be
presented to a user as expected. The `bcp` guidance in SKILL.md, batch size handling, row counts,
character mode, follows the tool's documented flags.

## Recovery model: beside the point

In the local Azure SQL Database container, `ALTER DATABASE <database> SET RECOVERY BULK_LOGGED` is
accepted with no error, and `sys.databases.recovery_model_desc` reports `BULK_LOGGED` afterward. Do
not assume the cloud service accepts the same statement, or that it means anything if it does: the
`BULK INSERT` page's "Log behavior" section states flatly that "Minimal logging isn't supported in
Azure SQL Database", and the log rate governor below applies regardless of recovery model. That is
why this skill builds no advice on recovery model at all.

## The transaction log rate governor

Microsoft Learn, "Resource Management - Azure SQL Database" (`resource-limits-logical-server`,
section "Transaction log rate governance"), states the operative rule: "Transaction log rate
governance is a process in Azure SQL Database used to limit high ingestion rates for workloads such
as bulk insert, SELECT INTO, and index builds. These limits are tracked and enforced at the
subsecond level to the rate of log record generation, limiting throughput regardless of how many
IOs can be issued against data files."

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
`##MS_ServerStateReader##` on Basic, S0, S1 and pooled databases.

The same page's mitigation list: scale up to a higher service level or a different tier (Hyperscale
publishes an explicit per-database log rate, 150 MiB/s on premium-series hardware, 100 MiB/s on
other hardware); load transient staging data into `tempdb`, which is minimally logged there; for
analytic loads, target a table with a clustered columnstore index or data compression to reduce the
log volume the load generates.

## Platform limits and permissions from Microsoft Learn

From the `BULK INSERT (Transact-SQL)` page. These are the parts that differ from SQL Server, and so
the parts a SQL Server habit gets wrong.

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
