---
name: restore-and-recover
description: >-
  Recovers an Azure SQL Database after data loss, an accidental drop or a bad deployment, using
  point-in-time restore, geo-restore and long-term retention. Use when someone asks to "restore
  my Azure SQL database", "undo a dropped table or database", "roll back to before this migration
  ran", "recover from a region outage", or asks for RESTORE DATABASE or BACKUP DATABASE syntax.
  There is no backup or restore T-SQL here: BACKUP DATABASE, RESTORE DATABASE and every RESTORE
  ... ONLY variant are refused, and restoring is a control plane operation. Every restore creates
  a new database beside the one being recovered rather than overwriting it, so this covers the
  restore type and the rename or connection swap back. Not a schema rollback
  (schema-migrations-safely), not a logical export or import (sqlpackage-import-export), not
  creating it (provision-azure-sql-db).
---

# Recover an Azure SQL Database

Engine behaviour measured 2026-08-29 and 2026-09-03 against an engine reporting
`SERVERPROPERTY('EngineEdition')` 5, Edition `SQL Azure`, `ProductVersion` 12.0.2000.8. Every command line was taken on 2026-09-03 from
the help output of `az` 2.90.0 and SqlPackage 170.4.83.3 on this machine; the scope and retention
limits come from the Microsoft Learn pages in References. The restores need a real logical
server and were not run, so resource names are placeholders.

## The correction

Asked to recover an Azure SQL Database, an agent trained on the boxed engine reaches for
`RESTORE DATABASE ... WITH REPLACE`, `BACKUP DATABASE`, `RESTORE HEADERONLY` or
`ALTER DATABASE ... SET RECOVERY`. None of that surface exists here. Learn is blunt: you recover
using the portal, PowerShell, the Azure CLI or the REST API, and you can't use Transact-SQL. The
second wrong belief compounds the first. Learn again: **you can't overwrite an existing database
during restore.** Every restore creates a new database under the name you pass, and moving it to
where the application connects is a step you perform yourself. Nothing warns you if you skip it,
so the failure surfaces later as a connection error blamed on the application.

## 1. There is no restore T-SQL, measured

| Written from habit | What happens here |
|---|---|
| `RESTORE DATABASE db FROM DISK = '...' WITH REPLACE` | `Msg 40510`, not supported |
| `BACKUP DATABASE db TO DISK = '...'` or `TO URL = '...'` | `Msg 40510`, not supported |
| `BACKUP LOG db TO DISK = '...'` | `Msg 40510`, not supported |
| `RESTORE HEADERONLY` / `FILELISTONLY` / `VERIFYONLY` | `Msg 40510`, and the text names `RESTORE VOLUME` |
| `EXEC sys.sp_get_database_backup_policy` | `Msg 2812`, could not find stored procedure |
| `ALTER DATABASE db SET RECOVERY FULL` / `SIMPLE` | `Msg 40517`, keyword or option not supported |

There is no exception in this family, and the two numbers are the parser's own distinction:
`Msg 40510` rejects a whole statement, `Msg 40517` rejects one option of a statement that is
otherwise supported, which is why `ALTER DATABASE` still renames a database in section 5. Every
row is a signal the agent is solving the wrong problem.

## 2. Find the restore point before you name it

`--time` must be at or after the source's `earliestRestoreDate`, so read it:

```bash
az sql db show --resource-group <rg> --server <server> --name <database> \
  --query earliestRestoreDate --output tsv
```

A dropped database is not in `az sql db show` at all. It is a separate resource carrying the
deletion timestamp you need, and its `name` is a composite, so read `databaseName`:

```bash
az sql db list-deleted --resource-group <rg> --server <server> \
  --query "[].{db:databaseName, deleted:deletionDate, earliest:earliestRestoreDate}" \
  --output table
```

## 3. Three restores, three commands, and they do not have the same reach

Point-in-time, into a new name on the same server. Pass the source's own tier so the copy can
stand in for it:

```bash
az sql db restore --resource-group <rg> --server <server> --name <database> \
  --dest-name <database>-restored --time "2026-09-02T14:30:00" \
  --edition GeneralPurpose --service-objective GP_Gen5_2 --backup-storage-redundancy Geo
```

A dropped database uses the same command with `--deleted-time` in place of, or alongside, `--time`,
matching `deletionDate` from the listing above exactly:

```bash
az sql db restore --resource-group <rg> --server <server> --name <dropped-database> \
  --dest-name <dropped-database>-recovered --deleted-time "2026-09-02T09:12:41"
```

Geo-restore is a different command, and the backup is addressed by resource id:

```bash
az sql db geo-backup list --resource-group <rg> --server <server> --output table

az sql db geo-backup restore --geo-backup-id <geo-backup-resource-id> \
  --dest-database <database> --dest-server <server-in-recovery-region> \
  --resource-group <target-rg>
```

Long-term retention is a third command, with backup ids listed per region:

```bash
az sql db ltr-backup list --location <region> --server <server> --database <database> \
  --output table

az sql db ltr-backup restore --backup-id <ltr-backup-resource-id> \
  --dest-database <database> --dest-server <server> --dest-resource-group <rg>
```

Pick by reach, not by habit. The rows are Learn's, and the wrong choice wastes a restore rather
than taking a slower route:

| Restore | Where it can land | What has to be true already |
|---|---|---|
| Point-in-time | the same server only, no cross-server, cross-subscription or cross-region | inside the retention window; the source is a primary, not a geo-secondary |
| Deleted database | the same server only | the server still exists; deleting a server deletes its databases and their backups together |
| Geo-restore | any server in any region, same subscription | backup storage redundancy was already `Geo` or `GeoZone`; it is not retroactive |
| Long-term retention | any server, and it outlives the source server | an LTR policy existed before the point you want |

