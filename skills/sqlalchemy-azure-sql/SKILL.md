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
  mapping and Alembic. Driver choice belongs to connect-from-python and retry to connect-to-azure-sql;
  the other object relational mappers have skills of their own.
---

# SQLAlchemy on Azure SQL Database

SQLAlchemy reaches Azure SQL Database through a dialect whose generated SQL differs from every other
backend in one specific way, and almost every surprise here traces back to it. Every Python block
below was verified on 2026-09-03 against SQLAlchemy 2.0.52 and pyodbc 5.3.0 and its output quoted
verbatim; the version boundary below was measured the same day against 2.0.8, 2.0.9 and 2.0.10.
Engine error numbers are from Microsoft Learn.

The dialect is named `mssql` and that name belongs only in the URL scheme. Everywhere else the
product is **Azure SQL Database**, and an agent that adopts the dialect name has begun giving advice
for a different product with different limits.

## The engine URL

```python
import os
from sqlalchemy import create_engine
from sqlalchemy.engine import URL

credential = {                          # read them, never inline them
    "username": os.environ["SQL_USER"],
    "password": os.environ["SQL_PASSWORD"],
}
url = URL.create(
    "mssql+pyodbc",
    host=os.environ["SQL_HOST"],        # <server-name>.database.windows.net
    port=1433,
    database=os.environ["SQL_DATABASE"],
    query={"driver": "ODBC Driver 18 for SQL Server"},
    **credential,
)
engine = create_engine(url, pool_pre_ping=True)
print(url.render_as_string(hide_password=True))
```

`URL.create` escapes the characters that break a hand built URL; `render_as_string` logs one with
the password back as `***`.

Driver choice, retry and passwordless connections belong to other skills; see References.

## The OUTPUT clause, which is the whole skill

To learn a server generated key the dialect adds an OUTPUT clause to the INSERT. Do not take that
on trust, compile it:

```python
from sqlalchemy import Column, Integer, String, insert
from sqlalchemy.dialects import mssql
from sqlalchemy.orm import DeclarativeBase

class Base(DeclarativeBase):                       # columns shared by both models
    id = Column(Integer, primary_key=True)
    sku = Column(String(20))

class Order(Base):
    __tablename__ = "orders"

class Audited(Base):                               # this one carries a trigger
    __tablename__ = "audited_orders"
    __table_args__ = {"implicit_returning": False}  # so: no OUTPUT clause

d = mssql.dialect()
print(insert(Order).values(sku="x").compile(dialect=d))
print(insert(Audited).values(sku="x").compile(dialect=d))
print(insert(Audited).values(sku="x").returning(Audited.id).compile(dialect=d))
```

Three lines out, and every claim below is one:

```
INSERT INTO orders (sku) OUTPUT inserted.id VALUES (:sku)
INSERT INTO audited_orders (sku) VALUES (:sku)
INSERT INTO audited_orders (sku) OUTPUT inserted.id VALUES (:sku)
```

Azure SQL Database refuses the first when the target carries an enabled trigger:

```
Msg 334, Level 15, State 1
The target table 'dbo.audited_orders' of the DML statement cannot have any enabled triggers
if the statement contains an OUTPUT clause without INTO clause.
```

Four properties decide how this plays out, and each is where agents guess wrong.

1. **It is per table, and nothing detects it.** The dialect has no trigger reflection and does not
   probe for one, so a codebase where 40 models work and one fails is the normal shape of the bug.
2. **The switch is on the table, not the engine**, as `__table_args__` above or
   `implicit_returning=False` passed to `Table` in Core. The key then comes back from
   `scope_identity()`, one extra round trip that works on a triggered table. Set it per table, not
   everywhere as a precaution: it costs the batched insert path on tables that never needed it.
3. **The engine level parameter is a trap.** `create_engine(url, implicit_returning=True)` and the
   `False` form are both accepted, both raise `SADeprecationWarning`, and neither changes one
   character of the SQL above.
4. **The flag does not cover an explicit `returning()`.** That is the third printed line: with the
   flag off, a hand written `insert().returning(...)` still compiles to OUTPUT without INTO, and
   `update().returning(...)` and `delete().returning(...)` do the same.

