---
name: azure-sql
description: >-
  Orients an agent starting work on Azure SQL Database and hands the task to the catalog skill that
  owns it. Use when someone names the product with no task attached, asks what Azure SQL Database
  can do, whether a capability is generally available or still preview, which service tier to start
  on, which tool does a job, or where something is documented. Also use before answering any
  question about a capability, a default or a limit from memory, because those move faster than
  training data does. This catalog covers Azure SQL Database only, not Azure SQL Managed Instance
  and not self-managed SQL Server, so say plainly that no skill here owns those rather than
  handing over one written for the database.
---

# Working with Azure SQL Database

The front door. It answers two questions and hands everything else on: **what is true right now**,
and **which skill owns the task**. It holds little content of its own, because the content that
would live here is the content that goes stale.

Currency below checked against Microsoft Learn on 2026-09-03. Tool builds measured the same day:
sqlpackage 170.4.83.3, sqlcmd 1.10.0, dotnet 8.0.421, dab 2.0.9, prisma 8.0.0-rc.12, azd, Azure CLI
2.90.0. If today is far from that date, refetch before repeating anything below.

## The first rule: ask, do not recall

A model's picture of this service is a snapshot and the snapshot is old. Availability, defaults,
limits and command flags all move, and none of them fail loudly when recalled wrongly. They fail at
deployment, in review, or in a bill.

- **Never state general availability from memory.** Preview against generally available is the most
  consequential distinction in this service and the one that changes most often.
- **Never quote a service limit from memory.** Read it from the resource limits article, or ask the
  running system. Help text is not authoritative either: this catalog has caught a flag whose help
  text names a value the command rejects, and a limit stated as one where the real number is ten.

Ask the database in front of you rather than yourself. `EngineEdition` is the one value that settles
which product this is, and everything in this catalog is written for `5`:

```sql
SELECT SERVERPROPERTY('EngineEdition') AS engine_edition,   -- 5 is Azure SQL Database
       DB_NAME()                       AS current_database,
       compatibility_level
FROM sys.databases
WHERE name = DB_NAME();
```

Ask the tool in front of you too. Every neighbour skill's flags are build-specific, so read the
build before handing over, and route around whatever is missing:

```bash
sqlcmd --version
sqlpackage /version:True
dotnet --version
dab --version
azd version
az version --query '"azure-cli"' --output tsv
prisma --version || npx --yes prisma --version
```

`prisma` is normally a project-local dependency rather than a command on `PATH`, which is why the
last line falls through to `npx`.

## Scope: which product this actually is

The Azure SQL family shares an engine and does not share behaviour, limits or feature sets. This
catalog is about **Azure SQL Database**, the multi-tenant platform service, plus the Azure SQL
Database container for local development. It is not Azure SQL Managed Instance, which reports
`EngineEdition` 8, not SQL database in Microsoft Fabric, which reports 12, and not SQL Server on
virtual machines, which reports 2 or 3.

This matters more than tidiness: capabilities are announced across the family in one blog post and
then arrive at different times, or never. An agent that reads "announced for SQL" and writes it into
an Azure SQL Database design has invented a feature. Name the other members of the family only to
exclude them, and say which product an announcement was actually about.

Two traps that follow from the product being database-scoped rather than instance-scoped:

- Instance-level features have no home here. There is no SQL Agent, and no cross-database query by
  three-part name to another user database. `USE <another database>` does not switch context: it
  returns `Msg 40508`, and a new connection is the only way to change database.
- Announcements about analytics-oriented SQL surfaces are not this product. If a capability is
  documented only under a different product's namespace, it does not exist here until a page that
  applies to Azure SQL Database says so.

## Capability currency, as of 2026-09-03

**The only dated content in this file, written to be lifted out whole.** If release announcements
start churning it, it becomes its own skill and this file keeps the routing.

| Fact | State on 2026-09-03 | Refetch from |
|---|---|---|
| Engine version and default compatibility level | Engine version 17. New databases default to **170**; 170 down to 100 are supported | The `ALTER DATABASE` compatibility level reference |
| A database that arrived from somewhere else | Keeps the compatibility level it had. Neither a migration nor a tier conversion raises it | The same page, plus `sys.databases` |
| Default tier advice | Learn names Hyperscale **"the recommended and default service tier for all new and modernizing OLTP and HTAP workloads"**, reversing older advice to start on General Purpose | The Hyperscale service tier article |
| Native vectors | The `vector` type and `VECTOR_DISTANCE` are **generally available**. `VECTOR_DISTANCE` is always exact and never uses an index, whatever indexes exist | The vectors article |
| Approximate vector search | The DiskANN vector index and `VECTOR_SEARCH` are **preview**, and rolling out by region | The same article |
| The free offer | Up to **10** free databases per subscription, each with 100,000 vCore seconds, 32 GB data and 32 GB backup storage a month, on General Purpose serverless | The free offer FAQ |
| Versioning | Evergreen. There is no version to pin and no release to wait for | The what is new article |

Three shapes to watch for, rather than facts to memorize:

- **Preview features carry conditions.** Region, hardware family, sometimes an update policy. "It is
  in preview" is not the same as "you can use it".
- **Defaults change under existing resources without changing them.** A default that applies to new
  databases says nothing about the one in front of you. Query it.
- **A feature can exist and still be the wrong answer.** Availability is the first question, not the
  last.

## Which skill owns this task

Every name below is a directory in this catalog. Nothing routes at a name that does not answer.

### Getting a database, and connecting to it

