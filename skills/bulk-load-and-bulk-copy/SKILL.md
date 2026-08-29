---
name: bulk-load-and-bulk-copy
description: >-
  Loads data into Azure SQL Database fast by choosing the right route: BULK INSERT and
  OPENROWSET(BULK ...) from Azure Blob Storage, bcp, .NET SqlBulkCopy, and the Python and Node.js
  bulk-copy equivalents. Use when someone says "bulk insert", "bulk load a CSV", "bcp in",
  "OPENROWSET BULK", "load a file into a table fast", "SqlBulkCopy", "fast_executemany", or pastes
  the error "OPENROWSET is not allowed to read local files" (Msg 12713) or a load stuck on a
  LOG_RATE_GOVERNOR wait. Covers choosing between the Blob-only server-side paths and the
  client-side paths, and the log rate cap that throttles every one of them regardless of logging
  mode. Does not cover designing the target table (design-azure-sql-schema), establishing the
  connection itself (connect-from-python, connect-from-dotnet, connect-from-typescript-and-node),
  or a whole-database schema-and-data export or import through a DACPAC or BACPAC
  (sqlpackage-import-export).
---

# Load data fast: bcp, BULK INSERT, OPENROWSET, and the driver libraries

Picks the right bulk-load route for Azure SQL Database and explains why the two habits an agent
brings from SQL Server, a local file path and a minimal-logging tune-up, do not survive the move.
This is about moving rows into a table that already exists; it does not design that table.

Measured on 2026-08-29 against a live engine reporting `SERVERPROPERTY('EngineEdition')` 5 and
Edition `SQL Azure`, with `bcp` 18.6.0002.1 from `mssql-tools18`, and against Microsoft Learn's
"Resource Management - Azure SQL Database" page for the log rate governor. Full transcript,
including the exact error text and what was and was not reachable, is in
[references/verified-behaviour.md](references/verified-behaviour.md).

## The correction

Asked to load data fast, an agent reaches for `BULK INSERT ... FROM '/local/path.csv'` and, when
told the load is slow, reaches for `TABLOCK`, a `BULK_LOGGED` recovery model and a larger batch
size. Both habits are built for SQL Server and both are wrong here.

**The local path is refused before the file is touched.** `BULK INSERT` and `OPENROWSET(BULK ...)`
against a filesystem path both fail with:

```
Msg 12713, Level 16, State 1, Server SQL Azure, Line 1
OPENROWSET is not allowed to read local files. Path: '/tmp/data.csv'.
```

The message names `OPENROWSET` even for a `BULK INSERT` statement, because `BULK INSERT` is built
on the same `OPENROWSET(BULK ...)` machinery underneath, and the same message is what surfaces
whether the path exists or not. That last part was checked directly: a path that does not exist on
disk produces the identical message, so the refusal is not the engine trying and failing to open
the file, it is a platform rule evaluated first. **Bulk load on Azure SQL Database only reads from
Blob Storage.** A path has to be a Blob URL, or a name resolved through an `EXTERNAL DATA SOURCE`
pointed at Blob Storage, before it is legal at all.

**Minimal logging is not the bottleneck to chase.** Every load into Azure SQL Database, minimally
logged or not, is subject to the transaction log rate governor: a fixed per-service-tier cap on how
fast the engine will generate transaction log, tracked at the subsecond level and enforced
independent of how many data-file IOs the load could otherwise issue. It shows up as a
`LOG_RATE_GOVERNOR` wait (or `POOL_LOG_RATE_GOVERNOR` in an elastic pool). `TABLOCK` and
`BATCHSIZE` were confirmed to have no effect on the Msg 12713 refusal above; more generally,
neither one raises the log rate cap, because the cap is not a locking or batching problem.
Mitigating it means scaling to a higher service level or a different tier (Hyperscale publishes an
explicit per-database log rate), routing transient staging data through `tempdb`, or targeting a
table with a clustered columnstore index or data compression for analytic loads. See
[references/verified-behaviour.md](references/verified-behaviour.md) for the wait type table and
the source citation.

## Choose the route

1. **Data is already in Azure Blob Storage.** Use `BULK INSERT` or `OPENROWSET(BULK ...)` with a
   `DATA_SOURCE`, below. This is the only case where the server reads the file itself.
2. **Data lives on a machine that is not the server, and nothing is connected yet.** Use `bcp`. It
   streams over the bulk-copy protocol from the client, so the Blob-only rule does not apply, but
   see the caution on certificate trust below before promising it will "just work".
3. **Data is already inside a running application, in memory or streaming from another source.**
   Use the driver's own bulk API, `SqlBulkCopy`, `fast_executemany`, or the Node `mssql` package's
   `request.bulk()`, rather than shelling out to `bcp` or writing a file just to `BULK INSERT` it
   back. Connecting in the first place is a separate skill per language; see References.
4. **Whatever route is chosen, expect the log rate governor**, and do not promise a throughput
   number without checking the target service tier's log rate limit first.

## BULK INSERT and OPENROWSET(BULK ...) from Blob Storage

An ad hoc URL needs a matching credential, named after the container URL itself:

```sql
CREATE DATABASE SCOPED CREDENTIAL [https://your-storage-account.blob.core.windows.net/your-container]
  WITH IDENTITY = 'SHARED ACCESS SIGNATURE',
  SECRET = '<sas-token-without-leading-question-mark>';

BULK INSERT dbo.MyTable
  FROM 'https://your-storage-account.blob.core.windows.net/your-container/data.csv'
  WITH (DATA_SOURCE = NULL, FORMAT = 'CSV', FIRSTROW = 2);
```

