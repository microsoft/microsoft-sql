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
  type and the query surface. The end to end pipeline is rag-on-azure-sql, generating embeddings
  embeddings-and-external-models, and a vector column's place in a wider design
  design-azure-sql-schema.
---

# Vector storage and search on Azure SQL Database

The `vector` type behaves like no other column type in this engine, and the query that looks like
vector search is not the query that uses the vector index.

Syntax and status re-checked 2026-09-03 against Microsoft Learn's `vector data type`,
`VECTOR_SEARCH` and `CREATE VECTOR INDEX` pages. Every error number and plan below was measured
2026-08-28 against a live Azure SQL Database (`SERVERPROPERTY('EngineEdition')` returns 5, General
Purpose serverless, compatibility level 170) and again against the local Azure SQL Database
container, which reports the same edition. They agreed on every error number below.

## Build the fixture and the index first

Do not read about the index. Build one. It is the only way to learn whether the preview has reached
your engine.

```sql
CREATE TABLE dbo.chunks (
    id        int IDENTITY(1,1) NOT NULL PRIMARY KEY CLUSTERED,
    body      nvarchar(400) NOT NULL,
    category  nvarchar(40)  NOT NULL,
    embedding vector(5)     NULL
);
GO
INSERT INTO dbo.chunks (body, category, embedding)
SELECT CONCAT(N'chunk ', value), N'general',
       CAST(JSON_ARRAY(CAST(value * 0.01 AS float), CAST(value * 0.02 AS float),
                       CAST(value * 0.03 AS float), CAST(value * 0.04 AS float),
                       CAST(value * 0.05 AS float)) AS vector(5))
FROM GENERATE_SERIES(1, 150);
GO
CREATE NONCLUSTERED INDEX ix_chunks_category ON dbo.chunks (category);
GO
DECLARE @t0 datetime2(3) = SYSUTCDATETIME();
CREATE VECTOR INDEX vi_chunks ON dbo.chunks (embedding)
    WITH (METRIC = 'cosine', TYPE = 'diskann');
SELECT DATEDIFF(millisecond, @t0, SYSUTCDATETIME()) AS build_ms;
```

Measured over 140 rows: 145 ms on the local container, 276 ms in the cloud. If a plan, a document or
a model says this statement is not yet buildable, run it before believing it. You turn nothing
on first. Compatibility level is not the gate: column, insert, `VECTOR_DISTANCE` and approximate
search over an existing index all worked at level 150. `PREVIEW_FEATURES` is not the gate either:

```sql
SELECT [name], [value] FROM sys.database_scoped_configurations WHERE [name] = 'PREVIEW_FEATURES';
```

**Do not read a decision out of that number.** On the container it is not deterministic: six
freshly created databases on one engine read 0, 1, 0, 1, 1, 1 on 2026-09-03, while `model` and
`master` both read 0. Learn documents OFF as the default, scopes the requirement to the boxed
engine, and its own `CREATE VECTOR INDEX` example calls the setting "not needed for Azure SQL
Database". What matters is the statement above: the index builds and you set nothing. If a
document tells you to turn this on first, it is wrong whatever your database happens to
report. The type, `VECTOR_DISTANCE`, `VECTOR_NORM`, `VECTOR_NORMALIZE` and `VECTORPROPERTY` are
generally available; `CREATE VECTOR INDEX`, `VECTOR_SEARCH` and `TOP (N) WITH APPROXIMATE` are
preview and roll out by region, so a design that only performs with the index carries preview risk.

## The correction: which query shape reaches the index

An agent asked for fast similarity search writes this. It is wrong and nothing reports it:

```sql
-- Correct results. Never uses a vector index. Computes a distance for EVERY row.
DECLARE @q vector(5) = '[0.3,0.3,0.3,0.3,0.3]';
SELECT TOP (10) id, body, VECTOR_DISTANCE('cosine', embedding, @q) AS distance
FROM dbo.chunks
ORDER BY VECTOR_DISTANCE('cosine', embedding, @q);
```