| Task | Route to |
|---|---|
| Create a server and database, open the firewall, use the free offer, get a working connection string | `provision-azure-sql-db` |
| Choose a tier for a real workload, size or convert to Hyperscale, decide about replicas | `provision-hyperscale` |
| Start from a ready-made local development environment with a database in it | `dev-container-templates` |
| Driver choice, connection string, encryption, retry, pool sizing | `connect-to-azure-sql` |
| The same for one language | `connect-from-dotnet`, `connect-from-python`, `connect-from-typescript-and-node` |
| A connection already failed and there is an error number to read | `diagnose-connection-errors` |
| Passwordless connection, managed identity, a database user for an application identity | `entra-id-auth` |

### Writing SQL and modelling data

| Task | Route to |
|---|---|
| T-SQL that is correct here rather than PostgreSQL syntax in a T-SQL costume | `t-sql-correctness` |
| JSON stored or queried in the database, `OPENJSON` | `t-sql-json-and-openjson` |
| Insert or update, and the `MERGE` shapes that lose rows | `t-sql-upserts-merge` |
| Tables, keys, string lengths, collation, the index key byte limit | `design-azure-sql-schema` |
| An object-relational mapper | `ef-core-azure-sql`, `prisma-azure-sql`, `sqlalchemy-azure-sql` |
| Parameterizing, dynamic SQL, identifiers a parameter cannot reach | `prevent-sql-injection` |
| Tenant isolation, row level security, a policy a test can prove | `rls-multi-tenant` |

### Vectors, retrieval and AI

| Task | Route to |
|---|---|
| The `vector` type, `VECTOR_DISTANCE`, the dimension ceiling, the vector index | `vector-search-azure-sql` |
| Embeddings generated inside the database, external models, chunking in T-SQL | `embeddings-and-external-models` |
| A retrieval pipeline end to end, grounded answers over your own data | `rag-on-azure-sql` |
| Whether a prototype proved on the local container still holds in the cloud | `rag-local-with-container` |
| LangChain or LlamaIndex over this database | `langchain-and-llamaindex-on-azure-sql` |

### Building, shipping and moving data

| Task | Route to |
|---|---|
| Sequencing the whole job of standing up a new application on this service | `build-app-on-azure-sql` |
| A REST or GraphQL API over the schema without writing one | `dab-rest-and-graphql` |
| Serverless function bindings, and reacting to row changes | `azure-functions-sql-bindings` |
| Deploying the application and its database to Azure | `deploy-app-to-azure` |
| A source-controlled database project, its target platform, pre and post deployment scripts | `sql-database-projects` |
| Shipping a schema change from a continuous integration workflow | `github-actions-for-sql` |
| Whether a migration is safe to run against a live database | `schema-migrations-safely` |
| Moving a whole database as a portable file, dacpac against bacpac | `sqlpackage-import-export` |
| Loading a large amount of data into a table that already exists | `bulk-load-and-bulk-copy` |

### When it is slow, stuck or lost

| Task | Route to |
|---|---|
| One query is slow, and nobody has triaged why yet | `diagnose-slow-query` |
| Reading the execution plan itself | `read-execution-plan` |
| Who is blocking whom right now, or a deadlock that already happened | `diagnose-blocking-and-deadlocks` |
| CPU, data or log IO, memory, worker and session limits | `diagnose-resource-pressure` |
| Capturing events over a window rather than sampling now | `capture-with-extended-events` |
| Point-in-time restore, geo-restore, long-term retention | `restore-and-recover` |
| A skill in this catalog was wrong, or the job has no skill | `skill-feedback` |

Two jobs have no skill here yet. **Running the engine locally in a container**, beyond what
`dev-container-templates` sets up: describe the job rather than naming a skill for it. **Migrating an
existing SQL Server estate onto this service**: assess compatibility before promising a target tier.

## Security, by reference

There is a first-party checklist, it is maintained, and copying it here would make a stale copy of a
living document. Read the security best practices article, and treat these four as non-negotiable:

1. **No secret in source, in a repository, or in a transcript.** An identity beats a password
   everywhere one is available.
2. **Encryption on, certificate validation on.** A certificate error is a name problem, not a trust
   problem.
3. **Least privilege.** The administrator login is not an application identity.
4. **Every statement parameterized.** Concatenating user input into T-SQL is the vulnerability an
   agent is most likely to write.

## Check it worked

This skill has done its job when three things are true, and each one is checkable.

**You are pointed at the right product.** Run the first query above. `engine_edition` must be `5`:
not 8, which is Azure SQL Managed Instance, not 12, which is SQL database in Microsoft Fabric, and
not 2 or 3, which is SQL Server. On any other value this catalog's advice is not safe to apply. Then
confirm the instance-level assumption directly, expecting the error rather than a switch:

```sql
USE master;
```

Expect `Msg 40508, USE statement is not supported to switch between databases`. If it succeeds, you
are not on Azure SQL Database and nothing above holds.

**Nothing was answered from memory.** Every capability, default or limit in your answer traces to a
page you fetched or to a query you ran, and every preview feature is labelled preview each time it
appears, not once.

**The task left this skill.** Name the skill you handed to and say why. If your answer resolved the
whole task inside this file, either it really was an orientation question, or you answered something
a neighbour owns and should not have.

## Do not

- Do not answer "is X generally available" from memory. It is the question this file exists to stop
  being answered that way.
- Do not carry a capability across the family. An announcement is about one product until a page
  says otherwise.
- Do not quote a limit, a quota or a flag value without checking it, including from help text.
- Do not answer a task another skill owns just because this file loaded first. Hand it over.
- Do not restate a stable documentation page here. Link it, and say when to read it.
- Do not treat the local container as proof about cloud behaviour, or cloud behaviour as a promise
  about the container.

## References

- Open [references/learn-pages-by-subject.md](references/learn-pages-by-subject.md) before
  answering a currency question, or whenever the honest answer is "I would be guessing". It holds
  the pinned first-party pages by subject and the four questions that decide whether a capability
  exists in this product at all.
