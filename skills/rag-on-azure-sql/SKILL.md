---
name: rag-on-azure-sql
description: >-
  Builds retrieval augmented generation end to end on Azure SQL Database: chunking source text,
  generating and storing embeddings with the provenance that makes them re-runnable, retrieving
  with the filter and the permission check inside the same query, and grounding an answer on what
  came back. Use when someone asks to "build RAG on Azure SQL", "chat with my documents", "add
  semantic search over my data", "keep embeddings in sync when rows change", "re-embed with a new
  model", or "which chunks should I put in the prompt"; and when a retrieval pipeline returns
  plausible but wrong context, or returns text the asking user is not allowed to read. This skill
  owns the pipeline and the schema around it. The vector type, VECTOR_DISTANCE and the query shape
  that reaches the vector index belong to vector-search-azure-sql, generating the embedding and the
  external model endpoint belong to embeddings-and-external-models, and the offline container path
  is rag-local-with-container.
license: MIT
---

# Retrieval augmented generation on Azure SQL Database

This is the pipeline: what tables exist, what is written when, and what the retrieval query has to
carry. It is not a vector search tutorial and not an embedding API reference.

Verified on 2026-08-28 against a live Azure SQL Database, General Purpose serverless, compatibility
level 170. Every schema claim and every measured behaviour cited here was run.
[references/pipeline.md](references/pipeline.md) has the working schema and the runs.

## What this owns, and what it does not

| Question | Skill |
|---|---|
| The `vector` type, its restrictions, `VECTOR_DISTANCE`, the vector index, and the query shape that actually reaches it | `vector-search-azure-sql` |
| Creating an external model, calling the embedding function, permissions and the endpoint allowlist | `embeddings-and-external-models` |
| Running the whole thing offline against the local Azure SQL Database container | `rag-local-with-container` |
| Driver choice, pooling and retry underneath all of it | `connect-to-azure-sql` |
| Where an embedding column sits relative to the rest of the model | `design-azure-sql-schema` |

**The split with `vector-search-azure-sql` is strict.** That skill teaches how to ask the question.
This one teaches what is in the table when you ask it, and what to do with the answer. Retrieval
queries below are written the way that skill requires and are not re-explained here.

## The correction

An agent asked for RAG on this database ports a vector store recipe: one table holding chunk text
plus one embedding column, retrieved by the application's identity, top k pasted into the prompt.
It works on the first demo. Two things are then wrong, and **neither raises an error**.

**1. The chunk table is a second copy of the source text.** Whatever protected the original does
not follow the copy. Row level security on `dbo.documents` does not apply to `dbo.chunks`, and
neither do its grants, its tenant column or its soft delete flag. A retrieval that is otherwise
perfect puts text the asking user may not read into a prompt, and the model then quotes it back.
The fix is cheap and that is exactly why it gets skipped: measured, a filter predicate placed on
the chunk table **is** honoured through approximate vector search, so the search returns only the
rows the caller may see. The failure is the omission, not the mechanism.

**2. Nothing records which model produced a stored vector.** A `vector(n)` column carries a
dimension count and a base type and nothing else. The two most widely used embedding models both
produce 1536 dimensions, so re-embedding half a corpus with a different model inserts cleanly,
matches on dimension, and leaves two incompatible geometries in one column. Distances across them
are meaningless, no statement fails, and the only symptom is that answers get worse.

Being wrong here costs a data leak that reads as a correct answer, and a corpus whose retrieval
quality degrades with nothing to point at.

## Step 1: fix the model before anything else

The model is chosen before the schema, because the column's dimension follows it and the engine's
ceiling is **1998 dimensions**, so a model emitting more has to be asked for a shorter vector at
generation time.

- **Write the number down twice**: as `vector(n)` in the schema and as the dimension requested from
  the model. When they disagree the insert fails on dimension mismatch, which is the one failure in
  this pipeline that is loud.
- **Record the model name and version in the table**, not in a wiki. Step 2.

## Step 2: the schema

Two tables, not one. The source rows stay authoritative and the chunks are derived.

```sql
CREATE TABLE dbo.documents (
    document_id   INT           NOT NULL IDENTITY PRIMARY KEY,
    tenant_id     INT           NOT NULL,
    title         NVARCHAR(400) NOT NULL,
    body          NVARCHAR(MAX) NOT NULL,
    updated_at    DATETIME2(3)  NOT NULL CONSTRAINT df_documents_updated DEFAULT SYSUTCDATETIME()
);

CREATE TABLE dbo.document_chunks (
    chunk_id      INT           NOT NULL IDENTITY PRIMARY KEY,   -- clustered, the index needs one
    document_id   INT           NOT NULL REFERENCES dbo.documents (document_id),
    tenant_id     INT           NOT NULL,                        -- carried, not joined for, see step 6
    ordinal       INT           NOT NULL,
    chunk_text    NVARCHAR(MAX) NOT NULL,
    source_hash   BINARY(32)    NOT NULL,                        -- hash of chunk_text
    embed_model   SYSNAME       NOT NULL,                        -- provenance
    embed_dims    SMALLINT      NOT NULL,
    embedded_at   DATETIME2(3)  NOT NULL,
    embedding     VECTOR(1536)  NULL
);

CREATE UNIQUE INDEX ux_chunks_identity
    ON dbo.document_chunks (document_id, ordinal);
CREATE INDEX ix_chunks_tenant
    ON dbo.document_chunks (tenant_id);           -- the filter column, used during the search
CREATE INDEX ix_chunks_pending
    ON dbo.document_chunks (embedded_at)
    WHERE embedding IS NULL;                      -- the work queue
```

