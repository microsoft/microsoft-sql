---
name: rag-local-with-container
description: >-
  Answers whether a retrieval augmented generation prototype proved against the local Azure SQL
  Database container still holds in Azure SQL Database, and names the three things that do not
  survive the move. Owns the offline loop, with the embedding model on the developer's own
  machine, and the parity claim. Use when someone asks to "prototype RAG offline with no
  cloud account", "use a local embedding model with SQL", "develop against the container and
  deploy to Azure SQL Database", or asks what will have to be redone after the move; and when the
  engine refuses a local embedding endpoint, or a vector index and a security policy will not
  coexist. A plain request to build RAG on the container, the first vector table and a top
  k search over it, belongs to azuresql-db-rag; come here for the move. The cloud pipeline is
  rag-on-azure-sql, the type and the query are vector-search-azure-sql, embedding inside the
  engine is embeddings-and-external-models, and framework wiring is
  langchain-and-llamaindex-on-azure-sql.
license: MIT
---

# Local RAG on the Azure SQL Database container

Build the whole retrieval loop on a laptop with no cloud account, no keys and no outbound calls,
then move it. This skill is about **what survives the move and what does not**.

Verified on 2026-08-28 by running one script against the local container and the same script
against a live Azure SQL Database provisioned for the run, and comparing the outputs line by line.
Both engines report `SERVERPROPERTY('EngineEdition')` of 5. The full runs, the diff and the
reproduction steps are in [references/parity.md](references/parity.md).

## What this owns

| Question | Skill |
|---|---|
| The `vector` type, `VECTOR_DISTANCE`, the index and the query shape that reaches it | `vector-search-azure-sql` |
| The cloud pipeline: chunk identity, provenance, re-embedding, grounding | `rag-on-azure-sql` |
| Producing a vector inside the engine, credentials and the endpoint allowlist | `embeddings-and-external-models` |
| Vector store adapters, retrievers, agent toolkits and their guardrails | `langchain-and-llamaindex-on-azure-sql` |
| A first vector table and a full scan top k on a fresh container | `azuresql-db-rag` |

`azuresql-db-rag` is the shipped starting recipe: start the container, create the table, embed from
application code, run a full scan search. **A plain "build RAG on the container" is that skill's,
not this one's.** This skill is the next question, which that one does not answer: **is the thing I
just proved locally still true in the cloud?**

## The correction

An agent told the container is the same engine concludes that anything proved locally holds in the
cloud, and an agent told it is "just a container" refuses to prototype offline at all and reaches
for a hosted endpoint and a key on day one. Both are wrong, and the measurements point in opposite
directions.

**Parity is real for the part people doubt.** The same 140 chunk corpus, embedded by the same local
model, inserted into both engines, produced **identical cosine distances to six decimal places**,
an identical top three, a vector index that built on both, and approximate search that returned the
same rows in the same order on both. Every error text matched. The offline prototype is not a
simulation.

**Three things break, and each one breaks in the direction that flatters the laptop.**

| What | Container | Azure SQL Database | Consequence |
|---|---|---|---|
| Outbound calls from the engine | any public host answers | only an allowlist of domains, `Msg 31612` before DNS | Works locally, refused in the cloud |
| Row level security together with a vector index | refused, `Msg 37579` and `Msg 42244` | both coexist, either order | The isolation the cloud design depends on cannot be rehearsed locally |
| Managed identity for an outbound credential | refused, `Msg 31644` | works | The production identity has no local rehearsal |

And a fourth that is not an engine difference at all and costs the most: **the code moves unchanged,
the corpus does not.** A local embedding model and a hosted one produce different geometries and
usually different dimensions, and the dimension is baked into the column and cannot be altered.

Being wrong costs a retrieval query that passes every local test and is refused by policy on its
first cloud run, a tenant isolation control that ships having never been exercised, and a full
re-embed of the corpus discovered after the schema is deployed.

## Step 1: fix the dimension before writing anything

This is the decision that cannot be revisited, and it is made once for both environments.

- Look up the output dimension of the **local** model. A common local embedding model emits 768.
- Choose a cloud model that can be **asked** for that same number. Measured, a hosted model whose
  default is 1536 returned a 768 dimension vector when the external model definition carried
  `PARAMETERS = '{"dimensions":768}'`, and a 512 dimension vector when asked for 512.