Measured plan with a current DiskANN index: `Clustered Index Scan`, then `Compute Scalar`
evaluating `vector_distance` per row, then `Sort`. The index is not in the plan. Learn states it
outright: vector distance is always exact and doesn't use any vector index, even if available. The
shape that does reach the index is a different statement, not a tuning option:

```sql
-- Uses the vector index. Vector Index Seek in the measured plan.
DECLARE @q vector(5) = '[0.3,0.3,0.3,0.3,0.3]';
SELECT TOP (10) WITH APPROXIMATE t.id, t.body, r.distance
FROM VECTOR_SEARCH(TABLE = dbo.chunks AS t, COLUMN = embedding,
                   SIMILAR_TO = @q, METRIC = 'cosine') AS r
WHERE t.category = N'general'
ORDER BY r.distance;
```

Four shapes, measured on the same table and index:

| Query | Measured plan |
|---|---|
| `ORDER BY VECTOR_DISTANCE(...)` with `TOP` | Clustered Index Scan, exact, full scan |
| `VECTOR_SEARCH` with `TOP` and no `WITH APPROXIMATE` | Clustered Index Scan, exact kNN |
| `VECTOR_SEARCH` with `TOP (N) WITH APPROXIMATE` | **Vector Index Seek**, approximate |
| `TOP (N) WITH APPROXIMATE` on a table with **no** vector index | Clustered Index Scan, **no error** |

**Every wrong shape returns correct rows.** That is the whole hazard. A pipeline tested on a few
thousand rows passes, ships, then computes one distance per row per query forever, so the defect shows
up as latency and cost, not as a failure anyone can point at. Learn says a warning is
raised when no compatible index is found; nothing surfaced here.

Turn the silent fallback into a failure. `WITH (FORCE_ANN_ONLY)` goes on the `VECTOR_SEARCH` alias
and needs an index and `WITH APPROXIMATE` present:

```sql
DECLARE @q vector(5) = '[0.3,0.3,0.3,0.3,0.3]';
SELECT TOP (10) WITH APPROXIMATE t.id, r.distance
FROM VECTOR_SEARCH(TABLE = dbo.chunks AS t, COLUMN = embedding,
                   SIMILAR_TO = @q, METRIC = 'cosine') AS r WITH (FORCE_ANN_ONLY)
ORDER BY r.distance;
```

With no usable index that fails with `Msg 42227` instead of quietly scanning. Use it in a test, not
in production.

### The older syntax an agent reaches for first

`VECTOR_SEARCH(..., TOP_N = 10)` is what most published examples still show. Against a current index
it fails with `Msg 42274`. Match on that number, not the text: Learn prints "version 3 index" where
the engine measured here printed "newer index version". `TOP_N` belongs to an earlier index format
that cannot be upgraded in place, so move the count to `SELECT TOP (N) WITH APPROXIMATE`.

`WITH APPROXIMATE` is also not a general modifier. Without a `VECTOR_SEARCH` it fails with
`Msg 42248`, and its `ORDER BY` is fixed: the `distance` column, ascending, nothing else, or
`Msg 42271`. Learn's own end to end example on the `CREATE VECTOR INDEX` page ends
`ORDER BY s.distance, t.title`, which its own `VECTOR_SEARCH` page says is `Msg 42271`. Copy the
rule, not the example. `GROUP BY`, window functions, `DISTINCT`, set operators, extra sort keys and
`CROSS APPLY` all need the approximate search in a subquery and the outer query doing the rest.

## What VECTOR_DISTANCE returns, and the sign trap

Three metrics exist and nothing else does: `'cosine'`, `'euclidean'`, `'dot'`. Anything else is
`Msg 42201`. The metric may be a variable and is case insensitive.

