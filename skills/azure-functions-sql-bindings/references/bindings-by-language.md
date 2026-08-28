# Binding declarations by language

## Contents

- [What you install](#what-you-install)
- [C#, isolated worker model](#c-isolated-worker-model)
- [C#, in-process model](#c-in-process-model)
- [Java](#java)
- [Python, v2 programming model](#python-v2-programming-model)
- [JavaScript and TypeScript](#javascript-and-typescript)
- [PowerShell and the function.json form](#powershell-and-the-functionjson-form)
- [Property names, in one table](#property-names-in-one-table)
- [Host settings](#host-settings)

Verified against the Microsoft Learn binding reference on 2026-08-27. The bindings require version
4.x or later of the Functions runtime. Go is not supported.

## What you install

| Language | What to add |
|---|---|
| C#, isolated worker | `dotnet add package Microsoft.Azure.Functions.Worker.Extensions.Sql` |
| C#, in-process | `dotnet add package Microsoft.Azure.WebJobs.Extensions.Sql` |
| Java | The extension bundle, plus `com.microsoft.azure.functions:azure-functions-java-library-sql` |
| Python, JavaScript, TypeScript, PowerShell | The extension bundle only |

The extension bundle reference lives in `host.json`:

```json
{
  "version": "2.0",
  "extensionBundle": {
    "id": "Microsoft.Azure.Functions.ExtensionBundle",
    "version": "[4.0.0, 5.0.0)"
  }
}
```

Every function targeting the same database must use the same extension version. Mixing them is
called out as a breaking-change hazard in the reference.

The in-process C# model reaches end of support on 10 November 2026, so new work belongs on the
isolated worker model.

## C#, isolated worker model

```csharp
// input
[SqlInput(
    commandText: "SELECT [Id], [title] FROM dbo.ToDo WHERE Id = @Id",
    commandType: System.Data.CommandType.Text,
    parameters: "@Id={Query.id}",
    connectionStringSetting: "SqlConnectionString")]
IEnumerable<ToDoItem> todo

// output, on a property of a multiple-output return type
[SqlOutput("dbo.ToDo", connectionStringSetting: "SqlConnectionString")]
public ToDoItem ToDoItem { get; set; }

// trigger
[SqlTrigger("[dbo].[ToDo]", "SqlConnectionString")]
IReadOnlyList<SqlChange<ToDoItem>> changes
```

`SqlChange<T>` carries `Item` and `Operation`, where `Operation` is `Insert`, `Update` or `Delete`.

## C#, in-process model

Both the input and the output binding are the single `[Sql]` attribute; only the direction of the
parameter distinguishes them. The trigger keeps its own name.

```csharp
[Sql(commandText: "dbo.ToDo", connectionStringSetting: "SqlConnectionString")]
IAsyncCollector<ToDoItem> toDoItems

[SqlTrigger("[dbo].[ToDo]", "SqlConnectionString")]
IReadOnlyList<SqlChange<ToDoItem>> changes
```

With `IAsyncCollector`, the rows are written when `FlushAsync` is awaited, which is the one place
an output binding exception can be caught before it stops the function.

## Java

Annotations from `com.microsoft.azure.functions.sql.annotation`, all requiring `name`:

```java
@SQLInput(name = "todo", commandText = "SELECT * FROM dbo.ToDo WHERE Id = @Id",
          commandType = "Text", parameters = "@Id={Query.id}",
          connectionStringSetting = "SqlConnectionString")

@SQLOutput(name = "toDoItem", commandText = "dbo.ToDo",
           connectionStringSetting = "SqlConnectionString")

@SQLTrigger(name = "todoItems", tableName = "[dbo].[ToDo]",
            connectionStringSetting = "SqlConnectionString")
```

Note the casing: `SQL` in Java, `Sql` in C#.

## Python, v2 programming model

Decorators on the function app object, with snake_case arguments:

```python
@app.sql_input(arg_name="todo",
               command_text="SELECT * FROM dbo.ToDo WHERE Id = @Id",
               command_type="Text",
               parameters="@Id={id}",
               connection_string_setting="SqlConnectionString")

@app.sql_output(arg_name="todo",
                command_text="[dbo].[ToDo]",
                connection_string_setting="SqlConnectionString")

@app.sql_trigger(arg_name="todo",
                 table_name="ToDo",
                 connection_string_setting="SqlConnectionString")
```

Rows are `func.SqlRow` and `func.SqlRowList`; `func.SqlRow.from_dict` builds one from a parsed
body.

## JavaScript and TypeScript

In the v4 programming model the bindings are `input.sql()` and `output.sql()`, taking an options
object with `commandText`, `commandType`, `parameters` and `connectionStringSetting`. The v3 model
uses the `function.json` form below.

## PowerShell and the function.json form

```json
{
  "name": "todoItems",
  "type": "sql",
  "direction": "out",
  "commandText": "dbo.ToDo",
  "connectionStringSetting": "SqlConnectionString"
}
```

```json
{
  "name": "todoChanges",
  "type": "sqlTrigger",
  "direction": "in",
  "tableName": "dbo.ToDo",
  "connectionStringSetting": "SqlConnectionString"
}
```

`type` is `sql` for both the input and the output binding, distinguished by `direction` (`in` or
`out`). The trigger's `type` is `sqlTrigger` and its `direction` is `in`. In PowerShell the value
reaches the binding through `Push-OutputBinding -Name <name>`.

## Property names, in one table

| Concept | C# isolated | C# in-process | Java | Python v2 | function.json |
|---|---|---|---|---|---|
| Input | `SqlInput` | `Sql` | `SQLInput` | `sql_input` | `type: sql, direction: in` |
| Output | `SqlOutput` | `Sql` | `SQLOutput` | `sql_output` | `type: sql, direction: out` |
| Trigger | `SqlTrigger` | `SqlTrigger` | `SQLTrigger` | `sql_trigger` | `type: sqlTrigger` |
| Query or table | `commandText` | `commandText` | `commandText` | `command_text` | `commandText` |
| Text or procedure | `commandType` | `commandType` | `commandType` | `command_type` | `commandType` |
| Bound parameters | `parameters` | `parameters` | `parameters` | `parameters` | `parameters` |
| Monitored table | `TableName` | `TableName` | `tableName` | `table_name` | `tableName` |
| Setting name | `connectionStringSetting` | `connectionStringSetting` | `connectionStringSetting` | `connection_string_setting` | `connectionStringSetting` |

`commandType` is `Text` for a query and `StoredProcedure` for a procedure. `parameters` is one
string in the form `@a=1,@b=2`, and neither a name nor a value may contain a comma or an equals
sign. The trigger also accepts an optional leases table name; leave it unset unless two functions
must watch the same table.

## Host settings

Under `extensions.Sql` in `host.json`:

| Setting | Default | Effect |
|---|---|---|
| `MaxBatchSize` | 100 | Changes handed to the function per iteration |
| `PollingIntervalMs` | 1000 | Delay between batches |
| `MaxChangesPerWorker` | 1000 | Pending changes per worker before scaling out, with runtime scale monitoring on |

The same three exist as `Sql_Trigger_MaxBatchSize`, `Sql_Trigger_PollingIntervalMs` and
`Sql_Trigger_MaxChangesPerWorker` in `local.settings.json` for local runs.
