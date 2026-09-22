---
name: azure-functions-sql-bindings
description: >-
  Wires Azure Functions to Azure SQL Database with the SQL input and output bindings and the SQL
  trigger, including the change tracking the trigger cannot run without and the identity
  permissions the trigger needs beyond the ones the bindings need. Use when a user asks for "a
  serverless CRUD API over SQL", to "add a SQL input binding", "write to SQL from a function",
  "react to inserts and updates", "SQL trigger function", "SqlTrigger", "SqlInput", "SqlOutput",
  or says "my SQL trigger never fires and there is no error". Also use when an output binding
  silently updated an existing row instead of inserting, which is the documented upsert behaviour.
  This is the Azure SQL Database story; the same bindings against the local Azure SQL Database
  container belong to azuresql-db-functions, and connection reuse across invocations to the
  per-language connect skills.
---

# Azure Functions with the Azure SQL bindings

Two bindings and a trigger. The bindings are straightforward. **The trigger has a prerequisite
that fails without failing the app**, which is what this skill exists for.

Every command and C# block below was measured 2026-09-03 against Core Tools 4.12.0, .NET SDK
8.0.421 and `Microsoft.Azure.Functions.Worker.Extensions.Sql` 3.1.536. Error numbers are
from Microsoft Learn.

## What this skill does not own

| Question | Skill |
|---|---|
| These bindings against the local Azure SQL Database container | `azuresql-db-functions` |
| Reusing a connection across invocations, pool sizing, retry | `connect-from-dotnet`, `connect-from-python`, `connect-from-typescript-and-node` |
| Getting the identity to a working passwordless connection | `entra-id-auth` |
| Publishing the app and its infrastructure | `deploy-app-to-azure` |

The bindings open their own connections, so that pooling advice is about code you write inside the
function.

## Step 0: scaffold and add the extension

```bash
func init todo-fn --worker-runtime dotnet-isolated
cd todo-fn
dotnet add package Microsoft.Azure.Functions.Worker.Extensions.Sql
```

That resolved 3.1.536, clearing the v3.1.284 floor Learn sets for Consumption plans. Two
things the tooling does not tell you:

**Core Tools 4.12.0 scaffolds `net10.0`.** On .NET SDK 8.0.421 the next restore fails with
`error NETSDK1045: The current .NET SDK does not support targeting .NET 10.0`. Set
`<TargetFramework>` to a version your SDK has before you add the package.

**`func new` cannot create the SQL functions, though `func templates list` advertises them.** The
template name loses its spaces and is then rejected:

```bash
func templates list | grep 'SQL Trigger'
func new --template "SQL Trigger" --name ToDoTrigger
```

The first prints `SQL Trigger`. The second fails with
`Unknown template 'SQLTrigger' (Parameter 'templateName')`, as do `SqlTrigger`, `SQLTrigger` and
`SQL Input Binding`. `HTTP trigger` succeeds in the same command, so a working `func new` proves
nothing about the SQL templates. Write the attribute by hand.

## The failure this skill exists to prevent

The trigger is built on SQL change tracking. At startup the listener asks the database for
`CHANGE_TRACKING_MIN_VALID_VERSION(<table-id>)`, which Learn documents as returning null when
change tracking is off for the database, the object id is invalid, or permission to the table is
insufficient. The listener throws on that null, before it polls once.

**What that looks like from outside is nothing.** The host catches it and restarts that one
listener with exponential backoff, which Learn documents as startup retries. The app starts,
reports healthy, keeps serving every other function. The trigger never fires, and the only evidence
is one error line naming the listener rather than the missing feature. So change tracking is step
one, not a tuning step.

## Step 1: enable change tracking, in two places

Two statements. Enabling it on the database does **not** enable it on any table, and the table
statement fails if the database is not enabled first.

```sql
ALTER DATABASE CURRENT
SET CHANGE_TRACKING = ON
(CHANGE_RETENTION = 2 DAYS, AUTO_CLEANUP = ON);

ALTER TABLE [dbo].[ToDo]
ENABLE CHANGE_TRACKING;
```

