---
name: langchain-and-llamaindex-on-azure-sql
description: >-
  Wires LangChain or LlamaIndex to Azure SQL Database from Python: the SQL toolkits, their text to
  SQL prompts, the langchain-sqlserver vector store, and the guardrails neither framework
  enforces. Use when someone asks to "use LangChain with Azure SQL", "build a SQL agent over the
  database", "text to SQL", "SQLDatabaseToolkit", "NLSQLTableQueryEngine", "which LlamaIndex
  vector store works with Azure SQL", or "make the SQL agent read only"; when a SQL agent keeps
  generating LIMIT, its query checker approves a query the database refuses, or its schema tool
  puts real rows into the prompt; or when a framework-created embedding table refuses CREATE
  VECTOR INDEX or a metadata filter throws arithmetic overflow. Vector type and query shape are
  vector-search-azure-sql, the cloud pipeline is rag-on-azure-sql, and drivers and token
  authentication are connect-from-python. Offline local embedding is an application-side workflow.
---

# LangChain and LlamaIndex on Azure SQL Database

Both frameworks connect to this engine on the first try and then get three things wrong that the
connection test cannot show. This is not a text to SQL tutorial and not a vector search reference.

**Measured 2026-08-28** by installing the packages, reading what ships, and running every statement
below against a local Azure SQL Database container (`SERVERPROPERTY('EngineEdition')` returns 5).
Every argument name was re-checked 2026-09-03 against the LangChain and LlamaIndex reference
documentation. The pinned versions move fast, so re-run the reference file before trusting one.

## Reproduce it first, in two minutes

```bash
python -m venv .venv && .venv/bin/pip install \
  "langchain==1.3.18" "langchain-community==0.4.2" "langchain-classic==1.0.8" \
  "langchain-sqlserver==1.0.1" "llama-index-core==0.14.24" "sqlalchemy==2.0.52" "pyodbc==5.3.0"
```

```python
import os, urllib.parse
from langchain_community.utilities import SQLDatabase
from langchain_community.agent_toolkits.sql.prompt import SQL_PREFIX

odbc = urllib.parse.quote_plus(
    "DRIVER={ODBC Driver 18 for SQL Server};SERVER=<host>,<port>;DATABASE=<database>;"
    "UID=<user>;PWD=" + os.environ["SQL_PASSWORD"] + ";Encrypt=yes;TrustServerCertificate=yes")
db = SQLDatabase.from_uri(f"mssql+pyodbc:///?odbc_connect={odbc}")

print(db.dialect)                                       # mssql
print(SQL_PREFIX.format(dialect=db.dialect, top_k=10))  # "always limit your query to at most 10"
print(db.get_table_info())                              # DDL plus three real rows per table
```

Three prints, three defects: the dialect is a string from the URL, the prompt tells the model to
limit, and the schema tool hands live rows to the model before anyone asked it a question.

## The correction

**1. The dialect is the string `mssql`, and the agent prompt still says "limit".** It comes from the
URL, not the server, so it is the same for the container and the cloud, and it is interpolated into
a prompt that never learned T-SQL. Section 1.

**2. The framework-created vector table cannot take a vector index.** `langchain-sqlserver` 1.0.1
creates it with `PRIMARY KEY NONCLUSTERED`, so the table is a heap and `CREATE VECTOR INDEX` is
refused with `Msg 42254`. The package holds no approximate search path at all, so retrieval is a
full scan for the life of the table, with correct results and latency that only grows. **LlamaIndex
has no Azure SQL Database vector store**, so an agent installs a neighbour and wires the wrong
database. Section 2.

**3. Read-only, table scoping and no-DML are prompt text, not access control.** With
`include_tables` set to one table, the query tool still ran a `SELECT` against an excluded table and
returned a row; `db.run` executed an `INSERT` and a `CREATE`/`DROP` pair. Section 3.

