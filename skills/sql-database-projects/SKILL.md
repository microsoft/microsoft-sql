---
name: sql-database-projects
description: >-
  Builds and publishes a SQL database project against Azure SQL Database: the SDK-style
  `.sqlproj` on `Microsoft.Build.Sql`, the target platform that decides what the build actually
  validates, pre and post deployment scripts, the refactorlog, and code analysis. Use when a user
  asks to "create a SQL database project", "build a dacpac", "publish a dacpac to Azure SQL",
  "add a post-deployment script", "rename a column without losing its data", or "turn on code
  analysis", and when a user reports that "the build passed but the publish failed", "the deploy
  said success and the data is gone", or "the post-deployment script failed and the table already
  changed". Covers what `dotnet build` does and does not check, what SqlPackage does with a
  mismatched target platform, and which publish options change data rather than schema.
  github-actions-for-sql owns running this from a pipeline, schema-migrations-safely owns the
  change doctrine, and deploy-app-to-azure owns application deployment.
---

# Build and publish a SQL database project

**This owns the tooling: the project file, the build, the dacpac and the publish.** It does not
own the doctrine of how to sequence a schema change (`schema-migrations-safely`), running the
publish from a pipeline (`github-actions-for-sql`), or deploying the application beside it
(`deploy-app-to-azure`). Each ORM owns its own migration tool.

Verified on 2026-08-28 with the .NET SDK 8.0.421 on macOS, `Microsoft.Build.Sql` 2.2.0,
`Microsoft.Build.Sql.Templates` 2.2.0 and SqlPackage 170.4.83.3, publishing into the Azure SQL
Database container reporting `EngineEdition` 5, `SQL Azure`, `12.0.2000.8`.

## Two facts that shape everything below

**A SQL database project builds anywhere.** It is an SDK-style project, so `dotnet build` is the
whole build story on Linux, macOS and Windows alike. No IDE, no Windows-only component:

```bash
dotnet new install Microsoft.Build.Sql.Templates
dotnet new sqlproj -n ShopDb -o ShopDb --target-platform SqlAzureV12
dotnet build ShopDb           # produces ShopDb/bin/Debug/ShopDb.dacpac
```

**SqlPackage is not installed by the SDK and is not on any hosted build image by default.** It is
a separate global tool, and every publish below needs it:

```bash
dotnet tool install -g microsoft.sqlpackage
```

## The correction: a green build is not a validated schema

### The template default targets the wrong platform

`dotnet new sqlproj` defaults `--target-platform` to the newest box-product value, not to Azure
SQL Database. That default lands in the project file as one property:

```xml
<DSP>Microsoft.Data.Tools.Schema.Sql.Sql170DatabaseSchemaProvider</DSP>   <!-- the default -->
<DSP>Microsoft.Data.Tools.Schema.Sql.SqlAzureV12DatabaseSchemaProvider</DSP>   <!-- Azure SQL Database -->
```

Read that property before anything else. It is the single line that decides which rules the build
applies, and nothing in the build output announces it.

### What the wrong target platform actually does, measured

A project holding `CREATE QUEUE [dbo].[OrderQueue];`, which Azure SQL Database has never
supported, built under both targets:

| Target platform | `dotnet build` | Errors | Then `sqlpackage /Action:Publish` to Azure SQL Database |
|---|---|---|---|
| default box-product target | **succeeds** | 0 | **refused before any change**, exit code 1 |
| a lower box-product target | **succeeds** | 0 | **refused before any change**, exit code 1 |
| `SqlAzureV12` | **fails** | 1 | never reached |

Under `SqlAzureV12` the build says exactly what is wrong, at the line that is wrong:

```text
OrderQueue.sql(1,1,1,1): Build error SQL70015: Statement 'CREATE QUEUE' is not supported for
the targeted platform.
```

Under the default target the same file produces no error at all, and the objection arrives from
SqlPackage instead, during plan generation:

```text
Initializing deployment (Failed)
*** An error occurred during deployment plan generation. Deployment cannot continue.
A project which specifies <target platform> as the target platform cannot be published to
Microsoft Azure SQL Database v12.
```

**So the answer is: the build silently accepts it, and the publish then refuses the whole package
before touching the database.** SqlPackage compares the dacpac's declared platform against the
server it is pointed at and stops if they disagree, so nothing half-deploys and no dacpac
misbehaves in production from this cause alone.

