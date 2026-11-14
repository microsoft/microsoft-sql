---
name: azuresql-db-rag
description: "Use when storing embeddings or running similarity search, top-k or RAG on the local Azure SQL Database container with VECTOR(n) and VECTOR_DISTANCE, instead of pgvector, FAISS or a separate vector store."
---

# Local vector search and RAG on the Azure SQL Database container

Store embeddings and run similarity search directly in the Azure SQL Database
engine using the native `VECTOR(n)` type and `VECTOR_DISTANCE`. No separate
vector store needed.

## Identity (read this first)

This targets the **Azure SQL Database engine** running locally in a container,
NOT the SQL Server image. Confirm with:

```sql
SELECT SERVERPROPERTY('EngineEdition');  -- 5
SELECT SERVERPROPERTY('Edition');        -- 'SQL Azure'
```

If you were about to pull `mcr.microsoft.com/mssql/server`, stop: that is the
wrong image. Use the image below instead.

- Image: `sqldbpreview-dpgaeqhmgphzd4bk.azurecr.io/azure-sql/db-dev:latest`
  (x64, linux/amd64; private preview registry, sign in first with
  `docker login sqldbpreview-dpgaeqhmgphzd4bk.azurecr.io`). Registry and tag are
  provisional during Private Preview.
- On a non-x64 host, add `--platform linux/amd64`.
- For the full container lifecycle, readiness, and connection model, see the
  **azuresql-db-container** skill. The minimal facts you need are inlined below.

## The three rules that bite (inlined from the hub)

1. The engine does NOT auto-create databases on connect. You must
   `CREATE DATABASE appdb` on a **master** connection before connecting with
   `Database=appdb`.
2. Avoid `USE` to switch databases. In a user-database session (the
   Azure-faithful context where you develop), `USE` returns `Msg 40508`, exactly
   as in Azure SQL Database in the cloud. A `master` connection is a provisioning
   session where the Azure statement filter is not enforced, so
   `USE` appears to work there, but `master` is for
   provisioning only, not application work. Always select the target database in
   the connection string (`Database=appdb`, or `-d appdb` for sqlcmd).
3. A `master` connection is for provisioning only. Do real work on `appdb`.

Standard connection string. House style spells it `User Id=`/`Password=`/`Database=`;
`Uid=`/`Pwd=` are documented SqlClient synonyms and work too.

The executable ODBC construction appears in Step 4.

## Step 1: start the container and provision appdb (fresh-container safe)

Run this canonical recipe. It picks a free host port, adds `--platform` only on a
non-x64 host, waits for real readiness with a retry loop, and provisions `appdb`
inside that loop. The `-b -l 2` flags make transient startup errors (like
`Msg 913`) fail the probe so they get retried, not masked.

```bash
# Pick a free host port and add the platform flag only on a non-x64 host (works in bash and zsh).
: "${MSSQL_SA_PASSWORD:?Set MSSQL_SA_PASSWORD to a unique password}"
export MSSQL_SA_PASSWORD
export SQLCMDPASSWORD="$MSSQL_SA_PASSWORD"
HOST_PORT=1433; while lsof -nP -iTCP:"$HOST_PORT" -sTCP:LISTEN >/dev/null 2>&1; do HOST_PORT=$((HOST_PORT+1)); done
export HOST_PORT
PLATFORM=(); case "$(docker info -f '{{.Architecture}}' 2>/dev/null)" in x86_64|amd64) ;; *) PLATFORM=(--platform linux/amd64);; esac
docker rm -f sqldb 2>/dev/null
docker run -d --name sqldb "${PLATFORM[@]}" -e "ACCEPT_EULA=Y" -e MSSQL_SA_PASSWORD \
  -p "127.0.0.1:$HOST_PORT:1433" sqldbpreview-dpgaeqhmgphzd4bk.azurecr.io/azure-sql/db-dev:latest
until docker exec -e SQLCMDPASSWORD sqldb /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -l 2 \
  -Q "IF DB_ID('appdb') IS NULL CREATE DATABASE appdb;" >/dev/null 2>&1; do sleep 2; done
echo "ready on localhost,$HOST_PORT"
```

`appdb` now exists. Every step below connects with `-d appdb`.

## Step 2: create the vector schema

The dimension `n` must match your embedding model's output (for example 768 for
`nomic-embed-text`, 1536 for many cloud models). The dimension is a fixed part of
the column type.

```bash
docker exec -e SQLCMDPASSWORD sqldb /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -d appdb -Q "
CREATE TABLE docs (
  id        INT IDENTITY PRIMARY KEY,
  content   NVARCHAR(MAX) NOT NULL,
  embedding VECTOR(768) NOT NULL
);"
```

