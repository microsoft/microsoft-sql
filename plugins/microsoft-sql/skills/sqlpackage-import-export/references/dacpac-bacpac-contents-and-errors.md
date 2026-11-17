# What lands inside a dacpac and a bacpac, and the errors on the way

## Contents

- [Setup](#setup)
- [Extract versus Export: what lands inside the file](#extract-versus-export-what-lands-inside-the-file)
- [ExtractAllTableData: a dacpac that carries data](#extractalltabledata-a-dacpac-that-carries-data)
- [Import into a new, empty target](#import-into-a-new-empty-target)
- [Publish creates the target database](#publish-creates-the-target-database)
- [Import refuses a non-empty target](#import-refuses-a-non-empty-target)
- [Publish reruns against its own target with no changes](#publish-reruns-against-its-own-target-with-no-changes)
- [There is no BACKUP T-SQL](#there-is-no-backup-t-sql)

## Setup

SqlPackage installed as a global .NET tool, `dotnet tool install -g microsoft.sqlpackage`, and a
source database with one table holding three rows and one view over it:

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

$ sqlpackage /Action:Export /SourceConnectionString:"..." /TargetFile:widget.bacpac
Processing Table '[dbo].[Widget]'.
Successfully exported database and saved it to file '.../widget.bacpac'.
```

Listing both files shows what each carries; the sizes will differ with your schema:

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

The target database `dq_from_dacpac` need not exist beforehand: `SELECT name FROM sys.databases`
before and after shows it appear. On a logical server the publishing login needs permission to
create databases: the server admin, or a member of the `dbmanager` role in `master`. The row count
in the published target is 0, because the source file is a schema-only dacpac:

```sql
SELECT COUNT(*) FROM dq_from_dacpac.dbo.Widget;   -- 0
```

## Import refuses a non-empty target

Run the Import a second time against `dq_from_bacpac`, which the first Import populated:

```text
$ sqlpackage /Action:Import /SourceFile:widget.bacpac /TargetConnectionString:"...dq_from_bacpac..."
Creating deployment plan
Initializing deployment
*** Error importing database: Data cannot be imported into target because it contains one or more
user objects. Import should be performed against a new, empty database.
Error SQL71659: Data cannot be imported into target because it contains one or more user objects.
```

It is refused before any statement runs against the target, and the row count in
`dq_from_bacpac` is unchanged.

## Publish reruns against its own target with no changes

Run the same Publish a second time against a target it already published, `dq_from_dacpac2` here:

```text
$ sqlpackage /Action:Publish /SourceFile:widget.dacpac /TargetConnectionString:"...dq_from_dacpac2..."
Initializing deployment (Complete)
Analyzing deployment plan (Complete)
Updating database (Start)
Update complete.
Successfully published database.
```

There are no object-creation lines the second time; the plan has nothing to apply, and the rerun
finishes far sooner than the first publish, which created the database and both objects.

## There is no BACKUP T-SQL

```text
$ sqlcmd -Q "BACKUP DATABASE dq_sqlpackage TO DISK='/tmp/x.bak';"
Msg 40510, Level 16, State 1, Server SQL Azure, Line 1
'BACKUP DATABASE' is not supported in this version of SQL Server.
```
