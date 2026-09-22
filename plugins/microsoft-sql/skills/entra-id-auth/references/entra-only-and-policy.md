# Microsoft Entra-only authentication, and enforcing it

## Contents

- [What enabling it actually does](#what-enabling-it-actually-does)
- [Order, and who is allowed to do it](#order-and-who-is-allowed-to-do-it)
- [What stops working](#what-stops-working)
- [The two Azure Policy definitions](#the-two-azure-policy-definitions)
- [Reading the policies rather than trusting a summary](#reading-the-policies-rather-than-trusting-a-summary)
- [Sources](#sources)

## What enabling it actually does

> When enabling Microsoft Entra-only authentication, SQL authentication is disabled at the server
> level and prevents any authentication based on any SQL authentication credentials.

Three consequences worth being explicit about:

- It applies to the **whole logical server**, so every database on it, and to the server
  administrator login as well.
- Existing SQL logins and users are **not removed**. New ones can still be created by an Entra
  account with the right permission. They simply cannot connect.
- Entra users with the right permission can still impersonate SQL users, and impersonation between
  SQL authentication users keeps working while the feature is on.

```bash
az sql server ad-only-auth enable -g <resource-group> -n <server>
az sql server ad-only-auth disable -g <resource-group> -n <server>
az sql server ad-only-auth get -g <resource-group> -n <server>
```

```sql
SELECT SERVERPROPERTY('IsExternalAuthenticationOnly');   -- 1 enabled, 0 disabled
```

The CLI subcommands still carry the older Active Directory naming, which is expected: the product
name changed and the identifiers deliberately did not.

## Order, and who is allowed to do it

- **The Microsoft Entra administrator must be set before enabling.** Without one the setting stays
  inactive, and enabling through the APIs fails as well.
- **The administrator cannot be removed while it is enabled.** Removing it through an API fails.
  Removing the administrator and disabling the setting together is allowed with the right
  permissions.

The Azure roles are split on purpose, and neither of the obvious SQL roles can do the whole job.

| Role | Set the Entra administrator | Toggle Entra-only |
|---|---|---|
| `SQL Server Contributor` | Yes | No |
| `SQL Security Manager` | No | Yes |
| `Contributor`, `Owner` | Yes | Yes |

The rationale is separation of duties: a role that can create a server or set an administrator
should not also be able to turn a security control off. The actions behind the setting are
`Microsoft.Sql/servers/azureADOnlyAuthentications/*`, plus
`Microsoft.Sql/servers/administrators/read` for anyone who needs to see it in the resource pages.

## What stops working

In Azure SQL Database, with Entra-only authentication on:

- Elastic jobs
- SQL Data Sync
- SQL Insights
- `EXEC AS` for Microsoft Entra group member accounts
- Change data capture across the boundary: a database created by an Entra user has CDC artifacts a
  SQL user cannot change, and the reverse holds too
- Transactional replication into the database, because that path requires SQL authentication between
  participants

Check this list against what already runs on the server. Nothing warns at enable time.

## The two Azure Policy definitions

Both are built in, both default to the `Audit` effect, and both accept `Audit`, `Deny` and
`Disabled`. Read on 2026-08-27 from the live definitions.

| Display name | Definition id | Evaluates |
|---|---|---|
| `Azure SQL logical servers should have Microsoft Entra-only authentication enabled during creation` | `abda6d70-9778-44e7-84a8-06713e6db027` | `Microsoft.Sql/servers` at create time |
| `Azure SQL Database should have Microsoft Entra-only authentication enabled` | `b3a22bc9-66de-45fb-98fa-00f5df42f41a` | `Microsoft.Sql/servers/azureADOnlyAuthentications` on an existing server |

Their own descriptions say why one is not enough:

> Require Azure SQL logical servers to be created with Microsoft Entra-only authentication. This
> policy doesn't block local authentication from being re-enabled on resources after create.

> Require Azure SQL logical servers to use Microsoft Entra-only authentication. This policy doesn't
> block servers from being created with local authentication enabled. It does block local
> authentication from being enabled on resources after create.

Both then say: "Consider using the 'Microsoft Entra-only authentication' initiative instead to
require both."

The initiative is **`Azure SQL Database should have Microsoft Entra-only authentication`**,
`a55e4a7e-1b9c-43ef-b4b3-642f303804d6`, and it contains exactly those two definitions.

Two details the definitions carry that a summary loses:

- The creation-time policy **exempts a server whose `createMode` is `Restore`**, so a restored
  server can arrive non-compliant without the assignment complaining at create time.
- Both exclude servers whose resource group is managed by the analytics workspace provider.

A server can be created already compliant, and the administrator set in the same call:

```bash
az sql server create -g <resource-group> -n <server> -l <location> \
  --enable-ad-only-auth \
  --external-admin-principal-type User \
  --external-admin-name "<display name>" \
  --external-admin-sid <object-id>
```

## Reading the policies rather than trusting a summary

The published article about these policies is older than the definitions and still names them with
the previous product wording, and it describes two definitions where the live catalog carries a
create-time and a steady-state pair per product plus an initiative. Reading the live definitions is
one command and settles it:

```bash
az policy definition list \
  --query "[?displayName!=null && contains(displayName, 'Entra-only authentication')].{display:displayName, id:name, allowed:parameters.effect.allowedValues, def:parameters.effect.defaultValue}" \
  -o json

az policy set-definition list \
  --query "[?displayName!=null && contains(displayName, 'Entra-only')].{display:displayName, id:name}" \
  -o json
```

Do the same before quoting a policy name in a plan. The names in this file were read that way, not
recalled, and they should be re-read rather than trusted after a few months.

## Sources

- Microsoft Entra-only authentication with Azure SQL: `/azure/azure-sql/database/authentication-azure-ad-only-authentication`, which carries the feature description, the permission split and the unsupported feature list.
- Azure Policy for Microsoft Entra-only authentication: `/azure/azure-sql/database/authentication-azure-ad-only-authentication-policy`, which carries the effects and the compliance behaviour, and whose policy names are behind the live catalog.
- The live definitions, read with Azure CLI 2.89.1 on 2026-08-27.