- Declare that one number once, as `vector(768)` in the schema and as the dimension requested from
  every model.

Matching the number keeps **the column type** portable. It does not make the vectors
interchangeable: two models are two geometries, and a corpus embedded locally has to be re-embedded
before the cloud model queries it. What matching buys is that the re-embed is an `UPDATE` rather
than a new table, a new index and a migration.

If the numbers cannot be matched, plan for a second column from the start rather than discovering
it later. `ALTER COLUMN` cannot change a vector's dimension, even on an empty table.

## Step 2: embed in the application, because the engine cannot reach a local model

This is the structural difference from the cloud pipeline, and it is not a preference.

The engine's own embedding function calls an endpoint over the network, and every route to a
locally hosted model is closed. Measured on the container:

- A plain `http://` endpoint is `Msg 31610`. HTTPS is required.
- A hostname resolving to a private address is `Msg 31624`, refused before the handshake.
- A private certificate authority is `Msg 31608`, and it stays refused after that authority is
  installed in the container's own operating system trust store and accepted there by a command
  line client in the same container. The engine does not read that store.

So the local loop embeds in application code, calling the local model directly, and writes the
vector in. That is the same shape `azuresql-db-rag` uses, and it is correct:

```python
DIM = 768                       # decided in step 1, a literal in the SQL text

def embed(texts: list[str]) -> list[list[float]]:
    """The one thing that changes when this moves. Nothing else does."""
    ...                         # local model now, hosted model later

cursor.execute(
    f"INSERT dbo.kb (tenant_id, body, embedding) "
    f"VALUES (?, ?, CAST(CAST(? AS NVARCHAR(MAX)) AS VECTOR({DIM})))",
    tenant_id, body, json.dumps(vector),
)
```

The dimension is interpolated as a literal and the vector is bound as a JSON array string. Passing
the dimension as a parameter is a syntax error, which is a property of the type rather than of the
container.

Chunking is the exception, and it is worth taking. `AI_GENERATE_CHUNKS` runs in the engine with no
endpoint, no credential, no permission grant and no network, and produced byte identical output on
both engines. Chunk in the database on both sides and one more piece of the pipeline stops being
environment specific. Its options belong to `embeddings-and-external-models`.

## Step 3: build the loop, and measure it

A complete offline run, verified end to end on the container: 152 chunks embedded by a local model
in 0.8 seconds, inserted, indexed, searched with a tenant filter, and answered by a local
generation model in 2.3 seconds. No cloud account, no key, nothing leaving the host.

The retrieval query is the one `vector-search-azure-sql` specifies, unchanged, and the filter sits
inside it exactly as `rag-on-azure-sql` requires. Neither is restated here.

Two measurements worth having in front of a team arguing about where to develop:

| Operation | Container | Cloud |
|---|---|---|
| Insert 140 rows carrying a 768 dimension vector | 766 ms | 16851 ms |
| Exact top three over 140 rows | 16 ms | 150 ms |

The gap is round trips and provisioned throughput, not engine capability. It is the actual reason
the inner loop belongs on the laptop, and it is worth stating rather than asserting that local is
faster.

## Step 4: know what you cannot rehearse locally

**Row level security and a vector index are mutually exclusive on the container.** Measured, in
both orders:

- Create the vector index first, then the security policy: `Msg 37579, The security policy '<name>'
  cannot reference tables with vector indexes`.
- Create the security policy first, then the vector index: `Msg 42244, A vector index cannot be
  created on tables with security policies`.

In the cloud both orders succeeded and both objects coexisted. This matters because the security
predicate on the chunk table is the cheapest defence in the whole design, and the local environment
cannot hold it and the index at the same time. Two workable answers, and the wrong answer is to
drop the predicate:

1. **Rehearse the predicate on an unindexed local table.** Under a few thousand rows an exact scan
   is fast, and the predicate is what is being tested, not the plan.
2. **Keep the indexed local table for retrieval work and prove the isolation in the cloud**, with a
   test that runs there and fails loudly if the policy is missing.

Either way, the tenant filter still belongs inside the retrieval query locally, so the query text
that ships is the query text that was tested.

