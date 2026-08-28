---
name: vector-search-azure-sql
description: >-
  Stores and searches vectors natively in Azure SQL Database: the vector type, VECTOR_DISTANCE,
  the 1998 dimension ceiling, the DiskANN vector index, and the long list of places a vector
  column is refused. Use when a schema needs an embedding column, when someone asks to "store
  embeddings in SQL", "do similarity search", "cosine distance", "top k nearest neighbours",
  "CREATE VECTOR INDEX", "VECTOR_SEARCH" or "WITH APPROXIMATE"; when a vector column is rejected
  as a key, a constraint, a computed column or inside ORDER BY, GROUP BY, DISTINCT or UNION; and
  when a similarity query returns the right rows but scans the whole table. This skill owns the
  type and the query surface. The end to end retrieval pipeline is rag-on-azure-sql, generating
  embeddings and the external model endpoint are embeddings-and-external-models, and where a
  vector column belongs in a wider design is design-azure-sql-schema.
license: MIT
---

# Vector storage and search on Azure SQL Database

The `vector` type behaves like no other column type in this engine, and the query that looks like
vector search is not the query that uses the vector index.

Verified on 2026-08-28 by running every statement below against a **live Azure SQL Database**
(`SERVERPROPERTY('EngineEdition')` returns 5, General Purpose serverless, compatibility level 170)
and repeating the whole set against the local Azure SQL Database container. Both engines agreed on
every result. The raw runs, including the execution plans, are in
[references/measured-behaviour.md](references/measured-behaviour.md).

## What is generally available and what is preview, today

| Surface | Status in Azure SQL Database |
|---|---|
| `vector(n)` column type, variables, parameters, return types | **Generally available** |
| `VECTOR_DISTANCE`, `VECTOR_NORM`, `VECTOR_NORMALIZE`, `VECTORPROPERTY` | **Generally available** |
| `vector(n, float16)` half precision | Preview. The documentation gates it on the `PREVIEW_FEATURES` database scoped configuration; on the database measured the column was accepted without it, so do not rely on the flag as the gate |
| `CREATE VECTOR INDEX`, `VECTOR_SEARCH`, `TOP (N) WITH APPROXIMATE` | **Preview**, and rolling out by region |

