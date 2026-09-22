---
name: sql-database-projects
description: >-
  Builds and publishes a SQL database project against Azure SQL Database: the SDK-style
  `.sqlproj` on `Microsoft.Build.Sql`, the target platform that decides what the build actually
  validates, pre and post deployment scripts, the refactorlog, and code analysis. Use when a user
  asks to "create a SQL database project", "build a dacpac", "publish a dacpac to Azure SQL",
  "add a post-deployment script", "rename a column without losing its data", or "turn on code
  analysis", and reports "the build passed but the publish failed", "the deploy said success and
  the data is gone", or "the post-deployment script failed and the table already changed". Covers
  what `dotnet build` does not check, what SqlPackage does with a mismatched target platform, and
  which publish options change data rather than schema. github-actions-for-sql owns the pipeline,
  schema-migrations-safely the change doctrine.
---

# Build and publish a SQL database project

**This owns the tooling: the project file, the build, the dacpac and the publish.** It does not
own how to sequence a schema change (`schema-migrations-safely`), running the publish from a
pipeline (`github-actions-for-sql`), or deploying the application beside it
(`deploy-app-to-azure`). Open `sqlpackage-import-export` when the job is moving a whole database
rather than building one, or when the artifact is a bacpac.

Verified 2026-09-03 with the .NET SDK 8.0.421 on macOS, `Microsoft.Build.Sql` 2.2.0,
`Microsoft.Build.Sql.Templates` 2.2.0 and SqlPackage 170.4.83.3, publishing into the Azure SQL
Database container reporting `EngineEdition` 5, `SQL Azure`, `12.0.2000.8`.

## The build runs anywhere, and SqlPackage is a separate install

```bash
dotnet new install Microsoft.Build.Sql.Templates
dotnet new sqlproj -n ShopDb -o ShopDb --target-platform SqlAzureV12
dotnet build ShopDb                       # writes ShopDb/bin/Debug/ShopDb.dacpac
dotnet tool install -g microsoft.sqlpackage
```

It is an SDK-style project, so `dotnet build` is the whole build story on Linux, macOS and Windows
alike, with no IDE and no Windows-only component. SqlPackage is not installed by the SDK, is not
on a hosted build image by default, and every publish below needs it.

## The template's default target is not Azure SQL Database

`dotnet new sqlproj --help` lists ten platforms and defaults to `Sql170`, the box product. The
choice lands in the project file as one property, and nothing in the build output announces it:

```xml
<DSP>Microsoft.Data.Tools.Schema.Sql.Sql170DatabaseSchemaProvider</DSP>      <!-- the default -->
<DSP>Microsoft.Data.Tools.Schema.Sql.SqlAzureV12DatabaseSchemaProvider</DSP> <!-- Azure SQL Database -->
```

A project holding `CREATE QUEUE [dbo].[OrderQueue];`, which Azure SQL Database has never
supported, built under both:

| Target platform | `dotnet build` | Then `/Action:Publish` to Azure SQL Database |
|---|---|---|
| `Sql170`, the template default | **succeeds, 0 errors** | **refused before any change**, exit 1 |
| `SqlAzureV12` | **fails, 1 error** | never reached |

Under `SqlAzureV12` the build names the file and the line:

```text
OrderQueue.sql(1,1,1,1): Build error SQL70015: Statement 'CREATE QUEUE' is not supported for
the targeted platform.
```

Under the default the objection arrives from SqlPackage instead, during plan generation:

```text
*** An error occurred during deployment plan generation. Deployment cannot continue.
A project which specifies <the project's target platform> as the target platform cannot be
published to Microsoft Azure SQL Database v12.
```

Nothing half-deploys from this cause: SqlPackage compares the dacpac's declared platform against
the server and stops. It still costs a release, because the build went green and the artifact was
tagged before anyone learned. Check an inherited project without editing it, by overriding the
provider on the command line:

```bash
dotnet build ShopDb -t:Rebuild /p:DSP=Microsoft.Data.Tools.Schema.Sql.SqlAzureV12DatabaseSchemaProvider
```

If that fails where the ordinary build passed, the project is not targeting Azure SQL Database.
`/p:AllowIncompatiblePlatform=true` on the publish forces past the refusal instead of fixing it.
It defaults to `False`. Leave it there.

## The right target validates statements, not references

`SqlAzureV12` does not check that a referenced object exists. A procedure calling a mail or agent
stored procedure Azure SQL Database does not have builds under the Azure target with only:

```text
Build warning SQL71502: Procedure: [dbo].[DoWork] has an unresolved reference to object
[dbo].[NoSuchTable].
```

Warnings do not fail a build, so the procedure reaches the database and fails the first time it
runs. Answer each one, or escalate the whole class:

```bash
dotnet build ShopDb -t:Rebuild -p:TreatTSqlWarningsAsErrors=true
```

