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
---

# Connect from TypeScript and Node.js

The package is `mssql`, the pool belongs to the module and not the request handler, and the types
come from a second package.

Verified on 2026-09-03 against `mssql` 12.7.0, `tedious` 20.0.0 and `@types/mssql` 12.3.0 on
Node 24.15.0, resolved in a running process.

## The stack

| Package | What it is |
|---|---|
| `tedious` | The TDS protocol implementation. Microsoft names it the Node.js driver for SQL Server and contributes to it, but states it is community-supported with no Microsoft support |
| `mssql` | The wrapper almost every application uses: pooling, parameterised requests and transactions, over `tedious` |
| `@types/mssql` | The TypeScript definitions. `mssql` publishes **no** `types` field of its own |

```bash
npm install mssql
npm install --save-dev @types/mssql
```

`mssql` 12.7.0 accepts `tedious` `^19.2.2 || ^20.0.0` and declares `engines.node >= 18.19.0`;
`tedious` 20.0.0 declares `engines.node >= 22`. Node 22 or later resolves to `tedious` 20;
Node 18 quietly stays on 19. Pin the Node version in `package.json` and CI.

## The config object

```ts
import sql from 'mssql';

export const config: sql.config = {
  server: process.env.AZURE_SQL_SERVER!,     // <server>.database.windows.net
  port: 1433,                                // a number, never a string
  database: process.env.AZURE_SQL_DATABASE!,
  options: { encrypt: true, trustServerCertificate: false },
  pool: { max: 10, min: 0, idleTimeoutMillis: 30000 },
};
```

- **`port` must be a number.** The config is not coerced, and a string port fails in a way that
  reads like a network fault.
- **At these versions both packages default `encrypt` to `true` and `trustServerCertificate` to
  `false`.** `mssql` seeds the pair before handing `options` to `tedious`, and `tedious` 20 resolves
  the same two on its own, so a pool built with an empty `options` still resolves to that pair.
  Earlier majors disagreed, so pin the versions rather than trust the default. At these versions a
  wrong value is something a person typed. When either may legitimately change is `connect-to-azure-sql`.
- **The `pool` values above are the defaults.** Ten is a floor for a toy and a ceiling for a real
  API, so set `max` deliberately. Choosing the number, and why the binding limit is workers rather
  than sessions, is `connect-to-azure-sql`.

## The pool is a module-level object

This is the failure this skill exists for.

`sql.connect(config)` does not open a connection. It constructs a **process-wide `ConnectionPool`
the first time it is called** and returns that same pool on every later call.

```ts
// db.ts: one pool, created once, awaited by everything else
import sql from 'mssql';
import { config } from './config.js';

export const poolPromise = new sql.ConnectionPool(config).connect();
```

Every handler does `const pool = await poolPromise;` and nothing more.

What goes wrong when the pool moves into the handler:

- **A new `ConnectionPool` per invocation** pays a TCP connect, a TLS handshake and a login every
  request, and each pool holds its own sockets, so the process ends far over its intended count.
- **`sql.close()` at the end of a handler** destroys the global pool under requests still using it,
  and against a `new sql.ConnectionPool` it closes only the pool `sql.connect()` built, returns
  `null` and leaves the sockets open. Use `pool.close()`, on a shutdown path and nowhere else.
- **In a serverless host**, module scope survives warm invocations and the handler body does not,
  which is what makes reuse possible.

## Microsoft Entra ID without a secret

`mssql` passes `authentication` straight through to `tedious`. The types `tedious` 20 accepts, from
the shipped `connection.d.ts`:

| `authentication.type` | Use it for |
|---|---|
| `azure-active-directory-default` | Local development and most Azure hosts. Walks the `@azure/identity` chain |
| `azure-active-directory-msi-app-service`, `azure-active-directory-msi-vm` | A managed identity |
| `azure-active-directory-service-principal-secret` | An app registration and client secret |
| `azure-active-directory-access-token` | A token the app acquired itself |
| `token-credential` | An `@azure/identity` credential supplied directly |
| `azure-active-directory-password` | Nothing. Microsoft has deprecated this flow |

```ts
export const entraConfig: sql.config = {
  server: process.env.AZURE_SQL_SERVER!,
  database: process.env.AZURE_SQL_DATABASE!,
  options: { encrypt: true, trustServerCertificate: false },
  authentication: {
    type: 'azure-active-directory-default',
    options: { clientId: process.env.AZURE_CLIENT_ID },  // user-assigned identity only
  },
};
```

