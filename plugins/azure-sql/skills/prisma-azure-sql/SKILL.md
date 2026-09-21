---
name: prisma-azure-sql
description: >-
  Uses Prisma ORM against Azure SQL Database on JavaScript and TypeScript, inside the connector's
  real limits: no Json type, no enums, no scalar lists, a default string length that quietly
  breaks keys, a connection URL that moved out of the schema file in Prisma 7, and a migration
  workflow that succeeds locally and is refused in the cloud. Use when a user says "Prisma with
  Azure SQL", "prisma migrate dev", "prisma db push", "schema.prisma", "prisma.config.ts",
  "driver adapter", or pastes "P3020", "the automatic creation of shadow databases is disabled",
  "the current connector does not support the Json type", or "the datasource property url is no
  longer supported". Also use when Prisma migrations work locally and fail against Azure. Covers
  schema, type mapping, migrations and identity for Prisma only. Drivers and pooling are
  connect-from-typescript-and-node, retry connect-to-azure-sql.
---

# Prisma on Azure SQL Database

Prisma's support for this database is real, narrower than its PostgreSQL support, and it moved in
Prisma 7. A schema written from PostgreSQL habits fails validation, and a migration workflow proved
against a local database is refused in the cloud.

Measured on 2026-09-03 against `prisma` 7.9.1 and 7.10.0, `@prisma/adapter-mssql` 7.9.1 and `prisma`
8.0.0-rc.12, all installed from the package index. The P3020 result below was measured on 2026-08-27
against an Azure SQL Database engine reporting `EngineEdition` 5.

The datasource provider is the literal string `sqlserver`. **That is a connector identifier, not the
name of the product**, whose limits are not SQL Server's: everywhere else it is Azure SQL Database.

## Pin the version, because the newest has no connector at all

```bash
npm view prisma dist-tags          # latest: 8.0.0-rc.12   prev: 7.10.0
npm install prisma@7 @prisma/client@7 @prisma/adapter-mssql@7
```

`latest` is a release candidate for the next major, so a bare `npm install prisma` installs it. The
string `sqlserver` appears nowhere in that package, only `postgresql`, and its command surface is a
different product: no `validate`, no `db push`, no `migrate`, and `migrate diff` replaced by a
`migration` group. Pin to 7 and keep `prisma` and `@prisma/client` equal.

## The connection URL is JDBC style, not a URI

Every other Prisma connector takes a URI. This one does not:

```bash
# rejected: P1013, "Conversion error: invalid digit found in string in database URL"
sqlserver://user:password@<server-name>.database.windows.net:1433/appdb

# accepted
sqlserver://<server-name>.database.windows.net:1433;database=appdb;user=app;password=<secret>;encrypt=true
```

The error blames a digit and never mentions the shape, so it reads as a typo. An ADO.NET style
`Server=...;Database=...` string is rejected too, with `must start with the protocol sqlserver://`.

## Prisma 7 moved the URL out of the schema file

A `url` inside the `datasource` block now fails `prisma validate` with `P1012`, pointing at the line:

```
The datasource property `url` is no longer supported in schema files.
```

The rest of that message sends the URL to `prisma.config.ts` and the adapter to the client:

```ts
// prisma.config.ts
import 'dotenv/config'                                  // nothing else loads .env
import { defineConfig, env } from 'prisma/config'

export default defineConfig({
  schema: 'prisma/schema.prisma',
  datasource: {
    url: env('DATABASE_URL'),
    shadowDatabaseUrl: env('SHADOW_DATABASE_URL'),
  },
})
```

`env()` is strict and fails the whole command, including `prisma validate`, which needs no database:
`PrismaConfigEnvError: Cannot resolve environment variable: DATABASE_URL`. The `dotenv/config` import
is what stops that; the configuration file loads no `.env` on its own.

The client needs a driver adapter as well. `@prisma/adapter-mssql` wraps `mssql` ^12.2.0, the Node
driver `connect-from-typescript-and-node` owns.

## What the connector refuses, before any database is involved

```bash
./node_modules/.bin/prisma validate
```

Three field kinds are rejected outright, all three reproduced on 7.9.1:

```
error: Field `payload` in model `Thing` can't be of type Json. The current connector does not support the Json type.
error: Field "tags" in model "Thing" can't be a list. The current connector does not support lists of primitive types.
error: Error validating: You defined the enum `Status`. But the current connector does not support enums.
```

Instead: **JSON** is a string column with the shape enforced in application code, since the
database's own JSON handling needs a raw query; an **enum** is a lookup table with a relation, the
form that survives contact with reporting; a **scalar list** is a child table.

## The default string length, and the failure it defers

Read the DDL Prisma will emit before it runs. This needs a parseable URL and opens no connection:

```bash
./node_modules/.bin/prisma migrate diff --from-empty --to-schema=prisma/schema.prisma --script
```

For `id String @id` and `email String @unique` with no native type, that prints:

```sql
CREATE TABLE [Account]
(
[id] NVARCHAR(1000) NOT NULL,
[email] NVARCHAR(1000) NOT NULL,
CONSTRAINT [Account_pkey] PRIMARY KEY CLUSTERED ([id]),
CONSTRAINT [Account_email_key] UNIQUE NONCLUSTERED ([email])
);
```

1000 Unicode characters is **2000 bytes**, against index key limits of **1700 bytes** nonclustered
and **900 bytes** clustered. Nothing fails at migration time. The engine emits `Msg 1945` at
**severity 10**, which succeeds:

```
Warning! The maximum key length for a nonclustered index is 1700 bytes.
The index 'Account_email_key' has maximum length of 2000 bytes.
For some combination of large values, the insert/update operation will fail.
```

Severity 10 sets no non-zero exit, so `sqlcmd -b` alone reports a clean migration and the pipeline
goes green. Without `-m-1` the message prints no `Msg` number at all, and on go-sqlcmd it prints no
number with `-m-1` either, which the check section below explains. The bill arrives later, on a
genuinely long value:

```
Msg 1946, Level 16, State 3
Operation failed. The index entry of length 1800 bytes for the index 'Account_email_key'
exceeds the maximum length of 1700 bytes for nonclustered indexes.
```

`String @id` is worse: a clustered primary key against the 900 byte limit, again with a warning only.
**So size every string that carries a key, a unique constraint or a foreign key.**

```prisma
model Account {
  id    String  @id @db.NVarChar(64)
  email String  @unique @db.NVarChar(320)
  bio   String? @db.NVarChar(Max)
}
```

Re-running the diff emits `NVARCHAR(64)`, `NVARCHAR(320)` and `NVARCHAR(max)`. 450 characters is the
widest value safe in every index position; anything outside an index can be longer, and unbounded
text belongs in `NVarChar(Max)` rather than a large fixed default.

One more PostgreSQL habit, same area: a **nullable unique column accepts one null row only**. The
second fails `Msg 2627`, `The duplicate key value is (<NULL>)`. A model with several optional unique
fields works on other engines and does not work here.

That number depends on what Prisma built. `@unique` and `@@unique` emit
`ADD CONSTRAINT ... UNIQUE NONCLUSTERED`, a **constraint**, on both the create and the alter path,
though Prisma labels the step `-- CreateIndex` in the migration. A constraint violation is
`Msg 2627`; a hand-written `CREATE UNIQUE INDEX` raises `Msg 2601`. Match the number to the object
or you search for the wrong one. Key design in general is `design-azure-sql-schema`.

## Migrations, and the one that will not run in the cloud

`prisma migrate dev` needs a **shadow database**: a second temporary database it creates, replays
history into, inspects and drops, so it can detect drift. `prisma migrate deploy` does not use one.

Against Azure SQL Database, Prisma will not create it and stops with a dedicated error:

```
P3020
The automatic creation of shadow databases is disabled on Azure SQL.
Please set up a shadow database using the `shadowDatabaseUrl` datasource attribute.
```

Three things follow.

1. **A local success proves nothing, and this is not a permission problem.** Against the local Azure
   SQL Database container the shadow database is created and dropped and `migrate dev` works. The
   same schema and the same administrative login return P3020 in the cloud, so granting rights fixes
   nothing, and a pipeline is where this is found.
2. **The error names a place that no longer exists.** "datasource attribute" was the Prisma 6
   location. In Prisma 7 `shadowDatabaseUrl` sits in the configuration file beside `url`.
3. **The fix is a second database, not a grant.** Provision another database on the same logical
   server and point `SHADOW_DATABASE_URL` at it; Prisma refuses if the two match, with `The shadow
   database you configured appears to be the same as the main database.` Creating one needs the
   server administrator, the Entra administrator or the database manager role, which an application
   login is not: that is `provision-azure-sql-db`.

| Situation | Command | Shadow database |
|---|---|---|
| Iterating against the container | `prisma migrate dev` | Created and dropped for you |
| Iterating against a cloud database | `prisma migrate dev` | You provide it, once |
| Prototyping with no migration history | `prisma db push` | Not used |
| Deploying | `prisma migrate deploy` | Not used |

Never run `migrate dev` against a database holding real data: it is the command that resets. Whether
a change is safe for a live database at all is `schema-migrations-safely`.

## Getting an identity to the client

The adapter supports Microsoft Entra ID and the Prisma documentation does not mention it, so an agent
working from the docs alone concludes it is impossible. Read out of the installed 7.9.1 package, the
connection string accepts `authentication=DefaultAzureCredential`,
`authentication=ActiveDirectoryManagedIdentity` with an optional client id, and
`authentication=ActiveDirectoryServicePrincipal`; the object form is
`authentication: { type: 'azure-active-directory-default' }`.

