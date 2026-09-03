---
name: t-sql-json-and-openjson
description: >-
  Queries and stores JSON on Azure SQL Database using the native json type, a JSON index, and
  OPENJSON with an explicit WITH schema, instead of the older nvarchar(max) plus JSON_VALUE
  pattern the training data is full of. Use when asked to "store JSON in SQL", "query a JSON
  column", "shred a JSON array into rows", "flatten this payload into a table", "index a JSON
  property", "should this be nvarchar(max) or the json type", "parse the API response we saved",
  or when JSON_VALUE, JSON_QUERY, JSON_MODIFY, ISJSON, OPENJSON, JSON_OBJECT or JSON_ARRAYAGG
  appears in a query being written or reviewed; and when a JSON lookup returns NULL for a value
  that is visibly present, or invalid JSON reached a column that nothing rejected. Where a
  document column belongs in a table design is design-azure-sql-schema, and general T-SQL dialect
  is t-sql-correctness.
---

# Query JSON on Azure SQL Database with the native type

Two generations of JSON support exist here and a model has read far more of the first: a document
in `nvarchar(max)` read with functions. The second is a real `json` type with its own storage,
validation and index. Both work, and the differences are not only speed. Measured 2026-08-28
against a live engine reporting `EngineEdition` 5 and Edition `SQL Azure`; the Learn pages for
`OPENJSON`, `JSON_VALUE` and `CREATE JSON INDEX` were re-read 2026-09-03.
Open [references/json-type-errors-and-timings.md](references/json-type-errors-and-timings.md) when
an error number you hit is not listed here, or before you change one that is.

## What the json type actually changes

| | `nvarchar(max)` | `json` |
|---|---|---|
| Invalid JSON on insert | accepted silently | rejected, `Msg 13609` |
| `CREATE JSON INDEX` | no, `Msg 13680` | yes, one per column |
| `JSON_VALUE(..., path RETURNING type)` | no, json input only | yes |
| `=`, `ORDER BY`, `GROUP BY`, `DISTINCT`, `LIKE` | yes | no: `Msg 402`, `13636`, `421`, `8116` |
| Text preserved byte for byte | yes | no, reformatted and duplicate keys dropped |

**Validation.** `nvarchar(max)` takes `{not json at all` without a word, and the damage surfaces
months later as a `JSON_VALUE` returning `NULL` in a report.

```sql
CREATE TABLE dbo.doc_nv   (id int IDENTITY PRIMARY KEY CLUSTERED, payload nvarchar(max) NULL);
CREATE TABLE dbo.doc_json (id int IDENTITY PRIMARY KEY CLUSTERED, payload json NULL);
CREATE TABLE dbo.doc_chk  (id int IDENTITY PRIMARY KEY CLUSTERED, payload nvarchar(max) NULL
    CONSTRAINT ck_doc_chk_json CHECK (ISJSON(payload) = 1));
INSERT INTO dbo.doc_nv   (payload) VALUES (N'{not json at all');   -- no message of any kind
INSERT INTO dbo.doc_json (payload) VALUES (N'{not json at all');   -- Msg 13609
INSERT INTO dbo.doc_chk  (payload) VALUES (N'{not json at all');   -- Msg 547
```

The constraint buys the refusal back for a column that must stay `nvarchar(max)`, and added later
it fails if a bad row is already there, which is the audit. `ISJSON` still returns 1 over a `json`
column; to demand a property rather than mere well-formedness Learn uses
`CHECK (JSON_PATH_EXISTS(payload, '$.basket') = 1)`.

**Indexing.** The difference that cannot be worked around:

```sql
CREATE TABLE dbo.orders_json (id int IDENTITY PRIMARY KEY CLUSTERED, payload json NOT NULL);
CREATE JSON INDEX jix_orders ON dbo.orders_json (payload)
    FOR ('$.customer', '$.lines') WITH (OPTIMIZE_FOR_ARRAY_SEARCH = ON, FILLFACTOR = 80);
```

The same statement against `dbo.doc_nv` returns `Msg 13680`. Learn adds the fence: the table needs
a clustering key, one index per `json` column and 249 per table, the default path set is `$`,
listed paths may not overlap, builds are offline only. It serves `JSON_PATH_EXISTS`,
`JSON_CONTAINS` and `JSON_VALUE` compared with `=`, `RETURNING` cast included, but not `LIKE` or
`IS [NOT] NULL`. Learn's page omits Azure SQL Database from its applies-to banner
and calls the feature preview, yet it built and served queries on the engine measured here.

One equality predicate on a nested property over 20,000 documents: 958 logical reads and 29 ms of
CPU on `nvarchar(max)`, 915 and 23 ms on `json` without a JSON index, **142 and 5 ms** with one.

The alternative on either storage is the promoted column, a `PERSISTED` computed column over
`JSON_VALUE` with an ordinary index, which `design-azure-sql-schema` owns. Converting is close to
one way: `ALTER COLUMN payload json` fails with `Msg 13609` if any row is invalid, and the reverse
is refused in place with `Msg 257`.

## OPENJSON, and why the WITH clause is not a style choice

Without `WITH`, `OPENJSON` returns `key` in a BIN2 collation, `value` as `nvarchar(max)`, and
`type` numbered 0 null, 1 string, 2 number, 3 true/false, 4 array, 5 object, first level only.
With `WITH` it returns the columns asked for, typed, and those three are then unavailable.

