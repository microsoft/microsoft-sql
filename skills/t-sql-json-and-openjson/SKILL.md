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

There are two generations of JSON support here and a model has read far more of the first. The
first is a document held in `nvarchar(max)` and read with functions. The second is a real `json`
type with its own storage, its own validation and its own index. Both work. They are not
equivalent, and the differences are not only about speed.

Measured on 2026-08-28 against a live engine reporting `EngineEdition` 5 and Edition `SQL Azure`.
Every number below came from that run, and the full statements are in
[references/verified-behaviour.md](references/verified-behaviour.md).

## What the json type actually changes

| | `nvarchar(max)` | `json` |
|---|---|---|
| Invalid JSON on insert | **accepted silently** | rejected, `Msg 13609` |
| Text preserved byte for byte | yes | **no**, reformatted and duplicate keys dropped |
| Storage for a realistic document | 506 bytes | 430 bytes, and 2205 against 3866 for a repeated array |
| Storage for a tiny document | 42 bytes | 79 bytes, so the format has a floor |
| `CREATE JSON INDEX` | **no**, `Msg 13680` | yes, one per column |
| Compared with `=`, sorted, grouped, `DISTINCT`, `LIKE` | yes | **no**, `Msg 402`, `13636`, `421`, `8116` |
| Available at every compatibility level | yes | yes, verified at 120 |

Two of those rows carry the real cost.

**Validation.** `nvarchar(max)` will take `{not json at all` without complaint, and the damage
surfaces later as a `JSON_VALUE` returning `NULL` in a report. The `json` type refuses it at the
insert. If a document column must stay `nvarchar(max)`, the substitute is explicit and cheap:

```sql
ALTER TABLE dbo.doc ADD CONSTRAINT ck_doc_json CHECK (ISJSON(payload) = 1);
```

Verified to reject the same text with `Msg 547`. Adding it is the difference between a loud
failure now and a silent wrong answer later.

**Indexing.** This is the one that cannot be worked around. `CREATE JSON INDEX` requires the
native type, and says so:

```text
Msg 13680  Column 'payload' on table 'dbo.orders_nv' is not of JSON data type,
           which is required to create a JSON index on it.
```

Measured over 20,000 documents, one equality predicate on a nested property:

| | logical reads | CPU |
|---|---|---|
| `nvarchar(max)`, no index possible | 958 | 29 ms |
| `json`, no JSON index | 915 | 23 ms |
| `json` with a JSON index | **142** | **5 ms** |

The plan reads an internal index object rather than the table. The alternative on either storage
is still the promoted column: a `PERSISTED` computed column over `JSON_VALUE` with a normal index,
which `design-azure-sql-schema` covers and which remains the right answer for the one or two
properties every query filters on.

**Migration is one way in practice.** `ALTER TABLE ... ALTER COLUMN payload JSON` fails with
`Msg 13609` if any existing row is not valid JSON, which is a useful audit. Going back is blocked:
`ALTER COLUMN payload NVARCHAR(MAX)` returns `Msg 257`, implicit conversion from `json` to
`nvarchar(max)` is not allowed. Reversing needs a new column and an explicit `CAST`.

## The old pattern still works, and sometimes still wins

`JSON_VALUE`, `JSON_QUERY`, `JSON_MODIFY` and `ISJSON` all work on both storages, and the
functions are not deprecated. On the native type they are cheap, because the document is already
parsed: pulling four scalar properties from every one of 20,000 rows cost **81 ms** of CPU with
`JSON_VALUE` against **735 ms** for `OPENJSON` with an explicit schema over the same rows. So no,
`OPENJSON` is not the answer to everything.

The division that held under measurement:

- **One or a few scalar properties, no array**: `JSON_VALUE`. It is the cheaper plan and it is the
  only one a JSON index can serve.
- **An array turned into rows**: `OPENJSON`, and with a `WITH` clause.

## OPENJSON with an explicit schema

Without `WITH`, `OPENJSON` returns three columns: `key`, `value`, `type`. With `WITH`, it returns
the columns asked for, typed.

```sql
SELECT o.id, l.sku, l.qty, l.price
FROM dbo.orders AS o
CROSS APPLY OPENJSON(o.payload, '$.lines')
    WITH (sku NVARCHAR(10) '$.sku', qty INT '$.qty', price DECIMAL(10,2) '$.price') AS l;
```

Measured against the default output plus a `JSON_VALUE` per field, shredding 40,000 array elements
out of 20,000 documents held as `nvarchar(max)`: **94 to 130 ms of CPU with `WITH`, against 375 to
395 ms without**, reproducible across three runs. Roughly four times the work for the same answer.