Measured: every `SQL71502` becomes `Build error SQL71502` and the build fails. Where one warning
is genuinely fine, `SuppressTSqlWarnings` takes a comma-separated list of numbers.

## Deployment scripts ride in the dacpac and are read by nothing

The SDK globs `**/*.sql` into the model, then removes whatever is declared as a deployment script
or as `None`. There is a `RefactorLog` item type and no glob creates one.

| Item type | Globbed | Parsed and validated |
|---|---|---|
| `Build`, ordinary object files | yes, `**/*.sql` | yes |
| `PreDeploy`, `PostDeploy` | no, declare them | **no, not at all** |
| `RefactorLog` | **no, declare it** | not applicable |

```xml
<ItemGroup>
  <PreDeploy Include="Script.PreDeployment.sql" />
  <PostDeploy Include="Script.PostDeployment.sql" />
  <RefactorLog Include="ShopDb.refactorlog" />
</ItemGroup>
```

A post-deployment script whose entire body is `INSERT INTO dbo.NoSuchTable (id) VALUES (1);`
builds with **0 errors and 0 warnings**. The same statement inside a stored procedure produces
`SQL71502`. A project takes one pre-deployment and one post-deployment script; chain more with
`:r .\scripts\script1.sql` inside them, and add `<Build Remove="scripts\script1.sql" />` so the
chained files stay out of the model. Seed data belongs here, written so a second run is a no-op,
never in a `Build` file.

## A failed publish does not roll back the schema

Publishing a project that adds a column and carries a post-deployment script that fails:

```text
Altering Table [dbo].[Product]...
Updating database (Failed)
Error SQL72014: ... Msg 208, Level 16, State 1, Line 2 Invalid object name 'dbo.NoSuchTable'.
Error SQL72045: Script execution error.
```

SqlPackage exits 1, **and the new column is there and stays there.**
`/p:IncludeTransactionalScripts=True` changes nothing here: deployment scripts run outside the
transactional block, which is exactly the part that failed. So a red pipeline step is not a
database that stayed still. Read the schema after a failed publish before deciding anything.
`schema-migrations-safely` owns why idempotent scripts are a rule rather than a nicety.

## The rename, which is the one that costs data

To a schema comparison a column rename is a drop and an add. The refactorlog turns it back into a
rename, and it is the easiest thing here to leave half-wired, because the file existing is not the
file being used.


Measured on a `Product` table holding two rows:

| What the project has | Publish result |
|---|---|
| the rename, no refactorlog | blocked: `Msg 50000 ... Rows were detected. The schema update is terminating because data loss might occur.` exit 1 |
| the file on disk but **not declared** | **the same block.** The build succeeded and said nothing |
| declared as a `RefactorLog` item | `Rename [dbo].[Product].[Name] to ProductName`, both rows keep their values, exit 0 |
| no refactorlog, `/p:BlockOnPossibleDataLoss=False` | `Successfully published database`, **exit 0, both values now null** |

The last row is the whole reason this skill exists: turning that option off to get a pipeline
green converts a blocked deployment into a successful one that dropped a column.

You do not need a database to find out which row you are in. DeployReport reads a dacpac against
another dacpac, so the plan is readable before any server is involved:

```bash
sqlpackage /Action:DeployReport /SourceFile:After/bin/Debug/After.dacpac \
  /TargetFile:Before/bin/Debug/Before.dacpac /TargetDatabaseName:ShopDb /OutputPath:plan.xml
```

Measured 2026-09-03, the same rename twice. Without the refactorlog declared:

```xml
<Alerts><Alert Name="DataIssue"><Issue Value="The column [dbo].[Product].[Name] is being dropped,
data loss could occur." Id="1" /></Alert></Alerts><Operations><Operation Name="Alter">
```

With it declared, the alert is gone and the operation changed:

```xml
<Alerts /><Operations><Operation Name="Rename"><Item Value="[dbo].[Product].[ProductName]"
Type="SqlSimpleColumn" /></Operation></Operations>
```

The first publish carrying a refactorlog creates `dbo.__RefactorLog` in the target and records the
operation key, so each rename applies once. That table is deployment state: copying a database
without it makes an already-applied rename look outstanding.

## The database is not the project

`/p:DropObjectsNotInSource` defaults to **False**. Measured: a table and a procedure created by
hand in the target both survive a publish of a project that contains neither, and the publish
reports success. Turning it on drops them and keeps `__RefactorLog`:

```text
Dropping Table [dbo].[Legacy]...
Dropping Procedure [dbo].[LegacyProc]...
```

Neither setting is the safe one. Decide whether this database is a mirror of the project or a
superset holding things the project does not describe, and never turn the option on without
reading a plan first.

## Code analysis is on request, and advisory until escalated

```xml
<RunSqlCodeAnalysis>true</RunSqlCodeAnalysis>
```

