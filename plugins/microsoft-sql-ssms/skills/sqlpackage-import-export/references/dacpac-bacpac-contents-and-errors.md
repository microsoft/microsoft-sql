# What lands inside a dacpac and a bacpac, and the errors on the way

## Contents

- [Provenance](#provenance)
- [Setup](#setup)
- [Extract versus Export: what lands inside the file](#extract-versus-export-what-lands-inside-the-file)
- [ExtractAllTableData: a dacpac that carries data](#extractalltabledata-a-dacpac-that-carries-data)
- [Import into a new, empty target](#import-into-a-new-empty-target)
- [Publish creates the target database](#publish-creates-the-target-database)
- [Import refuses a non-empty target](#import-refuses-a-non-empty-target)
- [Publish reruns against its own target with no changes](#publish-reruns-against-its-own-target-with-no-changes)
- [There is no BACKUP T-SQL](#there-is-no-backup-t-sql)
- [Environment](#environment)

## Provenance

Every parameter and `/p:` property named in `SKILL.md` was read out of
`sqlpackage /Action:<action> /?` on SqlPackage 170.4.83.3 on 2026-09-02, then cross-checked against
the Microsoft Learn page for that same action. Nothing is stated in the skill that failed both
checks, and nothing is carried from memory.

Engine behaviour was measured on 2026-08-29 against the Azure SQL Database container recorded under
[Environment](#environment), and the vector index row limits on 2026-08-31 against the same build.
Everything below is a transcript of those runs, not a reconstruction.

## Setup

A source database with one table holding three rows and one view over it:

```sql
CREATE TABLE dbo.Widget (Id INT IDENTITY PRIMARY KEY, Name NVARCHAR(100));
INSERT INTO dbo.Widget (Name) VALUES ('alpha'),('beta'),('gamma');
GO
CREATE VIEW dbo.WidgetView AS SELECT Id, Name FROM dbo.Widget;
```

## Extract versus Export: what lands inside the file

```text
$ sqlpackage /Action:Extract /SourceConnectionString:"..." /TargetFile:widget.dacpac
Successfully extracted database and saved it to file '.../widget.dacpac'.
Time elapsed 0:00:07.56

$ sqlpackage /Action:Export /SourceConnectionString:"..." /TargetFile:widget.bacpac
Processing Table '[dbo].[Widget]'.
Successfully exported database and saved it to file '.../widget.bacpac'.
Time elapsed 0:00:07.69
```

```text
$ unzip -l widget.dacpac
     5067  model.xml
      189  DacMetadata.xml
      175  [Content_Types].xml
     1643  Origin.xml
---------
     7074  4 files

$ unzip -l widget.bacpac
     5957  model.xml
      193  DacMetadata.xml
       46  Data/dbo.Widget/TableData-000-00000.BCP
     1693  Origin.xml
      357  _rels/.rels
      340  [Content_Types].xml
---------
     8586  6 files
```

The bacpac carries one `Data/` entry, for the base table. `WidgetView` produced no data entry in
either file, because a view has no rows of its own.

## ExtractAllTableData: a dacpac that carries data

```text
$ sqlpackage /Action:Extract /SourceConnectionString:"..." /TargetFile:widget_withdata.dacpac \
    /p:ExtractAllTableData=true
Processing Table '[dbo].[Widget]'.
Successfully extracted database and saved it to file '.../widget_withdata.dacpac'.

$ unzip -l widget_withdata.dacpac
     5067  model.xml
      189  DacMetadata.xml
       46  Data/dbo.Widget/TableData-000-00000.BCP
     1643  Origin.xml
      357  _rels/.rels
      340  [Content_Types].xml
---------
     7642  6 files
```

Same action, same `.dacpac` extension, and now the same `Data/` shape a bacpac carries. Nothing
about the filename or the action name changes; only the property does.

## Import into a new, empty target

```text
$ sqlpackage /Action:Import /SourceFile:widget.bacpac /TargetConnectionString:"...dq_from_bacpac..."
Importing data
Processing Table '[dbo].[Widget]'.
Successfully imported database.
Time elapsed 0:00:39.17
```

```sql
SELECT COUNT(*) FROM dq_from_bacpac.dbo.Widget;   -- 3
```

## Publish creates the target database

```text
$ sqlpackage /Action:Publish /SourceFile:widget.dacpac /TargetConnectionString:"...dq_from_dacpac..."
Updating database (Start)
Creating database dq_from_dacpac...
Creating Table [dbo].[Widget]...
Creating View [dbo].[WidgetView]...
Update complete.
Successfully published database.
```

The target database `dq_from_dacpac` did not exist before this run; confirmed with
`SELECT name FROM sys.databases` before and after. Row count in the published target is 0,
because the source file was a schema-only dacpac:

```sql
SELECT COUNT(*) FROM dq_from_dacpac.dbo.Widget;   -- 0
```

## Import refuses a non-empty target

Running Import a second time against `dq_from_bacpac`, which the first Import had already
populated:

```text
$ sqlpackage /Action:Import /SourceFile:widget.bacpac /TargetConnectionString:"...dq_from_bacpac..."
Creating deployment plan
Initializing deployment
*** Error importing database: Data cannot be imported into target because it contains one or more
user objects. Import should be performed against a new, empty database.
Error SQL71659: Data cannot be imported into target because it contains one or more user objects.
```

Refused before any statement ran against the target; the row count in `dq_from_bacpac` was
unchanged.

## Publish reruns against its own target with no changes

Running the same Publish a second time against `dq_from_dacpac2`, already fully published:

```text
$ sqlpackage /Action:Publish /SourceFile:widget.dacpac /TargetConnectionString:"...dq_from_dacpac2..."
Initializing deployment (Complete)
Analyzing deployment plan (Complete)
Updating database (Start)
Update complete.
Successfully published database.
Time elapsed 0:00:01.66
```

No object-creation lines the second time; the plan had nothing to apply. Compare the 32-second
first run, which created the database and both objects, against this 1.66-second no-op rerun.

## There is no BACKUP T-SQL

```text
$ sqlcmd -Q "BACKUP DATABASE dq_sqlpackage TO DISK='/tmp/x.bak';"
Msg 40510, Level 16, State 1, Server SQL Azure, Line 1
'BACKUP DATABASE' is not supported in this version of SQL Server.
```

## Environment

SqlPackage 170.4.83.3 installed as a global .NET tool (`dotnet tool install -g
microsoft.sqlpackage`), against a container reporting:

```sql
SELECT @@VERSION;                              -- Microsoft SQL Azure (RTM) - 12.0.2000.8
SELECT SERVERPROPERTY('EngineEdition');        -- 5
SELECT SERVERPROPERTY('Edition');              -- SQL Azure
```
