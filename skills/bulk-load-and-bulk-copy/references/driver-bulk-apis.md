# The client library bulk paths: documented, not measured here

SKILL.md carries a runnable snippet for each of the three. This file is what those snippets leave
out. None of it was exercised against a live database in this authoring session: there was no .NET,
Python or Node.js runtime alongside the engine used for
[bulk-load-errors-and-log-rate-governor.md](bulk-load-errors-and-log-rate-governor.md). Treat every
signature here as documented shape, and fetch the linked page before writing code against it.

## Contents

- [.NET: SqlBulkCopy](#net-sqlbulkcopy)
- [Python: pyodbc fast_executemany](#python-pyodbc-fast_executemany)
- [Node.js: the mssql package](#nodejs-the-mssql-package)

## .NET: SqlBulkCopy

`Microsoft.Data.SqlClient.SqlBulkCopy` takes a `DataTable`, a `DbDataReader` or an `IDataReader`
and streams it to `DestinationTableName`. Beyond the properties in SKILL.md:

- The behaviour flags are constructor-time, not properties: `SqlBulkCopyOptions` is a bitwise enum
  with `KeepIdentity` (1), `CheckConstraints` (2), `TableLock` (4), `KeepNulls` (8),
  `FireTriggers` (16), `UseInternalTransaction` (32), `AllowEncryptedValueModifications` (64) and
  `CacheMetadata` (128). Defaults are the inverse of `BULK INSERT`'s in the same places:
  constraints are not checked, triggers do not fire, row locks rather than a table lock.
- `TableLock` is the `TABLOCK` equivalent and does nothing about the log rate governor either.
- `UseInternalTransaction` puts each batch in its own transaction, so an error rolls back the
  current batch and leaves the earlier ones committed. Without it, and without an ambient
  transaction, a single bulk copy is one non-transacted operation with nothing to roll back.
- Learn warns that mismatched source and destination types are converted per value, which "can
  affect performance, and also can result in unexpected errors". Match the types.
- `CacheMetadata` skips the metadata discovery query on repeat loads to the same table, and Learn
  warns it can corrupt data if the schema changes underneath it. Call `ClearCachedMetadata()` after
  a schema change or a `ChangeDatabase`.

Reference: [SqlBulkCopy Class](https://learn.microsoft.com/dotnet/api/microsoft.data.sqlclient.sqlbulkcopy)
and [SqlBulkCopyOptions Enum](https://learn.microsoft.com/dotnet/api/microsoft.data.sqlclient.sqlbulkcopyoptions).

## Python: pyodbc fast_executemany

`cursor.fast_executemany` is a cursor property, default `False`. pyodbc's own type stub describes
the two modes: false means `executemany()` "does nothing more than iterate over the provided list
of parameters and calls execute() on each set of parameters. This is typically slow"; true means
"the parameters are sent to the database in one bundle (with the SQL)".

The reason SKILL.md chunks the rows by hand is in the implementation, not in the docs. `ExecuteMulti`
allocates one contiguous buffer sized for every remaining row and sets the ODBC `PARAMSET_SIZE`
attribute to the full converted row count. There is no chunking, no per-row status tracking and no
configurable batch size, so the peak memory of a `fast_executemany` call scales with the whole list
handed to it, and a conversion failure part way through is reported against the batch rather than a
row.

This is a parameterised `INSERT` bundled efficiently, not the bulk-copy wire protocol that `bcp`
and `SqlBulkCopy` use. It is the fastest route pyodbc offers and it is still generating a log record
per row, so the log rate governor is the ceiling here as everywhere else.

Which driver to install and how to connect is `connect-from-python`.

Reference: [pyodbc, Cursor.fast_executemany](https://github.com/mkleehammer/pyodbc/wiki/Cursor#fast_executemany).

## Node.js: the mssql package

`request.bulk(table, [options], [callback])` takes a `sql.Table`, and returns a promise resolving to
the row count when no callback is passed. The package's README is explicit that when defining
columns it is critical to state whether each one is nullable, which is why SKILL.md's snippet passes
`{ nullable: ... }` on every column rather than only where it looks necessary.

`table.create = true` lets the module create the destination table if it does not exist, including
single and multi column primary keys. Leave it `false` when loading into a table someone else owns:
a typo in a column type then fails loudly instead of silently creating a second wrong table.

Values in `rows.add(...)` are positional, in the order the columns were declared, so a reordered
column list silently loads into the wrong columns. Type mismatches surface as a conversion error
from the driver rather than from the engine, which is why the message will not look like a SQL
error. Connecting in the first place, including Entra ID, is `connect-from-typescript-and-node`.

Reference: [node-mssql, Bulk load](https://github.com/tediousjs/node-mssql#bulk-load).