Triggers cluster on auditing and history tables, exactly where an ORM meets an existing schema.
Find them before mapping one, with the query under Check it worked.

## fast_executemany, and what changed in 2.0

`fast_executemany=True` has existed since SQLAlchemy 1.3; what changed is what it does, and the
boundary is measurable with no database:

```bash
python3 -c "import sqlalchemy; from sqlalchemy.dialects import mssql; \
print(sqlalchemy.__version__, mssql.dialect().use_insertmanyvalues)"
```

That prints `2.0.8 True`, `2.0.9 False`, `2.0.10 True`. SQLAlchemy 2.0 introduced
**insertmanyvalues**, a batched INSERT form that returns keys, and because it returns keys it took
precedence over the driver's array binding and the flag stopped having any effect. 2.0.9 gave that
effect back for multi-parameter INSERT statements **carrying no returning clause**, switching
insertmanyvalues off here entirely to do it; 2.0.10 restored it, so **2.0.10 is the floor**.

The consequence agents miss: an ORM insert of a mapped class with a server generated key **does**
carry a returning clause, because that is the OUTPUT clause above, so on the default configuration
the flag changes nothing for exactly the bulk inserts people set it for. It bites only where the
INSERT carries no returning clause: the rows already hold their keys, or the table is declared
`implicit_returning=False`, or the load goes through Core rather than tracked ORM objects.

Two documented costs make this a decision, not a default: the batch must **fit in memory**,
the parameter is honoured for the Microsoft ODBC driver only, and `setinputsizes` is **not used**
for those calls, which is where the surprising type handling on large loads comes from.

## Type mapping, before the first migration

```python
from sqlalchemy import Column, MetaData, String, Table, Text, Unicode, UnicodeText
from sqlalchemy.dialects import mssql
from sqlalchemy.schema import CreateTable

t = Table("t", MetaData(),
          Column("a", String(50)), Column("b", Unicode(50)),
          Column("c", Text()), Column("d", UnicodeText()))
print(CreateTable(t).compile(dialect=mssql.dialect()))                            # not connected
print(CreateTable(t).compile(dialect=mssql.dialect(deprecate_large_types=True)))  # connected
```

The second print is what the ORM creates:

```
a VARCHAR(50) NULL, b NVARCHAR(50) NULL, c VARCHAR(max) NULL, d NVARCHAR(max) NULL
```

`String` is **not** Unicode. A model that uses it for names, addresses or user text gets a
non-Unicode column, and the mismatch between it and the Unicode parameter Python binds is the
implicit conversion that stops an index being used. Prefer `Unicode` or `NVARCHAR(n)` explicitly.

That the two prints differ is the second trap. Offline, `deprecate_large_types` is `None` and `c`
and `d` compile to `TEXT` and `NTEXT`; on first connect the dialect sets it from the server version,
and Azure SQL Database is always past the threshold. Compiling offline is the normal way to inspect
DDL and wrong for exactly this pair, so never report a `TEXT` or `NTEXT` read out of a compiled
statement as what will be created.

One default worth pinning: `Sequence("s")` with no `start` compiles to a bare
`CREATE SEQUENCE s`, and Microsoft Learn gives an ascending sequence's default start as the minimum
value of its type, `-9223372036854775808` for the default `bigint`. Pass `start=1`, and prefer an
identity column for surrogate keys.

## Alembic

Alembic drives the same dialect, so all the above applies to the DDL it emits. Read that DDL
before it runs, which is the point of offline mode:

```bash
alembic revision --autogenerate -m "add audited_orders"
alembic upgrade head --sql > migration.sql     # writes SQL, runs nothing
grep -nE 'TEXT|NTEXT|VARCHAR\(' migration.sql  # the type mapping above, before it ships
alembic upgrade head
```

Three operations need arguments here that they need nowhere else, and autogenerate will not add
them:

- `alter_column` requires `existing_type` when changing nullability.
- `drop_index` requires `table_name`.
- `drop_column` on a column with a DEFAULT, CHECK or single foreign key constraint takes
  `mssql_drop_default`, `mssql_drop_check` or `mssql_drop_foreign_key` to drop the unnamed
  constraint first.

