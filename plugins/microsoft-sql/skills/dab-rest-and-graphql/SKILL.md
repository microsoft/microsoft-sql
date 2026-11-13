---
name: dab-rest-and-graphql
description: "Use when a Data API builder config may expose more than intended, or to set roles and inheritance, row policies, relationships, a passwordless Azure SQL connection, or autoentities patterns that replace hundreds of hand-written entities in dab-config.json."
---

# What a Data API builder configuration publishes on Azure SQL Database

Generating endpoints is the easy part, and another skill owns it. What goes wrong later is that
**the configuration publishes more of the database than the author asked for**, and that **the
patterns generating it are not the syntax people write**.

## The boundary

This skill owns the version 2.0 configuration model on Azure SQL Database: what each entity
exposes, which role reaches it after inheritance, which rows come back, and what the connection
string looks like once nothing holds a password. It does not own getting a first endpoint
answering.

| Question | Skill |
|---|---|
| A first endpoint, or any run against the local Azure SQL Database container | `azuresql-db-dab` |
| Pointing an agent at the extra endpoint the same config serves at `/mcp` | `dab-mcp-endpoint` |
| Hosting the configuration in Azure: image, identity, health roles, the MCP host allowlist | `deploy-dab-to-azure` |
| Serverless handlers and change-driven code instead of an API | `azure-functions-sql-bindings` |
| Getting an application identity to a working passwordless connection | `entra-id-auth` |
| Creating the server, database and firewall rule | `provision-azure-sql-db` |

## The four facts that changed at version 2.0

Version 2.0 is stable from 2.0.8 (28 May 2026). Guidance written for 1.x gets all four wrong.

1. **`dab init` writes `"provider": "Unauthenticated"` and `"mode": "production"`.** Every request
   is evaluated as `anonymous`. No token is inspected, even if something in front authenticated the
   caller.
2. **Roles inherit upward**: a named role inherits from `authenticated`, which inherits from
   `anonymous`. A single `anonymous:read` is therefore read access for every role not configured on
   that entity, including named roles that appear nowhere in the file. A role that is configured on
   the entity gets only its own actions: on 2.1.5, `authenticated` granted `create` kept `create`
   alone and did not inherit `anonymous` read.
3. **Entities can be generated from patterns** (`autoentities`) instead of written one by one. The
   patterns are **T-SQL `LIKE`**, not regular expressions, and the default `include` is `%.%`,
   every object in every schema.
4. **`dab init --help` reports `mcp.enabled (Default: true)`**, so a second endpoint is published
   over the same entities and permissions whether or not anyone asked. Anything on REST is on it.

Put 1, 2 and 3 together and a two-line configuration serves the whole database to unauthenticated
callers, with nothing in the startup output naming the excess.

## Set the provider at init, not later

```bash
dab init --database-type mssql \
  --connection-string "@env('SQL_CONNECTION_STRING')" \
  --auth.provider EntraID \
  --auth.audience "<application-id-uri>" \
  --auth.issuer "https://login.microsoftonline.com/<tenant-id>/v2.0"
```

Valid providers are `Unauthenticated`, `StaticWebApps`, `EntraID`, `AzureAD`, `AppService`,
`Simulator` and `Custom`. Everything except the first, `StaticWebApps` and `Simulator` requires
both `--auth.audience` and `--auth.issuer`, and `dab validate` fails a config carrying one without
the other. Never write a literal connection string into the file: `@env('NAME')` reads an environment
variable and `@akv('secret-name')` a key vault secret, both resolved at startup.

## Hand-written entities or generated ones

**Hand-written** is right when the API surface is a deliberate subset, which is most production
APIs:

```bash
dab add Book --source dbo.books --source.type table --permissions "authenticated:read"
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

Four things to get right, each a real failure:

- **The patterns are T-SQL `LIKE`.** `%` is the wildcard. `.*`, `^`, `$` and character classes are
  literal characters here and match nothing.
- **The pattern format is `schema.object`.** `Products` alone never matches; write `dbo.Products`.
- **Omitting `include` means `%.%`.** The CLI's own help prints that default. Always write one.
- **Version 2.0 auto-config covers tables only**, and only on Microsoft SQL data sources. Views and
  stored procedures still need `dab add`.

Both forms can coexist, and `autoentities` re-resolve on every start, so a table created next
month that matches the pattern becomes an entity with no config change. That is the feature and
also the risk.

## Read the permissions that will actually apply

Permissions written in the file are not the permissions in force, because of inheritance:

```bash
dab configure --show-effective-permissions
```

**Grant the narrowest role, not the broadest.** A permission placed on `anonymous` to get
something working cannot be walked back by adding a named role later: the named role inherits it.

Actions are `create`, `read`, `update`, `delete` for tables and views, `execute` for stored
procedures, and `*` expands to whichever set fits the entity type.

## Relationships, views and stored procedures are still by hand

Generated entities have no GraphQL navigation until relationship blocks are added:

```bash
dab update Category --relationship category_books --target.entity Book \
  --cardinality many --relationship.fields "id:category_id"
