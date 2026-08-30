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

Choosing Hyperscale is easy. The two things that go wrong are that **the way you arrive decides
whether you can ever leave**, and that **scaling up does not buy the throughput people expect**.

Verified against Azure CLI 2.89.1 and a live Azure SQL Database logical server on 2026-08-28. Every
command and error message below was run, not recalled.

Hyperscale exists in Azure SQL Database, and not in Azure SQL Managed Instance.

## What this skill owns, and what it does not

**Owns**: the decision to use Hyperscale, sizing it, converting an existing database, controlling
the cutover, read scale-out through replicas, and the exit paths.

**Does not own.** Send these elsewhere:

| Question | Where |
|---|---|
| Creating the logical server, the database, the firewall rule, the free offer itself | `provision-azure-sql-db` |
| Retry, pool sizing, connection strings, and what `ApplicationIntent` means in each driver | `connect-to-azure-sql` |
| A database that is already slow or already throttled | No skill is installed for this yet. Capture waits and the plan before changing the tier |
| Restore, point-in-time recovery, backup retention | No skill is installed for this yet. Read the automated backups article before promising a restore |

## The decision: is this a Hyperscale workload

As of 2026-08-28 the service tier documentation names Hyperscale **the recommended and default
service tier for new and modernizing OLTP and HTAP workloads**, which is a reversal of the older
advice to start on General Purpose. That does not make it automatic. Four things decide it:

| Signal | Reading |
|---|---|
| Data over 4 TB, or growth you cannot forecast | Hyperscale. General Purpose and Business Critical stop at 4 TB; Hyperscale grows to 128 TB with no max size chosen up front |
| Backup or restore time is the problem | Hyperscale. Backups are file-snapshot based, so they do not scale with data volume |
| Read-heavy reporting alongside the write workload | Hyperscale, with replicas. Up to 4 high availability replicas and up to 30 named replicas |
| Small, stable, cost-sensitive, and may need to move back later | Not yet. Read the next section before creating anything |

Two counter-signals worth stating plainly, because they surprise people:

- **In-memory OLTP tables do not come with you.** Durable and non-durable memory-optimized tables
  are not supported, and a database containing In-Memory OLTP objects cannot be converted from
  Premium or Business Critical until those objects are dropped.
- **`DBCC CHECKDB` is not available** on Hyperscale. `DBCC CHECKTABLE ('TableName') WITH TABLOCK` is
  the documented workaround.

## The one-way door, which is about how you arrived

**This is the correction.** "Hyperscale is one way" is not true, and neither is "it is a tier change
like any other". The exit depends on how the database got there, and the difference was verified by
running both.

| How the database got to Hyperscale | Can it leave |
|---|---|
| **Converted** from another tier | Yes, for 45 days after the conversion, to General Purpose only, single database only, 2 vCores or more, no geo-replication and no named replicas |
| **Created** as Hyperscale | **No.** Refused outright, at any age |

A database that was converted comes back with a plain update. This ran successfully against a
converted database and took about nine minutes while empty:

```bash
az sql db update -g <rg> -s <server> -n <database> \
  --edition GeneralPurpose --service-objective GP_Gen5_2 --compute-model Provisioned
```

The same command against a database that was **created** as Hyperscale is refused in about two
seconds, before anything happens:

```
ERROR: (ProvisioningDisabled) Hyperscale database '<database>' is ineligible for reverse
migration. Database created as brand-new Hyperscale application.
```

**What being wrong here costs.** For an ineligible database the only route to a non-Hyperscale tier
is a bacpac export and import, and Microsoft documents that the portal, PowerShell, the Azure CLI
and the REST API **do not support** bacpac export or import for Hyperscale. That leaves a
client-side tool, documented as supported up to about 150 GB, with larger databases described as
slow and prone to failing. So the choice between "create it as Hyperscale" and "create it as
General Purpose and convert" is not a matter of taste. It decides whether an exit exists at all.

If the workload might not stay, create General Purpose and convert. The conversion is fast and the
45-day window then exists.

## The free offer funnel step

Both halves are true, and each was checked separately.

**First half: the free limit must be turned off before the tier can change.** The free offer runs on
General Purpose serverless. Attempting to put the free limit on a Hyperscale database is refused by
the service:

```
ERROR: (ProvisioningDisabled) Provisioning of free limit database is not supported for provided
service level objective or region
```

