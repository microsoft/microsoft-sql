# Leaving Hyperscale: eligibility, backups, and what was actually run

## Contents

- [How to use this file](#how-to-use-this-file)
- [The eligibility matrix](#the-eligibility-matrix)
- [What the service says when it refuses](#what-the-service-says-when-it-refuses)
- [What happens to backups across repeated moves](#what-happens-to-backups-across-repeated-moves)
- [The bacpac fallback, and its real limits](#the-bacpac-fallback-and-its-real-limits)
- [Verified transcript](#verified-transcript)
- [Sources](#sources)

## How to use this file

Read it before answering "can we go back". The answer is not a property of Hyperscale. It is a
property of the individual database, and the deciding fact is how that database arrived.

## The eligibility matrix

Every row has to be true at once. One false row means reverse migration is refused, and the refusal
happens before anything starts.

| Condition | Required for reverse migration |
|---|---|
| Origin | The database was **converted** from another service tier. One created as Hyperscale is never eligible |
| Age | Within **45 days** of the original conversion to Hyperscale |
| Target tier | **General Purpose only**. Provisioned or serverless compute, either is allowed |
| Target size | **2 vCores or more**. Scale below that only after the move completes |
| Elastic pool | Not in a pool, on either side. Remove the database from the Hyperscale pool first |
| Geo-replication | Not enabled |
| Named replicas | None |
| Allocated size | Small enough to fit the target service objective, and inside `--max-size` if one is given |

To reach Business Critical or a DTU tier, reverse migrate to General Purpose first, then change tier
again.

Duration is a size-of-data operation, not a metadata switch. It depends on database size, on write
activity during the move, and on the vCores given to the target, which should be at least the vCores
the Hyperscale database had. The source can be throttled on transaction log rate while the move
progresses. Final cutover is a few minutes of downtime.

## What the service says when it refuses

Verbatim, from a live attempt on 2026-08-28:

```
ERROR: (ProvisioningDisabled) Hyperscale database '<database>' is ineligible for reverse migration.
Database created as brand-new Hyperscale application.
```

The database name is the only thing elided. The message names the reason, which is worth reading
rather than retrying. "Created as brand-new Hyperscale application" is the origin rule, and no wait,
flag or support request changes it.

The free offer refusal, from the same session, is a different message with a similar shape:

```
ERROR: (ProvisioningDisabled) Provisioning of free limit database is not supported for provided
service level objective or region
```

That one is about the combination, not about a permission. The free offer runs on General Purpose
serverless, so the free limit and Hyperscale cannot both be set.

## What happens to backups across repeated moves

This is the part that gets discovered late. Only the backups of the **current** and the
**immediately previous** tier of a database are available for restore.

Microsoft's own worked example: General Purpose, convert to Hyperscale, reverse migrate to General
Purpose, change to Business Critical, convert to Hyperscale, reverse migrate to General Purpose. At
the end, only the backups from the last two steps exist. Everything earlier is gone, and it is gone
**as soon as a reverse migration starts**, and stays gone even if that migration is cancelled.

Two consequences:

- Repeated experimentation between tiers quietly destroys restore points. Do the experiment on a
  copy.
- Pre-migration backups taken before the move to Hyperscale live for the source database's retention
  period and can be restored to any tier that is not Hyperscale, from the command line. That is a
  real, time-limited safety net, and it is separate from the 45-day reverse migration window.

Also note the tier boundary in restore: a database that is not Hyperscale cannot be restored **as**
Hyperscale, and a Hyperscale database cannot be restored as anything else.

## The bacpac fallback, and its real limits

For a database that does not qualify, the documented route out is export and import, and the
documentation is unusually blunt about the gaps:

- bacpac export and import for Hyperscale is **not supported** from the portal, from PowerShell's
  export and import cmdlets, from the Azure CLI export and import commands, or from the REST API.
- It **is** supported from a client-side tool and the SqlPackage command line, version 18.4 or
  later, for databases **up to about 150 GB**.
- Above that, the documentation says the operation might take a long time and can fail for various
  reasons.

Other data movement paths exist, bulk copy and pipeline tooling among them, and they are the
realistic answer for a large database. None of them is a tier change, and all of them mean a new
database and a cutover of their own. Plan for that rather than discovering it.

## Verified transcript

Run on 2026-08-28 with Azure CLI 2.89.1 against a throwaway logical server, then deleted. Summarised
rather than pasted, because the values were environment specific.

| Step | Command | Result |
|---|---|---|
| Create General Purpose serverless | `az sql db create ... --edition GeneralPurpose --compute-model Serverless --family Gen5 --capacity 2` | Online, `GP_S_Gen5_2`, max size 32 GB |
| Convert with manual cutover | `az sql db update ... --edition Hyperscale --service-objective HS_Gen5_2 --manual-cutover` | Operation `InProgress` at 50 percent, `currentServiceObjectiveName` still `GP_S_Gen5_2`, `sku` already `HS_Gen5` |
| Cut over | `az sql db update ... --perform-cutover` | `HS_Gen5_2`, `highAvailabilityReplicaCount` 1, `readScale` Enabled, `maxSizeBytes` -1 |
| Try the free limit on it | `az sql db update ... --use-free-limit true` | Refused, `ProvisioningDisabled` |
| Try to disable read scale-out | `az sql db update ... --read-scale Disabled` | Accepted, and `readScale` stayed `Enabled` |
| Remove the replica | `az sql db update ... --ha-replicas 0` | `readScale` became `Disabled` on its own |
| Reverse migrate | `az sql db update ... --edition GeneralPurpose --service-objective GP_Gen5_2 --compute-model Provisioned` | Succeeded in about nine minutes, max size back to 1 TB |
| Create one directly as Hyperscale | `az sql db create ... --edition Hyperscale --family Gen5 --capacity 2` | Online in about six minutes, replica count 1, max size -1 |
| Reverse migrate that one | same update command | Refused in about two seconds |
| Premium-series family | `--family PRMS` rejected client side, `--family 8IM` created `HS_PRMS_2` | The help text's `Gen4, Gen5` is not the whole list |

## Sources

Fetch these rather than trusting the summary above, which carries a verification date for a reason.

- Convert a database to Hyperscale:
  <https://learn.microsoft.com/en-us/azure/azure-sql/database/convert-to-hyperscale>
- Reverse migrate from Hyperscale, including the eligibility list and the backup rules:
  <https://learn.microsoft.com/en-us/azure/azure-sql/database/reverse-migrate-from-hyperscale>
- Free offer FAQ, for the tier-change step and the fact it cannot be undone:
  <https://learn.microsoft.com/en-us/azure/azure-sql/database/free-offer-faq>
- Hyperscale service tier, for capabilities, replica counts and current limitations:
  <https://learn.microsoft.com/en-us/azure/azure-sql/database/service-tier-hyperscale>
- Hyperscale secondary replicas, for read scale-out behaviour and named replicas:
  <https://learn.microsoft.com/en-us/azure/azure-sql/database/service-tier-hyperscale-replicas>
- Single database vCore resource limits, for log rate, workers and tempdb per compute size:
  <https://learn.microsoft.com/en-us/azure/azure-sql/database/resource-limits-vcore-single-databases>
- Hyperscale elastic pools:
  <https://learn.microsoft.com/en-us/azure/azure-sql/database/hyperscale-elastic-pool-overview>