`@azure/identity` is a dependency of `tedious`, so there is nothing extra to install. This config
holds no secret and is safe in source control; the SQL authentication variant is not. The identity
still needs a database principal, which is `entra-id-auth`.

## Typed results

```ts
interface Person { id: number; first_name: string; }

const result = await pool.request()
  .input('id', sql.Int, id)
  .query<Person>('SELECT id, first_name FROM person WHERE id = @id');

const rows: Person[] = result.recordset;   // recordsets for every set, rowsAffected[0] for counts
```

The generic on `query<T>()` is a **compile-time assertion, not runtime validation**. Nothing checks
the columns against `Person`; a renamed column yields `undefined` at run time while the types
compile. If the shape matters, validate the rows or generate the types from the schema.

Use `request.input(name, type, value)` for every value; concatenating into the SQL text is how
injection gets in.

## Check it worked

Ask through `mssql` itself: what a command line client proves about encryption is true of its own
session, not of the pool your process opened. Save this beside `db.ts` as `check-connection.mjs`.

```js
import { poolPromise } from './db.js';

const pool = await poolPromise;
const { recordset: [r] } = await pool.request().query(`
  SELECT c.encrypt_option, DB_NAME() AS db,
         SUSER_NAME() AS login, USER_NAME() AS db_user
  FROM sys.dm_exec_connections AS c WHERE c.session_id = @@SPID`);
console.log(r, 'pool:', pool.size, pool.available, pool.borrowed);
await pool.close();
```

```bash
node check-connection.mjs
```

| Read | Expect | A wrong value means |
|---|---|---|
| `encrypt_option` | `TRUE` | the session is in clear text; someone overrode `options.encrypt` |
| `db` | your database, never `master` | `database` is missing from the config |
| `login`, `db_user` | the principal you granted rights to | the credential chain picked another one |
| `pool.size` | at most `pool.max`, and flat as requests arrive | a pool per handler, the failure above |

Two things this check trips over, measured 2026-09-03:

- **`pool.size` throws before the pool is awaited**, `TypeError: Cannot read properties of
  undefined (reading 'numFree')`, while `@types/mssql` declares it `readonly size: number`. Read it
  after the await or the check dies on its own instrumentation.
- A wrong host or port stops the script first, as `ConnectionError: Failed to connect to
  <host>:<port>`.

`sys.dm_exec_connections` needs `VIEW DATABASE STATE`, and on Basic, S0, S1 and elastic pools the
server administrator, the Microsoft Entra administrator or `##MS_ServerStateReader##`. Grant it for
the check, then revoke it. `CONNECTIONPROPERTY` is no substitute: its documented property list has no
`encrypt_option`.

## Do not

- Do not call `sql.connect()` or construct a pool inside a request handler, route or serverless
  function body.
- Do not call `pool.close()` outside a deliberate shutdown path.
- Do not set `trustServerCertificate: true` to clear a certificate error. Read
  `connect-to-azure-sql`.
- Do not use `azure-active-directory-password`. Microsoft has deprecated the flow it uses.
- Do not write retry loops here. Transient faults are one policy for every language, in
  `connect-to-azure-sql`.

## References

- [Node.js driver for SQL Server](https://learn.microsoft.com/sql/connect/node-js/node-js-driver-for-sql-server):
  what `tedious` is and what support it carries. Read it when asked which driver is official.
- [Connect and query with Node.js and mssql](https://learn.microsoft.com/azure/azure-sql/database/azure-sql-javascript-mssql-quickstart):
  the first-party quickstart, passwordless configuration included. Read it for a working end-to-end
  sample.
- [node-mssql documentation](https://tediousjs.github.io/node-mssql/): the config, pool and request
  API in full. Read it when a config key is in question.
- [sys.dm_exec_connections](https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-views/sys-dm-exec-connections-transact-sql):
  the columns and the permission the check needs. Read it when the check returns no row.
- `connect-to-azure-sql`: encryption doctrine, retry and transient faults, pool sizing, and the
  first-connect error on a paused database.
- `connect-from-edge-runtimes`: for a runtime without TCP sockets, where `mssql` does not run.
