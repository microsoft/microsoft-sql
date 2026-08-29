# The client-library bulk paths: not verified against a live engine

None of the API behaviour on this page was exercised against a live database in this authoring
session: there was no .NET, Python or Node.js runtime available alongside the engine used to
verify the server-side paths in
[verified-behaviour.md](verified-behaviour.md). What follows is the documented shape of each API,
included so the skill can route to the right one, not asserted as measured. Fetch each linked page
before writing code against it, because signatures and defaults are exactly the kind of thing that
drifts between versions.

## Why these exist alongside BULK INSERT and bcp

All three server-side paths above (`BULK INSERT`, `OPENROWSET(BULK ...)`, `bcp`) either require
the data to already be sitting in Blob Storage or require a separate command-line tool. When the
data is already inside a running application, in memory or streaming from another source, the
client-library bulk APIs avoid writing a file at all: they open one connection and stream rows over
the same bulk-copy wire protocol `bcp` uses, without a server-side `OPENROWSET` in the picture at
all. That also means the Msg 12713 local-path refusal does not apply to them; they were never
reading a server-side path to begin with.

## .NET: SqlBulkCopy

`Microsoft.Data.SqlClient.SqlBulkCopy` takes a `DataTable`, a `DataReader` or an
`IDataReader` and streams it to a destination table. The properties that matter most in practice:

- `BatchSize`: rows per network round trip. Left at its default (0, meaning one batch for the
  whole operation) it holds a single transaction open for the entire load.
- `BulkCopyTimeout`: per-batch, not per-operation; a large unbatched load needs this raised.
- `ColumnMappings`: required whenever the source and destination column order or names differ;
  without it, a silent column-order mismatch inserts values into the wrong columns rather than
  raising an error.
- `EnableStreaming`: true lets it stream from a `DataReader` without materialising the whole source
  in memory first, which matters for anything larger than fits comfortably in memory.

Reference: [SqlBulkCopy Class](https://learn.microsoft.com/dotnet/api/microsoft.data.sqlclient.sqlbulkcopy).

## Python: cursor.executemany, mssql-python's bulk path, and pyodbc's fast_executemany

Plain `cursor.executemany()` sends one round trip per row unless the driver batches it, which makes
it the slowest of the options here for anything beyond a few hundred rows. Two faster options:

- `pyodbc` exposes `cursor.fast_executemany = True`, which rewrites the same `executemany` call to
  batch parameters into fewer round trips. It changes an existing `executemany` call site into a
  bulk one without changing its shape, at the cost of some type-inference edge cases the project's
  own documentation calls out.
- Driver and ORM-level bulk helpers (bulk insert support in `mssql-python`, or an ORM's own bulk
  insert method) exist and change across releases; check the driver in use rather than assuming a
  method name.

Which driver to install and how to connect is `connect-from-python`; this reference is only about
moving rows quickly once connected.

Reference: [pyodbc, Cursor.fast_executemany](https://github.com/mkleehammer/pyodbc/wiki/Cursor#fast_executemany).

## Node.js: mssql (tedious) bulk

The `mssql` package (built on `tedious`) exposes a `Table` object and a `request.bulk()` call that
streams rows over the same bulk-copy protocol as the other client paths, rather than issuing one
`INSERT` per row:

```javascript
const table = new sql.Table('dbo.t1');
table.create = false;
table.columns.add('id', sql.Int);
table.columns.add('name', sql.VarChar(50));
table.rows.add(1, 'alpha');

const request = new sql.Request();
await request.bulk(table);
```

The table's column definitions have to match the destination table's types closely enough for the
driver's own type coercion, and a mismatch surfaces as a conversion error from the driver rather
than from the server. Connecting from Node in the first place, including Entra ID, is
`connect-from-typescript-and-node`.

Reference: [node-mssql, Bulk load](https://github.com/tediousjs/node-mssql#bulk-load).