`CHANGE_RETENTION` defaults to 2 days and is how far back the trigger catches up; an app stopped
longer loses the older changes. `AUTO_CLEANUP = OFF` pauses that removal while diagnosing a stalled
trigger. These options cannot be combined with other `ALTER DATABASE` options in one statement,
which fails with Msg 22114.

**The monitored table must have a primary key.** Without one the second statement fails with
`Msg 4997, Cannot enable change tracking on table '<name>'. Change tracking requires a primary key
on the table.` This skill printed Msg 22119 for that refusal until 2026-09-06, when it was measured
on the Azure SQL Database container at 18.0.226_4_147 and came back 4997. A deployment log grepped
for 22119 finds nothing. The cloud number is not verified here, so match on the text if you are
reading a log from a real Azure SQL Database.

## Step 2: write the trigger

The trigger receives a batch of changes, each carrying the changed item and the operation
(`Insert`, `Update`, `Delete`). This compiles as written:

```csharp
[Function("ToDoTrigger")]
public static void Run(
    [SqlTrigger("[dbo].[ToDo]", "SqlConnectionString")]
    IReadOnlyList<SqlChange<ToDoItem>> changes,
    FunctionContext context)
{
    foreach (SqlChange<ToDoItem> change in changes)
    {
        context.GetLogger("ToDoTrigger").LogInformation(
            "{Operation} on {Id}", change.Operation, change.Item.Id);
    }
}
```

Open [references/bindings-by-language.md](references/bindings-by-language.md) before writing this
declaration in anything but C#: the attribute name, argument casing and package change per
language, and nothing else does.

**Changes are batched per row, not per statement.** A row written three times between two polls
arrives as one entry, showing the difference between the last processed state and now.
Anything needing every intermediate value needs another mechanism.

## Step 3: grant the trigger more than the bindings need

`db_datareader` and `db_datawriter` are enough for the input and output bindings. Microsoft's
wording is that they **are not sufficient** for the trigger, which reads change tracking and keeps
its own state and leases tables in an `az_func` schema it creates if absent.

```sql
GRANT CREATE TABLE TO [<identity-name>];
GRANT CREATE SCHEMA TO [<identity-name>];

GRANT SELECT ON [dbo].[ToDo] TO [<identity-name>];
GRANT VIEW CHANGE TRACKING ON [dbo].[ToDo] TO [<identity-name>];

GO
CREATE SCHEMA az_func;
GO
GRANT ALTER ON SCHEMA::az_func TO [<identity-name>];
GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA::az_func TO [<identity-name>];
```

Missing these fails the same way: a listener that will not start, an app that looks fine.

## Step 4: input and output bindings

The input binding runs a query or stored procedure and hands the rows to the function.
**Parameters are bound, not interpolated**, which keeps a route value out of the SQL text:

```csharp
[SqlInput(
    commandText: "SELECT [Id], [title] FROM dbo.ToDo WHERE Id = @Id",
    commandType: System.Data.CommandType.Text,
    parameters: "@Id={Query.id}",
    connectionStringSetting: "SqlConnectionString")]
IEnumerable<ToDoItem> todo
```

`parameters` is one string of the form `@a=1,@b=2`. No name or value may contain a comma or an
equals sign, a real limit binding free text.

The output binding takes an object or a collection and a table name:

```csharp
[SqlOutput("dbo.ToDo", connectionStringSetting: "SqlConnectionString")]
public ToDoItem ToDoItem { get; set; }
```

**It upserts.** Learn states the output bindings use T-SQL `MERGE`, so a write whose key already
exists updates that row rather than failing, and an agent treating the binding as an insert will
report a create that was an overwrite. `MERGE` also needs `SELECT` on the target, not only
`INSERT`.

Two limits. Columns typed `NTEXT`, `TEXT` or `IMAGE` are unsupported and the upsert fails, because
they are incompatible with the `OPENJSON` the binding builds its `MERGE` from. And an
exception in the binding stops the function, so an HTTP trigger returns 500 unless
`IAsyncCollector` is used and `FlushAsync` awaited inside a try block.

## Step 5: point it at Azure SQL Database, passwordless

