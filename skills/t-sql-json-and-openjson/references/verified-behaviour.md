# Verified behaviour: the json type, JSON indexes and OPENJSON

## Contents

- [How this was measured](#how-this-was-measured)
- [Validation, or the absence of it](#validation-or-the-absence-of-it)
- [Round trip and normalization](#round-trip-and-normalization)
- [Storage size](#storage-size)
- [What a json column cannot do](#what-a-json-column-cannot-do)
- [The JSON index](#the-json-index)
- [Compatibility levels](#compatibility-levels)
- [The 4000 character cliff](#the-4000-character-cliff)
- [OPENJSON default output versus an explicit schema](#openjson-default-output-versus-an-explicit-schema)
- [Timing table](#timing-table)
- [Converting an existing column](#converting-an-existing-column)
- [What is documented rather than measured](#what-is-documented-rather-than-measured)

## How this was measured

One engine reporting:

```text
SERVERPROPERTY('EngineEdition')  = 5
SERVERPROPERTY('Edition')        = SQL Azure
```

Date of the run: 2026-08-28. Two 20,000 row tables holding identical documents, one column typed
`JSON` and one `NVARCHAR(MAX)`, each document an order with a nested customer object and a two
element line array. Timings are `SET STATISTICS TIME` CPU, reads are `SET STATISTICS IO` logical
reads, and every timing below was taken at least twice.

## Validation, or the absence of it

```sql
INSERT INTO dbo.doc_nv   (payload) VALUES (N'{not json at all');   -- accepted
INSERT INTO dbo.doc_json (payload) VALUES (N'{not json at all');
```

```text
Msg 13609  JSON text is not properly formatted. Unexpected character 'n' is found at position 1.
```

The `nvarchar(max)` insert produced no message of any kind. The substitute, on a table that must
keep `nvarchar(max)`:

```sql
CREATE TABLE dbo.nvchk (
    id      INT IDENTITY PRIMARY KEY,
    payload NVARCHAR(MAX) NULL CONSTRAINT ck_json CHECK (ISJSON(payload) = 1)
);
INSERT INTO dbo.nvchk (payload) VALUES (N'not json');
```

```text
Msg 547  The INSERT statement conflicted with the CHECK constraint "ck_json".
```

`ISJSON` over a native `json` column returns 1, so the function is not made redundant by the type.

## Round trip and normalization

Input, into both columns:

```text
{  "b" : 1,   "a" :  2, "dup": 1, "dup": 2 }
```

Read back:

```text
json  -> {"b":1,"a":2,"dup":1}
nvarc -> {  "b" : 1,   "a" :  2, "dup": 1, "dup": 2 }
```

Whitespace removed, key order preserved in this case, and the second `"dup"` dropped. `JSON_VALUE`
over the duplicate key returned `1` on both storages, so the two agree on which duplicate wins,
but only the `json` column discards the loser permanently.

## Storage size

`DATALENGTH` on the same content:

| Content | `nvarchar(max)` | `json` |
|---|---|---|
| `{"b":1,"a":2,"dup":1}` | 42 | 79 |
| A realistic order document | 506 | 430 |
| An array of 51 small objects | 3866 | 2205 |

At table scale, 20,000 rows: `orders_nv` used 7664 KB, `orders_json` used 7320 KB. The binary
format has a fixed floor that a tiny document cannot amortize, and pays back on documents with
repeated keys.

## What a json column cannot do

Each statement was run in its own batch, because these are compile time failures that abort the
batch rather than errors a `TRY` block can catch.

```text
SELECT COUNT(*) FROM dbo.doc_json WHERE payload = N'{"b":1}';
Msg 402   The data types json and nvarchar are incompatible in the equal to operator.

SELECT COUNT(*) FROM dbo.doc_json GROUP BY payload;
Msg 13636 The JSON data type cannot be compared or sorted, except when using the IS NULL operator.

SELECT TOP 1 id FROM dbo.doc_json ORDER BY payload;
Msg 13636 (same)

SELECT TOP 1 id FROM dbo.doc_json WHERE payload LIKE '%a%';
Msg 8116  Argument data type json is invalid for argument 1 of like function.

SELECT DISTINCT payload FROM dbo.doc_json;
Msg 421   The json data type cannot be selected as DISTINCT because it is not comparable.

SELECT ... FROM dbo.doc_json a JOIN dbo.doc_json b ON a.payload = b.payload;
Msg 13636 (same)
```

A `json` column **is** accepted as an `INCLUDE` column and in the `WHERE` clause of a filtered
index. Both were created cleanly.

## The JSON index

```sql
CREATE JSON INDEX jix_orders ON dbo.orders_json (payload);          -- succeeds
CREATE JSON INDEX jix_doc2   ON dbo.doc_json    (payload) FOR ('$.a');
```

```text
Msg 13681  A JSON index 'jix_doc' already exists on column 'payload' on table 'doc_json',
           and multiple JSON indexes per column are not allowed.
```

On the `nvarchar(max)` column:

```text
Msg 13680  Column 'payload' on table 'dbo.orders_nv' is not of JSON data type,
           which is required to create a JSON index on it.
```

One predicate, `WHERE JSON_VALUE(payload, '$.customer.id') = 'C500'`, 20,000 rows:

| Storage | logical reads | CPU |
|---|---|---|
| `nvarchar(max)` | 958 on the base table | 29 ms |
| `json`, no JSON index | 915 on the base table | 23 ms |
| `json` with a JSON index | 142, on an object named `json_index_<ids>` | 5 ms |

The index is maintained on write. After `UPDATE ... SET payload = N'{"t":"bronze"}'` on a row that
had been `gold`, a filter for `gold` returned 0 and a filter for `bronze` returned 1.

## Compatibility levels

A database set to each level in turn:

| Level | `json` type | `CREATE JSON INDEX` | `JSON_VALUE` | `JSON_OBJECT`, `JSON_ARRAYAGG` | `OPENJSON` |
|---|---|---|---|---|---|
| 100 | not retested | not retested | not retested | not retested | **`Msg 208`** |
| 120 | works | works | works | works | **`Msg 208`** |
| 130 | works | works | works | works | works |
| 170 | works | works | works | works | works |

```text
Msg 208, Level 16, State 1
Invalid object name 'OPENJSON'.
```

Read the level with `DATABASEPROPERTYEX(DB_NAME(), 'CompatibilityLevel')` rather than
`sys.databases`, which was observed returning a stale value immediately after an `ALTER DATABASE`
in the same session.

## The 4000 character cliff

A document holding one 5000 character string property:

```text
doc length = 5010
JSON_VALUE lax                        -> NULL (silently)
JSON_VALUE over the json column type  -> NULL (silently)
OPENJSON WITH (v NVARCHAR(MAX) ...)   -> len 5000
```

Under a `strict` path:

```text
Msg 13625  String value in the specified JSON path would be truncated.
```

Both storages behave identically, so this is a `JSON_VALUE` property, not an `nvarchar` property.
The return type is capped, and lax mode turns the overflow into `NULL`.

## OPENJSON default output versus an explicit schema

Default output over `{"orderId":1,"customer":{...},"lines":[...],"placedAt":"..."}`:

```text
orderId  | 1                            | type=2
customer | {"id":"C1","tier":"silver"}  | type=5
lines    | [{"sku":"A-100",...          | type=4
placedAt | 2026-01-02T10:00:00Z         | type=1
```

Described result set:

```text
key    nvarchar(8000)  collation = Latin1_General_BIN2
value  nvarchar(max)   collation = SQL_Latin1_General_CP1_CI_AS
type   tinyint
```

The `key` collation is the trap. On a case-insensitive database:

```text
WHERE [key] = N'orderId'  -> 1 row
WHERE [key] = N'orderid'  -> 0 rows
```

Paths behave the same way:

```text
JSON_VALUE('{"orderId":1}', '$.orderid') -> NULL
JSON_VALUE('{"orderId":1}', '$.orderId') -> 1
```

Behaviour of the `WITH` clause:

```text
WITH (qty INT '$.qty') over "qty":"abc"
  Msg 245  Conversion failed when converting the nvarchar value 'abc' to data type int.

WITH (qty INT '$.qty')        over a document with no qty  -> NULL
WITH (qty INT 'strict $.qty') over a document with no qty
  Msg 13608  Property cannot be found on the specified JSON path.

WITH (lines NVARCHAR(100) '$.lines' AS JSON)
  Msg 13618  AS JSON option can be specified only for column of nvarchar(max) type in WITH clause.

WITH (lines NVARCHAR(MAX) '$.lines' AS JSON)  -> [1,2]
WITH (c NVARCHAR(MAX) '$.c') over "c":{"x":1} -> NULL
```

That last line is the quiet one: a nested object requested without `AS JSON` comes back as `NULL`
rather than as its text, and lax mode raises nothing.

## Timing table

20,000 documents, 40,000 array elements. CPU milliseconds, best of at least two runs.

| Work | Storage | Shape | CPU |
|---|---|---|---|
| Shred the `lines` array | `nvarchar(max)` | `OPENJSON ... WITH` | 94 to 130 |
| Shred the `lines` array | `nvarchar(max)` | default output plus `JSON_VALUE` | 375 to 395 |
| Shred the `lines` array | `json` | `OPENJSON ... WITH` | 790 to 1105 |
| Shred the `lines` array | `json` | default output plus `JSON_VALUE` | 927 to 1259 |
| Four scalar properties, every row | `json` | `JSON_VALUE` four times | 81 to 120 |
| Four scalar properties, every row | `json` | `OPENJSON ... WITH` | 592 to 735 |
| Four scalar properties, every row | `nvarchar(max)` | `JSON_VALUE` four times | 114 to 157 |

Two conclusions, and the second is the one that is easy to get backwards:

- For array shredding on `nvarchar(max)` storage, which is what a model writes, the explicit schema
  is about four times cheaper than the default output plus `JSON_VALUE`.
- For scalar property reads there is no array to shred, and `OPENJSON` is the **more** expensive
  plan on both storages. `JSON_VALUE` is the right tool there, and it is the only one a JSON index
  can serve.

Array shredding on the `json` column measured slower than on `nvarchar(max)` in every run. That is
reproducible here but not explained, so it is recorded rather than turned into advice.

## Converting an existing column

```sql
ALTER TABLE dbo.mig ALTER COLUMN payload JSON NULL;
```

With one invalid row present:

```text
Msg 13609  JSON text is not properly formatted. Unexpected character 'n' is found at position 0.
The statement has been terminated.
```

After `DELETE FROM dbo.mig WHERE ISJSON(payload) = 0`, the same statement succeeded and
`sys.types` reported `json`. Reversing it:

```text
ALTER TABLE dbo.mig ALTER COLUMN payload NVARCHAR(MAX) NULL;
Msg 257  Implicit conversion from data type json to nvarchar(max) is not allowed.
         Use the CONVERT function to run this query.
```

So the conversion out needs a new column and an explicit `CAST`, not an in place `ALTER`. Plan the
move as a one way door and keep the raw text separately if anything depends on it.

## What is documented rather than measured

Read on 2026-08-28 for Azure SQL Database, not reproduced here.

- The `json` type is generally available, is available under all database compatibility levels,
  and stores up to 2 GB.
- A `json` column is permitted as an included column and in the `WHERE` clause of a filtered index.
  Both were confirmed here; the size table on the documentation page was not copied.
- `design-azure-sql-schema` measured the key restrictions on the same engine: `Msg 1978` for a
  `json` column used as an index key, and `Msg 402` for an equality comparison against `nvarchar`.
  This page confirms both rather than re-deriving them.
