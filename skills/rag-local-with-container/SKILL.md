---
name: rag-local-with-container
description: >-
  Answers whether a retrieval augmented generation prototype proved on the local Azure SQL
  Database container still holds in Azure SQL Database, and names what does not survive the move.
  Owns the offline loop, the local embedding model, and the parity claim. Use when someone asks
  to "prototype RAG offline with no cloud account", "use a local embedding model with SQL",
  "develop against the container and deploy to Azure SQL Database", or asks what has to be redone
  after the move; and when the engine refuses a local embedding endpoint, or a vector index and a
  security policy will not coexist. A plain request to build RAG on the container belongs to
  azuresql-db-rag; come here for the move. The cloud pipeline is rag-on-azure-sql, the type and
  the query vector-search-azure-sql, embedding in the engine embeddings-and-external-models,
  framework wiring langchain-and-llamaindex-on-azure-sql.
---

# Local RAG on the Azure SQL Database container

Build the whole retrieval loop on a laptop with no cloud account, no keys and no outbound calls,
then move it. This skill is about **what survives the move and what does not**.

Verified 2026-08-28 by running one script against the local Azure SQL Database container and the
same script against a live Azure SQL Database and comparing line by line; both report
`SERVERPROPERTY('EngineEdition')` of 5. The local model commands were rerun 2026-09-03 on Ollama
0.33.2. The two sqlcmd builds were compared on 2026-09-05, go-sqlcmd 1.10.0 against ODBC sqlcmd
18.6.0002.1, and the chunk lengths below were re-read off the engine the same day. Open
[references/parity.md](references/parity.md) before repeating any number below, or whenever someone
disputes that the offline prototype is real.

## What this owns

| Question | Skill |
|---|---|
| The `vector` type, `VECTOR_DISTANCE`, the index and the query shape that reaches it | `vector-search-azure-sql` |
| The cloud pipeline: chunk identity, provenance, re-embedding, grounding | `rag-on-azure-sql` |
| A vector produced inside the engine, credentials and the endpoint allowlist | `embeddings-and-external-models` |
| Vector store adapters, retrievers and their guardrails | `langchain-and-llamaindex-on-azure-sql` |
| A first vector table and a full scan top k on a fresh container | `azuresql-db-rag` |

This skill is the next question after those: **is what I just proved locally still true in the
cloud?**

## The correction

An agent told the container is the same engine concludes everything proved locally holds in the
cloud. An agent told it is "just a container" will not prototype offline at all. Both are wrong.

**Parity is real for the part people doubt.** The same 140 chunk corpus, embedded by the same local
model and inserted into both engines, produced **identical cosine distances to six decimal
places**, an identical top three, a vector index that built on both, and approximate search
returning the same rows in the same order. The prototype is not a simulation.

**Three things break, and each breaks in the direction that flatters the laptop.**

| What | Container | Azure SQL Database | Consequence |
|---|---|---|---|
| Outbound calls from the engine | any public host answers | an Azure domain allowlist, `Msg 31612` before DNS | Works locally, refused in the cloud |
| Row level security beside a vector index | refused, `Msg 37579` and `Msg 42244` | both coexist, either order | The isolation cannot be rehearsed locally |
| Managed identity for an outbound credential | refused, `Msg 31644` | works | The production identity has no local rehearsal |

A fourth is not an engine difference and costs the most: **the code moves unchanged, the corpus
does not.** A local model and a hosted one are different geometries and usually different
dimensions, and the dimension is baked into the column.

Being wrong costs a retrieval query that passes every local test and is refused by policy on its
first cloud run, an isolation control that ships never having been exercised, and a full re-embed
discovered after the schema is deployed.

## Step 1: fix the dimension before writing anything

This decision cannot be revisited and is made once for both environments. Ask the local model
rather than assuming, because the number goes straight into the column:

```bash
ollama show nomic-embed-text
```

`embedding length` is the answer, and on Ollama 0.33.2 it reads `768`. Confirm that against the
endpoint the code will actually call:

```bash
curl -s http://localhost:11434/api/embed \
  -d '{"model": "nomic-embed-text", "input": "the parity claim"}' |
  python3 -c "import json,sys; print(len(json.load(sys.stdin)['embeddings'][0]))"
```

Expect `768`. Two calls with the same input returned a byte identical vector, so the local corpus
is reproducible and a diff between runs means the model changed.

Then choose a cloud model that can be **asked** for that same number. A hosted model whose default
is 1536 returned a 768 dimension vector when its external model definition carried
`PARAMETERS = '{"dimensions":768}'`, and 512 when asked for 512; Microsoft Learn documents
`PARAMETERS` on `CREATE EXTERNAL MODEL` and the same override per call on
`AI_GENERATE_EMBEDDINGS`.

Declare that number once, as `vector(768)` in the schema and as the dimension asked of every model.
Matching keeps **the column type** portable, not the vectors: a locally embedded corpus still has
to be re-embedded before the cloud model queries it. What it buys is that the re-embed is an
`UPDATE` rather than a new table, a new index and a migration. If the numbers cannot be matched,
plan a second column from the start. `ALTER COLUMN` cannot change a vector's dimension, even on an
empty table.

