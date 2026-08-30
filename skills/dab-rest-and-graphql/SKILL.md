---
name: dab-rest-and-graphql
description: >-
  Exposes REST and GraphQL endpoints over an Azure SQL Database schema with Data API builder,
  covering the version 2.0 configuration model: pattern-generated entities, role inheritance,
  relationships, database policies, and the move from a local run to a hosted one on cloud identity.
  Use when a user asks to "expose my tables as a REST API", "generate a GraphQL API over Azure SQL",
  "set up Data API builder", "dab init", "dab-config.json", "autoentities", "my config has hundreds
  of entities", or "why can anonymous read this entity". Also use when a Data API builder
  configuration starts cleanly but publishes more than intended, which is usually the default
  include pattern combined with the Unauthenticated provider. This is the Azure SQL Database story;
  running Data API builder against the local Azure SQL Database container belongs to
  azuresql-db-dab, and configuring the MCP endpoint in depth is out of scope here.
---

# REST and GraphQL over Azure SQL Database with Data API builder

Generating the endpoints is the easy part. The two things that go wrong are that **the
configuration publishes more of the database than the author asked for**, and that **the patterns
that generate it are not the syntax people write**.

Verified against Data API builder 2.0.9 (`dab --version`) and Microsoft Learn on 2026-08-27.

## What this skill owns, and what it does not

**Owns**: the configuration model at version 2.0, the permission and policy shape, entity
generation from patterns, relationships, and getting the same configuration running against Azure
SQL Database on a cloud identity.

**Does not own.** Send these elsewhere rather than answering them here:

| Question | Skill |
|---|---|
| The same tool against the local Azure SQL Database container | `azuresql-db-dab` |
| The MCP endpoint over the same entity model, in depth | `dab-mcp-endpoint`, once it exists. Until then, say the endpoint is on by default and stop there |
| Serverless handlers and change-driven code instead of an API | `azure-functions-sql-bindings` |
| Which data access path an application should take at all | `build-app-on-azure-sql` |
| Getting an application identity to a working passwordless connection | `entra-id-auth` |
| Taking the whole application to Azure | `deploy-app-to-azure` |
| Creating the server, database and firewall rule | `provision-azure-sql-db` |
| Retry, pooling and connection string doctrine | `connect-to-azure-sql` |

Where behaviour is identical between the container and Azure SQL Database, it is identical: the
configuration file does not change, only the connection string does.

## The four facts that changed at version 2.0

Version 2.0 is stable from 2.0.8 (28 May 2026), with 2.0.9 on 29 June 2026. A model that learned
Data API builder from 1.x will get all four of these wrong.

1. **`dab init` writes `"provider": "Unauthenticated"`.** Every request is evaluated as
   `anonymous`. No token is inspected, even if something in front of the API authenticated the
   caller.
2. **Roles inherit upward**: `named-role` inherits from `authenticated`, which inherits from
   `anonymous`. A single `anonymous:read` is therefore read access for every role, including
   named roles that appear nowhere in the file.
3. **Entities can be generated from patterns** (`autoentities`) instead of written one by one.
   The patterns are **T-SQL `LIKE`**, not regular expressions, and the default `include` is
   `%.%`, meaning every object in every schema.
4. **The MCP endpoint is on by default**, at `/mcp`, over the same entities and the same
   permissions. Anything published to REST is published there too.

Put 1, 2 and 3 together and a two-line configuration can serve the whole database to
unauthenticated callers while `dab validate` passes and startup logs nothing unusual.

## Step 1: initialise, then fix the provider

```bash
dab init --database-type mssql --connection-string "@env('SQL_CONNECTION_STRING')"
```

That writes `runtime.host.authentication.provider` as `Unauthenticated` and `runtime.host.mode` as
`production`. Before the API is reachable by anything other than the developer machine, set a real
provider:

```bash
dab configure --runtime.host.authentication.provider "EntraID"
dab configure --runtime.host.authentication.jwt.audience "<application-id-uri>"
dab configure --runtime.host.authentication.jwt.issuer "<issuer-url>"
```

Never put a literal connection string in the file. `@env('NAME')` reads an environment variable and
`@akv('secret-name')` reads a key vault secret; both are resolved at startup.

## Step 2: choose hand-written entities or generated ones

**Hand-written** is right when the API surface is a deliberate subset, which is most production
APIs:

```bash
dab add Book \
  --source dbo.books \
  --source.type table \
  --permissions "authenticated:read"
```

**Generated** is right when the objects and their permissions are predictable, which is what makes
a several-hundred-entity file worth replacing:

```bash
dab auto-config public-read \
  --patterns.include "dbo.%" \
  --patterns.exclude "dbo.internal%" "%.%_staging" \
  --patterns.name "{schema}_{object}" \
  --permissions "authenticated:read"
```

Four things to get right, each of which is a real failure:

- **The patterns are T-SQL `LIKE`.** `%` is the wildcard. `.*`, `^`, `$` and character classes are
  literal characters here and match nothing.
- **The pattern format is `schema.object`.** `Products` on its own never matches; write
  `dbo.Products`.
- **Omitting `include` means `%.%`**, every object in every schema. Always write one.
- **Version 2.0 auto-config covers tables only**, and only on Microsoft SQL data sources. Views and
  stored procedures still need `dab add`.

Both forms can coexist. When a name collides, the explicitly defined entity wins.

