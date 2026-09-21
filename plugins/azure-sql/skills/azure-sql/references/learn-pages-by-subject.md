# Microsoft Learn pages for Azure SQL Database, by subject

Each entry says what the page settles, so the fetch is targeted. Links checked 2026-09-03.

## Contents

- [Deciding whether a capability exists here](#deciding-whether-a-capability-exists-here)
- [The pinned pages, by subject](#the-pinned-pages-by-subject)
- [Questions to ask the running system instead](#questions-to-ask-the-running-system-instead)
- [Reading a first-party page without inheriting its mistakes](#reading-a-first-party-page-without-inheriting-its-mistakes)

## Deciding whether a capability exists here

Four questions, in order. Stopping early is how a wrong answer gets produced.

1. **Which product is the page about?** Look at the applies-to line at the top of a page. Many pages
   in this documentation set cover several products at once, and the applies-to line is the only
   place the difference is stated. A capability that applies to a sibling engine and not to Azure SQL
   Database is not available to you.
2. **Is it generally available or preview?** Preview is called out in a note, not in the title.
   Absence of the word is not evidence of general availability on a page that has not been updated.
3. **Are there conditions?** Region, hardware family, service tier, compute tier. Preview features
   routinely land in a subset of regions and on one hardware family, and the availability page is
   separate from the feature page.
4. **What does the change history say?** The what is new article carries dated entries, and the date
   at the top of the page itself tells you how much to trust it.

If the answer is preview, say so every time it is mentioned. A design built on a preview feature is
a decision, and it should be made deliberately.

## The pinned pages, by subject

### Orientation

- The service documentation root, which is the correct place to start a subject you do not have a
  page for: <https://learn.microsoft.com/en-us/azure/azure-sql/database/>
- What is new, for dated announcements and the current preview list:
  <https://learn.microsoft.com/en-us/azure/azure-sql/database/doc-changes-updates-release-notes-whats-new>
- Features comparison across the family, which is the fastest way to check whether a capability is
  actually this product's: <https://learn.microsoft.com/en-us/azure/azure-sql/database/features-comparison>

### Tiers, sizing and limits

- vCore purchasing model and service tiers:
  <https://learn.microsoft.com/en-us/azure/azure-sql/database/service-tiers-sql-database-vcore>
- Hyperscale service tier:
  <https://learn.microsoft.com/en-us/azure/azure-sql/database/service-tier-hyperscale>
- Single database resource limits, the only current source for workers, log rate, tempdb and storage
  per compute size:
  <https://learn.microsoft.com/en-us/azure/azure-sql/database/resource-limits-vcore-single-databases>
- Elastic pool resource limits:
  <https://learn.microsoft.com/en-us/azure/azure-sql/database/resource-limits-vcore-elastic-pools>
- Serverless compute, including the auto-pause behaviour that explains a first connection failing:
  <https://learn.microsoft.com/en-us/azure/azure-sql/database/serverless-tier-overview>
- The free offer, and its FAQ, which is where the per-subscription count and the tier-change rules
  live: <https://learn.microsoft.com/en-us/azure/azure-sql/database/free-offer> and
  <https://learn.microsoft.com/en-us/azure/azure-sql/database/free-offer-faq>

### Engine behaviour

- Compatibility level, including the table of defaults per product, which is the page that settles
  the 170 question:
  <https://learn.microsoft.com/en-us/sql/t-sql/statements/alter-database-transact-sql-compatibility-level>
- Vectors, vector search and vector indexes, including which parts are preview:
  <https://learn.microsoft.com/en-us/sql/sql-server/ai/vectors>
- The vector search function reference, for current syntax:
  <https://learn.microsoft.com/en-us/sql/t-sql/functions/vector-search-transact-sql>

### Connectivity and security

- Connectivity settings, for the minimum transport version rules and the connection policy:
  <https://learn.microsoft.com/en-us/azure/azure-sql/database/connectivity-settings>
- Security best practices, the checklist this catalog refers to rather than copying:
  <https://learn.microsoft.com/en-us/azure/azure-sql/database/security-best-practice>

### Operations

- Automated backups, retention and what a restore produces:
  <https://learn.microsoft.com/en-us/azure/azure-sql/database/automated-backups-overview>

### Tooling

- The `az sql db` command reference, which is the authority for flags, and which this catalog has
  already caught disagreeing with the command's own behaviour:
  <https://learn.microsoft.com/en-us/cli/azure/sql/db>

## Questions to ask the running system instead

Fetching a page answers what is true in general. These answer what is true here, which is usually
the actual question.

| Question | Ask |
|---|---|
| What compatibility level is this database on | `SELECT name, compatibility_level FROM sys.databases;` |
| What engine version am I connected to | `SELECT @@VERSION;` |
| Which product am I connected to | `SELECT SERVERPROPERTY('EngineEdition');` 5 is Azure SQL Database and nothing else is in scope, not 2 or 3 for SQL Server, not 8 for Azure SQL Managed Instance, not 12 for SQL database in Microsoft Fabric, per Learn's SERVERPROPERTY reference |
| Which service objectives exist in this region for this tier | `az sql db list-editions -l <region> -e <tier> --query "[].supportedServiceLevelObjectives[].name" -o tsv` |
| What is this database actually running right now | `az sql db show -g <rg> -s <server> -n <database> --query "{current:currentServiceObjectiveName,requested:requestedServiceObjectiveName}"` |
| Is a long-running change still in flight | `az sql db op list -g <rg> -s <server> -d <database> -o table` |
| What does this flag really accept | Run the command with a deliberately wrong value and read the rejection, which lists the accepted set |

The last one is worth keeping. A rejection message is generated from the same metadata the service
validates against, so it is more current than the help text beside it.

## Reading a first-party page without inheriting its mistakes

Documentation is written by people and it drifts, in specific and repeatable ways. Three that this
catalog has found and verified rather than assumed:

- **Command help text can name a value the command rejects.** It has happened in this command group,
  where the documented exhaustion behaviour value for the free offer is not one the tool accepts.
- **Help text can understate a limit.** The same command's help says the free offer is allowed on one
  database in a subscription. The offer's own FAQ says ten, twice.
- **Two pages can disagree about a maximum.** The tier overview and the resource limits reference
  have carried different maximum vCore counts for the same hardware family while a preview was rolling
  out. When two first-party pages disagree, prefer the resource limits reference for numbers, prefer
  the feature page for behaviour, and say that the sources disagree rather than picking silently.

When a page and the tool disagree, the tool is the tie-breaker for what will happen, and the page is
the tie-breaker for what is supported. Those are different questions, and both answers are worth
reporting.
