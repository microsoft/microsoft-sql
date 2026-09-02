---
name: sqlpackage-import-export
description: >-
  Moves a whole Azure SQL Database as a portable file with SqlPackage, choosing between the
  Extract, Publish, Export and Import actions, stating what each one carries, and giving the
  command line for each. Use when asked to export a database to a bacpac, extract or publish a
  dacpac, clone or move a database between servers or into the container, explain dacpac versus
  bacpac, or diagnose a failed sqlpackage run such as SQL71659 or SQL71627.
---

# Move a whole database with SqlPackage: dacpac and bacpac

Verified 2026-09-02 against SqlPackage 170.4.83.3, and the engine behaviour below measured
2026-08-29 against a container reporting `EngineEdition` 5, `12.0.2000.8`.

This owns the four-action decision for moving an entire existing database as a portable file, and
the command line for each action. Building a dacpac from a source-controlled SQL project, shipping
it through CI, its refactorlog and its pre and post deployment scripts are `sql-database-projects`.
Azure SQL Database's own automated backups and point-in-time or geo-restore are
`restore-and-recover`. Loading rows into a table that already exists is `bulk-load-and-bulk-copy`.
Vector indexes themselves are `azuresql-db-rag` and `vector-search-azure-sql`.

## Read the property list for the action before you write the command

Properties are per action. `ExtractAllTableData` is an Extract property and is not accepted by
Export. There is no catalog of properties that spans the actions, so ask the build in front of you:

```bash
sqlpackage /version:True
sqlpackage /Action:Export /?
```

An unknown property is refused before any connection is attempted:

```text
$ sqlpackage /Action:Export /p:ExportAllTableData=true /TargetFile:app.bacpac /SourceServerName:your-server.database.windows.net /SourceDatabaseName:app
*** 'ExportAllTableData' is not a valid argument for the 'Export' action.
```

A property can also be real, documented and still unavailable: `/p:Storage=File` is the .NET
Framework build's default, and Learn records `Memory` as the only option on the cross-platform
build.

Every parameter in this skill is written in long form. The same help output gives each one a short
form, `/Action` as `/a`, `/SourceFile` as `/sf`, `/TargetFile` as `/tf`, and the two forms are
interchangeable.

## The four actions, as four commands

| Action | Direction | Default contents | File |
|---|---|---|---|
| Extract | database to file | schema only | writes `.dacpac` |
| Publish | file to database | schema only | reads `.dacpac` |
| Export | database to file | schema and every base table's rows | writes `.bacpac` |
| Import | file to database | schema and every base table's rows | reads `.bacpac` |

Extract:

```bash
sqlpackage /Action:Extract /TargetFile:app.dacpac /DiagnosticsFile:extract.log \
  /SourceServerName:your-server.database.windows.net /SourceDatabaseName:<database> \
  /SourceUser:<user> /SourcePassword:"$SQLPACKAGE_PASSWORD" \
  /p:ExtractAllTableData=false /p:VerifyExtraction=true
```

Export:

```bash
sqlpackage /Action:Export /TargetFile:app.bacpac /DiagnosticsFile:export.log \
  /SourceServerName:your-server.database.windows.net /SourceDatabaseName:<database> \
  /SourceUser:<user> /SourcePassword:"$SQLPACKAGE_PASSWORD" \
  /p:VerifyExtraction=true /p:LongRunningCommandTimeout=0
```

Import:

```bash
sqlpackage /Action:Import /SourceFile:app.bacpac /DiagnosticsFile:import.log \
  /TargetServerName:your-server.database.windows.net /TargetDatabaseName:<new-database> \
  /TargetUser:<user> /TargetPassword:"$SQLPACKAGE_PASSWORD" \
  /p:DatabaseEdition=Standard /p:DatabaseServiceObjective=S1
```

Publish:

```bash
sqlpackage /Action:Publish /SourceFile:app.dacpac \
  /TargetServerName:your-server.database.windows.net /TargetDatabaseName:<database> \
  /TargetUser:<user> /TargetPassword:"$SQLPACKAGE_PASSWORD" \
  /p:BlockOnPossibleDataLoss=true /p:DropObjectsNotInSource=false
```

`/p:DatabaseEdition` and `/p:DatabaseServiceObjective` are accepted by Import and Publish and are
how the database they create is sized. Extract and Export do not accept them.

## Both Import and Publish can create the target; only Publish can rerun

Microsoft Learn states it for each. Publish: if the database doesn't exist on the server, the
publish operation creates it, otherwise an existing database is updated. Import: a new database
can be created by the import action when the authenticated user has create database permissions.

What Import will not do is load into a target that already holds a user object:

```text
Error SQL71659: Data cannot be imported into target because it contains one or more user objects.
```

It refuses before any statement runs against the target, and retrying the same Import against the
same name refuses again, every time, until that database is dropped and recreated or a new name is
chosen. Publish diffs instead: rerun it against a target it already published to and it reports
`Update complete` with nothing to apply.

## The property decides what is in the file, not the extension

An Extract of a database with one table and one view produced a `.dacpac` carrying no data entry
of any kind, and an Export of the same database produced a `.bacpac` carrying
`Data/dbo.Widget/TableData-000-00000.BCP`, one entry per base table holding rows.

Then the same Extract with one property added:

```bash
sqlpackage /Action:Extract /TargetFile:app-with-data.dacpac \
  /SourceServerName:your-server.database.windows.net /SourceDatabaseName:<database> \
  /SourceUser:<user> /SourcePassword:"$SQLPACKAGE_PASSWORD" /p:ExtractAllTableData=true
```

That file is still named `.dacpac`, is still the output of Extract, and now carries
`Data/dbo.Widget/TableData-000-00000.BCP` as well. `/p:TableData` is the narrower form, accepted
by both Extract and Export, naming one table per occurrence:

