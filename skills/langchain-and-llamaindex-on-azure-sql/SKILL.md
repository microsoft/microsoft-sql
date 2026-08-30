---
name: langchain-and-llamaindex-on-azure-sql
description: >-
  Wires LangChain or LlamaIndex to Azure SQL Database from Python: the SQL toolkits and their text
  to SQL prompts, the langchain-sqlserver vector store, and the guardrails neither framework
  enforces. Use when someone asks to "use LangChain with Azure SQL", "build a SQL agent over the
  database", "text to SQL", "SQLDatabaseToolkit", "NLSQLTableQueryEngine", "which LlamaIndex vector
  store works with Azure SQL", or "make the SQL agent read only"; when a generated query fails with
  incorrect syntax near a number because the framework prompt asked for a LIMIT clause; when a
  framework-created embedding table refuses CREATE VECTOR INDEX; and when a metadata filter starts
  throwing arithmetic overflow. This skill owns the Python framework wiring. The vector type and the
  query shape are vector-search-azure-sql, the cloud retrieval pipeline is rag-on-azure-sql, the
  offline container loop is rag-local-with-container, and drivers, connection strings and token auth
  are connect-from-python.
---

# LangChain and LlamaIndex on Azure SQL Database

Both frameworks connect to this engine on the first try and then get four things wrong that the
connection test cannot show. This is what they ship, where it disagrees with the engine, and what
their defaults expose.

It is not a text to SQL tutorial and not a vector search reference.

**Verified on 2026-08-28** by installing the packages and reading what ships, then running every
statement below against a local Azure SQL Database container (`SERVERPROPERTY('EngineEdition')`
returns 5, `@@VERSION` reports Microsoft SQL Azure). Pinned versions:

| Package | Version tested |
|---|---|
| `langchain` | 1.3.18 |
| `langchain-core` | 1.6.1 |
| `langchain-community` | 0.4.2 |
| `langchain-classic` | 1.0.8 |
| `langchain-sqlserver` | 1.0.1 |
| `llama-index-core` | 0.14.24 |
| `sqlalchemy` | 2.0.52, `pyodbc` 5.3.0, ODBC Driver 18 |

**These move fast.** Re-run [references/measured-runs.md](references/measured-runs.md) before
trusting a version number here. Every command in it is reproducible in about ten minutes.

## The correction

An agent points a SQLAlchemy URL at Azure SQL Database, takes the framework defaults, and believes
the framework knows the dialect and that its stated guardrails are enforced. Four things are then
wrong, and each one surfaces late.

**1. The dialect is the literal string `mssql`, and the agent prompt still says "limit".**
`SQLDatabase.dialect` returns `engine.dialect.name`, measured as `'mssql'`, identical for the
container and for the cloud because it comes from the URL and not from the server. That string is
interpolated into a prompt that never learned T-SQL. See section 1.

**2. The framework-created vector table cannot take a vector index.** `langchain-sqlserver` 1.0.1
creates its table with `PRIMARY KEY NONCLUSTERED`, so the table is a heap, and
`CREATE VECTOR INDEX` is refused with `Msg 42254`. Its search emits the exact-scan query shape and
the package contains no approximate search path at all. Every retrieval is a full scan for the life
of the table, with correct results and latency that only grows. See section 2.

**3. LlamaIndex has no Azure SQL Database vector store.** Not on the package index, not in the
integrations tree. The neighbours that do exist are for other stores, and an agent reaches for one
of those and wires the wrong database. See section 2.

**4. The read-only, table-scoping and no-DML guardrails are prompt text and prompt scoping, not
access control.** Measured: with `include_tables` set to one table, the query tool still executed a
`SELECT` against an excluded table and returned a row; `db.run` executed an `INSERT` and a
`CREATE`/`DROP` pair; and the schema tool returned three real rows of live data by default. See
section 3.

