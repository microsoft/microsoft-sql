---
name: azure-sql
description: >-
  Orients an agent working with Azure SQL Database in 2026: what the service is and is not, what is
  generally available against what is still preview, which tool does which job, and which skill owns
  the task in front of it. Use at the start of a piece of work, and when a user asks "what can Azure
  SQL Database do", "is that feature available yet or still preview", "which service tier should I
  start on", "which tool should I use for this", "where is this documented", or names the product
  with no task attached. Also use before answering any question about a capability, a default or a
  limit from memory, because those change faster than training data does. It routes rather than
  answers: connecting belongs to connect-to-azure-sql, creating a database to provision-azure-sql-db,
  tier choice to provision-hyperscale, identity to entra-id-auth, connection errors to
  diagnose-connection-errors, T-SQL syntax to t-sql-correctness, and starting an application to
  build-app-on-azure-sql.
---

# Working with Azure SQL Database

This is the front door. It answers three questions and hands everything else on: **what is true
right now**, **which tool does the job**, and **which skill owns the task**.

It deliberately holds very little content of its own, because the content that would live here is
the content that goes stale.

**Currency verified against Microsoft Learn on 2026-08-28.** Every dated claim below names a
page to refetch. If today is far from that date, refetch first and correct the user rather than
repeating this file.

## The first rule: fetch, do not recall

A model's picture of this service is a snapshot, and the snapshot is old. Availability, defaults,
service limits and command flags all move, and none of them fail loudly when recalled wrongly. They
fail at deployment, or in review, or in a bill.

So:

- **Never state general availability from memory.** Preview and generally available is the single
  most consequential distinction in this service and the one that changes most often.
- **Never quote a service limit from memory.** Read it from the resource limits article, or ask the
  tool. Command help text is not authoritative either: this catalog has already found flags whose
  help text names a value the command rejects, and a limit stated as one where the real number is
  ten.
- **Prefer asking the running system to asking yourself.** `az sql db list-editions`,
  `SELECT @@VERSION`, `SELECT compatibility_level FROM sys.databases` and the resource governance
  views answer questions about *this* database rather than about databases in general.

Where to look each thing up is in
[references/where-to-look-it-up.md](references/where-to-look-it-up.md).

## Scope: which product this actually is

The Azure SQL family shares an engine and does not share behaviour, limits or feature sets. This
catalog is about **Azure SQL Database**, the multi-tenant platform service, plus the Azure SQL
Database container for local development.

| In scope | Out of scope |
|---|---|
| Azure SQL Database, single databases and elastic pools | Not Azure SQL Managed Instance |
| The Azure SQL Database container, for local development only | Not SQL database in Microsoft Fabric |
| | Not SQL Server on virtual machines |

Why this matters more than tidiness: capabilities are announced across the family in a single blog
post and then arrive at different times, or never. An agent that reads "announced for SQL" and
writes it into an Azure SQL Database design has invented a feature. Name the other members of the
family only to exclude them, and say which product an announcement was actually about.

Two specific traps:

- Instance-level features have no home here. There is no SQL Agent, no cross-database query by
  three-part name to another user database, and `USE <database>` does not switch context.
- Announcements about analytics-oriented SQL surfaces are not this product. If a capability is
  documented only under a different product's namespace, it does not exist here until a page that
  applies to Azure SQL Database says so.

## Capability currency, as of 2026-08-28

**This block is the only dated content in this file and is written to be lifted out whole.** If
release announcements start churning it, it becomes its own skill and this file keeps the routing.