```bash
sqlpackage /Action:Extract /TargetFile:app-two-tables.dacpac \
  /SourceServerName:your-server.database.windows.net /SourceDatabaseName:<database> \
  /SourceUser:<user> /SourcePassword:"$SQLPACKAGE_PASSWORD" \
  /p:TableData=dbo.Widget /p:TableData=dbo.WidgetAudit
```

Open the file and look rather than reading the name:

```bash
unzip -l app-with-data.dacpac
```

## An export is not a backup, and is not consistent by default

Microsoft Learn states plainly that bacpac files aren't intended to be used for backup and restore
operations. `BACKUP DATABASE app TO DISK='/tmp/x.bak'` against this engine returns `Msg 40510`, and
there is no RESTORE either.

Learn again, on Export: for an export to be transactionally consistent, either no write activity is
occurring during the export, or the export is taken from a transactionally consistent copy of the
database. Nothing in the output of a successful export says which of those was true. Export from a
database copy, or from a database nothing is writing to, or state in the answer that the file may
be internally inconsistent.

## Before an Export or Extract from a database with operating history

Export is limited to the Azure SQL Database surface area, so a source carrying an element outside
it fails with `SQL71627` after the whole schema model has already been built, discarding the entire
attempt rather than the one object. The usual carriers are Windows-authenticated users and logins,
such as an inherited `NT AUTHORITY\SYSTEM`, and leftover Service Broker or query notification
permissions, most often a `RECEIVE` grant on `QueryNotificationErrorsQueue`.

Open [references/preflight-and-sql71627.md](references/preflight-and-sql71627.md) before running an
export against a database you did not create yourself: it holds the queries that find both classes
and the remediation for each.

Extract accepts two properties that drop the offending model elements, and Export accepts neither:

```bash
sqlpackage /Action:Extract /TargetFile:app.dacpac \
  /SourceServerName:your-server.database.windows.net /SourceDatabaseName:<database> \
  /SourceUser:<user> /SourcePassword:"$SQLPACKAGE_PASSWORD" \
  /p:IgnoreUserLoginMappings=true /p:IgnorePermissions=true
```

So when a database will not export, extracting the schema and moving the rows separately is the
route that still runs.

## Read the plan before a Publish that could drop something

DeployReport writes XML and Script writes T-SQL. Neither one changes the target database.

```bash
sqlpackage /Action:DeployReport /SourceFile:app.dacpac /DeployReportPath:deploy-report.xml \
  /TargetServerName:your-server.database.windows.net /TargetDatabaseName:<database> \
  /TargetUser:<user> /TargetPassword:"$SQLPACKAGE_PASSWORD"
```

```bash
sqlpackage /Action:Script /SourceFile:app.dacpac /DeployScriptPath:publish.sql \
  /TargetServerName:your-server.database.windows.net /TargetDatabaseName:<database> \
  /TargetUser:<user> /TargetPassword:"$SQLPACKAGE_PASSWORD"
```

`/p:BlockOnPossibleDataLoss` defaults to True and is what stops a publish that would drop data.
Leave it on. `/p:CreateNewDatabase=true` does not mean "create it if it is missing", which Publish
already does: Learn describes it as whether the target database should be updated or whether it
should be dropped and re-created. Setting it against a populated target destroys that target.

## A vector index breaks the round trip, and the export looks fine

Check before planning anything around a bacpac:

```sql
SELECT OBJECT_NAME(object_id) AS table_name, name
FROM sys.indexes WHERE type_desc = 'VECTOR';
```

An import creates schema objects before it loads data, so a vector index is created against an
empty table. Measured 2026-08-31 against `12.0.2000.8`: a vector index needs at least 100 rows
carrying non-null vectors, 99 is refused with `Msg 42266` and 100 succeeds. Drop the vector indexes
before exporting and recreate them after the data is loaded. `TRUNCATE TABLE` is refused while a
vector index exists (`Msg 42232`), so reloading in place hits the same wall one step earlier.

## Check it worked

Exit code 0 says the action SqlPackage attempted finished. It does not say the rows arrived.

```bash
unzip -l app.bacpac | grep TableData
```

Expect one `Data/<schema>.<table>/TableData-000-00000.BCP` entry per base table that held rows, and
none for a view. Then compare the target against the source:

```sql
SELECT SUM(p.rows) AS row_count, COUNT(DISTINCT t.object_id) AS table_count
FROM sys.tables AS t
JOIN sys.partitions AS p ON p.object_id = t.object_id AND p.index_id IN (0, 1);
```

Run it on both databases. Equal numbers, or a stated reason they differ, is the check. A schema
only dacpac publishes to zero rows and that is correct, not a failure.

## References

- [Measured runs, file listings, exit codes and provenance](references/dacpac-bacpac-contents-and-errors.md): open it when a claim above disagrees with what you are seeing, or to reproduce a measurement.
- [The SQL71627 pre-flight scan](references/preflight-and-sql71627.md)
- The property reference per action, and the only authority on whether a property exists:
  [Extract](https://learn.microsoft.com/sql/tools/sqlpackage/sqlpackage-extract),
  [Export](https://learn.microsoft.com/sql/tools/sqlpackage/sqlpackage-export),
  [Import](https://learn.microsoft.com/sql/tools/sqlpackage/sqlpackage-import),
  [Publish](https://learn.microsoft.com/sql/tools/sqlpackage/sqlpackage-publish),
  [Script](https://learn.microsoft.com/sql/tools/sqlpackage/sqlpackage-script) and
  [DeployReport](https://learn.microsoft.com/sql/tools/sqlpackage/sqlpackage-deploy-drift-report).