Two consequences. Storing embeddings and computing distances is a supported production decision
today. Accelerating that search is not yet, so a design that only performs acceptably with the
index carries preview risk, and the index is the part most likely to have changed since this was
written. Check
[Feature availability by region](https://learn.microsoft.com/azure/azure-sql/database/region-availability)
before promising the index in a region.

The type does **not** need compatibility level 170. Measured at level 150: the column, the insert
and `VECTOR_DISTANCE` all worked, and so did approximate search over an existing index.

## The correction: which query shape reaches the index

An agent asked for fast similarity search writes this, and it is wrong in a way nothing reports:

```sql
-- Correct results. Never uses a vector index. Computes a distance for EVERY row.
DECLARE @q vector(1536) = ...;
SELECT TOP (10) id, VECTOR_DISTANCE('cosine', embedding, @q) AS distance
FROM dbo.chunks
ORDER BY VECTOR_DISTANCE('cosine', embedding, @q);
```

Measured plan, on a table carrying a current DiskANN index: `Clustered Index Scan`, then
`Compute Scalar` evaluating `vector_distance` per row, then `Sort`. The index is not in the plan.

The shape that does reach the index is a different statement, not a tuning option:

```sql
-- Uses the vector index. Vector Index Seek in the measured plan.
DECLARE @q vector(1536) = ...;
SELECT TOP (10) WITH APPROXIMATE t.id, t.body, r.distance
FROM VECTOR_SEARCH(
        TABLE      = dbo.chunks AS t,
        COLUMN     = embedding,
        SIMILAR_TO = @q,
        METRIC     = 'cosine'
     ) AS r
ORDER BY r.distance;
```

Four shapes, measured on the same table and index:

| Query | Plan | Result |
|---|---|---|
| `ORDER BY VECTOR_DISTANCE(...)` with `TOP` | Clustered Index Scan | Exact, full scan |
| `VECTOR_SEARCH` with `TOP` and no `WITH APPROXIMATE` | Clustered Index Scan | Exact, full scan |
| `VECTOR_SEARCH` with `TOP (N) WITH APPROXIMATE` | **Vector Index Seek** | Approximate, index |
| `TOP (N) WITH APPROXIMATE` on a table with **no** vector index | Clustered Index Scan | Exact, full scan, **no error** |

**Every wrong shape returns correct rows.** That is the whole hazard. A pipeline built and tested
on a few thousand rows passes, ships, and then computes one distance per row per query forever, so
the defect surfaces as latency and compute cost rather than as a failure anyone can point at.

Two things make it visible:

- **Read the plan.** `Vector Index Seek` appears or it does not. Nothing else settles it.
- **Add `WITH (FORCE_ANN_ONLY)`** to the `VECTOR_SEARCH` alias in a test. With no usable index the
  query then fails with `Msg 42227, Cannot find a vector index with metric '<metric>' on column
  '<column>'` instead of quietly scanning. Use it to assert, not as a production hint.

### The older syntax an agent will reach for first

`VECTOR_SEARCH(..., TOP_N = 10)` is what most published examples still show. Against a current
index it fails outright:

> `Msg 42274, Vector search with newer index version does not support explicit TOP_N parameter.`

`TOP_N` belongs to an earlier index format that cannot be upgraded in place. Do not add it back to
make the error go away; move the count to `SELECT TOP (N) WITH APPROXIMATE`.

`WITH APPROXIMATE` is also not a general modifier. Without a `VECTOR_SEARCH` in the query it fails
with `Msg 42248`, and its `ORDER BY` is fixed: the `distance` column, ascending, and nothing else,
or `Msg 42271`. `GROUP BY`, window functions, `DISTINCT`, set operators, extra sort keys and
`CROSS APPLY` all need the approximate search wrapped in a subquery and the outer query doing the
rest.

## What VECTOR_DISTANCE returns, and the sign trap

Three metrics exist and nothing else does: `'cosine'`, `'euclidean'`, `'dot'`. Anything else is
`Msg 42201`. The metric may be a variable, and it is case insensitive.

`VECTOR_DISTANCE` returns a **distance**, so smaller is closer, always, for all three. Measured
with `@q = '[1,2,3]'`:

| Row | `cosine` | `euclidean` | `dot` |
|---|---|---|---|
| `[1,2,3]`, identical | 5.96e-08 | 0 | **-14** |
| `[1,2,4]` | 0.0085 | 1 | -17 |
| `[4,5,6]` | 0.0254 | 5.196 | -32 |

- **Cosine returns 1 minus the similarity**, not the similarity. An identical vector scores near
  zero, not near one. A relevance threshold copied from a similarity based store inverts.
- **`dot` returns the negative inner product.** The identical row scores -14, not 14. A query that
  sorts `dot` descending, or keeps the largest score, returns the **least** similar rows, with no
  error and a full result set. Downstream, that is an answer grounded on the worst matches.
- Both arguments must share a base type. Mixing `float32` and `float16` is `Msg 42243`.

## The type, in one place

- **Dimensions are 1 to 1998.** `vector(1999)` is `Msg 2717`, `vector(0)` is `Msg 1001`. Storage is
  `DATALENGTH` 8000 bytes at 1998 dimensions, four bytes per element plus a small header.
- **The 1998 ceiling is a design constraint, not a footnote.** A 3072 dimension embedding model
  does not fit and must be asked for fewer dimensions at generation time.
- **Base type is `float32`** unless `float16` is stated. Half precision is still preview, it is transmitted to clients as a JSON string rather than in binary, and a `float16` vector cannot be compared with a `float32` one.
  `VECTORPROPERTY(v, 'Dimensions')` and `VECTORPROPERTY(v, 'BaseType')` read it back.
- **It is written and read as a JSON array.** `'[1,2,3]'` converts implicitly from `varchar`,
  `nvarchar` and `json`, and `CAST(v AS nvarchar(max))` converts back.
- **The dimension in `CAST` must be a literal.** `CAST(@s AS vector(@d))` is a syntax error, so a
  helper that takes the dimension as a parameter has to be generated or use dynamic SQL.
- **Clients that predate the protocol change see `nvarchar(max)`.** Measured:
  `sp_describe_first_result_set` reports a vector column as `nvarchar(max)`, which is why an ORM
  maps it to a string. Native handling needs a current driver, for example `SqlVector<float>` in
  `Microsoft.Data.SqlClient` 6.1.0 or later.

## The restriction list

This is the part no model infers, because a `vector` column looks like a column. Every row was
measured, and the error numbers are the ones the engine actually returns.

**Refused in a table definition**

| Attempt | Error |
|---|---|
| `PRIMARY KEY` or `UNIQUE` on a vector column | `Msg 1919` |
| `FOREIGN KEY` referencing one | `Msg 1776`, there is no candidate key to reference |
| `CHECK` constraint | `Msg 1760`, constraints of type CHECK cannot be created on columns of type vector |
| `DEFAULT` constraint | `Msg 1752` |
| `PERSISTED` computed column over a vector function | `Msg 4936`, non-deterministic |
| Partition function or partition key | `Msg 7704` |
| Alias type with `CREATE TYPE ... FROM vector(n)` | `Msg 42212` |
| Assignment to `sql_variant` | `Msg 206` |
| Memory optimized table | Not supported |
| `ALTER COLUMN` to a different dimension, **even on an empty table** | `Msg 42204`. Drop and recreate the column |

**Allowed, and worth knowing because it is widely assumed otherwise**

`NULL` and `NOT NULL`, `SPARSE`, a non-persisted computed column, an `INCLUDE` column on a
nonclustered index, a table type column, a stored procedure parameter, a scalar function return
type, a table variable, a system versioned temporal table, a table carrying a clustered
columnstore index, `SELECT ... INTO`, `ALTER COLUMN` from `nvarchar` to `vector`, `CASE`,
`ISNULL`, `UNION ALL`, and `FOR JSON`.

**Refused in a query**

| Attempt | Error |
|---|---|
| `ORDER BY` or `GROUP BY` the column itself | `Msg 42213`, cannot be compared or sorted except with `IS NULL` |
| `SELECT DISTINCT` | `Msg 421` |
| `=`, `<`, `>`, `IN`, a join predicate on the column | `Msg 8117` |
| `MAX`, `MIN`, `COUNT(DISTINCT ...)` | `Msg 8117` |
| `UNION`, `INTERSECT`, `EXCEPT` | `Msg 5335`. `UNION ALL` is fine |
| `CREATE STATISTICS` on the column, or any b-tree or columnstore **key** | `Msg 1978` |
| `CAST` to `varbinary` | `Msg 529` |
| Inserting a JSON array of the wrong length | `Msg 42204` |
| Inserting a JSON array containing a string | `Msg 13670` |

`IS NULL` and `IS NOT NULL` are the only comparisons that work. There is no equality, so
**deduplicating rows by their embedding is not a query you can write**. Deduplicate on a hash of
the source text instead.

**Not supported with the type at all:** Always Encrypted, and `sp_verify_database_ledger` errors on
a database containing a vector column.

## The vector index, and what it costs to have one

`CREATE VECTOR INDEX vi ON dbo.chunks(embedding) WITH (METRIC = 'cosine', TYPE = 'diskann');`

Requirements, all measured:

- **The table needs a clustered index.** Without one, `Msg 42254`. A clustered primary key on
  `int`, `bigint`, `nvarchar` or a composite key all built successfully, so read
  `Msg 42217`'s narrower wording as stale rather than as the rule.
- **At least 100 rows with a non-null vector must already exist**, or `Msg 42266`. So a fresh
  database has no index until it has content, and every query against it is silently exact until
  then.
- **One vector index per column.** A second one, even with a different metric, is `Msg 42230`. The
  metric is fixed at build time, and `VECTOR_SEARCH` with a different metric gets `Msg 42227`
  rather than a fallback.
- The `METRIC` values are the three above. `TYPE` accepts `DiskANN` and defaults to it. `MAXDOP`
  bounds the build.

What it takes away once it exists:

| Operation | Result |
|---|---|
| `TRUNCATE TABLE` | `Msg 42232`. Drop the index, truncate, reload 100 rows, recreate |
| `ALTER INDEX ... REBUILD` or `DISABLE` | `Msg 42250`. There is no rebuild |
| `ALTER TABLE ... DROP COLUMN` on the indexed column | `Msg 5074` |
| Import from a data-tier package | Fails. The import creates the index before loading rows, so it hits the 100 row minimum. Drop the index before export and recreate after import |
| Partitioning the table | Not supported |

`INSERT`, `UPDATE`, `DELETE` and `MERGE` are all supported on a current index, and changes are
searchable after commit. Watch `sys.dm_db_vector_indexes` for background maintenance, and
**drop and recreate the index after replacing most of the embeddings**, because the graph was
built for the old distribution and recall degrades without any error.

Filter predicates in the `WHERE` clause are applied during the search on a current index, so a
filtered top ten returns ten rows when ten qualify. Give the filter columns an ordinary
nonclustered index.

## Validation rules

- Every similarity query that is expected to use the index is written as
  `SELECT TOP (N) WITH APPROXIMATE ... FROM VECTOR_SEARCH(...) ORDER BY <alias>.distance`, and its
  plan has been read once and shown to contain a `Vector Index Seek`.
- No query contains `TOP_N =`.
- Any query kept as `ORDER BY VECTOR_DISTANCE(...)` is deliberate, and a comment records that it is
  an exact scan over a table small enough to afford it.
- Ranking sorts distance **ascending**, and no code treats a `dot` result as a similarity score.
- Every declared dimension is between 1 and 1998 and matches what the embedding model is asked to
  produce.
- No vector column is a key, a `CHECK` or `DEFAULT` constraint, a persisted computed column, a
  partition key or a statistics target, and no code compares two vectors with `=`.
- Deduplication keys off the source text or a hash of it, never off the embedding.
- The vector index is created after the table holds at least 100 rows with non-null vectors, and
  the deployment pipeline creates it as a step after the data load rather than as part of a
  package import.
- Any process that truncates or bulk replaces the table drops and recreates the vector index.
- The preview status of the index is recorded wherever a production commitment is made.

## Do not

- Do not assume a vector index accelerates `ORDER BY VECTOR_DISTANCE(...)`. It does not, and the
  query keeps returning the correct answer while scanning the table.
- Do not conclude an index is being used because the results look right. Read the plan, or assert
  with `FORCE_ANN_ONLY`.
- Do not use the `TOP_N` parameter. It is rejected by current indexes.
- Do not treat `WITH APPROXIMATE` as a hint that can be dropped. It changes which algorithm runs.
- Do not sort a `dot` distance descending, and do not present a cosine distance as a similarity.
- Do not declare `vector(3072)`. The ceiling is 1998, and the fix belongs at embedding time.
- Do not try to enforce uniqueness, a range, a default or a foreign key on a vector column.
- Do not add a vector column to a table whose deployment path is a data-tier package while a vector
  index is defined on it.
- Do not raise the compatibility level expecting to unlock the type. It works at every level.
- Do not build the end to end ingest, chunking and grounding pipeline here. That is
  `rag-on-azure-sql`.

## References

- [references/measured-behaviour.md](references/measured-behaviour.md): every statement that
  produced the tables above, the execution plans for the four query shapes, and how to reproduce
  the whole set against a database of your own. Read it when a claim here needs to be re-verified,
  which for the preview surface is often.
- [vector data type](https://learn.microsoft.com/sql/t-sql/data-types/vector-data-type): the
  first party statement of dimensions, conversions, driver support and the type's own limitations.
- [CREATE VECTOR INDEX](https://learn.microsoft.com/sql/t-sql/statements/create-vector-index-transact-sql):
  preview status, the minimum row count, the migration from the older index format, and the data
  quality guidance. Read this before creating an index in production.
- [VECTOR_SEARCH](https://learn.microsoft.com/sql/t-sql/functions/vector-search-transact-sql):
  the `WITH APPROXIMATE` contract, iterative filtering, the table hints, and the subquery patterns
  for everything that cannot be combined with it directly.
- [Feature availability by region](https://learn.microsoft.com/azure/azure-sql/database/region-availability):
  where the index preview has reached. Check it rather than assuming.
- `rag-on-azure-sql`: chunking, embedding, provenance and grounding, which is the pipeline this
  query surface sits inside.
- `embeddings-and-external-models`: producing the embedding in the first place, the external model
  endpoint and its allowlist.
- `design-azure-sql-schema`: where an embedding column belongs relative to the rest of the model.