```sql
DECLARE @q vector(3) = '[1,2,3]';
SELECT v.label,
       VECTOR_DISTANCE('cosine',    CAST(v.txt AS vector(3)), @q) AS cosine,
       VECTOR_DISTANCE('euclidean', CAST(v.txt AS vector(3)), @q) AS euclidean,
       VECTOR_DISTANCE('dot',       CAST(v.txt AS vector(3)), @q) AS dot
FROM (VALUES ('identical', '[1,2,3]'), ('near', '[1,2,4]'), ('far', '[4,5,6]')) AS v(label, txt);
```

| Row | `cosine` | `euclidean` | `dot` |
|---|---|---|---|
| `[1,2,3]`, identical | 5.96e-08 | 0 | **-14** |
| `[1,2,4]` | 0.0085 | 1 | -17 |
| `[4,5,6]` | 0.0254 | 5.196 | -32 |

It returns a **distance**: smaller is closer, always, for all three.

- **Cosine returns 1 minus the similarity**, on a range Learn gives as 0 to 2. An identical vector
  scores near zero, so a threshold copied from a similarity based store inverts.
- **`dot` returns the negative inner product.** The identical row scores -14, not 14. A query that
  sorts `dot` descending, or keeps the largest score, returns the **least** similar rows, with no
  error and a full result set, and grounds its answer on the worst matches.
- Both arguments must share a base type. `float32` against `float16` is `Msg 42243`.

## The type, in one place

```sql
DECLARE @v vector(3) = '[1,2,3]';
SELECT VECTORPROPERTY(@v, 'Dimensions') AS dims,       -- 3
       VECTORPROPERTY(@v, 'BaseType')   AS base_type,  -- float32
       DATALENGTH(@v)                   AS bytes,      -- 20
       CAST(@v AS nvarchar(max))        AS round_trip;
```

- **Dimensions are 1 to 1998**, which Learn states and the engine enforces: `vector(1999)` is
  `Msg 2717`, `vector(0)` is `Msg 1001`. A populated `vector(1998)` has `DATALENGTH` 8000.
  **The declared dimension cannot be changed later**, even on an empty table: `ALTER COLUMN` is
  `Msg 42204`, so it is drop and recreate. A 3072 dimension model does not fit, and that fix
  belongs at embedding time.
- **Base type is `float32`** unless `float16` is stated. Half precision is preview and is a surface
  Learn does gate on `PREVIEW_FEATURES`, it crosses TDS as a JSON string rather than in binary, and
  it cannot be compared with a `float32` vector.
- **It is written and read as a JSON array**, converting implicitly from `varchar`, `nvarchar` and
  `json`. **The dimension in `CAST` must be a literal**: `CAST(@s AS vector(@d))` is `Msg 102`, so a
  helper taking the dimension as a parameter needs dynamic SQL.
- **Clients that predate the protocol change see `nvarchar(max)`**, because Learn records that
  `sp_describe_first_result_set` misreports the type, which is why an ORM maps it to a string.
  Native handling needs `Microsoft.Data.SqlClient` 6.1.0 or the JDBC driver 13.1.0.

## The restriction list

No model infers this: a `vector` column looks like a column. Every row was measured.

**Refused in a table definition**

| Attempt | Error |
|---|---|
| `PRIMARY KEY` or `UNIQUE` on a vector column | `Msg 1919` |
| `FOREIGN KEY` referencing one | `Msg 1776`, no candidate key to reference |
| `CHECK` constraint | `Msg 1760` |
| `DEFAULT` constraint | `Msg 1752` |
| `PERSISTED` computed column over a vector function | `Msg 4936`, non-deterministic |
| Partition function or partition key | `Msg 7704` |
| Alias type with `CREATE TYPE` | `Msg 42212` |
| Assignment to `sql_variant` | `Msg 206` |
| Memory optimized table | Not supported |
| `ALTER COLUMN` to a different dimension | `Msg 42204` |

**Allowed, though widely assumed otherwise:** `SPARSE`, a non-persisted
computed column, an `INCLUDE` column on a nonclustered index, a system versioned temporal table, a
table carrying a clustered columnstore index, `SELECT ... INTO`, `ALTER COLUMN` from `nvarchar` to
`vector`, `CASE`, `ISNULL`, `UNION ALL` and `FOR JSON`. Also parameters, return types and table
variables.

