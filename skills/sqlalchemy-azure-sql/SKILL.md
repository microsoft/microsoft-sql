---
name: sqlalchemy-azure-sql
description: >-
  Uses SQLAlchemy correctly against Azure SQL Database, where the dialect appends an OUTPUT
  clause to INSERT statements and that single clause explains two failures agents never connect:
  a hard error on any table carrying a trigger, and fast_executemany appearing to do nothing.
  Use when a user says "SQLAlchemy with Azure SQL", "mssql+pyodbc", "implicit_returning",
  "fast_executemany", "insertmanyvalues", "Alembic against Azure SQL", or pastes "the target
  table of the DML statement cannot have any enabled triggers if the statement contains an OUTPUT
  clause without INTO clause". Also use when an ORM insert fails on one table only, or a bulk load
  is no faster after fast_executemany was set. Covers the engine URL, the generated DML, type
  mapping and Alembic. Driver choice and installation belong to connect-from-python, retry and
  pool sizing to connect-to-azure-sql; Prisma, EF Core and Django have their own skills.
license: MIT
---

# SQLAlchemy on Azure SQL Database

SQLAlchemy talks to Azure SQL Database through a dialect whose generated SQL differs from every
other backend in one specific way, and almost every surprise in this stack traces back to it.

Verified on 2026-08-27 against SQLAlchemy 2.0.52, pyodbc 5.3.0 and Alembic 1.19.1 from the package
index, against the dialect source shipped in those releases, and against a live Azure SQL engine
reporting `EngineEdition` 5.

## The naming rule, first

The dialect is named `mssql`. It appears in exactly one place, the URL scheme:

```
mssql+pyodbc://...
```

**That string is a dialect identifier, not the name of the product.** Everywhere else, in prose, in
comments, in variable names and in anything written back to the user, the product is **Azure SQL
Database**. An agent that reads `mssql` in a URL and starts calling the database something else has
already begun giving advice for a different product with different limits.

## The engine URL

```python
from sqlalchemy import create_engine
from sqlalchemy.engine import URL

credential = {
    "username": os.environ["SQL_USER"],
    "password": os.environ["SQL_PASSWORD"],   # read it, never inline it
}

url = URL.create(
    "mssql+pyodbc",
    host=os.environ["SQL_HOST"],              # <server>.database.windows.net
    port=1433,
    database=os.environ["SQL_DATABASE"],
    query={"driver": "ODBC Driver 18 for SQL Server"},
    **credential,
)
engine = create_engine(url, pool_pre_ping=True)
```

Use `URL.create` rather than formatting a string. It escapes the characters that break a hand-built
URL, and it keeps the credential out of a literal.

Three points of ownership, so this skill does not repeat them:

- **Which driver, and installing it**, is `connect-from-python`. The newer first-party driver has a
  dialect only from SQLAlchemy 2.1.0b2, a pre-release series Microsoft states is not for production,
  so `mssql+pyodbc` is the production answer today.
- **Retry, transient faults and pool sizing** are `connect-to-azure-sql`. SQLAlchemy has no
  equivalent of a built-in retry policy, and `pool_pre_ping` does not cover it: it tests a
  connection at checkout, and a connection lost mid-transaction still loses the transaction and
  raises. Retry is the application's job.
- **Passwordless connections** are `entra-id-auth`. The identity reaches SQLAlchemy as an access
  token passed to the driver through a `do_connect` event, and the connection must then carry no
  user, no password and no `Trusted_Connection`, which the dialect otherwise adds for you. The
  token mechanics are in `connect-from-python`; get the database principal created first.

## The OUTPUT clause, which is the whole skill

To learn the value of a server-generated key, the dialect adds an OUTPUT clause to the INSERT.
Compiled from SQLAlchemy 2.0.52:

```sql
INSERT INTO orders (sku) OUTPUT inserted.id VALUES (?)
```

Azure SQL Database refuses that statement when the target table carries an enabled trigger:

```
Msg 334, Level 16, State 1
The target table 'dbo.orders' of the DML statement cannot have any enabled triggers
if the statement contains an OUTPUT clause without INTO clause.
```

