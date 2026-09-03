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

# Load rows fast: BULK INSERT from Blob Storage, bcp, and the driver bulk APIs

Moves rows into a table that already exists, and kills the two habits carried over from SQL Server:
a local file path, and a minimal-logging tune-up. Designing that table is another job.

Engine behaviour measured 2026-08-29 against a container reporting `SERVERPROPERTY('EngineEdition')`
5 and `12.0.2000.8`, with `bcp` 18.6.0002.1 from `mssql-tools18`. Every option and flag below comes
from Microsoft Learn's `BULK INSERT`, `bcp utility`, `sys.dm_user_db_resource_governance` and
"Resource management in Azure SQL Database" pages, fetched 2026-09-03.

## The correction

**A local path is refused before the file is opened.** `BULK INSERT` and `OPENROWSET(BULK ...)`
both fail on a filesystem path with:

```
Msg 12713, Level 16, State 1, Server SQL Azure, Line 1
OPENROWSET is not allowed to read local files. Path: '/tmp/data.csv'.
```

The message names `OPENROWSET` even for a `BULK INSERT`, which is built on the same machinery. A
path that was never created produces the identical message, so this is a platform rule evaluated
first, not a failed open. Learn's platform table agrees: on Azure SQL Database the only data source
is Azure Storage, authenticated by Microsoft Entra ID, a SAS token or a managed identity. `*`
wildcards in the path and `FORMAT = 'PARQUET'` are not supported there either.

**Minimal logging is not there to tune.** Learn, same page: "Minimal logging isn't supported in
Azure SQL Database." What caps ingestion is the transaction log rate governor, a per-service-tier
limit on log record generation enforced at the subsecond level, "limiting throughput regardless of
how many IOs can be issued against data files". It surfaces as a `LOG_RATE_GOVERNOR` wait, or
`POOL_LOG_RATE_GOVERNOR` in an elastic pool. `TABLOCK` and `BATCHSIZE` do not raise that ceiling,
and were measured not to move the Msg 12713 refusal either. The documented mitigations are to scale
up or change tier, stage transient data in `tempdb`, or load into a clustered columnstore or
compressed table.

Before quoting an error number, a wait type or a throughput figure, open [references/bulk-load-errors-and-log-rate-governor.md](references/bulk-load-errors-and-log-rate-governor.md).

## Choose the route

| What you have | Route |
|---|---|
| A file already in Azure Blob Storage | `BULK INSERT` or `OPENROWSET(BULK ...)` with `DATA_SOURCE`. The only case where the server reads the file |
| A file on a client machine | `bcp`, which streams from the client, so the Blob-only rule never applies |
| Rows in a running application | that language's bulk API. Never write a file just to load it back |
| A whole database, not rows for one table | `sqlpackage`. Wrong route, right command |

## BULK INSERT from Blob Storage

Managed identity leaves no secret to leak. Grant the database's identity the **Storage Blob Data
Contributor** role on the container first:

```sql
CREATE DATABASE SCOPED CREDENTIAL BlobCred WITH IDENTITY = 'Managed Identity';

CREATE EXTERNAL DATA SOURCE MyBlob WITH (
    TYPE = BLOB_STORAGE,
    LOCATION = 'https://<storage-account>.blob.core.windows.net/<container>',
    CREDENTIAL = BlobCred);

BULK INSERT dbo.MyTable
FROM 'load/data.csv'
WITH (DATA_SOURCE = 'MyBlob', FORMAT = 'CSV', FIRSTROW = 2,
      FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a', MAXERRORS = 0,
      ERRORFILE = 'load/rejects', ERRORFILE_DATA_SOURCE = 'MyBlob');
```

For a shared access signature instead, the credential needs a database master key behind it, and
the rest of the statement is unchanged:

```sql
CREATE MASTER KEY ENCRYPTION BY PASSWORD = '<strong-password>';

CREATE DATABASE SCOPED CREDENTIAL BlobCred
WITH IDENTITY = 'SHARED ACCESS SIGNATURE', SECRET = '<sas-token>';
```

Five details decide whether it runs:

- The path in `FROM` is **relative** to `LOCATION`, not a second copy of it.
- `MAXERRORS` defaults to 10, so an unset load discards nine bad rows and still reports success.
- `ERRORFILE` needs `ERRORFILE_DATA_SOURCE` beside it here or the import can fail with a
  permissions error, and the named file must not already exist in the container.
- The SAS token carries no leading `?`, needs at least `srt=o&sp=r`, and all its dates are UTC.
- The caller needs `INSERT` and `ADMINISTER DATABASE BULK OPERATIONS`. `ADMINISTER BULK
  OPERATIONS`, without `DATABASE`, is the SQL Server spelling.

`FIRSTROW` is not a header skip: Learn says `BULK INSERT` does not support skipping headers, and
skipped rows are scanned for field terminators without being validated.

An ad hoc `https://` URL with no credential object of that name fails with `Msg 15151` naming the
whole URL, which means no such credential exists, not that one was denied.
`OPENROWSET(BULK 'load/data.csv', DATA_SOURCE = 'MyBlob', SINGLE_CLOB)` takes the same data source
and fails through the same layer, so the two count as one route.

## bcp, from a client machine

`bcp` ships inside the engine container image, not on the host, so run it there:

```bash
/opt/mssql-tools18/bin/bcp dbo.MyTable in data.csv \
  -S <server>.database.windows.net -d <database> -G \
  -c -t',' -r'\n' -F 2 -b 5000 -m 0 -e bcp-rejects.txt
```

`-G` is Microsoft Entra authentication, the supported route to Azure SQL Database; `-T` (Windows
integrated) is not supported against it. `-c` is character mode; `-t` and `-r` override the tab and
newline defaults; `-F 2` skips the header row that `BULK INSERT` cannot; `-b` makes each batch its
own committed transaction, so a failure late in the file keeps the batches already loaded; `-m 0`
tolerates no conversion error (also 10 by default); `-e` is the only way to see the rejected rows.
The `-h "TABLOCK"` hint is Windows only, so it does not exist in the container.

Certificate trust was measured on 2026-08-29 as failing **silently**: `-u`, `-Yo` and an ODBC DSN
carrying `TrustServerCertificate=yes` each exited 1 with zero bytes on stdout and stderr, while the
paths that refuse the certificate returned a readable SSL or TCP error. Never promise `bcp` will
"just work" once a trust flag is added.

## The client library bulk APIs

These stream rows over the bulk-copy protocol on the connection the application already holds, so
Msg 12713 cannot apply: none of them reads a path on the server.

.NET, `Microsoft.Data.SqlClient.SqlBulkCopy`:

```bash
dotnet add package Microsoft.Data.SqlClient
dotnet run
```

```csharp
using var bulk = new SqlBulkCopy(connection);
bulk.DestinationTableName = "dbo.MyTable";
bulk.BatchSize = 5000;          // 0, the default, is one transaction for the entire load
bulk.BulkCopyTimeout = 0;       // per batch, not per operation
bulk.EnableStreaming = true;
bulk.ColumnMappings.Add("csv_id", "Id");   // required whenever names or order differ
await bulk.WriteToServerAsync(reader);
```

Python, `pyodbc`. `fast_executemany` bundles every parameter set into one ODBC array and has **no
batch size**: the driver allocates one contiguous buffer for all remaining rows, so a million-row
list is a single allocation. Chunk it yourself.

```python
cursor.fast_executemany = True
statement = "INSERT INTO dbo.MyTable (Id, Name) VALUES (?, ?)"
for start in range(0, len(rows), 5000):
    cursor.executemany(statement, rows[start:start + 5000])
    cursor.commit()
```

Node.js, the `mssql` package. Every column has to state its nullability explicitly:

```javascript
const table = new sql.Table('dbo.MyTable');
table.create = false;
table.columns.add('Id', sql.Int, { nullable: false });
table.columns.add('Name', sql.VarChar(50), { nullable: true });
for (const r of rows) table.rows.add(r.id, r.name);
const rowCount = await new sql.Request().bulk(table);
```

None of the three was exercised live, so before tuning past the properties shown, open [references/driver-bulk-apis.md](references/driver-bulk-apis.md).

## Not a bulk load: a whole database

If every table's schema and rows are moving, rather than rows into one existing table, this is
`sqlpackage-import-export`, not a bulk load:

```bash
sqlpackage /Action:Import /SourceFile:app.bacpac \
  /TargetServerName:<server>.database.windows.net /TargetDatabaseName:<database> \
  /TargetUser:<user> /TargetPassword:"$SQLPACKAGE_PASSWORD"
```

## Check it worked

Exit code 0, or a "rows copied" line, says the client finished, not that the rows landed.

```bash
sqlcmd -S <server>.database.windows.net -d <database> -G \
  -Q "SELECT COUNT_BIG(*) AS loaded FROM dbo.MyTable;"
```

Expect the file's row count minus its header. Short means rows were rejected, not lost: they are in
the `ERRORFILE` or the `-e` file, and at the default of 10 the load still reports success.

Then find the ceiling it worked against, before promising a number next time. **This runs in the
cloud only:**

```sql
SELECT database_name, primary_max_log_rate / 1048576.0 AS max_log_MiB_per_sec
FROM sys.dm_user_db_resource_governance;

SELECT wait_type, waiting_tasks_count, wait_time_ms
FROM sys.dm_db_wait_stats
WHERE wait_type LIKE '%LOG_RATE_GOVERNOR%';
```

`primary_max_log_rate` is that tier's maximum log generation rate in bytes per second. A non-zero
`wait_time_ms` on `LOG_RATE_GOVERNOR` is the load being throttled by it, and the answer is a higher
service level or less log volume, not a bigger batch.

**On the local container the first query fails with `Msg 208`, invalid object name, and there is no
substitute.** Measured 2026-09-03: `sys.dm_user_db_resource_governance` and `sys.dm_db_resource_stats`
are both absent, and `sys.dm_internal_resource_governor_resource_pools` exists but returns zero rows.
The log rate governor is a service behaviour and it is not observable locally, so do not size a load
against a number the container gave you. The wait statistics query does run in both places.

## Do not

- Do not write a local or UNC path into either statement. Msg 12713, file or not.
- Do not offer `TABLOCK`, a bigger `BATCHSIZE` or a recovery model change for a slow load.
- Do not read Msg 15151 as a permissions error. No credential object of that name exists.
- Do not leave `MAXERRORS` or `-m` at 10 and call the load clean.
- Do not write application data out to a file so it can be loaded back in.

## References

- Before quoting Msg 12713, 15151 or 4861 or a wait type, open [references/bulk-load-errors-and-log-rate-governor.md](references/bulk-load-errors-and-log-rate-governor.md), which carries the exact text of each plus the platform limits table.
- [BULK INSERT (Transact-SQL)](https://learn.microsoft.com/sql/t-sql/statements/bulk-insert-transact-sql)
  and [bcp utility](https://learn.microsoft.com/sql/tools/bcp-utility): fetch before using an
  option or flag not shown here, because both say which platforms accept which.
- [Resource management in Azure SQL Database](https://learn.microsoft.com/azure/azure-sql/database/resource-limits-logical-server):
  the per-tier and Hyperscale log rate numbers, before promising a throughput.
- `connect-from-python`, `connect-from-dotnet`, `connect-from-typescript-and-node` for getting
  connected, which this skill assumes is done. `diagnose-resource-pressure` when a whole workload
  is slow rather than one load hitting the governor.