## Step 3: simulate before starting

```bash
dab auto-config-simulate
dab auto-config-simulate --output results.csv
```

It connects to the database, resolves each pattern and prints the matched objects without writing
anything. Compare that list against the tables the user actually named. **This is the only step
that catches an over-broad pattern before it is serving traffic**, because a pattern that matches
too much produces a clean startup.

## Step 4: read the permissions that will actually apply

Permissions written in the file are not the permissions in force, because of inheritance. Ask:

```bash
dab configure --show-effective-permissions
```

For an entity granted only `anonymous:read`, the real answer is:

```text
Entity: Book
  Role: anonymous | Actions: Read
  Role: authenticated | Actions: Read (inherited from: anonymous)
  Any unconfigured named role inherits from: anonymous
```

The consequence worth stating to the user: **grant the narrowest role, not the broadest.** A
permission placed on `anonymous` to "get it working" cannot be walked back by adding a named role
later, because the named role inherits it.

Actions are `create`, `read`, `update`, `delete` for tables and views, `execute` for stored
procedures, and `*` expands to whichever set fits the entity type.

## Step 5: relationships, views and stored procedures are still by hand

`autoentities` has no relationships in its template. Pattern-generated entities have no GraphQL
navigation until relationship blocks are added:

```bash
dab update Category \
  --relationship category_books \
  --target.entity Book \
  --cardinality many \
  --relationship.fields "id:category_id"
```

A many-to-many needs the linking object as well, with `--linking.object`,
`--linking.source.fields` and `--linking.target.fields`.

For a view, mark the key columns with `fields[].primary-key`. The older `source.key-fields` is
deprecated at 2.0 and the schema rejects an entity that carries both it and `fields`.

## Step 6: filter rows with a database policy

A database policy is an OData predicate the database evaluates, so a caller sees only their own
rows:

```json
{
  "role": "consumer",
  "actions": [
    {
      "action": "read",
      "policy": { "database": "@item.ownerId eq @claims.oid" }
    }
  ]
}
```

`@item.<field>` names a column, `@claims.<type>` injects a claim from the caller's token.
**Policies are supported on `read`, `update` and `delete` only.** They are not supported on
`create` or `execute`, so a policy is not a way to stop a caller inserting a row they should not
own. Validate that on the way in, or push it into a database check.

## Step 7: run against Azure SQL Database on an identity

The configuration does not change between the container and the cloud. The connection string does,
and in the cloud it should carry no password:

```text
Server=<server-name>.database.windows.net;Database=<database-name>;Encrypt=true;Authentication=Active Directory Default;
```

`Active Directory Default` resolves to the developer's own credentials locally and to the host's
managed identity once deployed, so one string works in both places. For a user-assigned identity,
add `User Id=<client-id-of-the-identity>`.

That identity still needs a database user. Connect as the Microsoft Entra administrator and grant
the least privilege the API actually uses:

```sql
CREATE USER [<identity-name>] FROM EXTERNAL PROVIDER;
ALTER ROLE db_datareader ADD MEMBER [<identity-name>];
GO
```

Add `db_datawriter` only if the configuration grants `create`, `update` or `delete`. Do not make
the API identity the server administrator; a deployment walkthrough that does is taking a shortcut
that does not belong in a real environment.

## Validation rules

- `dab auto-config-simulate` was run, and its match list was compared against what the user asked
  for, before anything started.
- Every `autoentities` definition has an explicit `patterns.include`.
- Every pattern is `LIKE` syntax in `schema.object` form, with no regular expression characters.
- `dab configure --show-effective-permissions` was read, and no entity reaches `anonymous` unless
  the user asked for public access.
- The authentication provider is not `Unauthenticated` on anything reachable off the developer
  machine.
- The connection string in the configuration is an `@env()` or `@akv()` reference, never a literal,
  and the deployed one carries no password.
- Relationships exist for every association the GraphQL schema is expected to traverse.
- If the API is read-only, the database user has `db_datareader` and not `db_datawriter`.

## Do not

- Do not write `autoentities` patterns as regular expressions. The CLI's own help calls them
  "T-SQL LIKE pattern(s)", and a regular expression fails silently by matching nothing.
- Do not omit `patterns.include` on the assumption that it defaults to something conservative. It
  defaults to `%.%`.
- Do not reason about a role by reading its own permission block. Read the effective permissions.
- Do not use `anonymous` as a convenience while developing and plan to tighten it later.
  Inheritance means every other role keeps whatever `anonymous` was given.
- Do not assume disabling REST hides an entity. GraphQL and the MCP endpoint are separate switches
  on the same entity.
- Do not expect a database policy on `create` to hold. It is not supported there.
- Do not hand-write hundreds of entity blocks when the objects and permissions are predictable, and
  do not generate them when they are not.

## References

- [references/query-surface.md](references/query-surface.md): the REST query keywords, pagination
  and the response shape, the GraphQL equivalents, and the configuration keys for caching and page
  size. Read it when writing client code against the generated API or tuning what it returns.
- [Data API builder documentation](https://learn.microsoft.com/azure/data-api-builder/): the
  authority. Fetch the page rather than recalling it, especially the version 2.0 release notes.
- [`autoentities` configuration](https://learn.microsoft.com/azure/data-api-builder/configuration/autoentities):
  every pattern and template key with its default.