An unmatched credential fails with `Msg 15151`, naming the URL as the credential it could not
find, which is the platform's way of saying "no credential object with this exact name exists",
not "access denied". A reusable `EXTERNAL DATA SOURCE` is the tidier form for repeated loads:

```sql
CREATE DATABASE SCOPED CREDENTIAL BlobCred
  WITH IDENTITY = 'SHARED ACCESS SIGNATURE',
  SECRET = '<sas-token-without-leading-question-mark>';

CREATE EXTERNAL DATA SOURCE MyBlob
  WITH (TYPE = BLOB_STORAGE, LOCATION = 'https://your-storage-account.blob.core.windows.net/your-container',
        CREDENTIAL = BlobCred);

BULK INSERT dbo.MyTable FROM 'data.csv'
  WITH (DATA_SOURCE = 'MyBlob', FORMAT = 'CSV', FIRSTROW = 2);
```

`OPENROWSET(BULK 'data.csv', DATA_SOURCE = 'MyBlob', ...)` takes the same `DATA_SOURCE`, and both
statements were confirmed to reach the network layer identically against an unreachable host,
which is why they are treated as one path here rather than two.

## bcp, from a client machine

```bash
bcp dbo.MyTable in data.csv -S your-server.database.windows.net -d MyDatabase \
  -G -c -t, -b 5000
```

`-G` asks for Entra ID authentication rather than a `-U`/`-P` login. Against the container used to
verify this skill, every flag that asked the client to trust the engine's certificate, `-u`,
`-Yo`, and an ODBC DSN carrying `TrustServerCertificate=yes`, exited 1 with **zero output**: no
SQLState, no message, nothing to act on. The flags that refused the certificate produced a real,
readable SSL or TCP error instead. Do not tell a user `bcp` "should just work" against a
self-signed or otherwise untrusted certificate without warning that the failure may be silent
rather than diagnosable; point them at their driver's certificate trust configuration first if `-G`
or `-U`/`-P` produces no output and no error at all.

## The client-library bulk APIs

`SqlBulkCopy` in .NET, `fast_executemany` in `pyodbc`, and `request.bulk()` in the Node `mssql`
package all stream rows over the client connection without a server-side `OPENROWSET` involved,
so Msg 12713 does not apply to them; they were never reading a server-side path. None of the three
was exercised against a live engine in this authoring session; their documented shape, and what to
watch for in each, is in
[references/driver-bulk-apis.md](references/driver-bulk-apis.md).

## Validation rules

- No `BULK INSERT` or `OPENROWSET(BULK ...)` in the answer names a local or UNC filesystem path.
- Every Blob-sourced load names a `DATA_SOURCE` (or an ad hoc URL) backed by a credential that
  actually exists, and the credential's name is checked against what the URL or data source form
  requires rather than assumed.
- No claim about load speed is made without naming the target service tier and its log rate limit.
- `TABLOCK` and `BATCHSIZE` are not offered as a fix for a local-path refusal.
- A `bcp` command aimed at an untrusted or self-signed certificate carries a warning that a silent,
  message-free failure is possible, not just a hypothetical one.
- Data already inside a running application is routed to that language's bulk API, not written to
  a file first so it can be `BULK INSERT`ed back in.

## Do not

- Do not write `BULK INSERT ... FROM '/local/path'` or an equivalent UNC path for Azure SQL
  Database. It fails with Msg 12713 before the file is opened, existing or not.
- Do not suggest `TABLOCK`, a larger `BATCHSIZE`, or switching recovery model as the fix for a slow
  load without first checking whether the wait is `LOG_RATE_GOVERNOR`. That wait is a per-tier cap,
  not a locking or batch-size problem.
- Do not promise `bcp` "will just work" once a certificate-trust flag is added. On the platform
  checked here, the trust flags failed with no output at all rather than a readable error.
- Do not treat Msg 15151 as a permissions error. It means no credential object exists with the name
  the URL or data source form is looking for, not that an existing one was denied.
- Do not write a file to disk from application code purely so it can be `BULK INSERT`ed back in.
  Use the language's own bulk-copy API on the connection that already exists.
- Do not restate the recovery model doctrine from SQL Server here. Whether changing recovery model
  helps on Azure SQL Database was not established either way in this skill; the log rate governor
  applies regardless of recovery model, which is the fact that actually matters for throughput.

## References

- [references/verified-behaviour.md](references/verified-behaviour.md): the exact error text for
  every server-side case tried, how the local-path refusal was proven to be platform behaviour
  rather than a missing-file error, the bcp certificate-trust finding, and the log rate governor
  wait types with their Microsoft Learn citation. Read this before quoting an error message.
- [references/driver-bulk-apis.md](references/driver-bulk-apis.md): the documented shape of
  `SqlBulkCopy`, `fast_executemany` and the Node `mssql` bulk API, marked as not verified live.
  Read this before writing bulk-copy code in application language.
- [BULK INSERT (Transact-SQL)](https://learn.microsoft.com/sql/t-sql/statements/bulk-insert-transact-sql):
  the full syntax and every `WITH` option. Fetch it rather than reciting option names from memory.
- [Resource Management - Azure SQL Database](https://learn.microsoft.com/azure/azure-sql/database/resource-limits-logical-server):
  the transaction log rate governance section, including the per-tier and Hyperscale log rate
  numbers. Read it before promising a load throughput number.
- `connect-from-python`, `connect-from-dotnet`, `connect-from-typescript-and-node`: how to get
  connected in each language, including Entra ID. This skill assumes that part is already done.
- `sqlpackage-import-export`: moving a whole database's schema and data through a DACPAC or
  BACPAC, a different job from loading rows into an existing table.
- `diagnose-resource-pressure`: what to check when a workload is broadly slow, beyond a single
  bulk load hitting the log rate governor.