Four properties decide how this plays out, and each one is a place agents guess wrong.

1. **It is per table, and nothing detects it.** The dialect has no trigger reflection and does not
   probe for one. A codebase where 40 models work and one fails is the normal shape of this bug.
2. **The switch is on the table, not the engine.** Declare it on every mapped class whose table
   carries a trigger:

   ```python
   class Order(Base):
       __tablename__ = "orders"
       __table_args__ = {"implicit_returning": False}
   ```

   For a Core table, pass `implicit_returning=False` to `Table`. The INSERT then compiles with no
   OUTPUT clause and the key is read back with `scope_identity()` instead.
3. **The engine-level parameter is a trap.** `create_engine(implicit_returning=...)` is deprecated,
   accepts only `True`, and its own documentation says it does nothing in SQLAlchemy 2.0. An agent
   that sets it on the engine has written a line that changes no SQL and emits a warning.
4. **The flag does not cover an explicit `returning()`.** `implicit_returning=False` suppresses the
   clause the dialect adds by itself. A hand-written `insert().returning(...)`, `update().returning(...)`
   or `delete().returning(...)` still compiles to OUTPUT without INTO, and still fails with Msg 334
   on a triggered table. Verified by compiling all three against a table declared with the flag off.

Triggers are common on tables that carry auditing or history, which is exactly where an ORM gets
pointed at an existing schema. Check for them before mapping one.

## fast_executemany, and what actually changed in 2.0

```python
engine = create_engine(url, fast_executemany=True)
```

The parameter has existed since SQLAlchemy 1.3 and is not new. What changed is what it does.

SQLAlchemy 2.0 introduced **insertmanyvalues**, a batched INSERT form that returns keys. Because it
returns keys, it took precedence over the driver's array binding, and setting `fast_executemany=True`
stopped having an effect in most cases. That was treated as a regression and fixed in **2.0.9**: the
flag now applies to multi-parameter INSERT statements **that carry no returning clause**. Azure SQL
Database support for insertmanyvalues was itself disabled in 2.0.9 and restored in 2.0.10, so
**2.0.10 is the floor** for anyone relying on this.

The consequence agents miss: an ORM insert of a mapped class with a server-generated key **does**
carry a returning clause, because that is the OUTPUT clause above. So on the default configuration,
`fast_executemany=True` changes nothing for exactly the bulk inserts people set it for. It takes
effect when the INSERT has no returning clause, which means one of:

- the rows already carry their primary keys, or
- the table is declared `implicit_returning=False`, or
- the load goes through Core rather than through identity-tracked ORM objects.

Two documented costs, so this is a decision rather than a default:

- The batch has to **fit in memory**, and the parameter is honoured for the Microsoft driver only.
- Parameter type hinting through `setinputsizes` is **not used** for those calls, which is where the
  reports of surprising type handling on large loads come from.

Everything else about moving large volumes, and whether an ORM is the right tool for it at all, is a
schema and loading question rather than a SQLAlchemy one.

## Type mapping worth checking before the first migration

Compiled against a dialect that has **connected**, so these are what the ORM actually creates
against Azure SQL Database:

| Declared | Created |
|---|---|
| `String(50)` | `VARCHAR(50)`, which is **not** Unicode |
| `Unicode(50)` | `NVARCHAR(50)` |
| `Text()` | `VARCHAR(max)` |
| `UnicodeText()` | `NVARCHAR(max)` |

The consequence is the first two rows. A model that uses `String` for anything holding names,
addresses or user text gets a non-Unicode column, and the mismatch between it and the Unicode
parameter Python binds is the implicit conversion that stops an index being used. Prefer `Unicode`
and `NVARCHAR(n)` explicitly.

**Do not read a `TEXT` or `NTEXT` out of a compiled statement and report it as what will be
created.** On a dialect that has never opened a connection, `Text()` compiles to `TEXT` and
`UnicodeText()` to `NTEXT`. On first connect the dialect sets `deprecate_large_types` from the
server version, and Azure SQL Database is always past the threshold, so the large-object types never
reach it. Compiling offline is the normal way to inspect generated DDL and it is wrong for exactly
this pair.