The documented path is to turn the free offer off first, then change the tier. On the command line
that is `--use-free-limit false`, and the portal exposes the same switch under compute and storage.

**Second half: turning it off is permanent.** Microsoft's wording is exact: "Once you convert a
free offer database to a paid service tier, you can't revert to the free offer." Combined with the
section above, a developer who converts a free database straight into a **newly created**
Hyperscale database has closed two doors in one afternoon.

Say this out loud before running the command. An agent that turns off a free offer without telling
anyone has spent someone's free tier for them.

## Sizing

Service objectives are `HS_Gen5_<vCores>` for standard-series provisioned, `HS_S_Gen5_<vCores>` for
serverless, `HS_PRMS_<vCores>` for premium-series and `HS_MOPRMS_<vCores>` for premium-series memory
optimized. Ask the service rather than recalling the list:

```bash
az sql db list-editions -l <region> -e Hyperscale \
  --query "[].supportedServiceLevelObjectives[].{slo:name,family:sku.family}" -o table
```

### Gotcha: the hardware family names are not the ones the help text offers

`az sql db create --help` lists `--family` as accepting `Gen4, Gen5`. For Hyperscale the real
families include **`8IM`** for premium-series and **`8IH`** for premium-series memory optimized.
`--family PRMS` is rejected client side, and the rejection prints the true list:

```
ERROR: Could not find sku in tier 'Hyperscale' with family 'PRMS', capacity 2.
Supported families & capacities for 'Hyperscale' are: [('Gen5', 2), ('8IM', 2), ('8IH', 2), ...]
```

Prefer `--service-objective HS_PRMS_8`, which says what you mean without depending on the family
spelling.

### Gotcha: more vCores does not buy more write throughput

The **maximum log rate is flat across every compute size** in a series. Standard-series is
100 MiB/s at 2 vCores and still 100 MiB/s at 80. Premium-series is 150 MiB/s at every size.

So for a write-bound workload, scaling from 8 vCores to 32 changes CPU, memory, workers and local
IOPS, and changes the write ceiling **not at all**. The moves that do help are premium-series
hardware, reducing log generation (batching, fewer indexes on the write path, minimal logging where
it applies), or splitting the workload. Scaling up first and measuring later is the expensive order.

What does scale with vCores, on standard-series:

| Per compute size | Value |
|---|---|
| Max concurrent workers | 100 per vCore provisioned, 75 per max vCore serverless |
| Max concurrent sessions | 30,000 at every size, so never the binding limit |
| tempdb, memory, local SSD IOPS | Proportional to vCores |
| Max data size | 128 TB at every size |

Pool sizing against workers rather than sessions belongs to `connect-to-azure-sql`, and the
arithmetic there applies unchanged here.

### Storage: there is no size to choose

A Hyperscale database is created with **no max size**. Confirmed on a live database, where
`maxSizeBytes` reads `-1` after conversion and after creation. Storage grows on its own between
10 GB and 128 TB and you are billed for what is allocated. Passing `--max-size` is a General Purpose
habit; carrying it into a Hyperscale command is how a plan acquires a limit the tier does not have.

### Serverless or provisioned

Serverless Hyperscale is **standard-series only**. Premium-series and premium-series memory
optimized do not offer a serverless compute tier. Choose serverless for intermittent and
development workloads, provisioned for steady ones. The compute tier can change later; the exit
rules in this file do not change with it.

## Read scale-out is a replica count, not a switch

**This is the second silent failure, and it was verified by running it.**

On Hyperscale, read scale-out follows the high availability replica count:

```bash
# provision the replica that read-intent connections will land on
az sql db update -g <rg> -s <server> -n <database> --ha-replicas 1
```

Three facts that fit together:

1. Setting `--ha-replicas 0` flips the database's `readScale` property to `Disabled` on its own.
   Setting it back to 1 flips it to `Enabled`. The replica count is the control.
2. **`--read-scale Disabled` on a Hyperscale database is accepted and does nothing.** The command
   returns success and the property stays `Enabled`. The flag's own help text says it is only
   settable for Premium and Business Critical, and on Hyperscale it fails quietly instead of
   erroring.
3. With zero replicas, an application that sets `ApplicationIntent=ReadOnly` is **not** refused.
   Microsoft's wording: the connection "is routed to the primary replica and defaults to the
   `ReadWrite` behavior". The read offload silently does not happen, and the only symptom is that
   the primary is busier than the architecture diagram says it should be.