**That is a cheap failure in the wrong place.** It costs a release, not data: the build went
green, the artifact was published, a version was tagged, and the objection surfaces in the
deployment step against the real target, which is the most expensive place to learn it and the
last one where a reviewer is watching. Set the target platform at `dotnet new` time, and check it
on any project inherited from a template or a sample.

### And the right target platform is not sufficient

`SqlAzureV12` validates **statements**. It does not validate a **reference to a server feature
that is not there**. A procedure calling a mail or agent stored procedure Azure SQL Database does
not have builds under the Azure target too, with only:

```text
Build warning SQL71502: Procedure: [dbo].[DoWork] has an unresolved reference to object
[sys].[sp_send_dbmail].
```

That warning is the only signal, and warnings do not fail a build. The procedure reaches the
database and fails the first time it runs. Enumerate `SQL71502` warnings and decide about each
one, or escalate the class:

```bash
dotnet build -t:Rebuild -p:TreatTSqlWarningsAsErrors=true
```

Measured: the same four warnings become four errors and the build fails.

## What the build reads, and what nothing reads

`Microsoft.Build.Sql` globs `**/*.sql` into the model, then removes whatever is declared as a
deployment script or as `None`. Two consequences, both measured:

| Item type | Globbed automatically | Parsed and validated |
|---|---|---|
| `Build` (ordinary object files) | yes, `**/*.sql` | yes |
| `PreDeploy`, `PostDeploy` | no, declare them | **no, not at all** |
| `RefactorLog` | **no, declare it** | not applicable |

A post-deployment script inserting into a table that does not exist builds with **zero warnings
and zero errors**. The same statement inside a stored procedure produces `SQL71502`. Deployment
scripts get no such treatment, because nothing reads them until the server does.

```xml
<ItemGroup>
  <PostDeploy Include="Script.PostDeployment.sql" />
  <RefactorLog Include="ShopDb.refactorlog" />
</ItemGroup>
```

## A failed publish does not roll back the schema

Measured, publishing a project that both adds a column and carries a post-deployment script that
fails:

```text
Updating database (Start)
Altering Table [dbo].[Product]...
post-deploy starting
Updating database (Failed)
Error SQL72014: ... Msg 208, Level 16, State 1, Line 2 Invalid object name 'dbo.NoSuchTable'.
Error SQL72045: Script execution error.
```

SqlPackage exits 1, **and the new column is there and stays there.** Re-running with
`/p:IncludeTransactionalScripts=True` changes nothing about this: the column survives that run
too, because the deployment scripts are outside the transactional block, which is exactly the
part that failed.

So a red pipeline step is not a database that stayed still. After a failed publish, read the
schema before deciding anything, and make deployment scripts idempotent so re-running them is
safe. `schema-migrations-safely` owns why that is the rule rather than a nicety.

## The rename, which is the one that costs data

A column rename in the project is, to a schema comparison, a drop and an add. The refactorlog is
what turns it back into a rename, and it is the easiest thing in the toolchain to leave
half-wired, because the file existing is not the file being used.

Measured on a `Product` table holding two rows:

| What the project has | Publish result |
|---|---|
| the rename, no refactorlog | blocked: `Msg 50000 ... Rows were detected. The schema update is terminating because data loss might occur.` exit 1 |
| the rename, refactorlog file on disk but **not declared** | **the same block.** The build succeeded and said nothing |
| the rename, refactorlog declared as a `RefactorLog` item | `Rename [dbo].[Product].[Name] to ProductName`, both rows keep their values, exit 0 |
| the rename, no refactorlog, `/p:BlockOnPossibleDataLoss=False` | `Successfully published database`, **exit 0, both values now null** |

The last row is the whole reason this skill exists. The publish prints success, the pipeline step
is green, and the only trace is one line above the plan, before the change was made:

```text
*** The column [dbo].[Product].[Name] is being dropped, data loss could occur.
```

Confirm the wiring rather than the file. A dacpac that carries a refactorlog has `refactor.xml`
inside it, and a dacpac that does not is a zip with four entries:

```bash
unzip -l bin/Debug/ShopDb.dacpac | grep refactor.xml   # no output means it is not wired
```

The first publish carrying one creates `dbo.__RefactorLog` in the target database and records the
operation key there, so each rename applies once. That table is part of the deployment state:
restoring or copying a database without it makes an already-applied rename look outstanding.

## The database is not the project

`DropObjectsNotInSource` defaults to **false**. Measured: a table and a procedure created by hand
in the target both survive a publish of a project that contains neither, and the publish reports
success. Turning it on drops them, and preserves `__RefactorLog`:

