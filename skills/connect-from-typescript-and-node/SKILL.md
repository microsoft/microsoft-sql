---
name: connect-from-typescript-and-node
description: >-
  Connects a TypeScript or JavaScript application to Azure SQL Database with the mssql package over
  tedious: which packages to install, where the connection pool has to live, how to type query
  results, and how to authenticate with Microsoft Entra ID without a password. Use when a user says
  "connect my Node app to Azure SQL", "which npm package for SQL Server", "mssql pool size",
  "azure-active-directory-default", "@types/mssql", "sql.connect", "tedious", or reports that a
  Node API gets slower under load, opens a connection per request, or runs out of connections. Also
  use when wiring an Azure Function or an Express route to a database. Covers driver installation,
  the config object, pool lifetime and Entra ID for this stack only. Encryption doctrine, retry and
  transient-fault handling belong to connect-to-azure-sql; Python and .NET have their own skills.
license: MIT
---

# Connect from TypeScript and Node.js

The package is `mssql`, the pool belongs to the module and not to the request handler, and the
types come from a second package.

Verified on 2026-08-27 against `mssql` 12.7.0 and `tedious` 20.0.0, installed from the registry and
inspected in a running process.

This skill owns the Node-specific half: packages, the config object, pool lifetime, typed results
and Entra ID. It does not own encryption doctrine, retry and transient faults, or the first-connect
error on a paused database. Those are the same in every language and live in `connect-to-azure-sql`.

## The stack, and who owns what

| Package | What it is |
|---|---|
| `tedious` | The TDS protocol implementation. Microsoft names it the Node.js driver for SQL Server and contributes to it, but states it is community-supported software without Microsoft support |
| `mssql` | The wrapper almost every application actually uses: connection pooling, parameterised requests, transactions. It delegates the protocol to `tedious` |
| `@types/mssql` | The TypeScript definitions. `mssql` publishes **no** `types` field of its own |

Install for a TypeScript project:

```bash
npm install mssql
npm install --save-dev @types/mssql
```

`mssql` 12.7.0 declares `engines.node >= 18.19.0` and accepts `tedious` 19 or 20. `tedious` 20.0.0
declares `engines.node >= 22`, so a fresh install on Node 22 or later resolves to `tedious` 20 and
an install on Node 18 quietly stays on `tedious` 19. Pin the Node version in `package.json` and CI
rather than discovering the split later.

## The config object

```ts
import sql from 'mssql';

const config: sql.config = {
  server: process.env.AZURE_SQL_SERVER!,     // <server>.database.windows.net
  port: 1433,                                 // a number, never a string
  database: process.env.AZURE_SQL_DATABASE!,
  options: {
    encrypt: true,
    trustServerCertificate: false,
  },
  pool: { max: 10, min: 0, idleTimeoutMillis: 30000 },
};
```

Two things worth knowing rather than guessing:

- **`port` must be a number.** The config is not coerced, and a string port fails in a way that
  reads like a network problem.
- **`encrypt` defaults to `true` and `trustServerCertificate` to `false`.** Confirmed by resolving
  the config in a running process: `mssql` seeds both before handing the options to `tedious`, and
  `tedious` 20 carries the same defaults. Setting `options.encrypt` explicitly overrides the seed,
  which is why the wrong value is usually something a person typed rather than a default. The
  reasoning about when either may change is `connect-to-azure-sql`.

## The pool is a module-level object

This is the failure this skill exists for.

`sql.connect(config)` does not open a connection. It constructs a **process-wide `ConnectionPool`
the first time it is called** and returns that same pool on every later call. `sql.close()`
destroys it for the whole process.

```ts
// db.ts  ->  one pool, created once, awaited by everything else
import sql from 'mssql';
import { config } from './config.js';

export const poolPromise = new sql.ConnectionPool(config).connect();
```

```ts
// route or function handler
import { poolPromise } from './db.js';

const pool = await poolPromise;
const result = await pool.request()
  .input('id', sql.Int, id)
  .query('SELECT id, first_name FROM person WHERE id = @id');
```

What goes wrong when the pool moves into the handler:

- **A new `ConnectionPool` per invocation** pays a TCP connect, a TLS handshake and a login on
  every request, and each pool holds its own sockets. Under concurrency the process holds far more
  open connections than anyone intended.
- **`sql.close()` at the end of a handler** closes the shared pool, so requests already using it
  fail. If a handler must clean up, it closes nothing; the pool outlives the request.
- **In a serverless host**, module scope survives warm invocations and the handler body does not.
  Creating the pool at module scope is what makes reuse possible at all.