| Fact | State on 2026-08-28 | Refetch from |
|---|---|---|
| Database engine version and default compatibility level | Engine version 17. **New databases default to compatibility level 170**, and levels 100 through 170 are supported | The `ALTER DATABASE` compatibility level reference |
| A database that arrived from somewhere else | Keeps the compatibility level it had. Migration does not raise it, and neither does a tier conversion | The same page, plus `sys.databases` |
| Default service tier advice | The documentation now names **Hyperscale the recommended and default service tier for new and modernizing OLTP and HTAP workloads**, which reverses older advice to start on General Purpose | The Hyperscale service tier article |
| Native vectors | The `vector` data type and `VECTOR_DISTANCE` are **generally available** in Azure SQL Database | The vectors article |
| Approximate vector search | The DiskANN vector index and `VECTOR_SEARCH` are **preview**. `VECTOR_DISTANCE` is always exact and never uses an index, whatever indexes exist | The same article |
| The free offer | Up to **10** free databases per subscription, each with its own monthly allowance, on General Purpose serverless | The free offer FAQ |
| Versioning | Evergreen. There is no version to pin and no release to wait for, so "which version of the engine do we get" is not a question this service answers | The what is new article |

Three shapes to watch for, rather than facts to memorize:

- **Preview features carry conditions.** Regional availability, a supported hardware family, and
  sometimes an update policy. "It is in preview" is not the same as "you can use it".
- **Defaults change under existing resources without changing them.** A default that applies to new
  databases says nothing about the one in front of you. Query it.
- **A feature can exist and still be the wrong answer.** Availability is the first question, not the
  last.

## Which tool for the job

| The job | The tool |
|---|---|
| Create, change, inspect Azure resources: servers, databases, pools, firewall rules | The Azure CLI `az sql` command group, or infrastructure as code for anything repeatable |
| Run T-SQL from a script, a pipeline, or an agent | A command line client, which needs no interactive session and works the same in continuous integration |
| Move a schema, a database, or both, as a file | The SqlPackage command line, with dacpac for schema and bacpac for schema plus data |
| Load a large amount of data | The bulk copy path, not row-by-row inserts from application code |
| Put a REST or GraphQL API over tables without writing one | Data API builder |
| Take a working application and its database to Azure | The Azure Developer CLI, reading the template's infrastructure rather than trusting it |
| Apply schema changes over time | The migration tooling the project already uses. The rule is one owner for schema, not one tool for everyone |
| Develop against the engine locally | The Azure SQL Database container. Not another database engine standing in for it |

Two anti-patterns worth naming, because they are common and expensive:

- **Reaching for the general SQL Server container image** when the target is this service. The
  editions differ, and so do the limits and the error semantics, so the local run proves less than
  it appears to.
- **Hand-writing a CRUD API** when a generated one would do. Decide against the generated one on
  purpose, not by default.

## Which skill owns this task

Routing entries name a skill only where that skill exists. Where it does not, the row says what to
do instead, so nothing is routed at a name that will not answer.

### Getting a database

| Task | Route |
|---|---|
| Create a server and database, open the firewall, use the free offer, get a working connection string | `provision-azure-sql-db` |
| Choose a service tier for a real workload, size or convert to Hyperscale, decide about replicas | `provision-hyperscale` |
| Start from a ready-made local development environment with a database in it | `dev-container-templates` |
| Run the engine locally, in a container, in compose, or in continuous integration | `azuresql-db-container`, which routes on to the rest of the container family |

### Connecting

| Task | Route |
|---|---|
| Which driver, what goes in the connection string, encryption, retry, pool sizing | `connect-to-azure-sql` |
| The same for .NET, Python, or TypeScript and Node.js specifically | `connect-from-dotnet`, `connect-from-python`, `connect-from-typescript-and-node` |
| A connection already failed and there is an error to read | `diagnose-connection-errors` |
| Passwordless connection, managed identity, database users for an application identity | `entra-id-auth` |

### Writing SQL and modelling data

| Task | Route |
|---|---|
| T-SQL that is correct here rather than PostgreSQL syntax in a T-SQL costume | `t-sql-correctness` |
| Entity Framework Core, Prisma, or SQLAlchemy against this service | `ef-core-azure-sql`, `prisma-azure-sql`, `sqlalchemy-azure-sql` |
| Designing a schema, choosing keys, string lengths and a collation | `design-azure-sql-schema` |
| JSON in the database, or an upsert | No skill is installed yet. Both have engine-specific answers here, so read the T-SQL reference for the function or statement rather than porting a pattern from another database |
| Storing embeddings, similarity search, the vector index | `vector-search-azure-sql` |
| A retrieval pipeline end to end, grounded answers over your own data | `rag-on-azure-sql` |

