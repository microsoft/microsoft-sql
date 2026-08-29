# Measured behaviour of the build and the publish

## Contents

- [How these were run](#how-these-were-run)
- [Target platform against the build](#target-platform-against-the-build)
- [Target platform against the publish](#target-platform-against-the-publish)
- [What the build parses](#what-the-build-parses)
- [Atomicity of a publish](#atomicity-of-a-publish)
- [Rename, refactorlog and data loss](#rename-refactorlog-and-data-loss)
- [Objects in the target and not in the project](#objects-in-the-target-and-not-in-the-project)
- [Code analysis](#code-analysis)
- [Project file properties worth setting](#project-file-properties-worth-setting)
- [SqlPackage options this skill relies on](#sqlpackage-options-this-skill-relies-on)

## How these were run

Every result below came from building a project and publishing it, on 2026-08-28, with:

| Component | Version |
|---|---|
| .NET SDK | 8.0.421, on macOS on an arm64 host |
| `Microsoft.Build.Sql` | 2.2.0, the current stable release |
| `Microsoft.Build.Sql.Templates` | 2.2.0 |
| SqlPackage | 170.4.83.3, installed with `dotnet tool install -g microsoft.sqlpackage` |
| Target engine | the Azure SQL Database container, `EngineEdition` 5, `SQL Azure`, `12.0.2000.8` |

The project is four files: a table, a Service Broker queue, a table using a filegroup clause, and
a procedure calling a mail stored procedure.

## Target platform against the build

`dotnet new sqlproj` offers ten target platforms and defaults to the newest box-product one. The
choice is written into the project as a single `DSP` property, and the schema provider for Azure
SQL Database is `Microsoft.Data.Tools.Schema.Sql.SqlAzureV12DatabaseSchemaProvider`.

| Source file | Default target | `SqlAzureV12` |
|---|---|---|
| `CREATE QUEUE [dbo].[OrderQueue];` | accepted, no diagnostic | `Build error SQL70015: Statement 'CREATE QUEUE' is not supported for the targeted platform.` |
| `CREATE TABLE ... ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]` | accepted | accepted, no diagnostic either |
| procedure calling `sys.sp_send_dbmail` | `Build warning SQL71502`, four of them | the same four warnings, still warnings |

Two things follow. The target platform catches statements and not references, and it does not
catch everything a reader might expect it to: a filegroup clause passes under both.

Escalating the warning class turns the third row into a build failure:

```bash
dotnet build -t:Rebuild -p:TreatTSqlWarningsAsErrors=true
# 4 Error(s), Build FAILED.
```

## Target platform against the publish

Publishing a dacpac whose declared platform is not Azure SQL Database:

```text
Publishing to database 'shopdb' on server '<server>'.
Initializing deployment (Start)
Initializing deployment (Failed)
*** An error occurred during deployment plan generation. Deployment cannot continue.
A project which specifies <target platform> as the target platform cannot be published to
Microsoft Azure SQL Database v12.
Time elapsed 0:00:01.45
```

Exit code 1. The message names the platform the project declared. Three different non-Azure
targets were tried and all three were refused with the same shape of message, at the same point,
before the deployment plan existed. Nothing is written to the database.

## What the build parses

`Sdk.props` globs `Build` items as `**/*.sql`, and `Sdk.targets` then removes from that glob
anything declared as `PreDeploy`, `PostDeploy`, `None` or an extension configuration. There is a
`RefactorLog` item type, and **no glob creates one**.

Evidence for the deployment scripts being unparsed: a post-deployment script whose entire body is
`INSERT INTO dbo.NoSuchTable (id) VALUES (1);` builds with `0 Error(s), 0 Warning(s)`. The same
statement inside a procedure produces `SQL71502`.

Evidence for the refactorlog not being globbed: a file named `<ProjectName>.refactorlog` sitting
beside the project produced a dacpac containing four entries and no `refactor.xml`. Adding
`<RefactorLog Include="ShopDb.refactorlog" />` produced five entries including `refactor.xml`.

## Atomicity of a publish

One publish that adds a column and then runs a failing post-deployment script:

```text
Updating database (Start)
Altering Table [dbo].[Product]...
post-deploy starting
An error occurred while the batch was being executed.
Updating database (Failed)
*** Could not deploy package.
Error SQL72014: Core Microsoft SqlClient Data Provider: Msg 208, Level 16, State 1, Line 2
  Invalid object name 'dbo.NoSuchTable'.
Error SQL72045: Script execution error.
```

Exit code 1. `sys.columns` afterwards still lists the added column.

The run was repeated with `/p:IncludeTransactionalScripts=True` after dropping the column again.
Same failure, and the column is present afterwards again. The option does not put a deployment
script inside the transaction.

## Rename, refactorlog and data loss

`dbo.Product` held two rows. The project renamed `Name` to `ProductName`.

| Configuration | Output | Exit | Data |
|---|---|---|---|
| no refactorlog | `Warning SQL72015: The column [dbo].[Product].[Name] is being dropped, data loss could occur.` then `Msg 50000 ... Rows were detected. The schema update is terminating because data loss might occur.` | 1 | unchanged |
| refactorlog present but not declared | identical to the row above | 1 | unchanged |
| refactorlog declared | `The following operation was generated from a refactoring log file <key>` / `Rename [dbo].[Product].[Name] to ProductName` | 0 | both values preserved |
| no refactorlog, `/p:BlockOnPossibleDataLoss=False` | `*** The column [dbo].[Product].[Name] is being dropped, data loss could occur.` then `Starting rebuilding table [dbo].[Product]...` then `Successfully published database.` | **0** | **both values null** |

The last row printed eleven lines in total. The only warning sat above `Initializing deployment
(Complete)`, and the final line was a success.

When a rename is applied, `dbo.__RefactorLog` appears in the target database and records the
operation key, so the same rename is not attempted twice.

## Objects in the target and not in the project

A table and a procedure were created directly in the target. The project contained neither.

| Publish | Result |
|---|---|
| default options | `Successfully published database.` Both objects still present |
| `/p:DropObjectsNotInSource=True` | `Dropping Table [dbo].[Legacy]...` / `Dropping Procedure [dbo].[LegacyProc]...` Both gone, `__RefactorLog` kept |

## Code analysis

`<RunSqlCodeAnalysis>true</RunSqlCodeAnalysis>` in the project runs the rule set during
`dotnet build`. On a procedure using `SELECT *` and `@@IDENTITY`:

```text
StaticCodeAnalysis warning SR0001: Microsoft.Rules.Data : The shape of the result set produced
  by a SELECT * statement will change if the underlying table or view structure changes.
StaticCodeAnalysis warning SR0008: Microsoft.Rules.Data : Potential misuse of system function
  @@IDENTITY.
Build succeeded.   0 Error(s)   2 Warning(s)
```

Escalating one rule to an error, which fails the build:

```bash
dotnet build -t:Rebuild -p:SqlCodeAnalysisRules='+!Microsoft.Rules.Data.SR0001'
# StaticCodeAnalysis error SR0001: ...
# 1 Error(s), Build FAILED.
```

Without `-t:Rebuild` an up-to-date project reports `0 Warning(s)` because it does not rebuild the
model, so the analysis never runs. A run that reports nothing may have analysed nothing.

The `sqlcodeanalysis` template creates a C# project targeting `netstandard2.1` with a
`Microsoft.SqlServer.DacFx` package reference and a sample rule class. It is for authoring a
custom rule and packaging it, not for enabling analysis.

## Project file properties worth setting

| Property or item | Why |
|---|---|
| `<DSP>` | the target platform. The only thing deciding which rules the build applies |
| `<RunSqlCodeAnalysis>` | runs the rule set inside the build |
| `<TreatTSqlWarningsAsErrors>` | turns unresolved references and their kind into build failures |
| `<SqlCodeAnalysisRules>` | `+!<rule id>` escalates one rule to an error, `-` disables one |
| `<PostDeploy Include=... />` | the one script that runs after the schema changes. Unparsed, so make it idempotent |
| `<PreDeploy Include=... />` | runs before them, and is equally unparsed |
| `<RefactorLog Include=... />` | never globbed. Without this line the rename is a drop and an add |

## SqlPackage options this skill relies on

| Option | Default | Effect |
|---|---|---|
| `/p:BlockOnPossibleDataLoss` | `True` | stops a deployment that would drop data. Turning it off turns the block into a silent success |
| `/p:DropObjectsNotInSource` | `False` | the target keeps objects the project does not describe |
| `/p:IncludeTransactionalScripts` | `False` | wraps generated schema statements, and not the deployment scripts |
| `/Action:DeployReport` | | writes the planned changes as XML and changes nothing |
| `/Action:Script` | | writes the deployment T-SQL and changes nothing |
| `/Action:DriftReport` | | reports how the target has diverged from what was last published |

`Extract`, `Import` and `Export` are SqlPackage actions but are not accepted by the GitHub action
wrapper, which is covered in `github-actions-for-sql`.
