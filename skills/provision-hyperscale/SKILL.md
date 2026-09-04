---
name: provision-hyperscale
description: >-
  Puts a real workload on the Hyperscale service tier of Azure SQL Database: when to choose it, how
  to size it, and how to convert an existing database without walking through a door that does not
  open again. Use when a user asks "should I use Hyperscale", "convert my database to Hyperscale",
  "we are close to the 4 TB ceiling", "how many vCores for Hyperscale", "Hyperscale serverless or
  provisioned", "add a read replica", "elastic pool for Hyperscale", or "can I go back from
  Hyperscale". Also use when a free offer database has to become a real one, because the free limit
  must be turned off before the tier can change and that step cannot be undone. Covers the
  eligibility rules for reverse migration, controlling the cutover, replica-based read scale-out,
  and what actually limits write throughput. Creating the server, the database and the firewall
  rule belongs to provision-azure-sql-db.
---

# Put a workload on Hyperscale

Choosing Hyperscale is easy. Two things go wrong: **the way you arrive decides whether you can ever
leave**, and **scaling up does not buy the throughput people expect**.

Verified on 2026-08-28 against a live Azure SQL Database logical server with Azure CLI 2.89.1, and
every flag below was re-read from Azure CLI 2.90.0 help on 2026-09-03.

Hyperscale exists in Azure SQL Database, and not in Azure SQL Managed Instance.

## What this skill does not own

| Question | Where |
|---|---|
| Creating the logical server, the database, the firewall rule, the free offer, and how many free databases a subscription gets | `provision-azure-sql-db` |
| Retry, pool sizing, connection strings, what `ApplicationIntent` means per driver | `connect-to-azure-sql` |
| A database that is already slow or already throttled | `diagnose-resource-pressure` |
| Running a restore, and why `BACKUP` and `RESTORE` T-SQL are refused on the service | `restore-and-recover` |

## The decision: is this a Hyperscale workload

The service tier comparison names Hyperscale **the recommended and default service tier for all new
and modernizing OLTP and HTAP workloads**, reversing the older advice to start on General Purpose.
That does not make it automatic. Four things decide it:

| Signal | Reading |
|---|---|
| Data over 4 TB, or growth you cannot forecast | Hyperscale. General Purpose and Business Critical stop at 4 TB; Hyperscale runs 10 GB to 128 TB |
| Backup or restore time is the problem | Hyperscale. Backups are storage snapshots, so an in-region restore takes minutes at any size. A **geo**-restore is still size-of-data |
| Read-heavy reporting beside the write workload | Hyperscale, with replicas. Up to 4 high availability replicas and up to 30 named replicas |
| Small, stable, cost-sensitive, may need to move back | Not yet. Read the next section before creating anything |

Three counter-signals that surprise people:

- **Durable and non-durable memory-optimized tables are not supported.** A database holding any
  In-Memory OLTP objects cannot be converted from Premium or Business Critical until they are
  dropped. Memory-optimized table types, table variables and natively compiled modules do come.
- **`DBCC CHECKDB` is not available.** `DBCC CHECKTABLE ('TableName') WITH TABLOCK` is the
  documented workaround.
- **Restore does not cross the tier boundary either way**: no restore into Hyperscale, and none out
  of it.

## The one-way door, which is about how you arrived

**This is the correction.** "Hyperscale is one way" is not true, and neither is "it is a tier change
like any other". The exit depends on how the database got there, and both cases were run.

| How the database got to Hyperscale | Can it leave |
|---|---|
| **Converted** from another tier | Yes, for 45 days after the conversion, to General Purpose only, single database only, 2 vCores or more, no geo-replication and no named replicas |
| **Created** as Hyperscale | **No.** Refused outright, at any age |

A converted database comes back with a plain update, which ran successfully in about nine minutes
while empty:

```bash
az sql db update -g <rg> -s <server> -n <database> \
  --edition GeneralPurpose --service-objective GP_Gen5_2 --compute-model Provisioned
```

The same command against a database **created** as Hyperscale is refused in about two seconds:

```
ERROR: (ProvisioningDisabled) Hyperscale database '<database>' is ineligible for reverse
migration. Database created as brand-new Hyperscale application.
```

**What being wrong costs.** The only route out of an ineligible database is a bacpac export and
import, which the portal, PowerShell, the Azure CLI and the REST API **do not support** for
Hyperscale, leaving a client-side tool documented to about 150 GB. If the workload might not stay,
create General Purpose and convert.

## The free offer funnel step

**The free limit must be turned off before the tier can change.** The free offer runs on General
Purpose serverless, and setting the free limit on a Hyperscale database is refused:

```
ERROR: (ProvisioningDisabled) Provisioning of free limit database is not supported for provided
service level objective or region
```

Turn the free offer off first with `--use-free-limit false`, then change the tier.

**Turning it off is permanent.** Microsoft's wording is exact: "Once you convert a free offer
database to a paid service tier, you can't revert to the free offer." Converting an existing
database *into* the free offer is unsupported too, so there is no way back. A developer who converts
a free database straight into a **newly created** Hyperscale database has closed two doors in one
afternoon. Say so before running the command.

