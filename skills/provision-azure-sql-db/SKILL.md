---
name: provision-azure-sql-db
description: >-
  Creates an Azure SQL Database and returns a connection string that actually works, covering the
  free offer and paid tiers, the firewall rule, and Microsoft Entra-only administration. Use when a
  user asks to "create an Azure SQL database", "set up a free SQL database in Azure", "provision
  SQL for this app", "give me a connection string", or when an application needs a cloud database
  and none exists yet. Also use when a provisioning attempt succeeded but nothing can connect,
  which is almost always the missing firewall rule. Covers how many free databases a subscription
  actually gets and the exhaustion behavior value the CLI accepts, which is not the one its own help
  text describes.
---

# Provision an Azure SQL Database

Creating the database is the easy part. Three things go wrong: **nothing can reach it**, **the free
offer is configured with a value the CLI rejects**, and **the free offer runs out saying nothing**.

Verified against Azure CLI **2.90.0** on 2026-09-03: every flag below was read from that CLI's own
`--help`, and the free offer numbers from the product documentation the same day.

## The shape of a working provision

Four commands, not one. A plan with fewer than four is incomplete.

```bash
# 1. resource group
az group create -n <rg> -l <region>

# 2. logical server
az sql server create -g <rg> -n <server> -l <region> \
  --admin-user <admin> --admin-password <password>

# 3. database
az sql db create -g <rg> -s <server> -n <database> \
  --edition GeneralPurpose --compute-model Serverless --family Gen5 --capacity 2

# 4. FIREWALL. Separate command. Step 3 has no flag for this.
az sql server firewall-rule create -g <rg> -s <server> -n allow-my-ip \
  --start-ip-address <your.ip> --end-ip-address <your.ip>
```

Hyperscale has its own plan and a one-way door in it: `provision-hyperscale`.

## Gotcha: the firewall is not part of database creation

`az sql db create` has **no firewall argument at all**. Confirm without provisioning anything:

```bash
az sql db create --help | grep -ci firewall     # 0
```

A plan that stops after step 3 produces a database that exists, bills, and refuses every connection
with a login timeout. It is the most common way an agent-generated provision fails, because the
failure surfaces at connect time and looks like a credentials problem.

To let other Azure services reach the server, use a rule from `0.0.0.0` to `0.0.0.0`. Both address
flags say so in their own help: "Use value '0.0.0.0' to represent all Azure-internal IP
addresses."

```bash
az sql server firewall-rule create -g <rg> -s <server> -n allow-azure-services \
  --start-ip-address 0.0.0.0 --end-ip-address 0.0.0.0
```

That is not an internet wildcard. `0.0.0.0` to `255.255.255.255` is what a wildcard would be, and
it is wrong.

## Gotcha: the free offer's exhaustion value is not what the help text says

```bash
az sql db create -g <rg> -s <server> -n <database> \
  -e GeneralPurpose -f Gen5 -c 2 --compute-model Serverless \
  --use-free-limit --free-limit-exhaustion-behavior AutoPause
```

`--free-limit-exhaustion-behavior` accepts exactly **`AutoPause`** and **`BillOverUsage`**. The
CLI's own help for that flag describes a value called `BillForUsage`. **That value does not exist**,
and passing it fails before any request reaches Azure:

```
ERROR: az sql db create: 'BillForUsage' is not a valid value for
'--free-limit-exhaustion-behavior'. Allowed values: AutoPause, BillOverUsage.
```

`AutoPause` makes the database inaccessible until the next calendar month and bills nothing.
`BillOverUsage` keeps it online, bills the overage, and **cannot be changed back**. Choose
`AutoPause` when the user says "free"; never pick `BillOverUsage` on their behalf.

### How many free databases, and the limit

**Up to 10 per subscription**, each with its own monthly **100,000 vCore seconds, 32 GB data and
32 GB backup storage**. The allowance is per database, unused seconds do not carry forward, and a
free database cannot be created by restoring an existing one.

**The CLI help for `--use-free-limit` says "Allowed on one database in a subscription".** That is
the second wrong statement in this command's own help, and it is wrong in the direction that makes
an agent refuse work it could do.

Neither number is a client-side gate. Measured with Azure Resource Graph on 2026-09-03: 47
free-limit databases across two subscriptions, one holding 39. **When free capacity is refused the
create call returns a bare HTTP 500 with no quota message**, documented nowhere on Microsoft Learn.
Read that 500 as "no free slot": drop `--use-free-limit` for an ordinary billed database, or free
one and wait, because **a deleted slot takes up to an hour** to come back.