So if the logical server itself was deleted, long-term retention is the only route left. Restoring
across the Hyperscale boundary, in either direction, is not supported at all.

## 4. Retention is a setting, and the default is seven days

Both windows are set per database:

```bash
az sql db str-policy set --resource-group <rg> --server <server> --name <database> \
  --retention-days 35 --diffbackup-hours 12

az sql db ltr-policy set --resource-group <rg> --server <server> --name <database> \
  --weekly-retention P4W --monthly-retention P12M --yearly-retention P10Y --week-of-year 1
```

Short-term retention defaults to 7 days and takes 1 to 35, except DTU Basic which takes 1 to 7.
`--diffbackup-hours` accepts only 12 or 24. Each long-term retention value takes a minimum of 7
days and a maximum of 10 years, and `--week-of-year` is 1 to 52. Those bounds are in both
the CLI's own help and the Learn pages below.

## 5. The swap nobody automates

The restore leaves two databases: the broken one and the new one holding the data. Learn names the
rename as the way to finish it. In T-SQL, measured on the engine above:

```sql
ALTER DATABASE [app-db] MODIFY NAME = [app-db-broken];
ALTER DATABASE [app-db-restored] MODIFY NAME = [app-db];
```

Or the same swap from the control plane, which still works when nothing can connect to run T-SQL:

```bash
az sql db rename --resource-group <rg> --server <server> --name <database> \
  --new-name <database>-broken
az sql db rename --resource-group <rg> --server <server> --name <database>-restored \
  --new-name <database>
```

Either way it is a cutover with a brief gap: pooled connections against the old name fail or
reconnect depending on the driver. The alternative is to repoint the connection string and rename
nothing, which has no gap but means finding every hardcoded copy of the database name, migration
tooling included.

## 6. Getting recovered data out of the subscription

Point-in-time restore is same-server and geo-restore is same-subscription, so neither reaches
another subscription or a workstation. Exporting the restored database is the only route out:

```bash
sqlpackage /Action:Export /TargetFile:recovered.bacpac \
  /SourceServerName:<server>.database.windows.net /SourceDatabaseName:<database>-restored \
  /SourceUser:<user> /SourcePassword:"$SQLPACKAGE_PASSWORD" /p:VerifyExtraction=true
```

A bacpac is a logical copy of one moment, not a restore point. It cannot recover anything the
retention window has already dropped; it only moves what a restore already produced.

## Check it worked

A restore command returning is not a recovered database.

The database exists and is serving:

```bash
az sql db show --resource-group <rg> --server <server> --name <database>-restored \
  --query "{name:name, status:status, sku:sku.name, tags:tags}" --output table
```

Expect `status` `Online`. Expect empty tags even on a healthy restore: Learn states a restore does
not carry the source's tags, so their absence is not a failure.

The rows are the rows you wanted, which the control plane cannot tell you. Run this against the
restored name and again against the name the application uses, after the swap in section 5:

```bash
sqlcmd -S <server>.database.windows.net -d <database>-restored -U <user> \
  -P "$SQLCMD_PASSWORD" -Q "SELECT DB_NAME() AS connected_to,
  SUM(p.rows) AS row_count, COUNT(DISTINCT t.object_id) AS table_count
FROM sys.tables AS t JOIN sys.partitions AS p
  ON p.object_id = t.object_id AND p.index_id IN (0, 1);"
```

Equal counts across the two names, or a stated reason they differ, is the check. A restore to a
point before a bad backfill is expected to differ, and you should be able to say by how much. Until
the second run returns the restored data, the recovery is not finished.

## Do not

- Do not write `RESTORE DATABASE`, `BACKUP DATABASE`, any `RESTORE ... ONLY` variant, or
  `SET RECOVERY` as the recovery step. All of them are refused, measured.
- Do not say a restore updates the existing database. Learn says outright that you can't overwrite
  an existing database during restore.
- Do not stop when the restored database exists. The rename or connection string swap is part of
  the recovery.
- Do not promise a geo-restore carries firewall rules, the Microsoft Entra administrator, or server
  level logins to a different logical server. Those are server scoped, contained users are not, and
  none of it was verified here.
- Do not quote a fixed geo-restore RPO or RTO. Learn's figures for this service are "typically
  minutes or hours", dependent on storage replication and backup size; a fixed pair of hours comes
  from a different product's page.
- Do not size the target casually. Learn notes a restore may need S3 or above, which you can scale
  back down once it finishes.

## References

- [references/backup-restore-tsql-errors.md](references/backup-restore-tsql-errors.md): open before
  restating any error number here as measured, or when an engine answers differently from the
  table in section 1.
- [Recover using automated database backups](https://learn.microsoft.com/azure/azure-sql/database/recovery-using-backups):
  read it before a restore that crosses a server, a subscription or a region; it is where the scope
  limits in section 3 come from.
- [Automated backups](https://learn.microsoft.com/azure/azure-sql/database/automated-backups-overview):
  read it when you need retention defaults or backup storage redundancy options.
- [Long-term retention](https://learn.microsoft.com/azure/azure-sql/database/long-term-retention-overview):
  read it before promising a restore point older than the short-term window.
- [Business continuity overview](https://learn.microsoft.com/azure/azure-sql/database/business-continuity-high-availability-disaster-recover-hadr-overview):
  read it when the requirement is near zero downtime, which failover groups and active
  geo-replication solve and restore does not.
- `provision-azure-sql-db`: creating a database and its firewall rule in the first place.
- `provision-hyperscale`: Hyperscale restore mechanics, which differ from the general case here.
- `schema-migrations-safely`: rolling back a bad schema change without touching data.
- `sqlpackage-import-export`: the full bacpac and dacpac surface behind the one command above.