| Capability | LangChain | LlamaIndex |
|---|---|---|
| SQL toolkit over an existing schema | `SQLDatabaseToolkit`, four tools | `NLSQLTableQueryEngine` |
| Per-dialect text to SQL prompt | Only on the legacy chain path | **None.** One template per engine |
| Native `vector` column store | `langchain-sqlserver`, first party | **None.** Keep retrieval in SQL |
| Approximate vector search | Not implemented | Not applicable |
| Table info includes live rows | **Yes, three by default** | No, columns and types only |

## 1. The dialect prompt, and the error that names the wrong token

There are two prompt surfaces in LangChain and **the per-dialect fix reached only one of them.**

| Surface | What it tells the model | Verdict |
|---|---|---|
| `SQL_PROMPTS['mssql']` in `langchain_classic.chains.sql_database.prompt`, used by `create_sql_query_chain` | "at most `{top_k}` results **using the TOP clause as per MS SQL**" | Correct |
| `SQL_PREFIX` in `langchain_community.agent_toolkits.sql.prompt`, the default `prefix` of `create_sql_agent` | "a syntactically correct `{dialect}` query ... always **limit** your query to at most `{top_k}` results" | Wrong, dialect-blind |
| The hub prompt `langchain-ai/sql-agent-system-prompt`, and the `system_prompt` written out in LangChain's own SQL agent guide | The same "always limit your query" wording | Wrong |
| `DEFAULT_TEXT_TO_SQL_TMPL` in `llama_index.core.prompts.default_prompts` | `{dialect}` only. No row cap, no pagination guidance, no per-dialect variant | Silent |

The fix exists and sits on the chain path current documentation steers people away from.

### The failure is loud in the wrong place

Measured through `QuerySQLDatabaseTool`, which is what the model reads before it retries:

| Query the model wrote | What comes back |
|---|---|
| `SELECT customer_id, full_name FROM customers LIMIT 10` | `Msg 102, Incorrect syntax near '10'` |
| `SELECT ... FROM customers ORDER BY full_name LIMIT 10` | `Msg 102, Incorrect syntax near 'LIMIT'` |
| `SELECT customer_id FROM customers OFFSET 0 ROWS FETCH NEXT 10 ROWS ONLY` | `Msg 102, Incorrect syntax near '0'` |

**Without an `ORDER BY`, the error names the number and never mentions `LIMIT`.** The reason is
measured, not inferred:

```sql
SELECT LIMIT.customer_id FROM dbo.customers LIMIT;   -- succeeds, returns every row
```

T-SQL parses `LIMIT` as a table alias and then trips over the integer that follows it. A model
handed `Incorrect syntax near '10'` has no reason to remove a keyword the message does not mention,
so it edits the number, or the column list, and tries again. Two things make that worse:

- The toolkit's `sql_db_query_checker` tool, which its own tool description says to call **before
  every query**, uses a prompt listing `NOT IN` with nulls, `UNION` versus `UNION ALL`, `BETWEEN`,
  type mismatches, quoting, argument counts, casts and join columns. **Dialect pagination is not on
  the list.** The checker passes the query through.
- `QuerySQLDatabaseTool` calls `db.run_no_throw`, so the failure never raises in the application. It
  becomes a string in the model's context and a longer trace.

### Replace the prompt. Do not pass the default and hope

`prefix` must still contain the `{dialect}` and `{top_k}` variables, so keep them and put the syntax
instruction in a sentence the dialect string is not carrying:

```python
from langchain_community.agent_toolkits import create_sql_agent

TSQL_PREFIX = """You are an agent designed to interact with an Azure SQL Database ({dialect}).
Write T-SQL. Return at most {top_k} rows with SELECT TOP ({top_k}), which is how this dialect caps
a result set. LIMIT does not exist in T-SQL and the parser reports it as a syntax error on the
number that follows it, not on the keyword. To page, write
ORDER BY <column> OFFSET <n> ROWS FETCH NEXT <m> ROWS ONLY; the ORDER BY is mandatory.
Never issue INSERT, UPDATE, DELETE, DROP or any other DML statement."""

agent = create_sql_agent(llm, db=db, agent_type="tool-calling", prefix=TSQL_PREFIX, top_k=10)
```