But performance is the smaller half. Four correctness differences:

1. **`JSON_VALUE` silently truncates to NULL above 4000 characters.** In the default lax mode a
   5000 character string property comes back as `NULL`, not as an error and not as a prefix. The
   same property through `OPENJSON ... WITH (v NVARCHAR(MAX) '$.big')` returned all 5000
   characters. This is data loss dressed as a missing key. Under `strict` the same read raises
   `Msg 13625`, "String value in the specified JSON path would be truncated".
2. **The `key` column is `Latin1_General_BIN2`.** Verified: on a case-insensitive database,
   `WHERE [key] = N'orderid'` matched zero rows against a document with `orderId`. JSON paths are
   case-sensitive too, so `JSON_VALUE(doc, '$.orderid')` returns `NULL` where `'$.orderId'`
   returns the value. Both failures look like a missing property.
3. **A bad value fails loudly instead of arriving as text.** `WITH (qty INT '$.qty')` over
   `"qty": "abc"` raises `Msg 245`. The default output hands back `abc` as `nvarchar(max)` and the
   error appears somewhere later, or not at all.
4. **A nested object or array needs `AS JSON`.** Without it the column returns `NULL` in lax mode
   rather than the nested document. `AS JSON` requires `NVARCHAR(MAX)`, and anything else is
   `Msg 13618`.

Three more things worth knowing:

- A missing property is `NULL` in lax mode and `Msg 13608` under a `strict` path. Choose
  deliberately.
- Path expressions are optional when the column name equals the property name, so
  `WITH (sku NVARCHAR(10), qty INT)` is valid and reads better.
- `OPENJSON` needs compatibility level 130. Measured failing at 100 and 120 with `Msg 208`,
  `Invalid object name 'OPENJSON'`, and working at 130. Everything else on this page, the `json`
  type and `CREATE JSON INDEX` included, worked at 120. Read the level with
  `DATABASEPROPERTYEX(DB_NAME(), 'CompatibilityLevel')`, and `post-migration-compatibility-level`
  owns raising it.

## Round tripping is not byte for byte

The `json` type stores a parsed document, not the text it was given. Verified: the input
`{  "b" : 1,   "a" :  2, "dup": 1, "dup": 2 }` came back as `{"b":1,"a":2,"dup":1}`. Whitespace is
gone, key order was preserved here, and the **duplicate key was dropped**. If any consumer depends
on the exact bytes, a signature over the raw text for example, keep the original in a separate
`nvarchar(max)` column rather than expecting the `json` column to hand it back.

## Validation rules

- A document column is `json`, or it is `nvarchar(max)` with a stated reason and a
  `CHECK (ISJSON(...) = 1)` constraint.
- Every `OPENJSON` that shreds an array into rows carries a `WITH` clause with typed columns.
- No `JSON_VALUE` is used to read a property that can exceed 4000 characters. That read goes
  through `OPENJSON ... WITH` on an `NVARCHAR(MAX)` column.
- Every JSON path in the query matches the case of the property in the document.
- Any property the queries filter on every time is either promoted to a computed column with an
  index, or covered by a JSON index on a native `json` column.
- No query compares, sorts, groups or applies `DISTINCT` or `LIKE` to a `json` column.
- A nested object or array pulled through `OPENJSON ... WITH` uses `NVARCHAR(MAX) ... AS JSON`.

## Do not

- Do not default to `nvarchar(max)` for a document column because that is the familiar shape. It
  accepts invalid JSON, and it cannot carry a JSON index at all.
- Do not claim `nvarchar(max)` plus functions is deprecated. It is not, and on scalar reads it is
  the cheaper plan.
- Do not reach for `OPENJSON` to read a single scalar property. Measured here it cost nine times
  the CPU of `JSON_VALUE` over the same rows.
- Do not use `JSON_VALUE` for anything that might be long text. Above 4000 characters it returns
  `NULL` and tells no one.
- Do not lower-case a JSON path or a `key` comparison. The path is case-sensitive and the `key`
  column is a binary collation, so both quietly match nothing.
- Do not store a value inside the document and then filter on it. Promote it, or index it.
- Do not assume a `json` column returns the text that went in. It returns a normalized document,
  and duplicate keys do not survive.
- Do not decide here whether the document belongs in this table at all, how wide the row becomes,
  or what the key is. That is `design-azure-sql-schema`.

## References

- [references/verified-behaviour.md](references/verified-behaviour.md): every statement and every
  message behind this page, including the storage comparisons, the JSON index measurements, the
  compatibility level boundary and the full `OPENJSON` timing table. Read it before changing a
  number here, or when a claim is being disputed.
