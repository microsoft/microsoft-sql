---
name: azure-functions-sql-bindings
description: >-
  Wires Azure Functions to Azure SQL Database with the SQL input and output bindings and the SQL
  trigger, including the change tracking the trigger cannot run without and the identity
  permissions the trigger needs beyond the ones the bindings need. Use when a user asks to "add a
  SQL input binding", "write to SQL from a function", "run code when a row changes", "SQL trigger
  function", "SqlTrigger", "sqlTrigger", "SqlInput", "SqlOutput", "SqlConnectionString", or says
  "my SQL trigger never fires and there is no error". Also use when an output binding silently
  updated an existing row instead of inserting, which is the documented upsert behaviour. This is
  the Azure SQL Database story; the same bindings against the local Azure SQL Database container
  belong to azuresql-db-functions, and connection reuse across invocations belongs to the
  per-language connect skills.
license: MIT
---

# Azure Functions with the Azure SQL bindings

Two bindings and a trigger. The bindings are straightforward. **The trigger has a prerequisite
that fails without failing the app**, and that is what this skill exists for.

Verified against Microsoft Learn and the extension source (`SqlTriggerListener.cs`,
`SqlTriggerUtils.cs`) on 2026-08-27.

## What this skill owns, and what it does not

**Owns**: the binding and trigger shapes per language, the change tracking prerequisite, the
permissions the trigger needs, and running the result against Azure SQL Database on an identity.

**Does not own.** Send these elsewhere rather than answering them here:

| Question | Skill |
|---|---|
| The same bindings against the local Azure SQL Database container | `azuresql-db-functions` |
| Reusing one connection across invocations, pool sizing, retry | `connect-from-dotnet`, `connect-from-python`, `connect-from-typescript-and-node` |
| An instant REST or GraphQL API instead of hand-written handlers | `dab-rest-and-graphql` |
| Which data access path the application should take at all | `build-app-on-azure-sql` |
| Getting the identity to a working passwordless connection | `entra-id-auth` |
| Publishing the function app and its infrastructure | `deploy-app-to-azure` |

The bindings open their own connections through the extension, so the pooling advice in the connect
skills applies to code you write inside the function, not to the bindings themselves.

## The failure this skill exists to prevent

The SQL trigger is built on SQL change tracking. At startup the listener runs
`SELECT CHANGE_TRACKING_MIN_VALID_VERSION(<table-id>)` against the monitored table. If change
tracking is not enabled, that returns null and the listener throws
`Could not find change tracking enabled for table: '<table>'` before it polls once.

**What that looks like from outside is nothing.** The Functions host catches the exception, logs
`Failed to start SQL trigger listener for table ...`, and retries that one listener with
exponential backoff. The app starts. It reports healthy. Every other function in it keeps working.
The trigger simply never fires, and the only evidence is one error line in the host log that names
the listener rather than the missing feature.

So change tracking is step one, not a tuning step, and confirming it is part of finishing the task.

## Step 1: enable change tracking, in two places

These are two statements. Enabling it on the database does **not** enable it on any table, and
enabling it on a table fails if the database is not enabled first.

```sql
ALTER DATABASE [<database-name>]
SET CHANGE_TRACKING = ON
(CHANGE_RETENTION = 2 DAYS, AUTO_CLEANUP = ON);

ALTER TABLE [dbo].[<table-name>]
ENABLE CHANGE_TRACKING;
```

`CHANGE_RETENTION` is how far back the trigger can catch up. A function app stopped for longer than
the retention window loses the changes older than it. `AUTO_CLEANUP` set to `OFF` pauses that
removal, which is worth doing while diagnosing a stalled trigger.

Confirm rather than assume:

```sql
SELECT DB_NAME() AS database_name, is_auto_cleanup_on, retention_period, retention_period_units_desc
FROM sys.change_tracking_databases
WHERE database_id = DB_ID();

SELECT OBJECT_SCHEMA_NAME(object_id) AS table_schema, OBJECT_NAME(object_id) AS table_name
FROM sys.change_tracking_tables;
```

Two rows, one from each query, or the trigger will not start. A missing row from the second query
is the common case, because the database-level statement looks like it did the job.

**The monitored table must have a primary key.** Without one the listener throws
`Could not find primary key created in table` the same way, and disappears the same way.

## Step 2: write the trigger

The trigger receives a batch of changes, each carrying the changed item and the operation
(`Insert`, `Update` or `Delete`).

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

The declaration names differ per language and nothing else does. See
[references/bindings-by-language.md](references/bindings-by-language.md).

**Changes are batched per row, not per statement.** If a row is written three times between two
polls, the function sees one entry showing the difference between the last processed state and the
current one. Handlers that need every intermediate value need a different mechanism.

## Step 3: grant the trigger what it needs, which is more than the bindings need

`db_datareader` and `db_datawriter` are enough for the input and output bindings. Microsoft's own
wording is that they **are not sufficient** for the trigger. The trigger reads change tracking and
maintains its own state and leases tables in a schema named `az_func`, which it creates if absent.

```sql
GRANT CREATE TABLE TO [<identity-name>];
GRANT CREATE SCHEMA TO [<identity-name>];

GRANT SELECT ON [dbo].[<table-name>] TO [<identity-name>];
GRANT VIEW CHANGE TRACKING ON [dbo].[<table-name>] TO [<identity-name>];

CREATE SCHEMA az_func;
GO
GRANT ALTER ON SCHEMA::az_func TO [<identity-name>];
GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA::az_func TO [<identity-name>];
```