A default conversion or creation gives **1** high availability replica, so read scale-out is on
unless someone turned it off. Named replicas, up to 30, are separate resources with their own
service objective, and they are the right answer when a reporting workload needs its own compute.

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

During the conversion, `az sql db show` reports `sku` and `edition` as the **target**, while
`currentSku` and `currentServiceObjectiveName` still report what is running and billing. Observed
mid-conversion on a live database:

```json
{ "edition": "Hyperscale", "requestedServiceObjectiveName": "HS_Gen5_2",
  "currentServiceObjectiveName": "GP_S_Gen5_2", "status": "Online" }
```

An agent that queries `sku` and reports success has reported success before the cutover happened.
**Read `currentServiceObjectiveName`, or read the operation list.** The pending manual cutover is
not visible in the database resource at all: `manualCutover` reads `null` throughout.

Three more facts about the cutover:

- **Billing for Hyperscale begins only after cutover**, so a conversion left waiting is not
  expensive, but the source database does switch from asynchronous to synchronous copying while it
  waits, which can raise write latency under load.
- The manual cutover window is **24 hours** from the moment the database is ready.
- The final cutover is usually **under a minute** of downtime, and converting from Premium or
  Business Critical drops existing connections during the first phase. Retry logic covers this.

### Before you start a conversion

- **Basic tier cannot convert directly.** Move to another tier first, then convert.
- **Geo-replication**: start from the primary. Converting a geo-secondary is refused, and the
  secondary converts with it. Reduce to a single geo-secondary first, and remove replica chains.
- **Elastic pools**: a zone-redundant pool cannot move directly into a pool that is not
  zone-redundant. Take the database out of the pool first.
- **Compatibility level does not change.** A converted database keeps the level it had.

## Elastic pools, briefly

Hyperscale elastic pools exist and are the right shape for many small databases with uneven demand.
Four rules that catch people:

- Adding a database that is not Hyperscale to a Hyperscale pool **converts** it.
- An existing pool of another tier cannot be changed into a Hyperscale pool, and the reverse is also
  unsupported. Create the pool you want.
- **Zone redundancy can only be set when the pool or database is created.** It cannot be changed
  afterwards.
- A named replica cannot be added to a pool, and a database in a pool must be removed from it before
  reverse migration.

## Validation rules

- The exit path was decided before creation, and stated: converted keeps a 45-day return to General
  Purpose, created as Hyperscale keeps none.
- A free offer database had its free limit turned off deliberately, with the user told that the free
  offer cannot be reclaimed.
- The service objective came from `az sql db list-editions` or from the resource limits page, not
  from memory.
- No `--max-size` was passed to a Hyperscale database.
- Write throughput expectations were set against the log rate for the series, not against vCores.
- Read scale-out was configured with `--ha-replicas`, and the replica count is at least 1 if any
  connection sets `ApplicationIntent=ReadOnly`.
- A conversion was confirmed with `currentServiceObjectiveName` or the operation list, after cutover.

## Do not

- Do not create a new database directly in Hyperscale for a workload that might have to move back.
  That is the door that does not reopen.
- Do not describe the conversion as one way, and do not describe it as reversible. State which of
  the two cases the database is in.
- Do not turn off a free offer without saying so first. It cannot be turned back on.
- Do not use `--read-scale` to control read scale-out on Hyperscale. It is accepted and ignored.
- Do not promise read offload while the replica count is 0. Read-intent connections land on the
  primary and nothing reports the problem.
- Do not scale vCores to fix a write-throughput ceiling before checking the log rate.
- Do not pass a max size, and do not carry a General Purpose sizing template into a Hyperscale
  command.
- Do not report a conversion as finished on the strength of the `sku` field.
- Do not plan a bacpac as the fallback exit without checking the tooling limits first.

## References

- [references/exit-paths-and-eligibility.md](references/exit-paths-and-eligibility.md): the full
  reverse migration eligibility matrix, what happens to backups across repeated conversions, the
  verified command transcripts, and the pinned sources. Read it before telling anyone a Hyperscale
  database can or cannot go back.

Resource limits, regional availability of premium-series and the current preview boundaries move.
Fetch the resource limits article and the Hyperscale service tier article rather than recalling
numbers from this file, which states the date it was verified for exactly that reason.