**Managed identity has no local rehearsal.** The container answers `Msg 31644` and names an
`sp_configure` remedy that the container itself refuses with `Msg 40510`. Use a key locally,
managed identity in the cloud, and keep the difference in the credential rather than in the code.

**The allowlist cannot be tested locally.** The container calls any public host, so a successful
local call is not evidence of anything. Check every endpoint the design depends on from a cloud
database before believing it.

## Step 5: make the move

Change the connection string. Then change these four things and nothing else:

1. **The embedding function's endpoint**, and its requested dimension if the model differs.
2. **The credential**, from a key to managed identity. The `USE MODEL` text does not change.
3. **Re-embed the corpus** with the cloud model. Same column, same index, new vectors, in one pass
   before any retrieval runs against it. A half migrated column is the failure `rag-on-azure-sql`
   describes and nothing raises it.
4. **Add the security policy** on the chunk table, which the local environment could not carry
   alongside the index.

Then re-run the same retrieval assertions against the cloud database. The point of the whole
exercise is that they are the same assertions.

## Validation rules

- One dimension number appears in the schema, in the local embedding call and in the cloud model's
  requested dimensions, and a test fails if any of the three disagree.
- The embedding call is a single function with one endpoint in it, and nothing else in the codebase
  calls a model.
- The retrieval query text is identical in both environments, filter included, and was executed
  against both.
- Nothing in the local path requires an outbound call. Running with the machine offline reaches the
  same results.
- No key, endpoint host name or account name is committed. The local password is a development
  value and the cloud identity is a managed identity.
- Every endpoint the design depends on was checked against the cloud allowlist from a cloud
  database, not from the container.
- The tenant or permission predicate was exercised somewhere: on an unindexed local table, or in
  the cloud, and there is a test that fails when the policy is absent.
- The corpus was fully re-embedded after the model changed, and a group by over the model column
  returns exactly one row.
- Sample corpora are fabricated. No customer text, no internal document, no real identifier.

## Do not

- Do not point the engine's embedding function at a locally hosted model. Every route to it is
  refused, and the fix is to embed in application code.
- Do not install a certificate authority in the container to work around that. The engine does not
  read the container's trust store, and a workaround that depends on modifying the image is not a
  design.
- Do not treat a successful local outbound call as evidence the cloud will allow it. The container
  has no allowlist.
- Do not conclude row level security is unavailable because the container refuses it next to a
  vector index. It works in the cloud, in either order.
- Do not drop the security predicate to make the local environment agree with itself.
- Do not assume a locally embedded corpus is usable by a different model in the cloud. It is not,
  whatever the dimensions say.
- Do not pick the local model and the cloud model independently. Their dimensions have to agree or
  the column has to be planned twice.
- Do not pass the vector dimension as a bind parameter. It is a literal in the statement text.
- Do not carry the development password into the cloud, and do not carry a key where an identity
  belongs.
- Do not re-teach the vector type, the distance function, the index or the query shape here. Those
  are `vector-search-azure-sql`, and the pipeline around them is `rag-on-azure-sql`.

## References

- [references/parity.md](references/parity.md): the one script run against both engines, the line
  by line comparison, the three breaks with their exact error numbers in both orders, the timing
  table, and how to reproduce the whole thing in about ten minutes. Read it before claiming
  anything about parity, including the claims above.
- `azuresql-db-rag`: starting the container, provisioning the user database, the first vector table
  and a full scan search. Start there, then come back here for the move.
- `vector-search-azure-sql`: the type, the restriction list, and the query shape that reaches the
  index rather than scanning.
- `rag-on-azure-sql`: chunk identity, provenance, idempotent ingest, re-embedding and grounding.
  Everything this skill assumes about the pipeline is defined there.
- `embeddings-and-external-models`: the in engine embedding path, the credential and the allowlist,
  which is what the cloud half of the move switches on.
- `langchain-and-llamaindex-on-azure-sql`: retrievers, vector store adapters and the guardrails, if
  the local loop is being built on a framework rather than by hand.
- [Intelligent applications with Azure SQL Database](https://learn.microsoft.com/azure/azure-sql/database/ai-artificial-intelligence-intelligent-applications):
  the first party view of the AI surface. Read it when checking whether one of the three breaks
  above has closed.