LlamaIndex takes the same correction through `text_to_sql_prompt`, whose template needs `{dialect}`,
`{schema}` and `{query_str}`:

```python
from llama_index.core import PromptTemplate
from llama_index.core.query_engine import NLSQLTableQueryEngine

tsql_tmpl = PromptTemplate(
    "Given an input question, write a syntactically correct T-SQL query for Azure SQL Database "
    "({dialect}). Cap rows with SELECT TOP (n). LIMIT is not valid T-SQL. Page with "
    "ORDER BY <column> OFFSET <n> ROWS FETCH NEXT <m> ROWS ONLY.\n"
    "Only use the tables below.\n{schema}\n\nQuestion: {query_str}\nSQLQuery: ")

engine = NLSQLTableQueryEngine(sql_database=lidb, tables=["customers"],
                               text_to_sql_prompt=tsql_tmpl)
```

Keep the prompt short. The dialect rules themselves belong in `t-sql-correctness`, not in a prompt
string that then goes stale.

## 2. Retrieval, and the index the vector store cannot have

`langchain-sqlserver` is the supported LangChain vector store for this engine and it does use the
native type. `embedding_length` is required and is not derived from the embedding function;
`distance_strategy` defaults to cosine:

```python
from langchain_sqlserver import SQLServer_VectorStore

store = SQLServer_VectorStore(connection_string=f"mssql+pyodbc:///?odbc_connect={odbc}",
                              embedding_function=embeddings, embedding_length=1536,
                              table_name="lcv_docs")
```

The table it then creates, read back off the engine, with the dimension from `embedding_length`:

```sql
CREATE TABLE lcv_docs (
    id               UNIQUEIDENTIFIER NOT NULL,
    custom_id        VARCHAR(1000) NULL,
    content_metadata json NULL,
    content          NVARCHAR(max) NOT NULL,
    embeddings       vector(1536) NOT NULL,
    PRIMARY KEY NONCLUSTERED (id)          -- this line is the problem
);
```

`PRIMARY KEY NONCLUSTERED` leaves the table a heap, and a heap cannot carry a vector index. Add the
clustered index immediately after the store first initialises, before it holds volume, because
adding it later rewrites the table's storage:

```sql
CREATE VECTOR INDEX vi_lcv ON dbo.lcv_docs (embeddings) WITH (METRIC='cosine', TYPE='diskann');
-- Msg 42254, Clustered index is required on table 'dbo.lcv_docs' to create a vector index.

CREATE CLUSTERED INDEX ix_lcv_docs_cl ON dbo.lcv_docs (id);
SET QUOTED_IDENTIFIER ON;
CREATE VECTOR INDEX vi_lcv ON dbo.lcv_docs (embeddings) WITH (METRIC='cosine', TYPE='diskann');
-- Msg 42266 once the clustered index clears the first gate: 100 non-null vectors are required.
```

`Msg 42266` is the expected second gate and proves the clustered index fixed the first. Without
`QUOTED_IDENTIFIER ON` the statement fails with `Msg 1934` before reaching either.

### The emitted query is the exact-scan shape, and that is not configurable

`similarity_search_with_score(k=2)` on a `vector(8)` store, captured off the connection with the
vector literal written out:

```sql
SELECT TOP 2 lcv_docs.id, lcv_docs.custom_id, lcv_docs.content_metadata, lcv_docs.content,
       VECTOR_DISTANCE('cosine', cast ('[0.1,0.2,0.3,0.4,0.5,0.6,0.7,0.8]' as vector(8)),
                       embeddings) AS distance
FROM lcv_docs ORDER BY distance ASC;
```

`TOP` and not `LIMIT`, because SQLAlchemy compiles the row cap for the dialect even when the prompt
does not. But the package contains **no `VECTOR_SEARCH`, no `WITH APPROXIMATE` and no
`CREATE VECTOR INDEX`** anywhere in its source, so there is no option to turn on. Below roughly tens
of thousands of rows, accept it. Above that, do the retrieval in SQL and keep the framework for
chunking, prompting and orchestration. Read `vector-search-azure-sql` before writing that query: the
shape that reaches the index is a different statement, not a tuning option.