Four things in there are load bearing:

- **`chunk_id` is a clustered primary key.** Without a clustered index the vector index cannot be
  created at all, and that is discovered late.
- **`source_hash` is how an ingest becomes idempotent.** Re-running over unchanged text must not
  re-embed it. There is no way to compare two vectors for equality on this engine, so the hash of
  the text is the only deduplication key available.
- **`embed_model` and `embed_dims` are the provenance** that failure 2 needs. They cost eight bytes
  a row and they are the difference between "re-embed the 4% that changed" and "re-embed
  everything because nobody knows what is in there".
- **`tenant_id` is carried on the chunk**, deliberately duplicated from the document, so the
  security predicate and the retrieval filter can be applied without a join. Step 6.

## Step 3: chunk

Chunking can happen in the database or in the application, and the choice is about where the source
text already is.

- **Text already in the database**: chunk in the database. The engine provides a chunking function,
  and doing it there avoids pulling every document across the wire to split it and pushing it back.
  The syntax and its options belong to `embeddings-and-external-models`.
- **Text arriving from files or an extraction step**: chunk in the application, where the parsing
  already lives, and insert chunks in batches.

What matters here regardless of where it runs:

- **Chunk the same way every time.** The chunk boundary is part of the retrieval unit's identity.
  Changing chunk size later invalidates every stored embedding just as surely as changing the model.
- **Keep the ordinal.** Retrieval returns fragments and grounding often needs the neighbours, which
  is a cheap lookup on `(document_id, ordinal)` and impossible without it.
- **Store enough text to be an answer.** A chunk that is too small retrieves well and grounds
  badly.

## Step 4: embed

The mechanics of calling a model belong to `embeddings-and-external-models`. The pipeline rules:

1. **Embed rows where `embedding IS NULL`, in batches, driven by the filtered index above.** A set
   based update over the whole table re-embeds work that is already done and costs real money.
2. **Write `embedding`, `embed_model`, `embed_dims` and `embedded_at` in the same statement.** A
   vector without its provenance is the thing failure 2 is made of.
3. **Make the batch restartable.** The identity is `(document_id, ordinal)`; re-running a batch that
   already landed must update rather than insert.
4. **Never leave a mixed corpus.** If the model changes, every row changes, in one pass, before any
   retrieval runs against it. Step 8.

## Step 5: build the vector index, after the data

The index cannot be created until the table holds at least 100 rows with a non-null vector, and it
is a step in the load, not part of the schema deployment.

```sql
CREATE VECTOR INDEX vi_document_chunks
    ON dbo.document_chunks (embedding)
    WITH (METRIC = 'cosine', TYPE = 'diskann');
```

Consequences to plan for rather than discover:

- **A schema-only deployment cannot carry it.** A data-tier package creates objects before loading
  rows, so an import that includes the vector index fails on the row minimum. Drop it before export
  and create it after the load.
- **The metric is fixed at build time** and the retrieval query has to name the same one.
- **Everything works before the index exists**, exactly and slowly. That is convenient for a
  prototype and it is why nobody notices the index was never created in an environment.
- Search accuracy is approximate once the index is in play. That is the trade being bought, and it
  is worth stating to whoever signs off on the answers.

## Step 6: retrieve, with the filter in the query

One query does the whole retrieval: the similarity, the permission filter, and the join back to the
authoritative row.

```sql
DECLARE @q VECTOR(1536) = /* the question, embedded with the SAME model as the corpus */;

SELECT TOP (8) WITH APPROXIMATE
       c.chunk_id, c.document_id, c.ordinal, c.chunk_text, r.distance
FROM VECTOR_SEARCH(
        TABLE      = dbo.document_chunks AS c,
        COLUMN     = embedding,
        SIMILAR_TO = @q,
        METRIC     = 'cosine'
     ) AS r
WHERE c.tenant_id = @tenant_id
ORDER BY r.distance;
```

- **The question must be embedded by the model that embedded the corpus.** A question embedded by a
  different model returns results, ranked by nothing.
- **The filter belongs in this query, not after it.** Filtering the result set in the application
  means asking for eight and grounding on three. The engine applies the predicate during the search
  on a current index, so a filtered top eight returns eight when eight qualify.
