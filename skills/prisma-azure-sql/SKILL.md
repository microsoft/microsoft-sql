---
name: prisma-azure-sql
description: >-
  Uses Prisma ORM against Azure SQL Database on JavaScript and TypeScript, inside the connector's
  real limits: no Json type, no enums, no scalar lists, a default string length that quietly breaks
  keys, a connection URL that moved out of the schema file in Prisma 7, and a migration workflow that
  succeeds locally and is refused in the cloud. Use when a user says "Prisma with Azure SQL",
  "prisma migrate dev", "prisma db push", "schema.prisma", "prisma.config.ts", "driver adapter", or
  pastes "P3020", "the automatic creation of shadow databases is disabled", "the current connector
  does not support the Json type", or "the datasource property url is no longer supported". Also use
  when Prisma migrations work locally and fail against Azure. Covers the schema, type mapping,
  migrations and identity for Prisma only. Driver and pool ownership sit with
  connect-from-typescript-and-node, retry with connect-to-azure-sql; EF Core, SQLAlchemy and Django
  have their own skills.
---

# Prisma on Azure SQL Database

Prisma's Azure SQL Database support is real, narrower than its PostgreSQL support, and it moved in
Prisma 7. A schema written from PostgreSQL habits fails validation; a migration workflow proved
against a local database is refused in the cloud.

Verified on 2026-08-27 against Prisma 7.9.1 and `@prisma/adapter-mssql` 7.9.1 installed from the
package index, the shipped schema engine, and a live Azure SQL engine reporting `EngineEdition` 5.

## The naming rule, first

The datasource provider is the literal string `sqlserver`:

```prisma
datasource db {
  provider = "sqlserver"
}
```

**That string is a connector identifier, not the name of the product.** Everywhere else, in prose, in
comments, in file names and in anything written back to the user, the product is **Azure SQL
Database**. An agent that reads the provider and starts calling the database something else has
begun giving advice about a different product with different limits.

## Pin the version, and do not reach for the newest

The connector is a **Prisma 7** feature. The next major is in release candidate and its supported
databases are PostgreSQL and MongoDB; **Azure SQL Database is not among them**. So the usual habit is
actively wrong here:

- Install a pinned 7 release. `npm install prisma @prisma/client` without a version can resolve to a
  prerelease of the next major, which has no connector for this database at all.
- Keep `prisma` and `@prisma/client` on the same version.

## What Prisma 7 changed, before anything else

Three structural changes catch every agent working from older examples. All three were reproduced.

**1. The connection URL left the schema file.** A `url` inside the `datasource` block now fails
validation:

```
Error code: P1012
The datasource property `url` is no longer supported in schema files.
```

It lives in `prisma.config.ts` instead, together with the shadow database URL:

```ts
import { defineConfig, env } from 'prisma/config'

export default defineConfig({
  schema: 'prisma/schema.prisma',
  datasource: {
    url: env('DATABASE_URL'),
    shadowDatabaseUrl: env('SHADOW_DATABASE_URL'),
  },
})
```

**2. That file does not load a `.env` for you.** With a `.env` present and holding the variable, the
configuration still failed with `Cannot resolve environment variable: DATABASE_URL` until the value
was exported into the process. Load it explicitly, or supply the variables the way the runtime
already does.

**3. The client needs a driver adapter.** Install `@prisma/adapter-mssql` and construct the client
with it. The adapter wraps the same Node driver package that `connect-from-typescript-and-node`
owns, and it accepts either that driver's configuration object or a connector-style connection
string.

The command surface moved too. `migrate dev` no longer takes a skip-generate flag, and
`migrate diff` takes `--to-schema` where older examples pass a datamodel flag that no longer exists.
Read the command's own help before copying an invocation out of a tutorial.

## What the connector will not accept

Reproduced with `prisma validate` on 7.9.1. These are validation errors, not runtime surprises, so
they cost a round trip rather than a production incident, but an agent that writes them wastes the
turn:

| Written | Result |
|---|---|
| `payload Json` | `Field ... can't be of type Json. The current connector does not support the Json type.` |
| `enum Status { ... }` | `You defined the enum ... But the current connector does not support enums.` |
| `tags String[]` | `Field ... can't be a list. The current connector does not support lists of primitive types.` |

