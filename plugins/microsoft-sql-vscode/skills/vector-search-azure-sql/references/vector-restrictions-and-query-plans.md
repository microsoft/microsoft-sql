# Vector restrictions and query plans: checks you can run

## Contents

- [What the tables cover](#what-the-tables-cover)
- [The four query shapes and their plans](#the-four-query-shapes-and-their-plans)
- [Metric semantics](#metric-semantics)
- [Type and dimension limits](#type-and-dimension-limits)
- [Table definition: refused](#table-definition-refused)
- [Table definition: allowed](#table-definition-allowed)
- [Query surface: refused](#query-surface-refused)
- [Vector index: requirements](#vector-index-requirements)
- [Vector index: what it blocks](#vector-index-what-it-blocks)
- [Approximate search syntax rules](#approximate-search-syntax-rules)
- [Claims that do not hold](#claims-that-do-not-hold)
- [Exact search scans, approximate search seeks](#exact-search-scans-approximate-search-seeks)

## What the tables cover

Every statement below behaves the same on Azure SQL Database at compatibility level 170 and on the
Azure SQL Database container, both reporting `SERVERPROPERTY('EngineEdition') = 5`. **Every error
number below is identical on both**, which is why each row is stated as an engine behaviour rather
than as a service behaviour. The one reading that cannot be stated at all is `PREVIEW_FEATURES`,
item 8 under Claims that do not hold.

Where the documentation and the engine disagree, the disagreement is under
[Claims that do not hold](#claims-that-do-not-hold).

## The four query shapes and their plans

On a table with a `vector` column and one DiskANN vector index with `METRIC = 'cosine'`, index
format version 3, `SET STATISTICS XML ON` shows these operators.

| Query | Operators in the actual plan |
|---|---|
| `SELECT TOP (5) id ... ORDER BY VECTOR_DISTANCE('cosine', e, @q)` | `Sort`, `Compute Scalar` defining `vector_distance`, `Clustered Index Scan` |
| `SELECT TOP (5) ... FROM VECTOR_SEARCH(...) ORDER BY s.distance` | `Top`, `Sort`, `Compute Scalar`, `Filter`, `Clustered Index Scan` |
| `SELECT TOP (5) WITH APPROXIMATE ... FROM VECTOR_SEARCH(...) ORDER BY s.distance` | `Top`, `Nested Loops`, **`Vector Index Seek`** on the vector index, `Clustered Index Seek` on the primary key |
| `SELECT TOP (2) WITH APPROXIMATE ... FROM VECTOR_SEARCH(...)` against a table with **no** vector index | `Sort`, `Compute Scalar`, `Filter`, `Clustered Index Scan`. No error, and the client may see no warning |

`WITH (FORCE_ANN_ONLY)` on the `VECTOR_SEARCH` alias succeeds on the indexed table and fails on
the unindexed one with `Msg 42227`. That is the only cheap way to turn the silent fallback into a
failure inside a test.

## Metric semantics

`DECLARE @q vector(3) = '[1,2,3]';` against rows `[1,2,3]`, `[4,5,6]`, `[1,2,4]`.

| Row | `cosine` | `euclidean` | `dot` |
|---|---|---|---|
| `[1,2,3]` | 5.960464477539063e-08 | 0 | -14 |
| `[4,5,6]` | 0.025368213653564453 | 5.196152210235596 | -32 |
| `[1,2,4]` | 0.008539915084838867 | 1 | -17 |

- `'manhattan'` and `'negative dot product'`: `Msg 42201, The requested distance metric '<name>' is
  not supported by vector_distance.`
- `'COSINE'` in upper case: accepted.
- The metric supplied as a `varchar` variable rather than a literal: accepted.
- Dimension mismatch between the two arguments: `Msg 42204, The vector dimensions 3 and 4 do not
  match.`
- `float16` against `float32` depends on the build. Container builds through `18.0.226` refuse it
  with `Msg 42243, VECTOR_DISTANCE function does not support different base types for vector
  arguments.` On builds `18.0.302.0_248` and `18.0.310.0_253`, `VECTOR_DISTANCE('cosine', ...)`
  between a `vector(3)` and a `vector(3, float16)` returns a distance with no error. Keep both
  arguments on one base type.

## Type and dimension limits

| Statement | Result |
|---|---|
| `CREATE TABLE t (v vector(1))` | Succeeds |
| `CREATE TABLE t (v vector(0))` | `Msg 1001, Length or precision specification 0 is invalid` |
| `CREATE TABLE t (v vector(1998))` | Succeeds |
| `CREATE TABLE t (v vector(1999))` | `Msg 2717, The size (1999) given to the column 'v' exceeds the maximum allowed (1998)` |
| `DATALENGTH` of a populated `vector(1998)` | 8000 bytes |
| `sys.columns.max_length` for a `vector(1998)` | 8000 |
| `SELECT CAST(v AS nvarchar(max))` | Succeeds, returning a JSON array such as `[1.0000000e+000,2.0000000e+000,3.0000000e+000]` |
| `SELECT CAST(v AS varbinary(max))` | `Msg 529, Explicit conversion from data type vector to varbinary(max) is not allowed` |
| `CAST('[1,2,3]' AS vector(@d))` with `@d` a variable | `Msg 102, Incorrect syntax near '@d'` |
| Insert `'[1,2]'` into a `vector(3)` | `Msg 42204` |
| Insert `'[1,"a",3]'` into a `vector(3)` | `Msg 13670, Input JSON is not a valid Vector : 'String not Supported'` |
| `VECTORPROPERTY(v, 'Dimensions')` | Returns the dimension count |
| `VECTORPROPERTY(v, 'BaseType')` | Returns `float32`, or `float16` where declared |
| `VECTOR_NORM(v, 'norm2')` and `'norm1'` | Both succeed |
| `VECTOR_NORMALIZE(v, 'norm2')` | Succeeds, returning a vector |
| `JSON_ARRAY_TO_VECTOR`, `VECTOR_TO_JSON_ARRAY` | `Msg 195`, not recognised. These names do not exist |
| Column, insert and `VECTOR_DISTANCE` at compatibility level 150 | All succeed |
| Approximate search over an existing index at compatibility level 150 | Succeeds |
| `vector(3, float16)` on Azure SQL Database | The `CREATE TABLE` succeeds |

## Table definition: refused

| Statement | Error |
|---|---|
| `v vector(3) PRIMARY KEY` | `Msg 1919`, invalid for use as a key column in an index, then `Msg 1750` |
| `v vector(3) UNIQUE` | `Msg 1919`, then `Msg 1750` |
| `CREATE CLUSTERED INDEX ix ON t(v)` | `Msg 1978`, invalid for use as a key column in an index or statistics |
| `CREATE INDEX ix ON t(v)` | `Msg 1978` |
| `v vector(3) REFERENCES other(v)` | `Msg 1776`, no candidate key in the referenced table |
| `v vector(3) CHECK (...)` | `Msg 1760, Constraints of type CHECK cannot be created on columns of type vector` |
| `v vector(3) DEFAULT '[0,0,0]'` | `Msg 1752`, invalid for creating a default constraint |
| `c AS VECTOR_NORM(v,'norm2') PERSISTED` | `Msg 4936`, cannot be persisted because the column is non-deterministic |
| `CREATE PARTITION FUNCTION pf (vector(3)) ...` | `Msg 7704, The type 'sys.vector' is not valid for this operation` |
| `CREATE TYPE myvec FROM vector(3)` | `Msg 42212, Cannot create alias types from a vector datatype` |
| `SET @sv = CAST('[1,2,3]' AS vector(3))` where `@sv` is `sql_variant` | `Msg 206, Operand type clash: vector is incompatible with sql_variant` |
| `CREATE STATISTICS s ON t(v)` | `Msg 1978` |
| `ALTER TABLE t ALTER COLUMN v vector(4)` from `vector(3)`, table empty | `Msg 42204, The vector dimensions 3 and 4 do not match` |
| Memory optimized table containing a vector column | Not supported. On a tier without memory optimized tables the error names the tier restriction rather than the type restriction |

## Table definition: allowed

Each of these succeeds. Confirm it in the catalogue views, as the right column shows, rather than
from the absence of an error.

| Statement | How to confirm it |
|---|---|
| `v vector(3) NULL` and `NOT NULL` | Insert of `NULL` and of a value |
| `v vector(3) SPARSE NULL` | `sys.columns.is_sparse = 1` on the vector column |
| `c AS VECTOR_NORM(v,'norm2')`, not persisted | Created |
| `c AS v`, a computed column of vector type | Created |
| `CREATE INDEX ix ON t(id) INCLUDE (v)` | `sys.index_columns.is_included_column = 1` for the vector column |
| `CREATE CLUSTERED COLUMNSTORE INDEX cci ON t` where `t` has a vector column | `sys.indexes.type_desc = CLUSTERED COLUMNSTORE` |
| System versioned temporal table with a vector column | `sys.tables.temporal_type_desc = SYSTEM_VERSIONED_TEMPORAL_TABLE` |
| `DECLARE @t TABLE (v vector(3))` | Insert and count |
| `CREATE TYPE vt AS TABLE (v vector(3))` | Created. This is a table type, unlike the alias type above |
| Stored procedure parameter, scalar function return type, inline table function parameter | All created |
| `SELECT id, e INTO t2 FROM t` | Created |
| `ALTER TABLE t ALTER COLUMN x vector(3)` from `nvarchar(100)` | Succeeds |
| A view selecting a vector column | Created |
| `ALTER TABLE t ENABLE CHANGE_TRACKING` | Succeeds |
| `FOR JSON PATH` over a vector column | Returns the vector as a JSON array |
| Two vector columns in one table, including a `vector(1998)` | Created |
| Row level security filter predicate on a table with a vector column | Enforced. With a vector index on the same table the result is build-dependent: see the note below |

## Query surface: refused

| Statement | Error |
|---|---|
| `ORDER BY e` | `Msg 42213, The vector data types cannot be compared or sorted, except when using the IS NULL operator` |
| `GROUP BY e` | `Msg 42213` |
| `SELECT DISTINCT e` | `Msg 421, The vector data type cannot be selected as DISTINCT because it is not comparable` |
| `WHERE e = '[1,2,3]'`, `a.e = b.e`, `e IN (...)` | `Msg 8117, Operand data type vector is invalid for equal to operator` |
| `WHERE e > '[1,2,3]'` | `Msg 8117`, greater than operator |
| `MAX(e)` | `Msg 8117`, max operator |
| `COUNT(DISTINCT e)` | `Msg 8117`, count operator |
| `SELECT e ... UNION SELECT e ...` | `Msg 5335, The data type vector cannot be used as an operand to the UNION, INTERSECT or EXCEPT operators because it is not comparable` |

Working: `IS NULL`, `IS NOT NULL`, `UNION ALL`, `CASE`, `ISNULL`, and `ORDER BY
VECTOR_DISTANCE(...)`.

**Row level security beside a vector index.** On earlier container builds a security policy and a
vector index cannot share a table in either order (`Msg 37579`, `Msg 42244`; see
`rls-multi-tenant`). On container build 18.0.310.0_253 both orders are accepted, the filter holds
through `TOP (n) WITH APPROXIMATE` with no cross-tenant rows, and the vector index is **not** used
under the policy (`WITH (FORCE_ANN_ONLY)` fails with `Msg 8622`, while the same tenant test written
as a `WHERE` clause on a table without a policy gets a `Vector Index Seek`). Azure SQL Database
behaves the same way, and SQL Server 2025 refuses the pair in both orders. Microsoft Learn
documents none of this, so it can change: keep the tenant filter in the retrieval query, test it,
and if a policy is added, check the plan for the `Vector Index Seek`.

`sp_describe_first_result_set` over a query selecting a vector column reports system type 231,
`nvarchar(max)`. That is why a client without current driver support sees a string.

## Vector index: requirements

| Statement | Result |
|---|---|
| `CREATE VECTOR INDEX` on a table with 0 rows | `Msg 42266, Cannot create a vector index. The table contains only 0 rows with non-null vectors, but at least 100 are required for vector index creation` |
| The same with 50 rows | `Msg 42266`, quoting 50 |
| The same with 500 rows | Succeeds. `sys.vector_indexes` reports `DiskANN`, `COSINE`, `build_parameters` `{"StartId":"...", "L":"48", "R":"48", "Version":"3"}` |
| On a heap with no clustered index | `Msg 42254, Clustered index is required on table '<table>' to create a vector index` |
| On a table whose primary key is nonclustered | `Msg 42254` |
| On a clustered primary key of type `int` | Succeeds |
| On a clustered primary key of type `bigint` | Succeeds |
| On a clustered primary key of type `nvarchar(20)` | Succeeds |
| On a composite clustered primary key of two `int` columns | Succeeds |
| `WITH (METRIC='cosine')`, `TYPE` omitted | Succeeds, defaulting to DiskANN |
| `WITH (METRIC='dot', TYPE='diskann')` | Succeeds |
| A second vector index on the same column with a different metric | `Msg 42230, Cannot create vector index on column '<column>' because it already has an existing vector index` |
| On a `vector(1998)` column with 150 rows | Succeeds |
| `VECTOR_SEARCH` naming a metric with no matching index, with `WITH (FORCE_ANN_ONLY)` | `Msg 42227, Cannot find a vector index with metric '<metric>' on column '<column>'` |
| The same, without the hint: `METRIC = 'euclidean'` against a `cosine` index, `TOP (5) WITH APPROXIMATE` | Returns 5 rows with no error or warning. The search silently computes exact distances instead of reading the index |

## Vector index: what it blocks

| Statement | Result |
|---|---|
| `TRUNCATE TABLE` | `Msg 42232, TRUNCATE TABLE statement failed because table '<table>' has a vector index on it` |
| `ALTER INDEX ... REBUILD` | `Msg 42250, One or more of the specified ALTER INDEX options is unsupported for a Vector Index` |
| `ALTER INDEX ... DISABLE` | `Msg 42250` |
| `ALTER TABLE ... DROP COLUMN` on the indexed column | `Msg 5074`, then `Msg 4922` |
| `INSERT`, `UPDATE`, `DELETE` | All succeed, and the changed rows are searchable |

## Approximate search syntax rules

| Statement | Result |
|---|---|
| `VECTOR_SEARCH(..., TOP_N = 3)` against a version 3 index | `Msg 42274, Vector search with newer index version does not support explicit TOP_N parameter` |
| `TOP_N = 10000` | `Msg 42253`, TOP_N and L must both be between 1 and 2000 |
| `SELECT TOP (N) WITH APPROXIMATE` with no `VECTOR_SEARCH` in the query | `Msg 42248, APPROXIMATE cannot be used in a query without VECTOR_SEARCH` |
| `WITH APPROXIMATE` with no `ORDER BY` | `Msg 42248, APPROXIMATE cannot be used in a query without ORDER BY` |
| `ORDER BY r.distance DESC` | `Msg 42271, TOP WITH APPROXIMATE and VECTOR_SEARCH requires ORDER BY on distance column ascending, and no other columns` |
| `ORDER BY r.distance, t.id` | `Msg 42271` |
| An aggregate in the same select list | `Msg 42271` |
| `WHERE` predicate alongside `WITH APPROXIMATE` | Succeeds, and the filter is applied during the search |
| `INNER JOIN` to another table alongside `WITH APPROXIMATE` | Succeeds |

## Claims that do not hold

1. **"Type GA, index preview."** On Azure SQL Database the index, `VECTOR_SEARCH` and
   `TOP (N) WITH APPROXIMATE` are generally available along with the type; preview applies to SQL
   Server 2025. The type works at compatibility level 150 rather than needing 170.
2. **`Msg 42217` states that a table "must have a clustered primary key on a single 4 byte INT
   column to create a vector index".** A clustered primary key on `bigint`, on `nvarchar(20)` and
   on a two column composite all accept a vector index. The message is narrower than the
   behaviour, and the rule that applies is `Msg 42254`, a clustered index is required.
3. **The `Msg 42274` text differs from the published text.** The engine returns "Vector search
   with newer index version does not support explicit TOP_N parameter". The documentation quotes
   "Vector search with version 3 index does not support explicit TOP_N parameter". Match on the
   number, not on the words.
4. **Widely repeated claim that a vector column cannot appear in an index at all.** It cannot be a
   key column, and it **can** be an `INCLUDE` column, as `sys.index_columns` shows.
5. **Widely repeated claim that a vector index makes the table read only.** That was true of an
   earlier index format. On a version 3 index every DML statement succeeds and the change is
   searchable.
6. The dynamic management view column naming the outstanding maintenance differs between Azure
   SQL Database and the container. Read the column list from the view rather than hard coding a
   name.
7. **Widely repeated claim that a DiskANN vector index cannot be built on the Azure SQL Database
   container.** It builds. The same index over the same rows builds on both engines, and
   approximate search returns the same rows from both.
8. **Widely repeated claim that `PREVIEW_FEATURES = ON` is a prerequisite for creating a vector
   index.** It is not, and **the setting's value in the container is not deterministic, so assert
   no value for it.**

   On a single container, freshly created databases return `0` or `1`, varying from one database
   to the next, while `model` and `master` both return `0`. The variation does not track engine
   uptime cleanly. **Any one reading is one sample of something that varies**, and a check built
   on it fails often, on a claim that was never the point.

   Microsoft Learn documents `OFF` as the default, scopes the requirement to the boxed engine, and
   calls the setting not needed for Azure SQL Database.

   The claim that matters is unaffected: nobody runs `ALTER DATABASE SCOPED CONFIGURATION`. With
   150 rows carrying a `vector(4)` value,
   `CREATE VECTOR INDEX ... WITH (METRIC = 'cosine', TYPE = 'diskann')` completes, is listed in
   `sys.vector_indexes`, and serves a `TOP (3) WITH APPROXIMATE` search.

## Exact search scans, approximate search seeks

On an Azure SQL Database, or on the Azure SQL Database container:

```sql
CREATE TABLE dbo.chunks (id INT IDENTITY PRIMARY KEY, body NVARCHAR(400), embedding VECTOR(4));

DECLARE @i INT = 1;
WHILE @i <= 500
BEGIN
    INSERT dbo.chunks (body, embedding)
    VALUES (CONCAT('sample chunk ', @i),
            CAST(CONCAT('[', RAND(CHECKSUM(NEWID())), ',', RAND(CHECKSUM(NEWID())), ',',
                             RAND(CHECKSUM(NEWID())), ',', RAND(CHECKSUM(NEWID())), ']') AS VECTOR(4)));
    SET @i += 1;
END;

CREATE VECTOR INDEX vi_chunks ON dbo.chunks (embedding) WITH (METRIC = 'cosine', TYPE = 'diskann');

SET STATISTICS XML ON;
DECLARE @q VECTOR(4) = '[0.1,0.2,0.3,0.4]';

-- exact, scans
SELECT TOP (5) id FROM dbo.chunks ORDER BY VECTOR_DISTANCE('cosine', embedding, @q);

-- approximate, seeks the vector index
SELECT TOP (5) WITH APPROXIMATE t.id, r.distance
FROM VECTOR_SEARCH(TABLE = dbo.chunks AS t, COLUMN = embedding, SIMILAR_TO = @q, METRIC = 'cosine') AS r
ORDER BY r.distance;
```

You will see two plans: the approximate query's contains `Vector Index Seek`, and the exact query's
does not. Every other row in this file is a single statement you can run the same way.
