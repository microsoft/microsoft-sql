# Measured runs

Everything asserted in SKILL.md, with the command that produced it. Run on 2026-08-28 against a
local Azure SQL Database container, `SERVERPROPERTY('EngineEdition')` = 5, `@@VERSION` reporting
Microsoft SQL Azure.

Two kinds of evidence are separated on purpose. **Read** means the shipped source of an installed
package. **Ran** means a statement that went to the engine and returned what is quoted.

## Contents

- [Setup](#setup)
- [Read: the four prompt surfaces](#read-the-four-prompt-surfaces)
- [Ran: the dialect string and the rendered prompt](#ran-the-dialect-string-and-the-rendered-prompt)
- [Ran: what LIMIT actually returns](#ran-what-limit-actually-returns)
- [Ran: the vector store table and its index](#ran-the-vector-store-table-and-its-index)
- [Ran: dimensions, metadata filters and batching](#ran-dimensions-metadata-filters-and-batching)
- [Read: no approximate search, no LlamaIndex integration](#read-no-approximate-search-no-llamaindex-integration)
- [Ran: the guardrails](#ran-the-guardrails)
- [What was not verified](#what-was-not-verified)

## Setup

```bash
python -m venv .venv && .venv/bin/pip install \
  langchain langchain-community langchain-sqlserver llama-index-core sqlalchemy
.venv/bin/pip freeze | grep -Ei 'langchain|llama-index|sqlalchemy|pyodbc'
```

Resolved to `langchain==1.3.18`, `langchain-core==1.6.1`, `langchain-community==0.4.2`,
`langchain-classic==1.0.8`, `langchain-sqlserver==1.0.1`, `llama-index-core==0.14.24`,
`sqlalchemy==2.0.52`, `pyodbc==5.3.0`.

The engine, and a table with fake rows:

```sql
CREATE DATABASE appdb;
GO
CREATE TABLE dbo.customers (
    customer_id INT IDENTITY PRIMARY KEY,
    full_name   NVARCHAR(100) NOT NULL,
    email       NVARCHAR(200) NOT NULL,
    ssn_last4   CHAR(4)       NOT NULL,
    city        NVARCHAR(80)  NOT NULL);
INSERT INTO dbo.customers (full_name, email, ssn_last4, city) VALUES
 (N'Ada Example', N'ada@example.com', '0001', N'Springfield'),
 (N'Bo Example',  N'bo@example.com',  '0002', N'Shelbyville'),
 (N'Cy Example',  N'cy@example.com',  '0003', N'Ogdenville'),
 (N'Di Example',  N'di@example.com',  '0004', N'North Haverbrook');
```

Connection used by every Python probe, with the secret supplied from the environment:

```python
odbc = urllib.parse.quote_plus(
    "DRIVER={ODBC Driver 18 for SQL Server};SERVER=localhost,<port>;DATABASE=appdb;"
    "UID=example_username;PWD=" + os.environ["SQL_PASSWORD"] + ";TrustServerCertificate=yes")
uri = f"mssql+pyodbc:///?odbc_connect={odbc}"
```

## Read: the four prompt surfaces

```bash
cat .venv/lib/python3.12/site-packages/langchain_community/agent_toolkits/sql/prompt.py
cat .venv/lib/python3.12/site-packages/langchain_classic/chains/sql_database/prompt.py
cat .venv/lib/python3.12/site-packages/langchain_community/tools/sql_database/prompt.py
sed -n '185,215p' .venv/lib/python3.12/site-packages/llama_index/core/prompts/default_prompts.py
```

- `SQL_PREFIX`, the agent prompt: `always limit your query to at most {top_k} results`. No T-SQL
  branch, no `TOP`.
- `SQL_PROMPTS` in the classic chain module has eleven per-dialect entries. `SQL_PROMPTS['mssql']`
  says `query for at most {top_k} results using the TOP clause as per MS SQL`. `create_sql_query_chain`
  selects it with `elif db.dialect in SQL_PROMPTS`.
- `QUERY_CHECKER`, the prompt behind `sql_db_query_checker`, lists eight common mistakes: `NOT IN`
  with nulls, `UNION` versus `UNION ALL`, `BETWEEN` for exclusive ranges, type mismatches in
  predicates, quoting identifiers, function argument counts, casting, and join columns. Pagination
  syntax is not among them.
- `DEFAULT_TEXT_TO_SQL_TMPL` in LlamaIndex takes `{dialect}` and has no row cap sentence at all.
  There is no per-dialect table in that module.

The hub prompt the toolkit docstring recommends was fetched and compared:

```bash
curl -s https://api.smith.langchain.com/commits/langchain-ai/sql-agent-system-prompt/latest
```

Commit `31156d5f...`. Its template contains `always limit your query to at most {top_k} results`,
identical wording to `SQL_PREFIX`.

## Ran: the dialect string and the rendered prompt

```python
db = SQLDatabase.from_uri(uri)
db.dialect                       # -> 'mssql'
SQL_PREFIX.format(dialect=db.dialect, top_k=10)
```

Rendered output, second and third lines:

```text
Given an input question, create a syntactically correct mssql query to run, then look at the
results of the query and return the answer.
Unless the user specifies a specific number of examples they wish to obtain, always limit your
query to at most 10 results.
```

`SQLDatabase.dialect` returns `self._engine.dialect.name`, which is fixed by the `mssql+pyodbc`
URL and not by the server, so this is the same string for the container and for the cloud.

LlamaIndex, same database: `llama_index.core.SQLDatabase.from_uri(uri).dialect` also returns
`'mssql'`, and `DEFAULT_TEXT_TO_SQL_PROMPT.format(dialect='mssql', ...)` renders
`create a syntactically correct mssql query` with no row-cap sentence following it.

## Ran: what LIMIT actually returns

Through `QuerySQLDatabaseTool.invoke`, which is what the model sees:

| Statement | Returned |
|---|---|
| `SELECT customer_id, full_name FROM customers LIMIT 10` | `Incorrect syntax near '10'. (102)` |
| `SELECT customer_id, full_name FROM customers ORDER BY full_name LIMIT 10` | `Incorrect syntax near 'LIMIT'. (102)` |
| `SELECT customer_id FROM customers OFFSET 0 ROWS FETCH NEXT 10 ROWS ONLY` | `Incorrect syntax near '0'. (102)` |
| `SELECT TOP (5) customer_id FROM customers` | Rows |
| `SELECT customer_id FROM customers ORDER BY customer_id OFFSET 0 ROWS FETCH NEXT 5 ROWS ONLY` | Rows |

The alias hypothesis, which explains why the first message names the number:

```sql
SELECT LIMIT.customer_id FROM customers LIMIT;   -- succeeds, returns all four rows
```

`LIMIT` is a legal table alias in T-SQL, so with no `ORDER BY` the parser accepts it and fails on
the integer that follows.

## Ran: the vector store table and its index

Constructed `SQLServer_VectorStore` with a deterministic fake embedding function, `embedding_length=8`,
`table_name="lcv_docs"`, then read the DDL back off the connection:

```sql
CREATE TABLE lcv_docs (
    id               UNIQUEIDENTIFIER NOT NULL,
    custom_id        VARCHAR(1000) NULL,
    content_metadata json NULL,
    content          NVARCHAR(max) NOT NULL,
    embeddings       vector(8) NOT NULL,
    PRIMARY KEY NONCLUSTERED (id)
)
CREATE UNIQUE NONCLUSTERED INDEX idx_custom_id ON lcv_docs (custom_id)
```

`sys.indexes` for that object: one `HEAP` row, one `NONCLUSTERED` primary key, one nonclustered
unique index. Then:

```sql
CREATE VECTOR INDEX vi_lcv ON dbo.lcv_docs(embeddings) WITH (METRIC='cosine', TYPE='diskann');
-- Msg 42254, Level 16, State 1
-- Clustered index is required on table 'dbo.lcv_docs' to create a vector index.

CREATE CLUSTERED INDEX ix_lcv_docs_cl ON dbo.lcv_docs(id);
SET QUOTED_IDENTIFIER ON;
CREATE VECTOR INDEX vi_lcv ON dbo.lcv_docs(embeddings) WITH (METRIC='cosine', TYPE='diskann');
-- Msg 42266, Level 16, State 1
-- Cannot create a vector index. The table contains only 4 rows with non-null vectors,
-- but at least 100 are required for vector index creation.
```

The second message is the expected row-count gate, which proves the clustered index cleared the
first one. Note the session needs `QUOTED_IDENTIFIER ON`, otherwise the statement fails with
`Msg 1934` before either gate is reached.

The search SQL, captured with a `before_cursor_execute` listener on `similarity_search_with_score(k=2)`:

```sql
SELECT TOP 2 lcv_docs.id, lcv_docs.custom_id, lcv_docs.content_metadata, lcv_docs.content,
       lcv_docs.embeddings,
       VECTOR_DISTANCE('cosine', cast ('[...]' as vector(8)), embeddings) AS distance
FROM lcv_docs ORDER BY distance ASC
```

`TOP`, not `LIMIT`, because SQLAlchemy compiles `.limit(k)` for the dialect. No `VECTOR_SEARCH`,
no `WITH APPROXIMATE`.

## Ran: dimensions, metadata filters and batching

```python
SQLServer_VectorStore(..., embedding_length=3072, table_name="lcv_big")
# The size (3072) given to the column 'embeddings' exceeds the maximum allowed (1998). (2717)

SQLServer_VectorStore(..., embedding_length=8)   # with a function returning 16 floats
vs.add_texts(["alpha"])
# The vector dimensions 8 and 16 do not match. (42204)
```

Metadata filters, captured off the connection:

```sql
-- filter={"src": "b"}
WHERE JSON_VALUE(lcv_docs.content_metadata, ?) = ?              params ('$.src', 'b')

-- filter={"n": {"$gt": 5}}
WHERE CAST(JSON_VALUE(lcv_num.content_metadata, ?) AS NUMERIC(10, 2)) > ?   params ('$.n', 5)

-- filter={"n": {"$in": [10]}}
WHERE JSON_VALUE(lcv_num.content_metadata, ?) IN (?)            params ('$.n', '10')
```

Both the path and the value are bound. The `$in` operator binds the value as a **string**, so it is
an exact text match on the JSON representation.

The overflow, with metadata `{"ts": 1756000000}` and `{"ts": 1756900000}`:

```python
vs.similarity_search("a", k=5, filter={"ts": {"$gt": 1756500000}})
# Arithmetic overflow error converting nvarchar to data type numeric. (8115)
vs.similarity_search("a", k=5, filter={"ts": {"$gte": 1}})
# Arithmetic overflow error converting nvarchar to data type numeric. (8115)
```

The second call proves the cast is applied to the stored column, not to the bound comparison value,
so shrinking the bound does not help. The rows insert without complaint; only the filter fails.

Batch size is checked in `_validate_batch_size` against `MAX_BATCH_SIZE = 419` and raises before any
round trip.

## Read: no approximate search, no LlamaIndex integration

```bash
grep -n "VECTOR_SEARCH\|APPROXIMATE\|CREATE VECTOR INDEX\|diskann" \
  .venv/lib/python3.12/site-packages/langchain_sqlserver/vectorstores.py
# no matches in 1362 lines
```

The Entra fallback is in the same file: `_create_engine` registers `_provide_token` unless the
connection string carries a user and secret or `Trusted_Connection=yes`, and `_provide_token` calls
`DefaultAzureCredential().get_token(...)`.

For LlamaIndex, the package index returns 404 for every plausible name
(`llama-index-vector-stores-azuresql`, `-mssql`, `-azure-sql`, `-sqlserver`) while known-good
neighbours such as `llama-index-vector-stores-postgres` return 200, so the 404s are a real absence
and not a broken probe. The integrations directory listing in the LlamaIndex repository confirms it:
the Azure entries there are for other services, and none of them is this engine.

## Ran: the guardrails

Read-only, with a dedicated login granted `db_datareader` and nothing else, through
`QuerySQLDatabaseTool.invoke`:

| Statement | Result |
|---|---|
| `SELECT TOP (2) full_name FROM customers` | `[('Ada Example',), ('Bo Example',)]` |
| `UPDATE customers SET city = N'Owned' WHERE customer_id = 1` | `The UPDATE permission was denied on the object 'customers', database 'appdb', schema 'dbo'. (229)` |
| `DROP TABLE customers` | `Cannot drop the table 'customers', because it does not exist or you do not have permission. (3701)` |
| `EXEC sp_executesql N'SELECT 1'` | `[(1,)]` |

With the high-privilege login instead, `db.run` executed and committed an `INSERT` (row count went
from 4 to 5) and a `CREATE TABLE dbo.scratch_probe (i INT); DROP TABLE dbo.scratch_probe;` pair in a
single call. LlamaIndex's `run_sql` executed an `UPDATE` and the new value was visible on the next
`SELECT`.

Table scoping:

```python
db = SQLDatabase.from_uri(uri, include_tables=["customers"], sample_rows_in_table_info=0)
db.get_usable_table_names()                                 # ['customers']
QuerySQLDatabaseTool(db=db).invoke("SELECT TOP (1) id FROM lcv_docs")
# [('CDD8DCEF-...',)]   an excluded table, queried successfully
```

Schema exposure, `InfoSQLDatabaseTool.invoke("customers")`:

- Default: the `CREATE TABLE` text, then a comment block headed `3 rows from customers table:` with
  all five columns of three real rows, including the column standing in for sensitive data.
- With `sample_rows_in_table_info=0`: the `CREATE TABLE` text only.

LlamaIndex's `get_single_table_info("customers")` returns one line of column names and types, with
no rows.

Error handling differs between the frameworks and it matters for the retry loop:

- LangChain: `QuerySQLDatabaseTool._run` calls `db.run_no_throw`, so nothing raises and the full
  driver message, database name, schema name and object name included, is returned to the model as
  a string.
- LlamaIndex: `run_sql` catches `ProgrammingError` and `OperationalError` and re-raises
  `NotImplementedError("Statement ... is invalid SQL.\nError: ...")`. The driver message survives on
  the second line, but the exception type does not, so an `except ProgrammingError` around it never
  fires.

## What was not verified

- **Everything above ran against the container, not against a cloud database.** The package
  behaviour is substrate-independent because it is source. The engine messages are quoted with their
  numbers so they can be re-checked in the cloud in a few minutes, and the vector index numbers
  (`42254`, `42266`) match what `vector-search-azure-sql` measured on both engines.
- **No model was called.** The prompts are quoted as rendered, not as followed. The claim that a
  model tends to emit `LIMIT` when told to "limit" is the catalog's prior, and what is measured here
  is that the prompt says it, that the engine rejects it, and that the rejection names the wrong
  token.
- **The checker tool's behaviour was not exercised end to end**, only its prompt read. The claim is
  that its list of mistakes omits pagination, which is a property of the text.
- **Cross-encoder re-ranking, streaming and the agent frameworks' async paths** were not touched.