Being wrong costs a retry loop on every top-k question that the model cannot diagnose from the
error it gets, a retrieval path that can never be indexed without rebuilding the table, and a tool
surface that hands whatever the login can do to any text that reaches the model.

## Which framework gives you what, on this engine

| Capability | LangChain | LlamaIndex |
|---|---|---|
| SQL toolkit over an existing schema | `SQLDatabaseToolkit`, four tools | `NLSQLTableQueryEngine` and the SQL retrievers |
| Per-dialect text to SQL prompt | Only on the legacy chain path | **None.** One template for every engine |
| Native `vector` column store | `langchain-sqlserver`, first party | **None.** Keep retrieval in SQL |
| Approximate vector search | Not implemented | Not applicable |
| Table info includes live rows | **Yes, three by default** | No, columns and types only |

## 1. The dialect prompt, and the error that names the wrong token

There are two prompt surfaces in LangChain and **the per-dialect fix reached only one of them.**

| Surface | What it tells the model | Verdict |
|---|---|---|
| `SQL_PROMPTS['mssql']` in `langchain_classic.chains.sql_database.prompt`, used by `create_sql_query_chain` | "query for at most `{top_k}` results **using the TOP clause as per MS SQL**" | Correct |
| `SQL_PREFIX` in `langchain_community.agent_toolkits.sql.prompt`, used by `create_sql_agent` | "create a syntactically correct `{dialect}` query ... always **limit** your query to at most `{top_k}` results" | Wrong, and dialect-blind |
| The hub prompt `langchain-ai/sql-agent-system-prompt`, which the toolkit's own docstring says to pull | Byte for byte the same "always limit your query" wording | Wrong |
| `DEFAULT_TEXT_TO_SQL_TMPL` in `llama_index.core.prompts.default_prompts` | `{dialect}` only. No row cap, no pagination guidance, no per-dialect variant anywhere | Silent |

So the fix exists, and it sits on the chain path that current documentation steers people away
from. The agent path, which is what anyone building a SQL agent today uses, renders as:

```text
create a syntactically correct mssql query to run ...
always limit your query to at most 10 results
```

`mssql` is not a phrase that carries T-SQL pagination, and "limit" is a strong instruction. That
combination is why the catalog note about `LIMIT` is still true in 2026.

### The failure is loud in the wrong place

Measured through the query tool, which is exactly what the model reads before retrying:

| Query the model wrote | What comes back |
|---|---|
| `SELECT customer_id, full_name FROM customers LIMIT 10` | `Msg 102, Incorrect syntax near '10'` |
| `SELECT ... FROM customers ORDER BY full_name LIMIT 10` | `Msg 102, Incorrect syntax near 'LIMIT'` |
| `SELECT customer_id FROM customers OFFSET 0 ROWS FETCH NEXT 10 ROWS ONLY` | `Msg 102, Incorrect syntax near '0'` |

**Without an `ORDER BY`, the error names the number and never mentions `LIMIT`.** The reason is
measured, not inferred: `SELECT LIMIT.customer_id FROM customers LIMIT` **succeeds**, because T-SQL
parses `LIMIT` as a table alias and then trips over the integer that follows it. A model handed
`Incorrect syntax near '10'` has no reason to remove a keyword the message does not mention, so it
edits the number, or the column list, and tries again.

Two things make that worse rather than better:

- The toolkit's `sql_db_query_checker` tool, which its own tool description says to call **before
  every query**, uses a prompt whose list of common mistakes is `NOT IN` with nulls, `UNION` versus
  `UNION ALL`, `BETWEEN`, type mismatches, quoting, argument counts, casts and join columns.
  **Dialect pagination is not on the list.** The checker passes the query through.
- `QuerySQLDatabaseTool` calls `db.run_no_throw`, so the failure never raises in the application.
  It becomes a string in the model's context and a longer trace.

### What to do

**Replace the system prompt. Do not pass the default and hope.** Both frameworks take a prompt
argument, and this is the one edit that matters:

- Say **T-SQL**, not `mssql`, and say **Azure SQL Database**. Do not interpolate `db.dialect` into
  the sentence that a model reads for syntax.
- State the row cap as **`SELECT TOP (n)`**, and say that `LIMIT` does not exist in this dialect.
- If the query is paged, say `ORDER BY ... OFFSET n ROWS FETCH NEXT m ROWS ONLY`, and that the
  `ORDER BY` is mandatory, which is why the third row of the table above fails.
- On LangChain, pass it as `prefix=` to `create_sql_agent`, or as the system message when the
  toolkit's tools are handed to an agent directly. On LlamaIndex, pass `text_to_sql_prompt=`.

The dialect rules themselves are `t-sql-correctness`. Load it alongside this skill rather than
restating its content in a prompt string that then goes stale.

## 2. Retrieval, and the index the vector store cannot have

`langchain-sqlserver` is the supported LangChain vector store for this engine. It does use the
native type: the table it created, read back from the engine, is

```sql
CREATE TABLE lcv_docs (
    id               UNIQUEIDENTIFIER NOT NULL,
    custom_id        VARCHAR(1000) NULL,
    content_metadata json NULL,
    content          NVARCHAR(max) NOT NULL,
    embeddings       vector(8) NOT NULL,
    PRIMARY KEY NONCLUSTERED (id)          -- this line is the problem
)
```

`PRIMARY KEY NONCLUSTERED` leaves the table a heap. Measured against that table:

```text
Msg 42254, Clustered index is required on table 'dbo.lcv_docs' to create a vector index.
```

Add one and the refusal moves on to the next gate, which is the expected one:

```sql
CREATE CLUSTERED INDEX ix_docs_cl ON dbo.lcv_docs (id);
-- Msg 42266, ... only 4 rows with non-null vectors, but at least 100 are required
```

So the clustered index is the fix, the store does not create it, and adding it after the fact means
a rebuild of the table's storage. **Create the table yourself, or add the clustered index as a
migration step immediately after the store first initialises, before it holds volume.**

### The emitted query is the exact-scan shape, and that is not configurable

The similarity search the store emits, captured off the connection:

```sql
SELECT TOP 2 ..., VECTOR_DISTANCE('cosine', cast ('[...]' as vector(8)), embeddings) AS distance
FROM lcv_docs ORDER BY distance ASC
```

Syntactically correct T-SQL, `TOP` and not `LIMIT`, because SQLAlchemy compiles the limit for the
dialect even when the prompt does not. But the package contains **no `VECTOR_SEARCH`, no
`WITH APPROXIMATE` and no `CREATE VECTOR INDEX`**, anywhere in its source. There is no option to
turn on, which means:

- Below roughly tens of thousands of rows, accept it and move on.
- Above that, do the retrieval in SQL yourself and use the framework only for chunking, prompting
  and orchestration. The query shape that reaches a vector index, and the reason this one does not,
  are `vector-search-azure-sql`.

### The rest of the store's contract, measured

| Behaviour | Detail |
|---|---|
| `embedding_length` is a **required** constructor argument | It is not derived from the embedding function. A mismatch fails loudly at write time: `Msg 42204, The vector dimensions 8 and 16 do not match` |
| A 3072 dimension model | Fails at construction: `Msg 2717, The size (3072) given to the column 'embeddings' exceeds the maximum allowed (1998)`. Decide the dimension budget first, which is `rag-on-azure-sql` |
| Metadata filters run inside the search query | `WHERE JSON_VALUE(content_metadata, ?) = ?`, parameterised, applied before the top-k. Good |
| **Numeric metadata filters cast to `NUMERIC(10, 2)`** | So `{"ts": {"$gt": 1756500000}}` returns `Msg 8115, Arithmetic overflow error converting nvarchar to data type numeric`. The cast is on the stored column, so a single oversized value poisons every numeric filter on that key, and it throws at read time, never at write time. Keep epoch times, large ids and money out of metadata, or store them as strings and filter on equality |
| Batch size is capped at 419 | Larger raises before any round trip |
| Auth falls back silently | A connection string with no `Uid`/`Pwd` and no `Trusted_Connection=yes` switches to `DefaultAzureCredential` and acquires a token. A typo in the credential keywords does not fail as a bad password, it fails as a token acquisition somewhere else entirely |