## Step 2: embed in the application, because the engine cannot reach a local model

This is structural, not a preference. Microsoft Learn lists `Ollama` as an accepted `API_FORMAT`
and gives its location path as `https://localhost:{port}/api/embed`, which reads as though the
engine can call a model on your machine. On the container every route is closed. Ollama serves
plain HTTP, and `LOCATION` accepts HTTPS only:

```sql
CREATE EXTERNAL MODEL local_embed
WITH (LOCATION = 'http://localhost:11434/api/embed',
      API_FORMAT = 'Ollama',
      MODEL_TYPE = EMBEDDINGS,
      MODEL = 'nomic-embed-text');
-- Msg 31610. The statement never gets as far as the network.
```

Putting TLS in front of it does not help. A hostname resolving to a private address is `Msg 31624`,
refused before the handshake, and a private certificate authority is `Msg 31608` even after that
authority is installed in the container's own trust store and accepted there by a command line
client in the same container. The engine does not read that store.

So the local loop embeds in application code, the same shape `azuresql-db-rag` uses:

```python
DIM = 768                       # decided in step 1, a literal in the SQL text

def embed(text: str) -> list[float]:
    """The one thing that changes when this moves. Nothing else does."""
    r = requests.post("http://localhost:11434/api/embed",
                      json={"model": "nomic-embed-text", "input": text}, timeout=60)
    r.raise_for_status()
    return r.json()["embeddings"][0]

cursor.execute(
    f"INSERT dbo.kb (tenant_id, body, embedding) "
    f"VALUES (?, ?, CAST(CAST(? AS NVARCHAR(MAX)) AS VECTOR({DIM})))",
    tenant_id, body, json.dumps(embed(body)),
)
```

The dimension is interpolated as a literal and the vector bound as a JSON array string. Passing the
dimension as a parameter is a syntax error, a property of the type rather than of the container.

Chunking is the exception and it is worth taking. `AI_GENERATE_CHUNKS` runs in the engine with no
endpoint, no credential and no network, and produced byte identical output on both engines:

```sql
SELECT c.chunk_order, c.chunk_offset, c.chunk_length
FROM (VALUES (N'Retrieval augmented generation grounds an answer in your own text.')) AS d(body)
CROSS APPLY AI_GENERATE_CHUNKS(SOURCE = d.body, CHUNK_TYPE = FIXED, CHUNK_SIZE = 25) AS c;
```

Expect three rows, lengths 25, 25 and 16. It needs compatibility level 170 or higher; below that
the engine cannot find the function at all. Chunk in the database on both sides and one more piece
of the pipeline stops being environment specific.

## Step 3: build the loop, and measure it

A complete offline run on the container: 152 chunks embedded locally in 0.8 s, indexed, searched
with a tenant filter and answered by a local generation model in 2.3 s, with nothing leaving the
host. The retrieval query is `vector-search-azure-sql`'s, unchanged, carrying the filter inside it
that `rag-on-azure-sql` requires. Neither is restated here.

| Operation, same 140 rows | Container | Cloud |
|---|---|---|
| Insert 140 rows carrying a 768 dimension vector | 766 ms | 16851 ms |
| Exact top three by distance | 16 ms | 150 ms |
| `CREATE VECTOR INDEX` over those rows | 145 ms | 276 ms |

The gap is round trips and provisioned throughput, not engine capability, and it is the honest
reason the inner loop belongs on the laptop. The last row also settles the belief that a vector
index cannot be built on the container: it builds, with no `ALTER DATABASE SCOPED CONFIGURATION`
to make it.

## Step 4: know what you cannot rehearse locally

**Row level security and a vector index are mutually exclusive on the container**, in both orders.
On a table holding at least 100 rows with non null vectors:

```sql
CREATE VECTOR INDEX vi_kb ON dbo.kb (embedding) WITH (METRIC = 'cosine', TYPE = 'diskann');
GO
CREATE FUNCTION dbo.fn_kb (@t INT) RETURNS TABLE WITH SCHEMABINDING AS
    RETURN SELECT 1 AS ok WHERE @t = CAST(SESSION_CONTEXT(N'tenant_id') AS INT);
GO
CREATE SECURITY POLICY dbo.p_kb
    ADD FILTER PREDICATE dbo.fn_kb (tenant_id) ON dbo.kb WITH (STATE = ON);
-- Container: Msg 37579. Cloud: succeeds.
```

Reverse the order and the container refuses the index instead, with `Msg 42244`. No ordering trick
gets both. The predicate on the chunk table is the cheapest defence in the design, so it has to be
exercised somewhere. Two workable answers, and the wrong one is to drop it:

1. **Rehearse the predicate on an unindexed local table.** Under a few thousand rows an exact scan
   is fast, and the predicate is what is under test, not the plan.
2. **Keep the indexed local table for retrieval and prove the isolation in the cloud**, with a test
   that runs there and fails loudly when the policy is missing.

Either way the tenant filter still belongs inside the retrieval query locally, so the query text
that ships is the query text that was tested.