**Two sources disagree on the cap, so quote neither.** The free offer FAQ says "There's a limit of
10 free databases per subscription"; `az sql db create --help` says `--use-free-limit` is "Allowed
on one database in a subscription". `provision-azure-sql-db` owns that count.

## Sizing

Service objectives are `HS_Gen5_<vCores>` for standard-series provisioned, `HS_S_Gen5_<vCores>` for
serverless, `HS_PRMS_<vCores>` for premium-series and `HS_MOPRMS_<vCores>` for premium-series memory
optimized. Ask the service rather than recalling the list:

```bash
az sql db list-editions -l <region> -e Hyperscale \
  --query "[].supportedServiceLevelObjectives[].{slo:name,family:sku.family}" -o table
```

### Gotcha: the hardware family names are not the ones the help text offers

`az sql db create --help` says `--family` accepts `Gen4, Gen5`. For Hyperscale the real families
include **`8IM`** (premium-series) and **`8IH`** (premium-series memory optimized). `--family PRMS`
is rejected client side, and the rejection prints the true list:

```
ERROR: Could not find sku in tier 'Hyperscale' with family 'PRMS', capacity 2.
Supported families & capacities for 'Hyperscale' are: [('Gen5', 2), ('8IM', 2), ('8IH', 2), ...]
```

Prefer `--service-objective HS_PRMS_8`, which does not depend on the spelling at all.

### Gotcha: more vCores does not buy more write throughput

The **maximum log rate is flat across every compute size** in a series. The resource limits table
reads 100 MiB/s for standard-series at 2 vCores and 100 MiB/s again at 80. Premium-series is
150 MiB/s at every size. So scaling 8 vCores to 32 changes CPU, memory, workers and local IOPS, and
changes the write ceiling **not at all**. What helps is premium-series hardware, generating less log
(batching, fewer indexes on the write path), or splitting the workload.

What does scale with vCores, on standard-series:

| Per compute size | Value |
|---|---|
| Max concurrent workers | 100 per vCore provisioned, 75 per max vCore serverless |
| Max concurrent sessions | 30,000 at every size, so never the binding limit |
| tempdb, memory, local SSD IOPS | Proportional to vCores |
| Max data size | 128 TB at every size |

Pool sizing against workers rather than sessions belongs to `connect-to-azure-sql`.

### Storage: there is no size to choose

A Hyperscale database is created with **no max size**, and `maxSizeBytes` reads `-1` after both
conversion and creation. It starts at 10 GB, grows in 10 GB steps to 128 TB, and bills for what is
allocated. The Hyperscale FAQ answers **no** to setting a hard cap on data growth, so `--max-size`
is a General Purpose habit that gives a plan a limit the tier lacks.

### Serverless or provisioned

Serverless Hyperscale is **standard-series only**; premium-series has no serverless compute tier.
Serverless suits intermittent and development workloads, provisioned steady ones. The compute tier
can change later; the exit rules above do not.

## Read scale-out is a replica count, not a switch

**The second silent failure, verified by running it.** Read scale-out follows the high availability
replica count:

```bash
# provision the replica that read-intent connections will land on
az sql db update -g <rg> -s <server> -n <database> --ha-replicas 1
```

1. `--ha-replicas 0` flips `readScale` to `Disabled` on its own; back to 1 flips it to `Enabled`.
   The replica count is the control.
2. **`--read-scale Disabled` on a Hyperscale database is accepted and does nothing.** It returns
   success and the property stays `Enabled`. The flag's help says it "is only settable for Premium
   and Business Critical databases", and on Hyperscale it fails quietly instead of erroring.
3. With zero replicas an `ApplicationIntent=ReadOnly` connection is **not** refused. Microsoft's
   wording: it "is routed to the primary replica and defaults to the `ReadWrite` behavior". The read
   offload silently does not happen and the only symptom is a busier primary.

A default conversion or creation gives **1** high availability replica, so read scale-out is on
unless someone turned it off.

### Named replicas, when reporting needs its own compute

Up to 30 per primary, each a separate read-only database with its own service objective and logins.
No data copy, so one appears in about a minute, and scaling either side does not disconnect the
other's users:

```bash
az sql db replica create -g <rg> -s <server> -n <database> --secondary-type Named \
  --partner-server <server> --partner-database <database>_reporting \
  --service-objective HS_Gen5_2
```

The same from `master`, with no Azure credentials at hand:

```sql
ALTER DATABASE [<database>]
  ADD SECONDARY ON SERVER [<server>]
  WITH (SERVICE_OBJECTIVE = 'HS_Gen5_2', SECONDARY_TYPE = Named,
        DATABASE_NAME = [<database>_reporting]);
```

A named replica has no high availability replica unless you add `--ha-replicas 1`, cannot join an
elastic pool, and blocks reverse migration while it exists.

## Converting an existing database

Two phases: a data copy while the source stays online, then a cutover. Take control of the cutover.