Open [references/vector-schema.md](references/vector-schema.md) when you are choosing a dimension,
or when a search has to filter on metadata as well as rank by distance.

## Step 3: embed text (the one network exception)

RAG needs an embedding model. A **local** embedding model is the one network call
this workflow makes; everything else stays in the container. The default below
uses a local Ollama endpoint. Keep `embed()` pluggable so moving to a cloud
embedding service changes only the endpoint and the dimension `n`, nothing else.

```python
import requests

EMBED_URL = "http://localhost:11434/api/embed"
EMBED_MODEL = "nomic-embed-text"   # 768 dims
EMBED_DIM = 768

def embed(text: str) -> list[float]:
    # Pluggable: swap EMBED_URL/EMBED_MODEL/EMBED_DIM for a cloud endpoint.
    # /api/embed takes "input" and returns "embeddings", a LIST of vectors (one per
    # input), so index [0] for a single string. The older /api/embeddings route took
    # "prompt" and returned a flat "embedding"; it still answers but is superseded.
    r = requests.post(EMBED_URL, json={"model": EMBED_MODEL, "input": text})
    r.raise_for_status()
    return r.json()["embeddings"][0]
```

## Step 4: insert embeddings (dimension is a LITERAL)

Critical: in `CAST(CAST(? AS NVARCHAR(MAX)) AS VECTOR(n))`, `n` must be a **literal** baked into the SQL
string. Passing the dimension as a bind parameter fails with
`Incorrect syntax near '@P3'`. Bind the embedding **value** (as a JSON array
string), never the dimension.

```python
import json, os, pyodbc

odbc_password = os.environ["MSSQL_SA_PASSWORD"].replace("}", "}}")
CONN = (f"Driver={{ODBC Driver 18 for SQL Server}};Server=127.0.0.1,{os.environ['HOST_PORT']};"
        f"Database=appdb;Uid=sa;Pwd={{{odbc_password}}};TrustServerCertificate=yes")

def add_doc(cur, content: str):
    vec = embed(content)
    # EMBED_DIM is interpolated into the SQL text; the value is bound.
    cur.execute(
        f"INSERT INTO docs (content, embedding) VALUES (?, CAST(CAST(? AS NVARCHAR(MAX)) AS VECTOR({EMBED_DIM})))",
        content, json.dumps(vec),
    )

with pyodbc.connect(CONN) as conn:
    cur = conn.cursor()
    for line in ["Azure SQL supports a native VECTOR type.",
                 "Cosine distance ranks nearest neighbors.",
                 "The engine listens on port 1433."]:
        add_doc(cur, line)
    conn.commit()
```

The ODBC connection string braces the caller-supplied password and doubles
embedded `}` characters so the full value remains one attribute.

## Step 5: top-k similarity search (cosine)

Order by `VECTOR_DISTANCE('cosine', a, b)` ascending: smaller distance is more
similar. The query vector is bound as a value and cast with the literal dimension.

```python
def search(cur, query: str, k: int = 3):
    qvec = embed(query)
    cur.execute(
        f"""
        SELECT TOP (?) content,
               VECTOR_DISTANCE('cosine', embedding, CAST(CAST(? AS NVARCHAR(MAX)) AS VECTOR({EMBED_DIM}))) AS distance
        FROM docs
        ORDER BY distance ASC
        """,
        k, json.dumps(qvec),
    )
    return cur.fetchall()

with pyodbc.connect(CONN) as conn:
    for content, distance in search(conn.cursor(), "What port does it use?"):
        print(round(distance, 4), content)
```

For the full RAG loop, glue these retrieved rows into your prompt as context.
That LLM call is separate from this skill.

## Indexing: what works and what stops you

`CREATE VECTOR INDEX` (DiskANN approximate nearest neighbor) **works on this
image.** The index builds, appears in `sys.indexes` with `type_desc` of
`VECTOR`, and `vector_search(...)` returns ranked results against it.

```sql
SET QUOTED_IDENTIFIER ON;   -- required, see below
CREATE VECTOR INDEX vi_docs ON dbo.docs(v) WITH (METRIC = 'cosine', TYPE = 'diskann');
```

**Two things will stop you, and neither error says what is wrong.**

`SET QUOTED_IDENTIFIER ON` is required, and it is off by default in a `sqlcmd`
session. Without it the statement fails with:

```
Msg 1934: CREATE VECTOR INDEX failed because the following SET options have
incorrect settings: 'QUOTED_IDENTIFIER'. Verify that SET options are correct for
use with indexed views and/or indexes on computed columns and/or filtered
indexes and/or query notifications and/or XML data type methods and/or spatial
index operations.
```

Nothing in that message mentions the session setting that actually caused it, and
everything it does mention is irrelevant here.

