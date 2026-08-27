---
name: provision-azure-sql-db
description: >-
  Creates an Azure SQL Database and returns a connection string that actually works, covering the
  free offer and paid tiers, the firewall rule, and Microsoft Entra-only administration. Use when a
  user asks to "create an Azure SQL database", "set up a free SQL database in Azure", "provision
  SQL for this app", "give me a connection string", or when an application needs a cloud database
  and none exists yet. Also use when a provisioning attempt succeeded but nothing can connect,
  which is almost always the missing firewall rule. Covers the free offer's one-per-subscription
  limit and the exhaustion behavior value the CLI accepts, which is not the one its own help text
  describes.
license: MIT
---

# Provision an Azure SQL Database

Creating the database is the easy part. The two things that go wrong are that **nothing can reach
it**, and that **the free offer is configured with a value the CLI rejects**.

Verified against Azure CLI 2.89.1 on 2026-08-27.

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

## Gotcha: the firewall is not part of database creation

`az sql db create` has **no firewall argument at all**. A plan that stops after step 3 produces a
database that exists, bills, and refuses every connection with a login timeout. This is the single
most common way an agent-generated provision fails, because the failure appears at connect time and
looks like a credentials problem.

To let other Azure services reach the server, the idiom is a rule from `0.0.0.0` to `0.0.0.0`:

```bash
az sql server firewall-rule create -g <rg> -s <server> -n allow-azure-services \
  --start-ip-address 0.0.0.0 --end-ip-address 0.0.0.0
```

That is not a wildcard for the internet. It is a documented special case meaning "Azure-internal
traffic". Opening `0.0.0.0` to `255.255.255.255` is what a wildcard would be, and it is wrong.

## Gotcha: the free offer's exhaustion value is not what the help text says

The free offer gives one database per subscription a monthly allowance. Two flags control it:

```bash
az sql db create -g <rg> -s <server> -n <database> \
  --edition GeneralPurpose --compute-model Serverless --family Gen5 --capacity 2 \
  --use-free-limit \
  --free-limit-exhaustion-behavior AutoPause
```

`--free-limit-exhaustion-behavior` accepts exactly **`AutoPause`** and **`BillOverUsage`**.

The CLI's own help text for that flag describes a value called `BillForUsage`. **That value does
not exist.** Passing it fails before any request reaches Azure:

```
ERROR: az sql db create: 'BillForUsage' is not a valid value for
'--free-limit-exhaustion-behavior'. Allowed values: AutoPause, BillOverUsage.
```

Choose deliberately:

| Value | Behaviour when the monthly allowance runs out |
|---|---|
| `AutoPause` | The database is inaccessible until the start of the next calendar month. Nothing bills |
| `BillOverUsage` | The database stays online and the overage is billed |

`AutoPause` is the safer default for a developer sandbox, and the one to pick when the user says
"free". Do not silently choose `BillOverUsage` for someone who asked for a free database.

### How many free databases, and how much

**Up to 10 free databases per subscription**, each with its own monthly allowance of **100,000
vCore seconds, 32 GB data storage and 32 GB backup storage**. The allowance is per database, not
shared, and unused vCore seconds do not carry into the next month.

**The CLI help text for `--use-free-limit` says "Allowed on one database in a subscription".** That
is the second wrong statement in this command's own documentation, and it is wrong in the direction
that makes an agent refuse work it could do. The free offer FAQ states the limit as 10, twice.

If the limit is reached, creating another fails until one is removed, and **a deleted slot takes up
to an hour to free**.

A free database cannot be created by restoring an existing one, and converting one to a paid tier
is one way: it cannot revert.

## Microsoft Entra-only administration

Passwordless is the better default, and it is set on the **server**, not the database. It needs
three flags together, and the SID is the object id of the principal rather than its name:

```bash
az sql server create -g <rg> -n <server> -l <region> \
  --enable-ad-only-auth \
  --external-admin-principal-type User \
  --external-admin-name <display name> \
  --external-admin-sid $(az ad signed-in-user show --query id -o tsv)
```

With `--enable-ad-only-auth`, `--admin-user` and `--admin-password` are not used and SQL
authentication is off. Do not pass both models and hope one wins.

## The connection string

Ask the CLI rather than assembling one by hand:

```bash
az sql db show-connection-string -c ado.net -s <server> -n <database>
```

It returns a template with `<username>` and `<password>` placeholders for you to fill from a secret
store. Two things to check in the result:

- **`Initial Catalog` names the user database, not `master`.** A string left pointing at `master`
  connects and then fails on the first real query.
- **`Encrypt=true`** stays. It is the default and it is not negotiable on Azure SQL Database.

Retry and transient-fault handling belong in the application, not here. See
`connect-to-azure-sql`.

## Checklist before reporting success

- [ ] A firewall rule exists, created by its own command
- [ ] The connection string names the user database
- [ ] If the free offer was requested, `--use-free-limit` is set and the exhaustion behavior is
      `AutoPause` or `BillOverUsage`, never `BillForUsage`
- [ ] If the user asked for passwordless, the server has `--enable-ad-only-auth` and no SQL admin
- [ ] The password, if any, went to a secret store rather than into a file or the transcript