```bash
# 1. start the conversion, and keep the cutover in your hands
az sql db update -g <rg> -s <server> -n <database> \
  --edition Hyperscale --service-objective HS_Gen5_2 --manual-cutover

# 2. watch it. This is the only place the real state shows up
az sql db op list -g <rg> -s <server> -d <database> -o table

# 3. cut over, within 24 hours of the database being ready
az sql db update -g <rg> -s <server> -n <database> --perform-cutover
```

### Gotcha: the database reports the tier it is going to, not the one it is on

During the conversion `az sql db show` reports `sku` and `edition` as the **target**, while
`currentSku` and `currentServiceObjectiveName` still report what is running and billing:

```json
{ "edition": "Hyperscale", "requestedServiceObjectiveName": "HS_Gen5_2",
  "currentServiceObjectiveName": "GP_S_Gen5_2", "status": "Online" }
```

An agent that queries `sku` has reported success before the cutover happened. The pending manual
cutover is not in the database resource at all: `manualCutover` reads `null` throughout.

- **Billing begins only after cutover**, so waiting is not expensive, but the source switches from
  asynchronous to synchronous copying while it waits, which can raise write latency under load.
- The manual cutover window is **24 hours** from the moment the database is ready.
- Final cutover is usually **under a minute** of downtime; converting from Premium or Business
  Critical drops connections during the first phase, which retry logic covers.

### Before you start

- **Basic tier cannot convert directly.** Move to another tier first.
- **Geo-replication**: start from the primary. Converting a geo-secondary is refused, and the
  secondary converts with the primary. Reduce to one geo-secondary and remove replica chains.
- **Elastic pools**: a zone-redundant pool cannot move into one that is not. Leave the pool first.
- **Compatibility level does not change.**

## Elastic pools, briefly

Right for many small databases with uneven demand. Four rules that catch people:

- Adding a non-Hyperscale database to a Hyperscale pool **converts** it.
- A pool of another tier cannot become a Hyperscale pool, or the reverse. Create the pool you want.
- **Zone redundancy is settable only at creation**, for the pool and for the database.
- A pooled database must leave the pool before reverse migration, and the pool's log rate is one
  125 MiB/s ceiling shared by everything in it.

## Check it worked

A command that returned is not a database on Hyperscale.

**The tier the engine itself reports.** Connect to the database and ask the catalog view:

```bash
sqlcmd -S <server>.database.windows.net -d <database> -U <user> -P "$SQLCMD_PASSWORD" -Q \
  "SELECT d.name, dso.edition, dso.service_objective
   FROM sys.database_service_objectives AS dso
   JOIN sys.databases AS d ON dso.database_id = d.database_id
   WHERE d.name = DB_NAME();"
```

Expect exactly one row, `edition` reading `Hyperscale` and `service_objective` reading the objective
you asked for, `HS_Gen5_2` above. Any other edition means the cutover has not happened. From
`master` the same query returns every database on the server. Microsoft Learn says the view returns
data only on Azure SQL Database, so this is not a check to run against the local container.

**The cutover, if you asked for a manual one.** From `master`:

```bash
sqlcmd -S <server>.database.windows.net -d master -U <user> -P "$SQLCMD_PASSWORD" -Q \
  "SELECT TOP 5 operation, state_desc, phase_desc, percent_complete
   FROM sys.dm_operation_status
   WHERE major_resource_id = '<database>' ORDER BY start_time DESC;"
```

While the conversion waits, `phase_desc` reads `WaitingForCutover`; after `--perform-cutover` the
newest row's `state_desc` reads `Completed`. No rows means no recent operation, which is not a
finished one.

**Storage and replicas, which only the control plane knows:**

```bash
az sql db show -g <rg> -s <server> -n <database> --query \
  "{cur:currentServiceObjectiveName, req:requestedServiceObjectiveName, max:maxSizeBytes, ha:highAvailabilityReplicaCount, rs:readScale}" -o table
```

Expect `cur` and `req` to match, `max` to read `-1`, and `ha` to be at least `1` if anything
connects with `ApplicationIntent=ReadOnly`. `cur` different from `req` is a conversion still in
flight, whatever `edition` says.

## Do not

- Do not create a new database directly in Hyperscale for a workload that might have to move back.
- Do not call the conversion one way, or call it reversible. State which case this database is in.
- Do not turn off a free offer without saying so first. It cannot be turned back on.
- Do not use `--read-scale` on Hyperscale, and do not promise read offload at 0 replicas. Both are
  accepted, ignored, and reported by nothing.
- Do not scale vCores to fix a write ceiling before checking the log rate, and do not pass a max
  size.
- Do not report a conversion finished on the strength of the `sku` field.

## References

- Before you tell anyone a Hyperscale database can or cannot go back, open
  [references/exit-paths-and-eligibility.md](references/exit-paths-and-eligibility.md) for the full
  eligibility matrix, what repeated conversions do to restorable backups, the verified transcripts,
  and the pinned Microsoft Learn sources.

Resource limits, premium-series regional availability and the preview boundaries move. Fetch the
resource limits article rather than recalling numbers from this file.