### LlamaIndex has no Azure SQL Database vector store

Checked on the package index and in the integrations tree on 2026-08-28. There is no
`llama-index-vector-stores` package for this engine, and the near neighbours that do exist point at
other databases and other services entirely. Do not let an agent install one of those because the
name looks close.

With LlamaIndex, the two honest options are to keep retrieval in T-SQL and feed the rows in as
nodes, or to use the SQL toolkit path for structured questions and put the semantic half somewhere
this catalog already covers. Generating the embeddings inside the engine is
`embeddings-and-external-models`.

## 3. Read-only, no schema dumping, parameterised

Treat all three as things to switch on. None of them is a default.

### Read-only is a login, not a setting

Neither framework has a read-only mode. `SQLDatabase.run` executed an `INSERT` that committed, and
a `CREATE TABLE`/`DROP TABLE` pair, in one call. LlamaIndex's `run_sql` executed an `UPDATE` and the
change was visible on the next read. The `DO NOT make any DML statements` line in `SQL_PREFIX` is a
sentence in a prompt, so any instruction that reaches the model through retrieved content competes
with it on equal terms.

The control is a dedicated least-privilege login for the agent's connection string. Measured
through the query tool with that login:

| Statement | Result |
|---|---|
| `SELECT TOP (2) full_name FROM customers` | Rows |
| `UPDATE customers SET city = N'...'` | `Msg 229, The UPDATE permission was denied on the object 'customers'` |
| `DROP TABLE customers` | `Msg 3701, Cannot drop the table ..., because it does not exist or you do not have permission` |
| `EXEC sp_executesql N'SELECT 1'` | Runs. The tool is not restricted to `SELECT` text either, so the login is the only boundary |

Creating that login and granting it correctly is `azuresql-db-auth`.

### `include_tables` scopes the prompt, not the connection

This one is worth measuring yourself, because the parameter name suggests otherwise. With
`include_tables=["customers"]`, `get_usable_table_names()` returned `['customers']` and the schema
tool described only that table. Then the query tool ran `SELECT TOP (1) id FROM lcv_docs` against a
table that was **not** in the list, and returned the row.

`include_tables` decides what the model is told about. It does not decide what the connection can
reach. Scope the login to the schema, or put the agent's tables behind a schema it is granted and
nothing else.

### The schema tool returns live rows by default

`SQLDatabase` defaults to `sample_rows_in_table_info=3`, so the schema tool returns the `CREATE
TABLE` text **plus three real rows of the table**, every column, into the model's context and into
whatever stores the trace. On a customer table that is three real customers.

```python
db = SQLDatabase.from_uri(uri, sample_rows_in_table_info=0)   # schema only
```

Set it to `0` unless there is a stated reason not to, and if sample values genuinely help the model
disambiguate a column, supply them with `custom_table_info` from fake data you control rather than
from production rows. LlamaIndex's `get_single_table_info` is columns and types only, so this
particular exposure is LangChain's alone.

Error text is a second channel. `run_no_throw` returns the driver message verbatim to the model,
including the database name, schema name and object name from `Msg 229` and `Msg 3701` above. That
is useful for retries and it is also schema disclosure, so do not point a public assistant at a
connection whose error messages you have not read.

### Parameterised means the parts you write

The framework's own SQL is parameterised: the vector store binds both the JSON path and the
comparison value, and `SQLDatabase.run` accepts a keyword-only `parameters` argument.