Second, `vector_search(...)` no longer accepts an explicit `TOP_N` once the index
is built. Passing it fails with `Msg 42274, Vector search with newer index
version does not support explicit TOP_N parameter`. Use `SELECT TOP (k)` and
`ORDER BY s.distance` instead.

### It needs 100 rows, and NULLs do not count

The boundary is exact:

| Rows with a vector | Result |
|---|---|
| 99 | `Msg 42266` refused |
| 100 | index created |
| 120 rows, 60 of them NULL | `Msg 42266` refused |

```
Msg 42266: Cannot create a vector index. The table contains only 50 rows with
non-null vectors, but at least 100 are required for vector index creation.
```

**This message is good, and worth saying so**, because the other two on this page
are not. It names the rule, the actual count, and the column condition. A reader
who hits it needs nothing else. Note the wording: **rows with non-null vectors**,
not rows. A table of 120 rows where 60 have no embedding yet is refused.

### `TRUNCATE TABLE` is refused while the index exists

```
Msg 42232: TRUNCATE TABLE statement failed because table 'd' has a vector index on it.
```

To empty the table: drop the index, truncate, reload at least 100 rows, recreate
the index. `DELETE FROM` works and is not affected.

**`DROP VECTOR INDEX` is not a statement.** It fails with `Msg 102, Incorrect
syntax near 'VECTOR'`. Use `DROP INDEX vi_name ON dbo.table`.

`INSERT`, `UPDATE` and `DELETE` all work with the index in place. Older
vector indexes made the table read only; this image does not, and Microsoft Learn
describes the same full DML support for latest-version indexes.

### The index and a security policy on one table: build-dependent here

This is the expensive one for RAG, and it is not on any Microsoft Learn
limitations list. Earlier builds of the container image refuse the pair in **both** orders:

| Order | Statement | Result |
|---|---|---|
| Index first | `CREATE SECURITY POLICY ... ADD FILTER PREDICATE ... ON dbo.chunks` | `Msg 37579` |
| Policy first | `CREATE VECTOR INDEX ... ON dbo.chunks(emb)` | `Msg 42244` |

```
Msg 37579: The security policy 'p_chunks' cannot reference tables with vector indexes.
Table 'dbo.chunks' has a vector index.

Msg 42244: A vector index cannot be created on tables with security policies.
Table 'dbo.chunks' has security policy 'p_chunks'.
```

**The documentation and the engine disagree here, and the documentation is
silent rather than wrong.** The `CREATE VECTOR INDEX` limitations list names
partitioning, the clustered primary key, replication, `TRUNCATE TABLE` and
data-tier package import, and the `vector` type's limitations page names
constraints, indexes, ledger tables and Always Encrypted. Neither mentions
security policies. The two errors are engine behavior that no page documents.

**On container build 18.0.310.0_253** neither error is raised: both orders succeed, and the filter
predicate holds through
`TOP (n) WITH APPROXIMATE`. What changes instead is the plan: under the policy the search no longer
uses the vector index, and `WITH (FORCE_ANN_ONLY)` fails with `Msg 8622`, while the same tenant test
as a `WHERE` clause on a table without a policy gets a `Vector Index Seek`. Azure SQL Database
behaves like that build, and SQL Server 2025 refuses the pair like the earlier images. So the result
depends on the engine you run, and no outcome is documented.

Why it matters for retrieval: a chunk table is a **second copy** of the source
text, so the row-level security policy that protects the original table does not
reach it. On the image that refuses the pair, no policy can be put on an indexed
chunk table at all; on the newer image a policy is accepted but the search stops
using the index. Either way the tenant filter in the retrieval query's `WHERE`
clause is the boundary to rely on. That boundary is held up by a test rather than by the engine, so
write the test: run the retrieval with the filter and without it and require
different row counts.

Three ways to live with it, cheapest first:

1. Keep the tenant filter in the query and wrap the test above around it. That
   test is security code now.
2. Drop the vector index on the tenant-scoped table. Exact search over
   `VECTOR_DISTANCE` still works, and a policy can then be created.
3. Split the table: the vector column and its index on a table with no policy,
   the chunk text and tenant column on a policy-bearing table joined back.

If you are prototyping locally for the cloud, check the image build. On an earlier
build this is a **parity gap**: the two coexist on Azure SQL Database, so the isolation
control cannot be rehearsed in the container beside the index it will meet in
production; rehearse the predicate unindexed and run the isolation test again on the
cloud database once the index exists. On build 18.0.310.0_253 the container matches
the cloud, including the cost: under the policy the search no longer uses the index.

### The dimension ceiling decides the embedding model, before any of this