`connectionStringSetting` names an **application setting**, not a connection string. Locally it
lives in `local.settings.json`, which never goes into source control. In Azure it is an app setting
whose value carries an identity:

```text
Server=<server-name>.database.windows.net; Authentication=Active Directory Default; Database=<database-name>; User Id=<client-id-of-user-assigned-identity>
```

Learn's managed identity tutorial states `Active Directory Default` resolves to developer
credentials locally and the managed identity in Azure, so one string serves both, and that
`User Id` is omitted for a system-assigned identity. The bindings overview page shows
`Active Directory Managed Identity` instead; both are valid, only the first also works locally.
The identity needs a database user:

```sql
CREATE USER [<identity-name>] FROM EXTERNAL PROVIDER;
ALTER ROLE db_datareader ADD MEMBER [<identity-name>];
ALTER ROLE db_datawriter ADD MEMBER [<identity-name>];
GO
```

`<identity-name>` is the identity's own name for a user-assigned identity, the function app's name
for a system-assigned one. If a trigger is in play, add the grants from step 3 on top.

## Step 6: tune the loop and let it scale

`MaxBatchSize` defaults to 100, `PollingIntervalMs` to 1000 and `MaxChangesPerWorker` to 1000, all
under `extensions.Sql` in `host.json`. On a Premium plan, scaling out on pending change count needs
runtime scale monitoring:

```bash
az resource update -g <resource-group> -n <function-app-name>/config/web \
  --set properties.functionsRuntimeScaleMonitoringEnabled=1 \
  --resource-type Microsoft.Web/sites
```

A batch that throws is retried after 60 seconds; a row failing five times in a row is ignored for
all future changes. A poison row is skipped, not queued behind, so log the key on failure or the
loss is invisible.

## Check it worked

Change tracking is provable from SQL alone, before the app runs. Two rows back, one per query, or
the trigger does not start:

```bash
sqlcmd -S <server-name>.database.windows.net -d <database-name> -G -Q \
  "SELECT DB_NAME() AS db, is_auto_cleanup_on, retention_period, retention_period_units_desc
   FROM sys.change_tracking_databases WHERE database_id = DB_ID();
   SELECT OBJECT_NAME(object_id) AS tracked_table FROM sys.change_tracking_tables;"
```

An empty second result set is the common failure: the database statement looks done. Then confirm
what the listener reads, a number rather than `NULL` once both statements have run:

```sql
SELECT CHANGE_TRACKING_MIN_VALID_VERSION(OBJECT_ID('dbo.ToDo')) AS min_valid_version;
```

Only then read the host log: `Started SQL trigger listener for table` is the success line, and
`Failed to start SQL trigger listener` on a healthy app is this skill's subject. Finally,
write the same primary key twice through the output binding. Two 201 responses and one row
confirms the `MERGE`.

## Do not

- Do not report a trigger as working because the function app started. It starts either way.
- Do not enable change tracking on the database and stop. The table statement is separate, and is
  the one usually missed.
- Do not grant only `db_datareader` and `db_datawriter` to a trigger identity.
- Do not create the `az_func` tables by hand or rename them. The trigger owns them.
- Do not treat the output binding as an insert. It is a `MERGE` on the primary key.
- Do not reach for `func new` here, or read a name in `func templates list` as proof it scaffolds.
- Do not open your own connection per invocation. That belongs to the connect skills.

## References

- [references/bindings-by-language.md](references/bindings-by-language.md): read it when the
  target language is not C#, or to look up the bundle and package a language needs.
- [Azure SQL bindings for Functions](https://learn.microsoft.com/azure/azure-functions/functions-bindings-azure-sql):
  the authority. Fetch it rather than recalling it.
- [Azure SQL trigger for Functions](https://learn.microsoft.com/azure/azure-functions/functions-bindings-azure-sql-trigger):
  fetch it for the host.json and local.settings.json tables and the retry rules.
- [About change tracking](https://learn.microsoft.com/sql/relational-databases/track-changes/about-change-tracking-sql-server):
  retention, cleanup and what the change tables hold.