The exposure is everywhere else. The query tool takes exactly one argument, a SQL string the model
wrote, so a text to SQL agent is by construction a machine that executes generated SQL. There is no
parameterisation to add there; the containment is the login, plus a review path for anything that
writes. For every query the application builds around the framework, bind the values, never format
them into the string, and never build a query out of a chunk retrieved from the corpus. That
practice is a skill of its own in this catalog and it is the thing agents get wrong most often.

## Validation rules

- The system prompt handed to the agent or the query engine names T-SQL and `SELECT TOP (n)`
  explicitly, and does not interpolate `db.dialect` into the sentence that describes syntax.
- No generated query in the traces contains `LIMIT`, and there is a test that fails if one does.
- The agent's connection string uses a dedicated login with read permission and nothing more, and
  there is a test that asserts an `UPDATE` through that connection is denied.
- `include_tables` is not the only thing separating the agent from a table it must not read.
- `sample_rows_in_table_info` is `0`, or the sample rows are fake data supplied through
  `custom_table_info`.
- The vector store's table has a clustered index if a vector index is ever intended, and that was
  checked before the table grew.
- `embedding_length` equals the dimension the embedding model is asked for, and it is 1998 or fewer.
- No metadata key holds a number larger than `NUMERIC(10, 2)` can carry if anything filters on it.
- The pinned framework versions are recorded, and the prompt and the vector store behaviour were
  re-checked on the last upgrade.

## Do not

- Do not accept the default SQL agent prompt on this engine. It renders as `mssql` and tells the
  model to limit, and the error it earns names the wrong token.
- Do not assume the per-dialect prompt applies to the agent. It exists only on the chain path.
- Do not conclude the query is fine because the checker tool approved it. Dialect pagination is not
  in the checker's list of mistakes.
- Do not fix a `LIMIT` failure by editing the number the error points at.
- Do not let the vector store create its table and then plan on a vector index later. The heap is
  the blocker and the migration gets more expensive with every row.
- Do not expect approximate vector search from `langchain-sqlserver`. There is no code path.
- Do not install a LlamaIndex vector store package whose name merely resembles this engine's.
- Do not rely on `include_tables`, on `posture` metadata, or on a sentence in a prompt to stop a
  write. A login is the only thing that stops a write.
- Do not ship with `sample_rows_in_table_info` at its default and call the agent read-only.
- Do not put an epoch timestamp or a large identifier in vector store metadata that anything filters
  on numerically.
- Do not re-teach `VECTOR_DISTANCE`, `VECTOR_SEARCH` or the vector index here. Those are
  `vector-search-azure-sql`.

## References

- [references/measured-runs.md](references/measured-runs.md): the install, every probe script, the
  raw output, the emitted SQL and the reproduction steps. Read it to re-verify a claim after a
  version bump, which for these packages is often.
- `vector-search-azure-sql`: the `vector` type, its restriction list, `VECTOR_DISTANCE`, and the
  query shape that reaches the vector index rather than scanning.
- `rag-on-azure-sql`: the chunk and embedding schema, provenance, the dimension budget, and the
  retrieval query with the permission filter inside it.
- `rag-local-with-container`: the same wiring offline against the local Azure SQL Database
  container, with no cloud dependency and no keys.
- `embeddings-and-external-models`: producing the embedding from inside the engine instead of from
  the framework.
- `t-sql-correctness`: the dialect rules the framework prompt fails to teach, including why `LIMIT`
  is not T-SQL and what replaces it.
- `connect-from-python`: the driver, the ODBC install, the connection string and token-based auth
  underneath everything above.
- `azuresql-db-auth`: creating the least-privilege login the read-only guardrail actually depends on.
- [LangChain SQL question answering](https://docs.langchain.com/oss/python/langchain/sql):
  the current first party guidance for the toolkit and the agent path. Read it to check whether the
  default prompt has changed before trusting section 1.
- [LlamaIndex structured data](https://docs.llamaindex.ai/en/stable/understanding/querying/querying/):
  the text to SQL query engines and where the prompt argument goes.