| Behaviour | Detail |
|---|---|
| A 3072 dimension model | `Msg 2717` at construction: the size exceeds the maximum allowed (1998). Decide the dimension budget first, which is `rag-on-azure-sql` |
| `embedding_length` mismatched to the function | `Msg 42204` at write time: the vector dimensions do not match |
| Metadata filters run inside the search query | `WHERE JSON_VALUE(content_metadata, ?) = ?`, parameterised, applied before the top-k. Good |
| **Numeric metadata filters cast to `NUMERIC(10, 2)`** | `{"ts": {"$gt": 1756500000}}` returns `Msg 8115`, arithmetic overflow converting nvarchar to numeric. The cast is on the stored column, so one oversized value poisons every numeric filter on that key, and it throws at read time, never at write. Keep epoch times, large ids and money out of metadata |
| Batch size is capped at 419 | Larger raises before any round trip |
| Auth falls back silently | No `Uid`/`Pwd` and no `Trusted_Connection=yes` switches to `DefaultAzureCredential`, so a typo in the credential keywords fails as a token acquisition, not as a bad password |

### LlamaIndex has no Azure SQL Database vector store

Checked on the package index and in the integrations tree on 2026-08-28. Do not let an agent install
a neighbouring package because the name looks close. The two honest options are to keep retrieval in
T-SQL and feed the rows in as nodes, or to use the SQL toolkit for structured questions and put the
semantic half where this catalog already covers it. Producing the embedding inside the engine is
`embeddings-and-external-models`.

## 3. Read-only, no schema dumping, parameterised

Treat all three as things to switch on. None of them is a default.

### Read-only is a login, not a setting

Neither framework has a read-only mode. `SQLDatabase.run` executed an `INSERT` that committed and a
`CREATE TABLE`/`DROP TABLE` pair in one call; LlamaIndex's `run_sql` executed an `UPDATE`. The
`DO NOT make any DML statements` line is a sentence in a prompt, so any instruction reaching the
model through retrieved content competes with it on equal terms. The control is a dedicated
least-privilege login. Measured through the query tool with that login:

| Statement | Result |
|---|---|
| `SELECT TOP (2) full_name FROM customers` | Rows |
| `UPDATE customers SET city = N'Owned' WHERE customer_id = 1` | `Msg 229, The UPDATE permission was denied on the object 'customers'` |
| `DROP TABLE customers` | `Msg 3701, Cannot drop the table ..., because it does not exist or you do not have permission` |
| `EXEC sp_executesql N'SELECT 1'` | Runs. The tool does not restrict itself to `SELECT` text either |

Create that login only with the read-only grants shown here, because the grant is the whole
guardrail.

### `include_tables` scopes the prompt, not the connection

Worth measuring yourself, because the parameter name suggests otherwise:

```python
db = SQLDatabase.from_uri(uri, include_tables=["customers"], sample_rows_in_table_info=0)
print(db.get_usable_table_names())     # ['customers']

from langchain_community.tools.sql_database.tool import QuerySQLDatabaseTool
print(QuerySQLDatabaseTool(db=db).invoke("SELECT TOP (1) id FROM lcv_docs"))   # returns the row
```

`include_tables` decides what the model is told about. It does not decide what the connection can
reach. Scope the login to the schema instead.

### The schema tool returns live rows by default

`sample_rows_in_table_info` defaults to `3`, so the schema tool returns the `CREATE TABLE` text
**plus three real rows**, every column, into the model's context and into whatever stores the trace.
On a customer table that is three real customers.

```python
db = SQLDatabase.from_uri(uri, sample_rows_in_table_info=0)                    # schema only
db = SQLDatabase.from_uri(uri, custom_table_info={"customers": FAKE_DDL})      # or fake samples
```

Error text is a second channel: `run_no_throw` returns the driver message verbatim, database, schema
and object names included, as in `Msg 229` and `Msg 3701` above.