What to write instead:

- **JSON**: a string column, with the shape enforced in application code. The database has its own
  JSON handling, and reaching it means a raw query rather than a Prisma type.
- **Enums**: a lookup table with a relation, or a plain string with the values constrained in code.
  A lookup table is the one that survives contact with reporting.
- **Scalar lists**: a child table. There is no array type here.

## The default string length, and the failure it defers

`String` with no native type maps to a 1000 character Unicode column. That is **2000 bytes**, and the
index key limits are **1700 bytes** for a nonclustered index and **900 bytes** for a clustered one.

The dangerous part is that nothing fails at migration time. Running the exact table Prisma generates
for `email String @unique` against a live database produced only:

```
Warning! The maximum key length for a nonclustered index is 1700 bytes.
The index 'Account_email_key' has maximum length of 2000 bytes.
For some combination of large values, the insert/update operation will fail.
```

The migration reports success. Short values insert fine. Then a genuinely long value arrives:

```
Msg 1946, Level 16, State 3
Operation failed. The index entry of length 1800 bytes for the index 'Account_email_key'
exceeds the maximum length of 1700 bytes for nonclustered indexes.
```

`String @id` is worse, because it produces a clustered primary key against the 900 byte limit, again
with a warning only.

**So give every string that carries a key, a unique constraint or a foreign key an explicit length.**

```prisma
model Account {
  id    String @id @db.NVarChar(64)
  email String @unique @db.NVarChar(320)
  bio   String? @db.NVarChar(Max)
}
```

450 characters is the largest value that is safe in every index position. Anything not participating
in an index can be longer, and text with no length ceiling should be an unbounded Unicode column
rather than a large default.

One more difference from PostgreSQL habits, in the same area: a **nullable unique column accepts only
one null row**. A second one fails, live-verified:

```
Msg 2627, Level 14, State 1
Violation of UNIQUE KEY constraint 'NullTest_code_key'. Cannot insert duplicate key ...
The duplicate key value is (<NULL>).
```

A model with several optional unique fields is a design that works on other engines and does not work
here. Sizing, collation and key design in general are `design-azure-sql-schema`.

## Migrations, and the one that will not run in the cloud

`prisma migrate dev` needs a **shadow database**: a second temporary database it creates, replays the
migration history into, inspects and drops, so it can detect drift. `prisma migrate deploy` does not
use one.

Against Azure SQL Database, Prisma does not merely fail to create it. **It refuses to try.** The
schema engine decides it is talking to Azure SQL Database when the host name contains the Azure SQL
Database domain suffix, and returns a dedicated error before issuing any statement:

```
P3020
The automatic creation of shadow databases is disabled on Azure SQL.
Please set up a shadow database using the `shadowDatabaseUrl` datasource attribute.
```

Three things follow, and each one is a place agents get it wrong.

1. **A local success proves nothing, and this is not a permission problem.** Against the local Azure
   SQL Database container the host name is not the cloud suffix, so the check does not fire, the
   shadow database is created and dropped, and `prisma migrate dev` simply works. Reaching the same
   database, with the same administrative login and the same schema, through a host name that ends in
   the cloud suffix returns P3020 instead. Both halves were run. The login was never the variable, so
   granting it more rights fixes nothing, and the first cloud run is where the developer finds out,
   usually in a pipeline.
2. **The error tells you to edit a place that no longer exists.** It says "datasource attribute",
   which was the Prisma 6 location. In Prisma 7 `shadowDatabaseUrl` goes in the configuration file,
   beside `url`.
3. **The fix is a second database, not a permission grant.** Provision another database on the same
   logical server, point `SHADOW_DATABASE_URL` at it, and never point it at the database that holds
   your data. Creating a database here means connecting to the administrative database as the server
   administrator, the Entra administrator for the logical server, or a member of the database manager
   role, which an application login is not; provisioning is `provision-azure-sql-db`.

The workflow that follows from that:

| Situation | Command | Shadow database |
|---|---|---|
| Iterating locally against the container | `prisma migrate dev` | Created and dropped for you |
| Iterating against a cloud database | `prisma migrate dev` | You provide it, once |
| Prototyping with no migration history | `prisma db push` | Not used |
| Deploying | `prisma migrate deploy` | Not used |