- **Add a security predicate to `dbo.document_chunks` as well as to `dbo.documents`.** Measured, it
  is enforced through this query. It is the cheapest defence against failure 1, and it survives a
  developer who forgets the `WHERE` clause.
- **Distance is ascending, and it is a distance.** Anything that turns it into a score belongs to
  `vector-search-azure-sql`, which is also where the query shape and the reason for it live.
- **Retrieve more than you ground on when quality matters**, and re-rank the candidates, but do not
  substitute a bigger k for a missing filter.

## Step 7: ground the answer

- **Pass the chunk text, the document identifier and the ordinal** so the answer can cite, and so a
  human can check the citation.
- **Give the model permission to say the context does not contain the answer.** A retrieval
  pipeline that always answers is a hallucination pipeline with extra steps.
- **Do not paste the distance into the prompt as a confidence.** It is a geometric distance, not a
  probability, and its scale differs by metric.
- **Log the retrieved chunk identifiers with the answer.** When someone reports a wrong answer, the
  only useful question is what was retrieved, and it is unanswerable after the fact otherwise.

## Step 8: keep it current

**When a source row changes**, delete its chunks and re-chunk it. Chunk boundaries move when text
changes, so updating in place leaves orphans. `(document_id, ordinal)` is the identity to
re-establish, and a `MERGE` against the freshly chunked set works on a table carrying a vector
index.

**When the model or the chunking changes**, everything is stale at once. Write the new vectors into
a **new column or a new table**, backfill fully, cut over, then drop the old. A half migrated column
is failure 2, and `embed_model` is what lets you see it:

```sql
SELECT embed_model, embed_dims, COUNT(*) AS chunks
FROM dbo.document_chunks
GROUP BY embed_model, embed_dims;
```

More than one row there and retrieval is already unreliable.

**After replacing most of the embeddings**, drop and recreate the vector index. The graph was built
for the old distribution, and recall degrades with no error.

**Truncating is not available** while the vector index exists. Drop the index, truncate, reload,
recreate.

## Validation rules

- The declared `vector(n)` dimension equals what the model is asked to produce, and is within the
  engine's 1998 ceiling.
- Every embedding row carries the model name, the dimension and a timestamp, and a group by over
  the model column returns exactly one row.
- The chunk table has a clustered primary key, a unique key on the chunk identity, and an index on
  the columns the retrieval filters by.
- The ingest is idempotent: re-running it over unchanged source text embeds nothing.
- The retrieval query carries the tenant or permission filter itself, and the chunk table has its
  own security predicate rather than relying on the source table's.
- The question is embedded with the same model as the corpus, and there is a test that fails if
  that stops being true.
- The vector index is created after the load, and the deployment pipeline does not attempt to
  import it as part of a schema package.
- A wrong answer can be investigated, because the retrieved chunk identifiers were logged with it.
- No source text, sample document or test fixture in the repository contains real customer data.

## Do not

- Do not store chunk text without re-applying whatever protected the source rows. The copy is a new
  table and inherits nothing.
- Do not store an embedding without recording which model made it.
- Do not mix two models' vectors in one column. Nothing will tell you, and every distance across
  them is meaningless.
- Do not filter retrieved rows in application code when the predicate could have been in the query.
- Do not embed the question with a different model from the corpus.
- Do not re-embed rows that have not changed. Hash the text and skip them.
- Do not treat a distance as a confidence score, and do not put it in the prompt.
- Do not create the vector index as part of a schema-only deployment.
- Do not leave a pipeline that cannot say "the retrieved context does not answer this".
- Do not teach the vector type, the distance function or the approximate query shape here. Those
  are `vector-search-azure-sql`.

## References

- [references/pipeline.md](references/pipeline.md): the full working schema, the ingest and
  re-embedding statements, the row level security policy that was measured through approximate
  search, and the checks that catch a mixed corpus. Read it while implementing step 2 onwards.
- `vector-search-azure-sql`: the type, its restriction list, the distance metrics, and the query
  shape that reaches the vector index rather than scanning the table.
- `embeddings-and-external-models`: creating the external model, the chunking function, the
  embedding function, permissions and the endpoint allowlist.
- `rag-local-with-container`: the same pipeline offline against the local Azure SQL Database
  container, with no cloud dependency and no keys.
- `connect-to-azure-sql`: driver choice, pooling and retry for the ingest and the query path.
- `design-azure-sql-schema`: key lengths, string sizing and where a derived table belongs.
- [Intelligent applications with Azure SQL Database](https://learn.microsoft.com/azure/azure-sql/database/ai-artificial-intelligence-intelligent-applications):
  the first party overview of the AI surface and what is currently available. Read it when checking
  whether a capability has moved out of preview.
- [Row level security](https://learn.microsoft.com/sql/relational-databases/security/row-level-security):
  the predicate mechanism this pipeline puts on the chunk table.