Missing these produces the same shape of failure as missing change tracking: a listener that will
not start, an app that looks fine.

## Step 4: input and output bindings

The input binding runs a query or a stored procedure and hands the rows to the function.
**Parameters are bound, not interpolated**, which is what keeps a route value out of the SQL text:

```csharp
[SqlInput(
    commandText: "SELECT [Id], [title] FROM dbo.ToDo WHERE Id = @Id",
    commandType: System.Data.CommandType.Text,
    parameters: "@Id={Query.id}",
    connectionStringSetting: "SqlConnectionString")]
```

`parameters` is a single string of the form `@a=1,@b=2`. Neither a name nor a value may contain a
comma or an equals sign, which is a real limit when binding free text.

The output binding takes an object or a collection and a table name. **It upserts.** The generated
statement is a T-SQL `MERGE` keyed on the primary key, so writing a row whose key already exists
updates that row rather than failing. An agent that treats the output binding as an insert will
report a create that was actually an overwrite. `MERGE` also means the identity needs `SELECT` on
the target table, not only `INSERT`.

Two limits worth knowing before choosing the output binding: columns typed `NTEXT`, `TEXT` or
`IMAGE` are not supported and the write fails, and an exception thrown by the binding stops the
function, so an HTTP trigger returns 500 unless the collection form is used and `FlushAsync` is
awaited inside a try block.

## Step 5: point it at Azure SQL Database without a password

The binding property is `connectionStringSetting`, and it names an **application setting**, not a
connection string. Locally that setting lives in `local.settings.json`, which never goes into
source control. In Azure it is an app setting, and its value should carry an identity:

```text
Server=<server-name>.database.windows.net;Database=<database-name>;Encrypt=true;Authentication=Active Directory Default;User Id=<client-id-of-the-user-assigned-identity>;
```

`Active Directory Default` resolves to developer credentials locally and to the managed identity in
Azure, so the same string works in both. Omit `User Id` for a system-assigned identity. The
identity needs a database user:

```sql
CREATE USER [<identity-name>] FROM EXTERNAL PROVIDER;
ALTER ROLE db_datareader ADD MEMBER [<identity-name>];
ALTER ROLE db_datawriter ADD MEMBER [<identity-name>];
GO
```

For a user-assigned identity `<identity-name>` is the identity's own name; for a system-assigned
one it is the function app's name. If a trigger is in play, add the grants from step 3 on top.

## Step 6: tune the loop, and let it scale

The trigger polls. `MaxBatchSize` defaults to 100 changes per iteration and `PollingIntervalMs` to
1000, both under `extensions.Sql` in `host.json`. On a Premium plan, scaling out on pending change
count needs runtime scale monitoring turned on:

```bash
az resource update -g <resource-group> -n <function-app-name>/config/web \
  --set properties.functionsRuntimeScaleMonitoringEnabled=1 \
  --resource-type Microsoft.Web/sites
```

If a single row throws five times in a row it is dropped from all future processing, so a poison
row is silently skipped rather than blocking the queue. Log the key on failure or the loss is
invisible.

For high-volume streaming rather than one invocation per change, change event streaming publishes
committed changes to Azure Event Hubs and is in preview.

## Validation rules

- `sys.change_tracking_databases` returns a row for the database, and `sys.change_tracking_tables`
  returns a row for the monitored table.
- The monitored table has a primary key.
- The host log contains `Started SQL trigger listener for table`, not
  `Failed to start SQL trigger listener`.
- The trigger's identity can read change tracking on the table and create the `az_func` schema and
  its tables, not just `db_datareader` and `db_datawriter`.
- The connection setting names an app setting; the deployed value carries an identity and no
  password, and `local.settings.json` is not in source control.
- Every input binding parameter is bound through `parameters`, with no value concatenated into the
  command text.
- Anything relying on the output binding to fail on a duplicate key has been rewritten, because it
  will upsert.

## Do not

- Do not report a trigger as working because the function app started. It starts either way.
- Do not enable change tracking on the database and stop. The table statement is separate and is
  the one usually missed.
- Do not grant only `db_datareader` and `db_datawriter` to a trigger identity. Those are the
  binding roles and Microsoft states they are not enough for the trigger.
- Do not create the `az_func` tables by hand or rename them. The trigger owns them.
- Do not treat the output binding as an insert. It is a `MERGE` on the primary key.
- Do not build a connection string into the binding. `connectionStringSetting` takes the name of a
  setting.
- Do not add the SQL trigger to a table with no primary key, or expect every intermediate value of
  a row that changed several times between polls.
- Do not open your own connection per invocation inside the function. That belongs to the
  per-language connect skills, and repeating it here would be a second opinion about the same
  thing.

## References

- [references/bindings-by-language.md](references/bindings-by-language.md): the exact attribute,
  annotation, decorator and configuration names for the input binding, the output binding and the
  trigger in each supported language, plus the package and extension bundle each one needs. Read it
  when writing the declaration for a language other than C#.
- [Azure SQL bindings for Functions](https://learn.microsoft.com/azure/azure-functions/functions-bindings-azure-sql):
  the authority. Fetch it rather than recalling it.
- [About change tracking](https://learn.microsoft.com/sql/relational-databases/track-changes/about-change-tracking-sql-server):
  retention, cleanup and what the change tables hold.