```

A many-to-many also needs `--linking.object`, `--linking.source.fields` and
`--linking.target.fields`. A view needs its key columns marked and cannot carry relationships:

```bash
dab add BookDetail --source dbo.vw_book_details --source.type view \
  --fields.name "id" --fields.primary-key "true" --permissions "authenticated:read"
```

## Filter rows with a database policy

A database policy is an OData predicate the database evaluates as a `WHERE` clause, so a caller
sees only their own rows:

```bash
dab update Order --permissions "consumer:read" \
  --policy-database "@item.ownerId eq @claims.oid"
```

`@item.<field>` names a column by its mapped API name, `@claims.<type>` injects a claim from the
caller's token, and the operators are `eq`, `ne`, `gt`, `ge`, `lt`, `le`, `and`, `or`.

**Policies are supported on `read`, `update` and `delete` only.** An `INSERT` takes no `WHERE`
clause and a stored procedure takes no predicate, so `create` and `execute` are not supported.
**The CLI does not stop you anyway.** Run the same command with `--permissions "consumer:create"`
and Data API builder 2.0.9 writes the policy into the config and exits 0, saying nothing. A
policy is therefore not a way to stop a caller inserting a row they should not own. Validate that on the way in, or push it
into a check constraint.

## Run against Azure SQL Database on an identity

The configuration does not change between the container and the cloud. The connection string does,
and in the cloud it carries no password:

```text
Server=tcp:<server-name>.database.windows.net,1433;Database=<database-name>;Authentication=Active Directory Default;Encrypt=True;TrustServerCertificate=False;
```

`Active Directory Default` resolves to the developer's own credentials locally and to the host's
managed identity once deployed, so one string works in both places. A user-assigned identity uses
`Authentication=Active Directory Managed Identity;User ID=<client-id>` instead.

That identity still needs a database user. Connect as the Microsoft Entra administrator and grant
the least privilege the configuration actually uses:

```sql
CREATE USER [<identity-name>] FROM EXTERNAL PROVIDER;
ALTER ROLE db_datareader ADD MEMBER [<identity-name>];
```

Add `db_datawriter` only if the configuration grants `create`, `update` or `delete`. Do not make
the API identity the server administrator.

## Check it worked

A clean start is not evidence. Three checks, in this order.

```bash
dab validate; echo "exit=$?"
```

`0` is the pass. Anything else means one of five ordered stages failed: schema, config properties,
permissions, database connection, entity metadata. Later stages are skipped, so fix the first.
With 2.0.9 a failure can print only `fail: Config is invalid.` and exit 255, naming no stage and no
reason, and a debug log level adds nothing. Learn documents a named error on that line, so walk
the five stages yourself rather than waiting to be told.

```bash
dab auto-config-simulate --output matched.csv
```

This connects to the database, resolves each pattern and writes the matched objects without
changing anything. Read the file and compare it line by line against the tables the user named.
**This is the only step that catches an over-broad pattern before it serves traffic**, because
`dab validate` has no stage that expands a pattern, so an `autoentities` block matching the whole
database is not a validation failure.

```bash
dab configure --show-effective-permissions
```

For an entity granted only `anonymous:read`, the output is:

```text
info: Entity: Book
info:   Role: anonymous | Actions: Read
info:   Role: authenticated | Actions: Read (inherited from: anonymous)
info:   Any unconfigured named role inherits from: anonymous
```

A role here that you never wrote is the finding. No entity should reach `anonymous` unless the user
asked for public access.

To prove the matrix with live requests, send writes only to a disposable copy of the database.
An allowed `create`, `update` or `delete` really changes the data behind the endpoint. Against a
shared or production database, use reads and the effective-permissions output above.

## Do not

- Do not write `autoentities` patterns as regular expressions. The CLI's own help calls them
  "T-SQL LIKE pattern(s)", and a regular expression fails silently by matching nothing.
- Do not omit `patterns.include` on the assumption that it defaults to something conservative.
- Do not reason about a role by reading its own permission block. Read the effective permissions.
- Do not use `anonymous` while developing and plan to tighten it later. Every role not configured on
  the entity keeps whatever `anonymous` was given.
- Do not treat a `dab validate` exit of 0 as evidence that the right objects are published.
- Do not assume disabling REST hides an entity. GraphQL and `/mcp` are separate switches on it.
- Do not expect a database policy on `create` to hold. It is unsupported and accepted silently.

## References

- [references/query-surface.md](references/query-surface.md): open it when writing client code
  against the generated API, when a caller reports a `$filter` or page size that does not behave,
  or when tuning what the endpoint returns. It holds the REST query keywords, pagination and
  response shape, their GraphQL equivalents, and the caching and page size configuration keys.
- [`Autoentities` configuration](https://learn.microsoft.com/azure/data-api-builder/configuration/autoentities):
  fetch it before writing a pattern you have not simulated. Every pattern and template key with its
  default.
- [`validate` command](https://learn.microsoft.com/azure/data-api-builder/command-line/dab-validate):
  fetch it when `dab validate` fails without naming a reason. The five stages and what each
  rejects.