**Refused in a query**

| Attempt | Error |
|---|---|
| `ORDER BY` or `GROUP BY` the column itself | `Msg 42213`, cannot be compared or sorted |
| `SELECT DISTINCT` | `Msg 421` |
| `=`, `<`, `>`, `IN`, a join predicate, `MAX`, `MIN`, `COUNT(DISTINCT ...)` | `Msg 8117` |
| `UNION`, `INTERSECT`, `EXCEPT` | `Msg 5335`. `UNION ALL` is fine |
| `CREATE STATISTICS` on the column, or any b-tree or columnstore **key** | `Msg 1978` |
| `CAST` to `varbinary` | `Msg 529` |
| Inserting a JSON array of the wrong length | `Msg 42204` |
| Inserting a JSON array containing a string | `Msg 13670` |

`IS NULL` and `IS NOT NULL` are the only comparisons that work. With no equality,
**deduplicating rows by their embedding is not a query you can write**. Deduplicate on a hash of the
source text, which Learn wants anyway: duplicates degrade recall. Always Encrypted is
unsupported, and `sp_verify_database_ledger` errors on a database holding a vector column.

## What the index requires, and what it costs

- **The table needs a clustered index.** Without one, `Msg 42254`. Learn says a primary key
  clustered index; clustered primary keys on `int`, `bigint`, `nvarchar` and a composite all built
  here, so `Msg 42217`'s narrower wording is stale, not the rule. Re-measured on a real logical
  server 2026-09-08: `bigint` and a composite `(int, int)` both built, a heap was refused with
  `Msg 42254` and not 42217, and **no input produced `Msg 42217` at all**.
- **At least 100 rows with a non-null vector must already exist**, or `Msg 42266`. A fresh database
  has no index until it has content, and every query is silently exact until then. The fixture
  inserts 150 for headroom.
- **One vector index per column.** A second, even with a different metric, is `Msg 42230`. The
  metric is fixed at build time, and asking `VECTOR_SEARCH` for a different one **falls back
  silently**. Measured 2026-09-06 against a `cosine` index on 150 rows: `METRIC = 'euclidean'` and
  `METRIC = 'dot'` both returned a full ordered result set, no error and no warning, computed
  exactly. This skill said `Msg 42227` here until that measurement, and the claim was backwards in
  the one direction that matters, because a reader who believes the engine will stop them has no
  reason to check. `Msg 42227` is raised only by `WITH (FORCE_ANN_ONLY)`, which is why that hint
  belongs in the test that proves the index is being read.
- **The local Azure SQL Database container builds it too.** Open
  `references/parity.md` in `rag-local-with-container` when a plan leans on the two engines
  agreeing.

| Operation | Result |
|---|---|
| `TRUNCATE TABLE` | `Msg 42232`. Drop the index, truncate, reload 100 rows, recreate |
| `ALTER INDEX ... REBUILD` or `DISABLE` | `Msg 42250`. There is no rebuild |
| `ALTER TABLE ... DROP COLUMN` on the indexed column | `Msg 5074` |
| Importing a dacpac or bacpac | Fails. The export is fine. Drop the indexes before export, recreate after the load |
| Partitioning the table | Not supported |

This skill used to report that import row as unsettled and it is settled. Learn states it: the
import creates schema objects before it loads data, so the index is built against an empty table and
trips the 100 row minimum.
`sqlpackage-import-export` measured the round trip on 2026-08-31 and agreed with Learn.
Open it before planning either half, because it owns the sequence.

`INSERT`, `UPDATE`, `DELETE` and `MERGE` are all supported on a current index and changes are
searchable after commit, which is new: earlier index versions made the table read only. Watch
`sys.dm_db_vector_indexes` for background maintenance, and **drop and recreate the index after
replacing most of the embeddings**: the graph was built for the old distribution and recall degrades
with no error. Filter predicates apply during the search, so a filtered top ten returns ten rows
when ten qualify. Give the filter columns a nonclustered index, as the fixture does.