**The command line is a separate path.** Migrations connect through the configuration file's URL,
whose documented arguments are a user and a password, so plan for them to run under a login even
where the application is passwordless. The identity still needs a database principal, which is
`entra-id-auth`.

## Check it worked

**The schema is one the connector accepts.** With `DATABASE_URL` exported:

```bash
./node_modules/.bin/prisma validate
```

Expect exactly `The schema at prisma/schema.prisma is valid 🚀`. Any `P1012` block is a Json field,
an enum or a scalar list; a `PrismaConfigEnvError` means the `dotenv/config` import is missing.

**No column is heading for Msg 1946.** Read the DDL before it runs:

```bash
./node_modules/.bin/prisma migrate diff --from-empty --to-schema=prisma/schema.prisma --script | grep -c 'NVARCHAR(1000)'
```

Expect `0`. Each match is one unsized `String`, and any of them in a key, unique constraint or
foreign key is a migration that warns and an insert that fails later.

**Nothing already migrated is over the limit.** Against the migrated database:

```bash
sqlcmd -S <server-name>.database.windows.net,1433 -d <database> -U <user> -C -b -m-1 -Q \
  "SELECT t.name AS tbl, i.name AS ix, i.type_desc, SUM(c.max_length) AS key_bytes
   FROM sys.indexes AS i
   JOIN sys.index_columns AS ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
        AND ic.is_included_column = 0
   JOIN sys.columns AS c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
   JOIN sys.tables AS t ON t.object_id = i.object_id
   GROUP BY t.name, i.name, i.type_desc
   HAVING SUM(c.max_length) > CASE WHEN i.type_desc = 'CLUSTERED' THEN 900 ELSE 1700 END;"
```

Expect zero rows. Each row is an index over its limit, `key_bytes` 2000 being the unsized default.
Keep `-m-1`: without it the create-time warning carries no `Msg` number, which is how these ship.

**`-m-1` is an ODBC `sqlcmd` instruction**, meaning the 18.x build from `mssql-tools18` or the
Microsoft command line utilities. Measured 2026-09-05, go-sqlcmd 1.10.0, the 1.x build
`brew install sqlcmd` and `winget install sqlcmd` install, prints no `Msg` header on a severity 10
message at any `-m` value, so on that build the 1945 warning `prisma migrate deploy` provokes stays
unnumbered and the migration still reads as clean. Run the migration through the ODBC build when the
number is what you are grepping for. `build-app-on-azure-sql` tells the two builds apart in one
table.

## Do not

- Do not answer a `Json`, `enum` or scalar-list validation error with a raw query. Model it as a
  column or a table.
- Do not read a green local migration as evidence that the cloud will accept it, and do not answer
  P3020 with a permission grant or by pointing `shadowDatabaseUrl` at the database holding your data.
- Do not skip certificate validation, and do not write a retry loop here. Encryption and
  transient-fault policy are one policy for every stack: `connect-to-azure-sql`.

## References

- [Prisma SQL Server connector](https://www.prisma.io/docs/orm/overview/databases/sql-server): the
  type mapping table and every connection URL argument with its default. Fetch it before adding an
  argument to the URL above.
- [Shadow database](https://www.prisma.io/docs/orm/prisma-migrate/understanding-prisma-migrate/shadow-database):
  what `migrate dev` does with it, and the cloud-hosted setup. Read it before configuring one.
- [Prisma error reference](https://www.prisma.io/docs/orm/reference/error-reference): the definitive
  text for P3020, P1012 and P1013. Read it when a P-code appears.
- [CREATE INDEX](https://learn.microsoft.com/sql/t-sql/statements/create-index-transact-sql): the
  900 and 1700 byte key limits in the engine's own words. Read it to confirm the rule, not the text.
- [Database Engine events and errors 1000 to 1999](https://learn.microsoft.com/sql/relational-databases/errors-events/database-engine-events-and-errors-1000-to-1999):
  1945 at severity 10 and 1946 at severity 16. Read it before asserting either number.
- `connect-from-typescript-and-node`: the `mssql` driver the adapter wraps. Open it before
  configuring the adapter's pool, which is that driver's.
- `connect-to-azure-sql`: encryption, retry, transient faults. Open it the moment one appears.
- `design-azure-sql-schema`: key length, sizing, collation. Open it before the first migration, not
  after the first `Msg 1946`.
- `schema-migrations-safely`: the doctrine Prisma Migrate inherits, including why a pipeline reports
  success on a migration that only warned.
- `provision-azure-sql-db`: creating the second database P3020 asks for. Open it on that error.