```sql
SELECT o.id, l.sku, l.qty, l.price, l.tags
FROM dbo.orders AS o
CROSS APPLY OPENJSON(o.payload, '$.lines')
    WITH (sku nvarchar(10), qty int, price decimal(10,2),
          tags nvarchar(max) '$.tags' AS JSON) AS l;
```

A path is optional where the column name equals the property name, as `sku` and `qty` show.
Shredding 40,000 array elements out of 20,000 `nvarchar(max)` documents cost **94 to 130 ms of CPU
with `WITH`, against 375 to 395 ms** for the default output plus a `JSON_VALUE` per field, across
three runs. The plans differ too, and reading them is `read-execution-plan`. Performance is the
smaller half:

1. **A bad value fails loudly instead of arriving as text.** `WITH (qty int '$.qty')` over
   `"qty": "abc"` raises `Msg 245`; the default output hands back `abc` as `nvarchar(max)`.
2. **A nested object or array needs `AS JSON`**, which requires `nvarchar(max)`; anything else is
   `Msg 13618`. Without it the column is `NULL` in lax mode rather than the nested document.
3. **Paths and `key` are case-sensitive**, matched BIN2 and collation-unaware, so on a
   case-insensitive database `WHERE [key] = N'orderid'` matched nothing against `orderId`.
4. **A missing property is `NULL` in lax mode and `Msg 13608` under `strict`**, and lax is the
   default when no mode is written. Choose deliberately.

## The 4000 character cliff, and the two ways past it

`JSON_VALUE` without `RETURNING` is typed `nvarchar(4000)`, and Learn is explicit that above 4000
characters it returns `NULL` in lax mode and an error in strict mode; measured, strict raised
`Msg 13625`, "would be truncated". That is data loss dressed as a missing key, and both escapes
fit in one statement:

```sql
DECLARE @j json = JSON_OBJECT('big': REPLICATE(CAST(N'x' AS nvarchar(max)), 5000));
SELECT JSON_VALUE(@j, '$.big')                              AS lax_returns_null,
       LEN(JSON_VALUE(@j, '$.big' RETURNING nvarchar(max))) AS returning_len,
       (SELECT LEN(v) FROM OPENJSON(@j) WITH (v nvarchar(max) '$.big')) AS openjson_len;
```

`RETURNING` is documented only for a `json` input, one more reason the storage choice is not
cosmetic; `OPENJSON ... WITH` works on both. It also takes the numeric, date and time types, so
`JSON_VALUE(payload, '$.customer.id' RETURNING int) = 16167` is both typed and indexable.

## Compatibility level 130 is real, and almost never your problem

`OPENJSON` is hidden below level 130 and returns `Msg 208`, `Invalid object name 'OPENJSON'`:
measured failing at 100 and 120, working at 130, while the `json` type and `CREATE JSON INDEX`
worked at 120. The requirement is real and nearly never the fault, because a database created on
Azure SQL Database today starts far above 130.

```sql
SELECT DATABASEPROPERTYEX(DB_NAME(), 'CompatibilityLevel') AS level;
```

Read it that way rather than from `sys.databases`, observed stale in the same session as an
`ALTER DATABASE`. If the level cannot move, `post-migration-compatibility-level` owns raising it,
and Learn documents a second door: `ALLOW_BUILTIN_TVF_IN_ALL_COMPAT_LEVELS`, a database-scoped
configuration that exempts `OPENJSON` and the other built-in table-valued functions.

## Check it worked

Five traps from this page in one row:

```sql
DECLARE @j json = N'{  "orderId" : 7,   "customer" : {"id":"C1"}, "dup": 1, "dup": 2 }';
SELECT CAST(@j AS nvarchar(max))            AS normalized,
       JSON_VALUE(@j, '$.orderid')          AS wrong_case,
       JSON_VALUE(@j, '$.orderId')          AS right_case,
       (SELECT c FROM OPENJSON(@j) WITH (c nvarchar(max) '$.customer'))         AS without_as_json,
       (SELECT c FROM OPENJSON(@j) WITH (c nvarchar(max) '$.customer' AS JSON)) AS with_as_json;
```

```text
normalized       {"orderId":7,"customer":{"id":"C1"},"dup":1}
wrong_case       NULL
right_case       7
without_as_json  NULL
with_as_json     {"id":"C1"}
```

Whitespace and a second `dup` in `normalized` mean the column is `nvarchar(max)`, not `json`; a
`NULL` in `right_case` means the property is spelled some other way. In a pipeline pass both error
flags, because `-b` alone sets a non-zero exit only above severity 10 and without `-m-1` a
severity 10 message prints with no `Msg` number to grep for:

```bash
sqlcmd -S <server>,1433 -d <database> -b -m-1 -i check-json.sql
```

## Do not

- Do not default to `nvarchar(max)` because it is familiar: it accepts invalid JSON, cannot carry
  a JSON index, and `RETURNING` is closed to it.
- Do not call `nvarchar(max)` plus functions deprecated. It is not, and on scalar reads it is the
  cheaper plan: four properties from each of 20,000 rows cost **81 ms** of CPU with `JSON_VALUE`
  against **735 ms** for `OPENJSON ... WITH`.
- Do not reach for `OPENJSON` to read one scalar property, and do not lower-case a path or a `key`
  comparison, which quietly matches nothing.
- Do not assume a `json` column hands back the text that went in. It is reparsed, whitespace goes
  and a duplicate key is dropped, so if a signature covers the exact bytes keep the raw text too.
- Do not review only the query. An unvalidated `nvarchar(max)`, a missing `WITH` or `AS JSON`, and
  a lower-cased path are all invisible in the result set.