## Microsoft Entra-only administration

Passwordless is the better default, and it is set on the **server**, not the database. It needs
three flags together, and the SID is the object id of the principal rather than its name:

```bash
az sql server create -g <rg> -n <server> -l <region> \
  --enable-ad-only-auth \
  --external-admin-principal-type User \
  --external-admin-name "<display name>" \
  --external-admin-sid $(az ad signed-in-user show --query id -o tsv)
```

With `--enable-ad-only-auth`, `--admin-user` and `--admin-password` are not used and SQL
authentication is off. Do not pass both models and hope one wins.

Those flags set the administrator and nothing else. **There is no `az` command for any other
principal**, so the plan needs a fifth step that is T-SQL, run as the administrator because only it
can create the first one: `CREATE LOGIN [<name>] FROM EXTERNAL PROVIDER` in virtual `master`, which
is what server roles attach to, or `CREATE USER [<name>] FROM EXTERNAL PROVIDER`, which reaches one
database only.

Stop there: choosing between them, granting, and diagnosing a login that still fails are all
`entra-id-auth`. Open
[Microsoft Entra server principals](https://learn.microsoft.com/azure/azure-sql/database/authentication-azure-ad-logins)
when you need the exact syntax rather than recalling it.

## The connection string

Ask the CLI rather than assembling one by hand. It runs offline and creates nothing:

```bash
az sql db show-connection-string -c ado.net -s <server> -n <database>
```

- **`Initial Catalog` names the user database, not `master`.** A string left pointing at `master`
  connects and then fails on the first real query.
- **`Encrypt=true`** stays. It is the default and it is not negotiable here.
- **`-a` cannot produce the production string.** It offers only `SqlPassword`, the default, plus
  `ADPassword` and `ADIntegrated`. A service running in Azure should use a managed identity, which
  Microsoft Learn calls the recommended method for programmatic access to SQL, so edit in
  `Authentication="Active Directory Managed Identity"`. Never hand back the `User ID` and
  `Password` template with a real password filled in.

## Check it worked

Three checks. The first two need no credential and no engine.

**One: it exists, and it is what was asked for.**

```bash
az sql db show -g <rg> -s <server> -n <database> -o yamlc \
  --query "{slo:currentServiceObjectiveName,status:status,free:useFreeLimit}"
```

Expect `slo: GP_S_Gen5_2` for the plan above, and `free: true` only if the free offer was asked
for. `status: Paused` is **not** a failure: serverless auto-pauses, and 46 of the 47 free-limit
databases visible on 2026-09-03 read `Paused`.

**Two: the firewall rule is on the server.**

```bash
az sql server firewall-rule list -g <rg> -s <server> -o table
```

Expect at least one row. An empty list is the failure this skill exists for.

**Three: you can reach it, and it is Azure SQL Database.**

```bash
export SQLCMDPASSWORD='<password>'
sqlcmd -S <server>.database.windows.net,1433 -d <database> -U <admin> -C -b -m-1 \
  -Q "SELECT CAST(SERVERPROPERTY('EngineEdition') AS int) AS engine_edition, DB_NAME() AS db;"
echo "exit $?"
```

Expect exit `0`, `engine_edition` of **`5`**, the value `SERVERPROPERTY` documents for Azure SQL
Database, and `db` equal to your database and never `master`.

Read the two failures apart. A login **timeout** with no message number is check two: the firewall
rule is missing. **`Msg 40613`**, the database is not currently available, is a paused serverless
database resuming and usually clears inside a minute, so retry. The application-side retry policy is
`connect-to-azure-sql`'s; any other number is `diagnose-connection-errors`'.

## Checklist before reporting success

- [ ] A firewall rule exists and `firewall-rule list` returns it
- [ ] `SERVERPROPERTY('EngineEdition')` returned 5 over the connection string being handed back
- [ ] The connection string names the user database and carries no password
- [ ] If free was requested, `--use-free-limit` is set and the behaviour is `AutoPause` or
      `BillOverUsage`, never `BillForUsage`
- [ ] If passwordless was requested, the server has `--enable-ad-only-auth` and no SQL admin
- [ ] Any identity beyond the administrator has a named principal and someone to create it