```text
Dropping Table [dbo].[Legacy]...
Dropping Procedure [dbo].[LegacyProc]...
```

Neither setting is the safe one by default. Decide which the database is: a mirror of the project,
or a superset that also holds things the project does not describe.

## Code analysis is on request, and advisory until escalated

Turn it on with one property, and it runs inside `dotnet build`:

```xml
<RunSqlCodeAnalysis>true</RunSqlCodeAnalysis>
```

Measured output on a procedure using `SELECT *` and `@@IDENTITY`:

```text
StaticCodeAnalysis warning SR0001: ... SELECT * ...
StaticCodeAnalysis warning SR0008: ... Potential misuse of system function @@IDENTITY.
Build succeeded.  0 Error(s), 2 Warning(s)
```

Warnings in a build log nobody reads are not a gate. Escalate a single rule with a `!`, which
fails the build:

```bash
dotnet build -t:Rebuild -p:SqlCodeAnalysisRules='+!Microsoft.Rules.Data.SR0001'
```

Two traps worth knowing. The `sqlcodeanalysis` template does **not** turn code analysis on: it
scaffolds a C# project for writing a custom rule, which then has to be packaged and referenced.
And `dotnet build` skips analysis entirely when the project is up to date, so a rerun that reports
zero warnings may have analysed nothing. Use `-t:Rebuild` when the warning count is the answer you
want.

## Publishing, and the flags that matter

```bash
sqlpackage /Action:Publish \
  /SourceFile:bin/Debug/ShopDb.dacpac \
  /TargetConnectionString:"Server=tcp:${AZURE_SQL_SERVER}.database.windows.net,1433;Initial Catalog=${AZURE_SQL_DATABASE};Authentication=Active Directory Default;Encrypt=True;"
```

Read the plan before applying it. Both of these write a file and change nothing:

```bash
sqlpackage /Action:DeployReport /SourceFile:... /TargetConnectionString:"..." /OutputPath:report.xml
sqlpackage /Action:Script       /SourceFile:... /TargetConnectionString:"..." /OutputPath:deploy.sql
```

`/Action:Publish` does not create the logical server or the database. Against the local container
in particular, the database has to exist first, because the engine does not create one on connect.

## Validation rules

- The `DSP` property was read out of the project file and reported before any claim about
  compatibility, and it is the Azure SQL Database schema provider when the target is Azure SQL
  Database.
- A build reporting zero errors was not described as a validated schema until a deployment plan
  was generated against the real target.
- Every `SQL71502` warning was listed and answered, rather than left in the log.
- Each pre and post deployment script was stated to be unchecked by the build, and each is safe to
  run twice.
- A rename carries a refactorlog entry, the refactorlog is declared as a `RefactorLog` item, and
  `refactor.xml` was confirmed inside the built dacpac.
- `BlockOnPossibleDataLoss` was left on, and any request to disable it was answered with the list
  of what would be dropped.
- Whether objects absent from the project should be dropped was decided rather than defaulted.
- The target database existed before `/Action:Publish` ran.

## Do not

- Do not accept the target platform the template picks. It is not Azure SQL Database, and nothing
  in the build output says so.
- Do not report a successful build as a schema that is valid for Azure SQL Database. It is valid
  for whatever the `DSP` says.
- Do not treat a failed publish as a database that did not change. Deployment scripts run outside
  the transaction, and the schema changes ahead of them stay applied.
- Do not set `BlockOnPossibleDataLoss` to `False` to get a pipeline green. It converts a blocked
  deployment into a successful one that has dropped a column.
- Do not assume a `.refactorlog` file in the project directory is being used. Declare it, then
  look for `refactor.xml` in the dacpac.
- Do not put seed data in a `Build` file. It belongs in a post-deployment script, written so a
  second run is a no-op.
- Do not expect `dotnet build` to check a deployment script. Nothing parses those.
- Do not expect a publish to remove what the project does not describe, and do not turn that on
  without knowing what is in the target.

## References

- [references/measured-behaviour.md](references/measured-behaviour.md): the runs behind every
  table above, with the commands, the exact messages and the exit codes, plus the project-file
  properties and the SqlPackage options this skill relies on. Read it when a result here needs to
  be reproduced or a claim needs a source.
- `sdk/Sdk.props` and `sdk/Sdk.targets` inside the `Microsoft.Build.Sql` package in the local
  package cache: the default item globs, and the item types that are never globbed. Read them
  when a file is sitting in the project directory and is not in the build.