**Managed identity has no local rehearsal.** The container answers `Msg 31644` and names
`sp_configure 'allow server scoped db credentials'` as the remedy, and the remedy does not take.
Which statement stops it was re-measured on 2026-09-06 against 18.0.226_4_147, because this skill
attributed it to the wrong one until that day. From a user database `sp_configure` is not there at
all, `Msg 2812, Could not find stored procedure`. Connected to `master` it runs and stages the value
without complaint. **`RECONFIGURE` is what refuses**, with
`Msg 40510, Statement 'CONFIG' is not supported in this version of SQL Server`, so the staged value
never takes effect and the only sign is a message a reader has to go looking for. Use a key locally
and an identity in the cloud, keeping the difference in the credential rather than in the code that
names it.

**The allowlist cannot be tested locally.** The container calls any public host, so a successful
local call is evidence of nothing. The cloud list is a fixed set of Azure service domains published
on the `sp_invoke_external_rest_endpoint` page. Check every endpoint the design needs from a cloud
database before believing it.

## Step 5: make the move

Change the connection string, then these four things and nothing else:

1. **The embedding endpoint**, and its requested dimension if the model differs.
2. **The credential**, from a key to managed identity. The `USE MODEL` text does not change.
3. **Re-embed the corpus** with the cloud model, in one pass before any retrieval runs against it.
   A half migrated column is the failure `rag-on-azure-sql` describes and nothing raises it.
4. **Add the security policy** the local environment could not carry alongside the index.

Then re-run the same retrieval assertions against the cloud database. The point of the exercise is
that they are the same assertions.

## Check it worked

Run these with the ODBC `sqlcmd` the container image already carries. `-b` returns a non-zero exit
on an error and `-m-1` makes severity 10 messages arrive with their `Msg` numbers rather than as
anonymous text, which `-b` alone never surfaces.

**`-m-1` is an ODBC `sqlcmd` instruction**, meaning the 18.x build from `mssql-tools18` or the
Microsoft command line utilities. Measured 2026-09-05, go-sqlcmd 1.10.0, the 1.x build
`brew install sqlcmd` and `winget install sqlcmd` install, prints no `Msg` header on a severity 10
message at any `-m` value, so on that build these commands print the message text with no number at
all. The ODBC build is inside the container image at `/opt/mssql-tools18/bin/sqlcmd`, one
`docker exec` away. `build-app-on-azure-sql` tells the two builds apart in one table.

Start with the declared dimension against what the model produces:

```bash
sqlcmd -S localhost,1433 -U sa -P "$SQL_PASSWORD" -d appdb -C -b -m-1 -h -1 \
  -Q "SET NOCOUNT ON;
      SELECT vector_dimensions FROM sys.columns
      WHERE object_id = OBJECT_ID('dbo.kb') AND name = 'embedding';"
```

Expect one row equal to the number `ollama show` printed in step 1. Two vector widths in one
database, or a width the model does not produce, is the half migrated corpus arriving as a schema
fact rather than as quietly worse answers.

For the offline claim, run the ingest and the retrieval again with the host's network down. Same
rows, same distances, no error. A failure names an outbound call you did not know you had.

## Do not

- Do not point the engine's embedding function at a locally hosted model, and do not add a
  certificate authority to the container to work around the refusal. The engine does not read that
  store, and modifying the image is not a design.
- Do not treat a successful local outbound call as evidence the cloud allows it, and do not
  conclude row level security is unavailable because the container refuses it beside a vector
  index. Never drop the predicate to make the local environment agree with itself.
- Do not pass the vector dimension as a bind parameter, and do not carry the development password
  into the cloud or a key where an identity belongs.

## References

- [references/parity.md](references/parity.md): read it before quoting any parity number, when a
  plan assumes the two engines agree, or when a break needs its exact error text in both orders. It
  holds the side by side run, the timings, the claims that did not hold, and how to reproduce all
  of it in about ten minutes.
- `azuresql-db-rag`: start there for the container, the first vector table and a full scan search,
  then come back here for the move.
- `vector-search-azure-sql`: open it before writing any similarity query, for the type, the
  restrictions and the shape that reaches the index rather than scanning.
- `rag-on-azure-sql`: read it when the pipeline around the query needs designing, for chunk
  identity, provenance, idempotent ingest and grounding.
- `embeddings-and-external-models`: the in engine embedding path, the credential, the allowlist and
  the chunking options, which is what the cloud half of the move switches on. Its neighbour
  `langchain-and-llamaindex-on-azure-sql` has the retrievers and adapters, if the loop runs on a
  framework rather than by hand.
- [sys.sp_invoke_external_rest_endpoint](https://learn.microsoft.com/sql/relational-databases/system-stored-procedures/sp-invoke-external-rest-endpoint-transact-sql)
  and [CREATE EXTERNAL MODEL](https://learn.microsoft.com/sql/t-sql/statements/create-external-model-transact-sql):
  the allowed endpoints table, `API_FORMAT`, `PARAMETERS` and the HTTPS requirement, when deciding
  whether an endpoint that answers locally will answer from Azure SQL Database.