Never run `migrate dev` against a database holding real data: it is the command that resets. Whether
a given change is safe to apply to a live database at all is `schema-migrations-safely`.

## Getting an identity to the client

The adapter supports Microsoft Entra ID, and the Prisma documentation does not mention it, so an
agent working from the docs alone will conclude it is impossible. Verified in the installed package:
the connection string accepts `authentication=DefaultAzureCredential`,
`authentication=ActiveDirectoryManagedIdentity` with an optional client id, and
`authentication=ActiveDirectoryServicePrincipal`; the configuration object form is
`authentication: { type: 'azure-active-directory-default' }`.

Two limits on that:

- **The command line is a separate path.** Migrations and introspection connect through the URL in
  the configuration file, and the documented arguments for that URL are a user and a password. Plan
  for migrations to run under a login even where the application itself is passwordless.
- **An identity still needs a database principal** before any of this connects. Creating it, and
  diagnosing it when it fails, is `entra-id-auth`.

## Validation rules

- The Prisma packages are pinned to a 7 release, and both are on the same version.
- The schema declares no `Json` field, no `enum` block and no scalar list.
- Every string that carries a key, a unique constraint or a foreign key has an explicit length of 450
  characters or fewer.
- Optional unique columns are justified, given that only one null row is allowed.
- The connection URL is in the configuration file, and the environment variables it reads are loaded
  by something explicit.
- Any `migrate dev` aimed at a cloud database has a `shadowDatabaseUrl` pointing at a different,
  already provisioned database.
- Deployment runs `migrate deploy`.
- No credential appears in the schema, the configuration file or the client construction.

## Do not

- Do not install the newest Prisma. The connector for this database does not exist in the next major.
- Do not put `url` in the `datasource` block. It fails validation in Prisma 7.
- Do not assume the configuration file picked up a `.env`. It did not.
- Do not reach for `Json`, an `enum` or a scalar list and then work around the validation error with a
  raw query. Model it as a column or a table.
- Do not leave `String` unsized on a column that will be indexed. The migration passes and the insert
  is what fails, much later.
- Do not read a green local migration as evidence that the cloud will accept it.
- Do not answer P3020 by granting the application login permission to create databases. Provision a
  shadow database instead.
- Do not point `shadowDatabaseUrl` at the database that holds your data.
- Do not run `migrate dev` against a database with real data in it.
- Do not set the option that skips certificate validation against a cloud database. Encryption
  doctrine is `connect-to-azure-sql`.
- Do not write a retry loop here. Transient-fault policy is one policy for every stack.
- Do not call the product by the provider name.

## References

- [Prisma SQL Server connector](https://www.prisma.io/docs/orm/overview/databases/sql-server): the
  type mapping table, the connection URL arguments and their defaults, and the connector's stated
  considerations. Fetch it before asserting what the connector supports.
- [Shadow database](https://www.prisma.io/docs/orm/prisma-migrate/understanding-prisma-migrate/shadow-database):
  what `migrate dev` does with it, and the cloud-hosted setup. Read it before configuring one.
- [Prisma error reference](https://www.prisma.io/docs/orm/reference/error-reference): the definitive
  text for P3020 and the neighbouring migration errors. Read it when an error code appears.
- [CREATE INDEX](https://learn.microsoft.com/sql/t-sql/statements/create-index-transact-sql): the
  engine's own statement of the 900 and 1700 byte key limits and what happens when data exceeds them.
- [CREATE DATABASE for Azure SQL Database](https://learn.microsoft.com/sql/t-sql/statements/create-database-transact-sql?view=azuresqldb-current):
  which principals may create a database, which is what the shadow database question really turns on.
- `connect-from-typescript-and-node`: the Node driver the adapter wraps, pooling, and typed results.
- `connect-to-azure-sql`: encryption doctrine, retry and transient faults, and pool sizing.
- `design-azure-sql-schema`: key length, sizing, collation and the implicit conversion trap.
- `schema-migrations-safely`: the tool-neutral migration doctrine Prisma Migrate inherits.