These come from the Alembic documentation, not from a run: Alembic was not installed on the machine
that produced the numbers above. Whether a migration is safe to run at all,
expand and contract, and never migrating on startup, are `schema-migrations-safely`.

## Check it worked

Three checks, in the order they catch things. **Which tables carry an enabled trigger** is first,
because nothing in Python will tell you:

```bash
sqlcmd -S <server-name>.database.windows.net,1433 -d <database> -U <user> -C -b -m-1 -Q \
  "SELECT OBJECT_SCHEMA_NAME(parent_id) + '.' + OBJECT_NAME(parent_id) AS triggered_table
   FROM sys.triggers WHERE parent_class = 1 AND is_disabled = 0 ORDER BY 1;"
```

Expect one row per table needing `implicit_returning=False`, none on a schema with no triggers.
Keep `-m-1`: a severity 10 message otherwise prints with no `Msg` number, and `-b` will
not fail on one.

**`-m-1` is an ODBC `sqlcmd` instruction**, meaning the 18.x build from `mssql-tools18` or the
Microsoft command line utilities. Measured 2026-09-05, go-sqlcmd 1.10.0, the 1.x build
`brew install sqlcmd` and `winget install sqlcmd` install, prints no `Msg` header on a severity 10
message at any `-m` value, so on that build a severity 10 message prints with no number whether you keep the flag or not. `build-app-on-azure-sql` tells the two
builds apart in one table.

**Every model that needs the flag has it.** Print the other list and compare:

```python
print(sorted(t.name for t in Base.metadata.tables.values() if t.implicit_returning))
```

`Table.implicit_returning` is `True` by default and `False` once set, so expect no name from the
`sqlcmd` output here. Any that appears is the next `Msg 334`.

**The columns the engine actually created.** Run this against the migrated database:

```sql
SELECT OBJECT_NAME(c.object_id) AS tbl, c.name AS col, t.name AS type_name
FROM sys.columns AS c JOIN sys.types AS t ON t.user_type_id = c.user_type_id
WHERE OBJECTPROPERTY(c.object_id, 'IsUserTable') = 1
  AND t.name IN ('varchar', 'char', 'text', 'ntext');
```

Expect zero rows anywhere text can hold a non-ASCII character. A `varchar` or `char` row is a
`String` column, a `text` or `ntext` row is DDL from a dialect that never connected, and the engine
accepts both without complaint, which is why nothing else catches them.

## Do not

- Do not claim `fast_executemany=True` sped up an ORM bulk insert without first checking that the
  statement carries no returning clause. On the default configuration it did not.
- Do not inline a credential in an engine URL, and do not call the product `mssql`.

## References

- [SQLAlchemy Microsoft SQL Server dialect](https://docs.sqlalchemy.org/en/20/dialects/mssql.html):
  triggers, identity, sequences, fast_executemany, setinputsizes. Fetch it before asserting what the
  dialect emits.
- [insertmanyvalues](https://docs.sqlalchemy.org/en/20/core/connections.html#engine-insertmanyvalues):
  what the batched form generates and how to turn it off. Read it when a bulk load is slow or noisy.
- [The OUTPUT clause](https://learn.microsoft.com/sql/t-sql/queries/output-clause-transact-sql): the
  restriction in the engine's own words, per DML action. Read it to confirm the rule, not the text.
- [Alembic operations reference](https://alembic.sqlalchemy.org/en/latest/ops.html): the
  dialect-specific arguments above. Read it while writing a migration that alters or drops a column.
- `connect-from-python`: driver choice, installation, pooling. Open it before writing the URL; the
  first-party driver has a dialect only from SQLAlchemy 2.1.0b2, not for production.
- `connect-to-azure-sql`: encryption, retry, pool sizing. Open it the moment a transient error
  appears: `pool_pre_ping` tests a connection at checkout and is not a retry policy.
- `entra-id-auth`: passwordless connections, which carry no user, no password and no
  `Trusted_Connection`. Open it before putting a token flow near the engine URL.
- `design-azure-sql-schema`: key length, sizing, collation. Open it before the first migration.
- `schema-migrations-safely`: the migration doctrine Alembic inherits, including why a pipeline can
  report success on a migration that only warned.