Sizing, collation, keys and the conversion trap in general belong to `design-azure-sql-schema`. What
belongs here is only that the defaults do not land where a PostgreSQL-shaped model expects.

One more default worth pinning: a SQLAlchemy `Sequence` with no `start` produces a sequence whose
first value is the minimum 64-bit integer, verified on a live database. Set `start=1` explicitly, and
prefer an identity column for surrogate keys.

## Alembic

Alembic drives the same dialect, and three of its operations need extra arguments here that they do
not need elsewhere:

- `alter_column` requires `existing_type` when changing nullability.
- `drop_index` requires `table_name`.
- `drop_column` on a column carrying a DEFAULT, CHECK or single foreign key constraint takes
  `mssql_drop_default`, `mssql_drop_check` and `mssql_drop_foreign_key` to drop the unnamed
  constraint first. Current Alembic already drops a default constraint automatically when altering a
  column, by looking the name up in the catalog views.

Whether a migration is safe to run against a live database, expand and contract, and never migrating
on application startup are `schema-migrations-safely`.

## Validation rules

- Every mapped table that carries an enabled trigger declares `implicit_returning=False`, and the
  reason is in a comment next to it.
- No explicit `returning()` targets a table that carries a trigger.
- `create_engine` does not pass `implicit_returning`.
- Wherever `fast_executemany=True` is set, SQLAlchemy is pinned at 2.0.10 or later and the inserts it
  is meant to speed up genuinely carry no returning clause.
- Columns holding human-readable text are declared `Unicode` or an explicit Unicode native type, not
  `String`.
- No `Sequence` relies on the default start value.
- The engine URL is built with `URL.create` and reads every value from the environment.
- Every value in a query is a bound parameter.

## Do not

- Do not assume an ORM insert behaves the way it does on other backends. Read the compiled SQL once,
  early, and the rest of this skill becomes obvious.
- Do not set `implicit_returning` on the engine. It is deprecated, it accepts only `True`, and it
  does nothing.
- Do not set `implicit_returning=False` on every table as a precaution. It costs the batched insert
  path and an extra round trip for the key on tables that never needed it.
- Do not claim `fast_executemany=True` sped up an ORM bulk insert without checking that the
  statement carries no returning clause. On the default configuration it did not.
- Do not use `String` for text that will hold anything outside ASCII.
- Do not use `Text` or `UnicodeText` for new columns. They map to deprecated types and the engine
  accepts them silently.
- Do not write a retry loop here. Transient-fault policy is one policy for every stack, in
  `connect-to-azure-sql`.
- Do not put a credential in the engine URL in source, and do not leave `Trusted_Connection` in a
  connection that carries an access token.
- Do not call the product by the dialect name.

## References

- [SQLAlchemy Microsoft SQL Server dialect](https://docs.sqlalchemy.org/en/20/dialects/mssql.html):
  the authority for the generated DML, the triggers section, identity and sequence behaviour, and the
  fast_executemany and setinputsizes notes. Fetch it before asserting what the dialect emits.
- [insertmanyvalues](https://docs.sqlalchemy.org/en/20/core/connections.html#engine-insertmanyvalues):
  what the batched insert form generates and how to turn it off. Read it when a bulk load is slower
  or noisier than expected.
- [The OUTPUT clause](https://learn.microsoft.com/sql/t-sql/queries/output-clause-transact-sql):
  the engine's own statement of the trigger restriction. Read it to confirm the rule rather than the
  error text.
- [Alembic operations reference](https://alembic.sqlalchemy.org/en/latest/ops.html): the
  dialect-specific arguments named above. Read it while writing a migration that alters or drops a
  column.
- `connect-from-python`: driver choice, driver installation, pooling and how an access token reaches
  the driver.
- `connect-to-azure-sql`: encryption doctrine, retry and transient faults, and pool sizing.
- `design-azure-sql-schema`: key length, sizing, collation and the implicit conversion trap.
- `schema-migrations-safely`: the tool-neutral migration doctrine Alembic inherits.