### Parameterised means the parts you write

The framework's own SQL binds its values. The query tool takes one argument, a SQL string the model
wrote, so a text to SQL agent is by construction a machine that executes generated SQL and there is
no parameterisation to add there; the containment is the login. In the code you write around the
framework, bind the values, and never build a query out of a chunk retrieved from the corpus.

## Check it worked

Four assertions against the wiring you are about to ship. The first two fail on a default install:

```python
import os, re
from langchain_community.tools.sql_database.tool import QuerySQLDatabaseTool

generated_sql = os.environ["AGENT_SQL"]      # one query your agent actually produced
assert "SELECT TOP" in TSQL_PREFIX and "LIMIT does not exist" in TSQL_PREFIX
assert "3 rows from" not in db.get_table_info()
denied = QuerySQLDatabaseTool(db=db).invoke("UPDATE customers SET city = N'x' WHERE 1 = 0")
assert "permission was denied" in denied, denied
assert not re.search(r"\bLIMIT\b", generated_sql, re.I), generated_sql
print("prompt, schema exposure, write permission and generated SQL all check out")
```

Expected: the script prints that line and exits 0. A failure on the `get_table_info` assertion means
`sample_rows_in_table_info` is still `3`; a failure on the `denied` assertion means the agent's login
can write, which is the finding and not a test bug. Then confirm the vector table can carry an index
at all, with the password in `SQLCMDPASSWORD`:

```bash
sqlcmd -S <host>,<port> -d <database> -U <user> -C -Q \
  "SELECT type_desc FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.lcv_docs') AND type_desc = 'CLUSTERED';"
```

Expected: one row reading `CLUSTERED`. An empty result set means the table is still the heap the
store created, and `CREATE VECTOR INDEX` on it will return `Msg 42254`.

## Do not

- Do not accept the default SQL agent prompt on this engine. It renders as `mssql`, tells the model
  to limit, and the error it earns names the wrong token.
- Do not assume the per-dialect prompt applies to the agent. It exists only on the chain path.
- Do not conclude the query is fine because the checker tool approved it, and do not fix a `LIMIT`
  failure by editing the number the error points at.
- Do not let the vector store create its table and then plan on a vector index later. The heap is
  the blocker and the migration gets more expensive with every row.
- Do not expect approximate vector search from `langchain-sqlserver`. There is no code path.
- Do not install a LlamaIndex vector store package whose name merely resembles this engine's.
- Do not rely on `include_tables` or on a prompt sentence to stop a write. A login stops a write.
- Do not ship with `sample_rows_in_table_info` at its default and call the agent read only.
- Do not put an epoch timestamp or a large id in metadata that anything filters on numerically.
- Do not re-teach `VECTOR_DISTANCE`, `VECTOR_SEARCH` or the vector index here. Those are
  `vector-search-azure-sql`.

## References

- Open [references/framework-prompts-and-vector-store.md](references/framework-prompts-and-vector-store.md) when a claim
  above disagrees with what you are seeing, which after a version bump it will: it holds the install,
  every probe script, the raw engine output and the reproduction steps.
- Read `vector-search-azure-sql` before writing the retrieval query yourself, for the `vector` type,
  its restriction list and the query shape that reaches the index rather than scanning.
- Read `rag-on-azure-sql` before choosing `embedding_length`, because the dimension budget, the chunk
  schema and the permission filter are decided there. For offline use, keep embedding
  application-side and preserve the same schema and permission filter.
- Read `t-sql-correctness` when the generated SQL is wrong in a way that is not pagination,
  `connect-from-python` when the failure is the driver, the connection string or the token rather
  than the framework. Apply the read-only grants in section 3 before exposing the connection.
- Read [LangChain's SQL agent guide](https://docs.langchain.com/oss/python/langchain/sql-agent) to
  check whether the shipped prompt has changed before trusting section 1, and
  [LlamaIndex structured data](https://developers.llamaindex.ai/python/framework/understanding/putting_it_all_together/structured_data)
  for where the prompt argument goes on the query engine.