**The default `max` is 10**, with `min` 0 and `idleTimeoutMillis` 30000, verified in the pool
source rather than recalled. Ten is a floor for a toy and a ceiling for a real API, so set it
deliberately. How to choose the number, and why the binding limit is workers rather than sessions,
is `connect-to-azure-sql`.

## Microsoft Entra ID without a secret

`mssql` passes the `authentication` block straight through to `tedious`. The types `tedious` 20
accepts, read from the shipped definitions:

| `authentication.type` | Use it for |
|---|---|
| `azure-active-directory-default` | Local development and most Azure hosts. Walks the `@azure/identity` credential chain |
| `azure-active-directory-msi-app-service` | A managed identity on an app hosting platform |
| `azure-active-directory-msi-vm` | A managed identity on a virtual machine |
| `azure-active-directory-service-principal-secret` | A registered application with a client secret |
| `azure-active-directory-access-token` | A token the application acquired itself |
| `token-credential` | An `@azure/identity` credential object supplied directly |
| `azure-active-directory-password` | Nothing. Microsoft has deprecated this flow |

```ts
const config: sql.config = {
  server: process.env.AZURE_SQL_SERVER!,
  database: process.env.AZURE_SQL_DATABASE!,
  authentication: {
    type: 'azure-active-directory-default',
    // options.clientId only for a user-assigned managed identity
    options: { clientId: process.env.AZURE_CLIENT_ID },
  },
  options: { encrypt: true },
};
```

Notes that save a debugging session:

- `@azure/identity` arrives as a dependency of `tedious`; there is nothing extra to install.
- A passwordless config object holds no secret, so it is safe in source control. The SQL
  authentication variant is not, and belongs in configuration or a secret store.
- The identity still needs a database principal. Creating it is `entra-id-auth`.

## Typed results, honestly

```ts
interface Person { id: number; first_name: string; }

const result = await pool.request()
  .input('id', sql.Int, id)
  .query<Person>('SELECT id, first_name FROM person WHERE id = @id');

const rows: Person[] = result.recordset;   // one result set
const all = result.recordsets;             // every result set the batch returned
const changed = result.rowsAffected[0];
```

The generic on `query<T>()` is a **compile-time assertion, not runtime validation**. Nothing checks
that the columns match `Person`; a renamed column produces `undefined` at runtime while the types
still compile. If the shape matters, validate the rows or generate the types from the schema.

Use `request.input(name, type, value)` for every value. String concatenation into the SQL text is
how injection gets in, and the parameterised form is not harder to write.

## Validation rules

- Exactly one `ConnectionPool` is constructed per process, at module scope.
- No request handler, route or function body calls `sql.close()`.
- `pool.max` is set to a chosen number rather than inheriting the default of 10.
- `options.encrypt` is `true` and `trustServerCertificate` is absent or `false`.
- `port` is a number.
- Every user-supplied value reaches the database through `request.input`.
- A TypeScript project has `@types/mssql` in `devDependencies`.
- No password, token or server hostname is hard-coded; all of them come from configuration.

## Do not

- Do not call `sql.connect()` or construct a pool inside a request handler, route or serverless
  function body. That is the failure this skill exists to prevent.
- Do not call `sql.close()` anywhere except a deliberate process shutdown path.
- Do not set `trustServerCertificate: true` to make a certificate error go away. Read
  `connect-to-azure-sql` first.
- Do not use `azure-active-directory-password`. Microsoft has deprecated the flow it is built on.
- Do not expect `query<T>()` to validate anything at runtime.
- Do not assume `mssql` ships its own TypeScript types. It does not.
- Do not build SQL text by concatenating request input.
- Do not write retry loops here. Transient-fault handling is one policy for every language, in
  `connect-to-azure-sql`.

## References

- [Node.js driver for SQL Server](https://learn.microsoft.com/sql/connect/node-js/node-js-driver-for-sql-server):
  Microsoft's statement of what `tedious` is and what support it carries. Read it when someone asks
  which driver is official.
- [Connect and query with Node.js and mssql](https://learn.microsoft.com/azure/azure-sql/database/azure-sql-javascript-mssql-quickstart):
  the current first-party quickstart, including the passwordless configuration. Read it for a
  working end-to-end sample rather than copying one from here.
- [node-mssql documentation](https://tediousjs.github.io/node-mssql/): the config, pool and request
  API in full. Read it when a config key is in question.
- `connect-to-azure-sql`: encryption doctrine, retry and transient faults, pool sizing, and the
  first-connect error on a paused database.
- `connect-from-edge-runtimes`: when the target is a runtime without TCP sockets, where `mssql`
  does not run at all.