Measured on a procedure using `SELECT *` and `@@IDENTITY`: `StaticCodeAnalysis warning SR0001`,
`SR0008`, and `Build succeeded. 0 Error(s), 2 Warning(s)`. Warnings in a log nobody reads are not
a gate. Escalate one rule with `+!`, which fails the build:

```bash
dotnet build ShopDb -t:Rebuild -p:SqlCodeAnalysisRules='+!Microsoft.Rules.Data.SR0001'
```

Measured: `StaticCodeAnalysis error SR0001`, 1 error and 1 warning, `Build FAILED`. Two traps. The
`sqlcodeanalysis` template does **not** turn analysis on: it scaffolds a C# project for writing a
custom rule, which then has to be packaged and referenced. And `dotnet build` skips analysis
entirely on a project that is up to date, so a rerun reporting zero warnings may have analysed
nothing. Use `-t:Rebuild` whenever the warning count is the answer you want.

## Publishing

```bash
sqlpackage /Action:Publish /SourceFile:ShopDb/bin/Debug/ShopDb.dacpac \
  /TargetConnectionString:"Server=tcp:<server-name>.database.windows.net,1433;Initial Catalog=<database>;Authentication=Active Directory Default;Encrypt=True;"
```

Read the plan against the real target before applying it. Both of these write a file and change
nothing:

```bash
sqlpackage /Action:DeployReport /SourceFile:ShopDb/bin/Debug/ShopDb.dacpac \
  /TargetConnectionString:"Server=tcp:<server-name>.database.windows.net,1433;Initial Catalog=<database>;Authentication=Active Directory Default;Encrypt=True;" \
  /OutputPath:plan.xml

sqlpackage /Action:Script /SourceFile:ShopDb/bin/Debug/ShopDb.dacpac \
  /TargetConnectionString:"Server=tcp:<server-name>.database.windows.net,1433;Initial Catalog=<database>;Authentication=Active Directory Default;Encrypt=True;" \
  /DeployScriptPath:publish.sql
```

`/OutputPath` is the DeployReport parameter and DeployReport does not accept `/DeployReportPath`;
`github-actions-for-sql` owns that trap and the pipeline around it.

`/Action:Publish` does not create the logical server, and in Azure that has to exist first.
**It does create the database.** Measured against the container reporting `EngineEdition` 5:
publishing a dacpac at a database name that did not exist printed `Creating database <name>...`,
then created the table, and the row count in `sys.databases` went from 0 to 1. Do not add a create
step before a publish on the assumption that it is required.

## Check it worked

Three checks in the order the failures happen. The first two need no database at all.

The dacpac declares the platform the publish will compare against the server, and that is the
value that decides the refusal, not the text in the project file:

```bash
unzip -p ShopDb/bin/Debug/ShopDb.dacpac model.xml | grep -o 'DspName="[^"]*"'
```

Expect exactly `DspName="Microsoft.Data.Tools.Schema.Sql.SqlAzureV12DatabaseSchemaProvider"`.
Anything else and the publish to Azure SQL Database is refused during plan generation.

Everything the build refuses to read sits in the package under a fixed name:

```bash
unzip -l ShopDb/bin/Debug/ShopDb.dacpac
```

Expect `refactor.xml` if this release carries a rename, `postdeploy.sql` if it carries a
post-deployment script, and `predeploy.sql` if it carries a pre-deployment one. Measured
2026-09-03: undeclared, the dacpac holds four entries and no `refactor.xml`; declared, five. A
missing entry means the item was never declared, and the build did not complain.

Then, after the publish, ask the target whether anything is left:

```bash
sqlpackage /Action:DeployReport /SourceFile:ShopDb/bin/Debug/ShopDb.dacpac \
  /TargetConnectionString:"<the same connection string>" /OutputPath:after.xml
grep -c "<Operation " after.xml
```

Expect `0`, and expect `<Alerts />` with nothing inside it. A publish that landed leaves the next
deploy report nothing to do, so any count above zero names an object the run did not apply.

## References

- Open [target-platform-and-refactorlog-runs.md](references/target-platform-and-refactorlog-runs.md) when a
  table above needs reproducing, when a build or publish message you are seeing does not match one
  quoted here, or to look up a property or SqlPackage option this body only names in passing.
- `sdk/Sdk.props` and `sdk/Sdk.targets` inside the `Microsoft.Build.Sql` package in the local
  NuGet cache: read them when a file is sitting in the project directory and is not in the build.
- Microsoft Learn is the authority on whether a property or item type exists. Open
  [SQL projects properties](https://learn.microsoft.com/sql/tools/sql-database-projects/concepts/project-properties),
  [target platform](https://learn.microsoft.com/sql/tools/sql-database-projects/concepts/target-platform)
  or [refactoring](https://learn.microsoft.com/sql/tools/sql-database-projects/concepts/refactor-overview)
  before writing a property this body does not name.