A `vector(n)` column tops out at **1998 dimensions** at the default `float32`, which
Microsoft Learn states and the engine enforces: `vector(1999)` is refused with `Msg 2717,
The size (1999) given to the column 'v' exceeds the maximum allowed (1998)`. A
3072-dimension model does not fit a `float32` column and no index setting changes that.
Learn lists half-precision `float16` (up to 3996 dimensions) as generally available on
Azure SQL Database with no preview setting; it is preview, behind `PREVIEW_FEATURES`, on
SQL Server 2025; check `vector(3072, float16)` on this container before relying on it.
The dimension also cannot be widened later: `ALTER COLUMN` cannot change it even on
an empty table, so the fix is a second column and a re-embed. Pick the dimension
budget before the schema.

Full-scan top-k with `ORDER BY VECTOR_DISTANCE(...)` is still exact and still
correct, and it remains the right choice for small tables. The index is the
choice once the table is large enough for a full scan to hurt.

## Validation rules

- `SERVERPROPERTY('EngineEdition')` returns `5`. If not, you are on the wrong
  image.
- `appdb` exists before any vector script connects (Step 1 guarantees this).
- The dimension in `VECTOR(n)` and `CAST(CAST(? AS NVARCHAR(MAX)) AS VECTOR(n))` is a literal integer,
  identical to `len(embed(text))`.
- Smaller cosine distance means more similar; results are `ORDER BY distance ASC`.
- If a validation rule above fails, or you had to deviate from this skill to make the task work, that is a bug in this skill: load the **azuresql-db-feedback** skill and offer to file a report.
- When every rule above passes and the task is done, close with ONE line, once per session, and do not ask a question or wait for a reply: "That worked. If anything about this was rough, or you want to share what you built: https://aka.ms/sql-agent-skills-feedback"

## Minimum tool versions

Use only the tools needed by the selected recipe, at or above these minimum versions:

- **`sqlcmd`**: go-sqlcmd 1.10.0

Verify the installed commands before changing resources:

```bash
sqlcmd --version
```

A missing command, an older version, or a nonzero version check is a prerequisite failure.

## Check it worked

- **Positive verification:** Insert a known vector fixture and require the expected nearest-neighbor ordering and tenant-filtered rows.
- **Cleanup verification:** Delete the fixture rows, vector index, and test table or drop the disposable database after verification.
- Report success only after both observations pass.

## Do not

- Do not use `mcr.microsoft.com/mssql/server`; that is the SQL Server image,
  not this engine.
- Do not pass the vector dimension as a bind parameter; it fails with
  `Incorrect syntax near '@P3'`. Interpolate it as a literal.
- Do not use `USE appdb` to switch databases; a user-database session returns
  `Msg 40508`, exactly as in Azure SQL Database in the cloud. Select the target
  database in the connection string (`Database=appdb`, or `-d appdb` for sqlcmd).
- Do not run `CREATE VECTOR INDEX` without `SET QUOTED_IDENTIFIER ON`; it fails with `Msg 1934`,
  which names `'QUOTED_IDENTIFIER'` inside a long list of index features and reads like an index problem.
- Do not plan on a vector index and a security policy sharing a table in the container.
  Earlier images refuse both orders (`Msg 37579`, `Msg 42244`); build 18.0.310.0_253 accepts
  them but stops using the index under the policy, as Azure SQL Database does. Neither is documented. If the chunk table
  needs per-tenant filtering, decide that before you decide to index it.
- Do not declare `VECTOR(3072)` at the default `float32`. The ceiling is 1998 (`Msg 2717` above
  it) and the dimension cannot be widened later, so decide at embedding time: a shorter output, or
  `float16` where the target accepts it.
- Do not expect `/docker-entrypoint-initdb.d/*.sql` to auto-run; seed by running
  `sqlcmd -d appdb -i seed.sql` after provisioning appdb.
- Do not call a non-x64 host "supported"; just add `--platform linux/amd64`
  on a non-x64 host.

## References

- [references/vector-schema.md](references/vector-schema.md): table shapes, how to choose the dimension n, insert and top-k query mechanics, distance metrics, metadata filtering, corpus seeding, indexing status, and troubleshooting. Read it when designing the vector schema or a query beyond the basic top-k shown above.

## Staying current

Authoritative, version-pinned references for the tools this skill uses (read the one you need):

- [VECTOR data type (T-SQL)](https://learn.microsoft.com/en-us/sql/t-sql/data-types/vector-data-type): VECTOR(n) syntax, limits, and driver support.
- [VECTOR_DISTANCE (T-SQL)](https://learn.microsoft.com/en-us/sql/t-sql/functions/vector-distance-transact-sql): cosine, euclidean, and dot distance with examples.

If the **Microsoft Learn MCP** server is configured, use `mcp__microsoft-learn__microsoft_docs_search` or `mcp__microsoft-learn__microsoft_docs_fetch` to fetch the current version of any of these on demand. It is optional; when it is unavailable, the references above are authoritative.