## Check it worked

Three checks. The middle one settles what this skill exists for.

```sql
-- 1. The index exists and is the current format. index_version must be 3.
SELECT i.name AS index_name, OBJECT_NAME(v.object_id) AS table_name,
       JSON_VALUE(v.build_parameters, '$.Version') AS index_version
FROM sys.vector_indexes AS v
JOIN sys.indexes AS i ON v.object_id = i.object_id AND v.index_id = i.index_id;

-- 2. The query reaches it. Read the plan and look for Vector Index Seek.
SET STATISTICS XML ON;
DECLARE @q vector(5) = '[0.3,0.3,0.3,0.3,0.3]';
SELECT TOP (10) WITH APPROXIMATE t.id, r.distance
FROM VECTOR_SEARCH(TABLE = dbo.chunks AS t, COLUMN = embedding,
                   SIMILAR_TO = @q, METRIC = 'cosine') AS r
ORDER BY r.distance;
SET STATISTICS XML OFF;

-- 3. Ranking is the right way up: the nearest row has the SMALLEST distance.
DECLARE @p vector(5) = '[0.3,0.3,0.3,0.3,0.3]';
SELECT MIN(VECTOR_DISTANCE('cosine', embedding, @p)) AS nearest,
       MAX(VECTOR_DISTANCE('cosine', embedding, @p)) AS furthest
FROM dbo.chunks;
```

Run them non-interactively with the password in `SQLCMDPASSWORD`, keeping the output:

```bash
sqlcmd -S <server-name>.database.windows.net,1433 -d <database> -U <user> -C \
  -i check-vector-index.sql -o check-vector-index.out
```

Expected: check 1 returns one row per vector index with `index_version` `3`; an empty result set
means there is no index and every similarity query is scanning. Check 2's plan contains
`Vector Index Seek`; a plan holding only `Clustered Index Scan` and `Compute Scalar` is the defect,
whatever the rows look like. Check 3 returns `nearest` below `furthest`, both non-negative.
`sqlcmd` exiting 0 says nothing about the three, so read the output file.

## Do not

- Do not conclude the index is in use because results look right. Read the plan, or assert with
  `FORCE_ANN_ONLY`. `WITH APPROXIMATE` is not a droppable hint: it changes the algorithm.
- Do not sort a `dot` distance descending, and do not present a cosine distance as a similarity.
- Do not declare `vector(3072)`. The ceiling is 1998, and the fix belongs at embedding time.
- Do not deduplicate on the embedding. There is no equality operator to do it with.
- Do not raise the compatibility level or set `PREVIEW_FEATURES = ON`. Neither is the gate, and the
  container's `1` is not the cloud's value.
- Do not report that the index cannot be built on the local container. It builds there.
- Do not build the ingest, chunking and grounding pipeline here. That is `rag-on-azure-sql`.

## References

- [references/vector-restrictions-and-query-plans.md](references/vector-restrictions-and-query-plans.md) when a claim here
  disagrees with what you are seeing, which on a preview surface happens: it holds the raw statements
  behind every table above, the four plans and the reproduction steps.
- Read [vector data type](https://learn.microsoft.com/sql/t-sql/data-types/vector-data-type) before
  choosing a dimension count or a driver, and
  [CREATE VECTOR INDEX](https://learn.microsoft.com/sql/t-sql/statements/create-vector-index-transact-sql)
  before creating an index in production, for preview status and the migration off the earlier
  format.
- Read [VECTOR_SEARCH](https://learn.microsoft.com/sql/t-sql/functions/vector-search-transact-sql)
  when a query will not compile alongside `WITH APPROXIMATE`, for the subquery patterns, and
  [Feature availability by region](https://learn.microsoft.com/azure/azure-sql/database/region-availability#vector-search)
  before promising the preview in a region you have not built one in.