### Building and shipping an application

| Task | Route |
|---|---|
| Sequencing the whole job of standing up a new application on this service | `build-app-on-azure-sql` |
| A REST or GraphQL API over the schema | `dab-rest-and-graphql` |
| Serverless functions, input and output bindings, reacting to row changes | `azure-functions-sql-bindings` |
| Deploying the application and its database to Azure | `deploy-app-to-azure` |
| Pipelines, database projects, and migrations under review | No skill is installed yet. Keep one owner for schema, run the change against a copy first, and treat a migration that only runs locally as unproven |

### The rest of wave one, not yet installed

These are real jobs with no skill on disk yet. Do not route a prompt at a name that does not answer.

| Task | What to do meanwhile |
|---|---|
| Generating embeddings from inside the database, or calling an external model | Check the availability line in the currency block above first, because the surface around external models moves quickly, then read the vectors article |
| A slow query, a plan to read, blocking, deadlocks, resource pressure, an event capture | Collect evidence before changing anything: the plan, the wait statistics, and the resource governance views. Changing the tier to fix a slow query is the expensive first move |
| Restore, point-in-time recovery, retention | Read the automated backups article before promising anything. Retention, and what a restore actually produces, are both easy to state wrongly |
| Bulk load, import and export, moving data between databases | Use the bulk copy or package tooling above. Application-level loops are the wrong tool at any size that matters |
| Preventing injection, row-level security, multi-tenant isolation | Parameterize every statement, without exception, and read the security checklist below before designing tenancy |
| Moving an existing SQL Server estate onto this service | That is the migration domain, which is scheduled and not installed. Assess compatibility before promising a target tier |
| Reporting that one of these skills was wrong or missing | Say so plainly to the user and point them at the catalog's issue templates. A skill that had to be worked around is a defect worth filing |

**This table ages faster than the rest of the file.** Skills arrive one at a time, so a row saying
no skill is installed can be wrong within a week. Check what is actually installed before repeating
a row, and prefer a skill that is present over the advice written here for its absence.

## Security, by reference

There is a first-party checklist, it is maintained, and copying it here would make a stale copy of a
living document. Read it, and treat these four as non-negotiable while you do:

1. **No secret in source, in a connection string in a repository, or in a transcript.** An identity
   is preferred to a password everywhere it is available.
2. **Encryption on, certificate validation on.** A certificate error is a name problem, not a trust
   problem.
3. **Least privilege on the database side.** The administrator login is not an application identity.
4. **Every statement parameterized.** Concatenating user input into T-SQL is the vulnerability an
   agent is most likely to write.

The playbook and the security best practices article are linked from
[references/where-to-look-it-up.md](references/where-to-look-it-up.md).

## Validation rules

- No claim about availability, a default, or a limit was made without either fetching a page or
  asking the running system.
- Any dated statement taken from this file was checked against its verification date, and refetched
  if the date is old.
- The product was named precisely, and other members of the family appeared only as exclusions.
- The task was routed to a skill that exists, or the job was described without naming one.
- Preview features were labelled as preview every time they were mentioned, not once.

## Do not

- Do not answer "is X generally available" from memory. It is the question this file exists to stop
  being answered that way.
- Do not carry a capability across the family. An announcement is about one product until a page
  says otherwise.
- Do not quote a service limit, a quota or a flag value without checking it, including from command
  help text.
- Do not route a prompt at a skill name that is not installed. Describe the job instead.
- Do not answer a task another skill owns just because this file was loaded first. Hand it over.
- Do not restate a stable documentation page here. Link it, and say when to read it.
- Do not treat the local container as proof about cloud behaviour, or cloud behaviour as a promise
  about the container.

## References

- [references/where-to-look-it-up.md](references/where-to-look-it-up.md): the pinned first-party
  pages by subject, what each one settles, and how to check whether a capability is generally
  available without guessing. Read it before answering any currency question.
