---
name: rag-on-azure-sql
description: >-
  Builds retrieval augmented generation end to end on Azure SQL Database: chunking source text,
  storing embeddings with the provenance that makes them re-runnable, retrieving with the filter
  and the permission check inside the same query, and grounding an answer on what came back. Use
  when someone asks to "build RAG on Azure SQL Database", "chat with my documents", "add semantic
  search over my data", "keep embeddings in sync when rows change", "re-embed with a new model", or
  "which chunks should I put in the prompt"; and when a retrieval pipeline returns plausible but
  wrong context, or returns text the asking user is not allowed to read. This skill owns the
  pipeline and the schema around it. The vector type, VECTOR_DISTANCE and the query shape that
  reaches the vector index belong to vector-search-azure-sql, generating the embedding and the
  external model endpoint belong to embeddings-and-external-models, and the offline container path
  is rag-local-with-container.
---

# Retrieval augmented generation on Azure SQL Database

What tables exist, what is written when, what the retrieval query has to carry, and how to prove it
worked.

Verified 2026-08-28 against a live Azure SQL Database, General Purpose serverless, compatibility
level 170, and re-run 2026-09-03, which is where `Msg 37579` comes from. Numbers not from those
runs are from Microsoft Learn, linked at the end.

Open [references/pipeline.md](references/pipeline.md) when you sit down to write the ingest or the
re-embed: it holds the `MERGE`, the embedding loop, and what the two runs disagreed about.

## What this owns

The tables, the ingest, what the retrieval query carries, and the grounding. Open
`vector-search-azure-sql` before writing any similarity query, for the `vector` type's restrictions
and the shape that reaches the index; `embeddings-and-external-models` before steps 3 and 4, for
the external model and the chunking and embedding functions; `rls-multi-tenant` for predicates,
with step 6's caveat; `rag-local-with-container` when there is no cloud endpoint to develop on.

## The correction

An agent asked to build RAG here ports a vector store recipe: one table of chunk text with one
embedding column, retrieved by the application's identity, top k pasted into the prompt. It works
on the first demo. Two things are then wrong and **neither raises an error**.

**1. The chunk table is a second copy of the source text.** Whatever protected the original does
not follow the copy. Row level security on `dbo.documents` does not apply to `dbo.document_chunks`,
and neither do its grants, its tenant column or its soft delete flag. A retrieval that is otherwise
perfect puts text the asking user may not read into a prompt, and the model quotes it back. The
obvious fix is refused: a security policy cannot reference a table carrying a vector index,
`Msg 37579`, so the chunk table cannot have a predicate at all and the retrieval query's `WHERE`
clause is the whole boundary.

**2. Nothing records which model produced a stored vector.** A `vector(n)` column carries a
dimension and a base type and nothing else. The two most widely used embedding models both emit
1536 dimensions, so re-embedding half a corpus with another inserts cleanly and leaves two
incompatible geometries in one column. Distances across them are meaningless, no statement
fails, and the only symptom is that answers get worse.

## 1. Fix the dimension before the schema

The dimension follows the model, the ceiling is 1998, and it cannot be widened by `ALTER COLUMN`
even on an empty table. A 3072 dimension model does not fit and has to be asked for a shorter
vector at generation time. Write the number twice, as `vector(n)` and as the dimension
requested from the model; when they disagree the insert fails, the one loud failure here.

## 2. The schema

Two tables. Source rows stay authoritative and chunks are derived.

```sql
CREATE TABLE dbo.documents (
    document_id   INT           NOT NULL IDENTITY PRIMARY KEY,
    tenant_id     INT           NOT NULL,
    title         NVARCHAR(400) NOT NULL,
    body          NVARCHAR(MAX) NOT NULL,
    updated_at    DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME()
);

CREATE TABLE dbo.document_chunks (
    chunk_id      INT           NOT NULL IDENTITY PRIMARY KEY,   -- clustered; the index needs one
    document_id   INT           NOT NULL REFERENCES dbo.documents (document_id),
    tenant_id     INT           NOT NULL,                        -- carried, not joined for, step 6
    ordinal       INT           NOT NULL,
    chunk_text    NVARCHAR(MAX) NOT NULL,
    source_hash   BINARY(32)    NOT NULL,                        -- HASHBYTES over chunk_text
    embed_model   SYSNAME       NOT NULL,                        -- provenance
    embed_dims    SMALLINT      NOT NULL,
    embedded_at   DATETIME2(3)  NULL,                            -- NULL exactly when embedding is
    embedding     VECTOR(1536)  NULL
);

CREATE UNIQUE INDEX ux_chunks_identity ON dbo.document_chunks (document_id, ordinal);
CREATE INDEX ix_chunks_tenant  ON dbo.document_chunks (tenant_id);   -- the retrieval filter
CREATE INDEX ix_chunks_pending ON dbo.document_chunks (chunk_id)
    WHERE embedded_at IS NULL;                                       -- the work queue
```

Four things are load bearing:

- **`chunk_id` is a clustered primary key.** Without a clustered index the vector index cannot be
  created at all, and that is discovered late.

- **`source_hash` is how an ingest becomes idempotent.** There is no equality operator on a vector,
  so a hash of the text is the only deduplication key. `HASHBYTES` takes the whole `nvarchar(max)`
  chunk here, with no 8,000 byte limit.
- **`embed_model` and `embed_dims` are the provenance** failure 2 needs. They are the difference
  between re-embedding what changed and re-embedding everything because nobody knows what is in
  there.
- **`tenant_id` is carried on the chunk**, deliberately duplicated, so the retrieval filter needs
  no join. It is not backed by a predicate here and cannot be. Step 6.

`embedded_at` is NULL exactly when `embedding` is, because step 4 writes both in one statement,
which is what lets the work queue be a filtered index on an ordinary column.

## 3. Chunk

Chunk in the database when the text is already there, in the application when it arrives from
files. The chunking function and its size and overlap parameters are
`embeddings-and-external-models`.

- **Chunk the same way every time.** Changing chunk size later invalidates every stored embedding
  as surely as changing the model.
- **Keep the ordinal.** Grounding often needs a hit's neighbours, a cheap seek on
  `(document_id, ordinal)` and impossible without it.
- **Store enough text to be an answer.** A chunk too small retrieves well and grounds badly.

## 4. Embed in restartable batches

The model call is `embeddings-and-external-models`. The pipeline shape:

```sql
UPDATE TOP (200) c
   SET embedding   = /* embeddings-and-external-models: the model call over c.chunk_text */,
       embed_model = @embed_model,
       embed_dims  = @embed_dims,
       embedded_at = SYSUTCDATETIME()
  FROM dbo.document_chunks AS c
 WHERE c.embedded_at IS NULL;
```

Loop until it affects zero rows. The filtered index makes that predicate a seek over a corpus that
is mostly done, where a set based update over the whole table re-embeds finished work and costs
money. Write the vector and its three provenance columns in the **same** statement: a vector
without provenance is what failure 2 is made of. It restarts safely because the identity is
`(document_id, ordinal)`.

## 5. The index goes in after the load

```sql
CREATE VECTOR INDEX vi_document_chunks
    ON dbo.document_chunks (embedding)
    WITH (METRIC = 'cosine', TYPE = 'diskann');
```

- **At least 100 rows carrying a non-null vector**, `Msg 42266` below that. So it belongs to the
  load, never the schema deployment: a package import creates objects before it loads rows. Drop
  the index before an export, create it after.
- **The metric is fixed at build time** and the retrieval query has to name the same one.
- **Everything works before the index exists**, exactly and slowly, which is why an environment
  runs without one and only latency says so.
- **`TRUNCATE TABLE` is refused once it exists**, `Msg 42232`. Drop, truncate, reload, recreate.

## 6. Retrieve with the filter in the query

One query does the similarity, the tenant filter and the ordering the prompt needs.

```sql
DECLARE @q VECTOR(1536) = /* the question, embedded with the SAME model as the corpus */;

SELECT chunk_id, document_id, ordinal, chunk_text, distance   -- reading order, for the prompt
FROM (
    SELECT TOP (8) WITH APPROXIMATE
           c.chunk_id, c.document_id, c.ordinal, c.chunk_text, r.distance
    FROM VECTOR_SEARCH(
            TABLE      = dbo.document_chunks AS c,
            COLUMN     = embedding,
            SIMILAR_TO = @q,
            METRIC     = 'cosine'
         ) AS r
    WHERE c.tenant_id = @tenant_id                    -- applied DURING the search, see below
    ORDER BY r.distance
) AS hits
ORDER BY document_id, ordinal;
```

- **Embed the question with the model that embedded the corpus.** A question embedded by a
  different model returns results ranked by nothing.
- **The filter belongs inside, not after.** On a current index version the predicate is applied
  during the search, so a filtered top eight returns eight whenever eight qualify. On an earlier
  index version the search runs before any predicate: the eight nearest are chosen first and the
  filter then removes some, returning three, or none, with qualifying rows unread. Check 3 says
  which one you have.
- **The inner `ORDER BY` takes the distance column ascending and nothing else.** Adding
  `c.ordinal` fails with `Msg 42271` and dropping it fails with `Msg 42248`, which is why reading
  order is applied in the outer query.
- **No policy can back that `WHERE` clause up.** `CREATE SECURITY POLICY` on a table carrying a
  vector index is refused, `Msg 37579`, measured 2026-09-03 and documented nowhere on Microsoft
  Learn. Keep the policy on `dbo.documents`, where it still guards direct reads, and treat the
  filter above as security code: test that removing it changes the result. If a predicate on the
  retrieval path is non-negotiable, the sourced ways out are to drop the vector index, since
  `VECTOR_SEARCH` still runs as a brute force scan without one, or to split the table so the index
  sits on an embeddings table carrying no policy and the protected text joins back, costing the
  filter its place inside the search.
- **Retrieve more than you ground on** and re-rank the candidates, but never substitute a bigger k
  for a missing filter.

## 7. Ground the answer

- **Pass the chunk text, the document identifier and the ordinal** so the answer can cite it and a
  human can check the citation.
- **Give the model permission to say the context does not contain the answer.** A pipeline that
  always answers is a hallucination pipeline with extra steps.
- **Do not paste the distance in as a confidence.** It is a geometric distance, not a probability,
  and its scale differs by metric.
- **Log the retrieved chunk identifiers with the answer.** When a wrong answer is reported, the
  only useful question is what was retrieved, and nothing else answers it later.

## 8. Keep it current

**When a source row changes**, delete its chunks and re-chunk it: boundaries move when text
changes, so updating in place leaves orphans. `MERGE` on `(document_id, ordinal)` does it, and is
supported on a table carrying a current vector index, which maintains itself. The statement is in
the reference.

**When the model or the chunking changes**, everything is stale at once. Add a new column with its
own provenance, backfill fully while retrieval still runs on the old, cut over, then drop the old
column and index. A half migrated column is failure 2. Rebuild the vector index afterwards: the
graph was built for the old distribution and recall degrades with no error.

## Check it worked

Four checks. The second decides whether the retrieval is safe to expose.

```sql
-- 1. Provenance: one model across the corpus, and nothing left unembedded.
SELECT embed_model, embed_dims, COUNT(*) AS chunks,
       SUM(CASE WHEN embedding IS NULL THEN 1 ELSE 0 END) AS unembedded
FROM dbo.document_chunks
GROUP BY embed_model, embed_dims;

-- 2. Which tables have a predicate and which have a vector index. Never both.
SELECT t.name AS table_name,
       MAX(CASE WHEN sp.target_object_id IS NULL THEN 0 ELSE 1 END) AS has_policy,
       MAX(CASE WHEN vi.object_id IS NULL THEN 0 ELSE 1 END) AS has_vector_index
FROM sys.tables AS t
LEFT JOIN sys.security_predicates AS sp ON sp.target_object_id = t.object_id
LEFT JOIN sys.vector_indexes     AS vi ON vi.object_id = t.object_id
GROUP BY t.name;

-- 3. The vector index exists and is the current version.
SELECT OBJECT_NAME(v.object_id) AS table_name, i.name AS index_name,
       JSON_VALUE(v.build_parameters, '$.Version') AS index_version
FROM sys.vector_indexes AS v
JOIN sys.indexes AS i ON v.object_id = i.object_id AND v.index_id = i.index_id;

-- 4. Every stored hash still agrees with the text it was taken from.
SELECT COUNT(*) AS hashes_disagreeing_with_their_text
FROM dbo.document_chunks
WHERE source_hash <> HASHBYTES('SHA2_256', chunk_text);
```

Run them non-interactively and keep the output:

```bash
sqlcmd -S <server-name>.database.windows.net,1433 -d <database> -U <user> -C -b -m-1 \
  -i check-rag-pipeline.sql -o check-rag-pipeline.out
```

Expected: check 1 returns **exactly one row** with `unembedded` `0`; two rows means two geometries
in one column and every distance across them meaningless, and a non-zero `unembedded` means part of
the corpus is invisible. Check 2 shows `documents` with `has_policy` `1`, and `document_chunks` with
`has_vector_index` `1` and `has_policy` `0`; that zero is the engine's rule, not an omission to fix,
which is why step 6's `WHERE` clause is what needs the test. Check 3 returns one row per vector
index with `index_version` `3`; empty means every retrieval is scanning, and an older version means
step 6's filter runs after the search rather than during it. Check 4 returns `0`; anything else
means the deduplication key is wrong and re-runs are re-embedding unchanged text.

`-m-1` makes a severity 10 message print its number, and `-b` only sets a non-zero exit at severity
11 and above, so `sqlcmd` exiting 0 says nothing about the four. Read the output file.

## Do not

- Do not assume the copy inherits the source's protection, and do not try to give it a policy of
  its own: that is refused. The query's filter is the boundary and needs a test that fails without
  it, in the database rather than in application code.
- Do not store an embedding without recording which model made it, and do not mix two models'
  vectors in one column. Nothing will tell you.
- Do not embed the question with a different model from the corpus.
- Do not re-embed rows that have not changed. Hash the text and skip them.
- Do not treat a distance as a confidence score, and do not put it in the prompt.
- Do not create the vector index as part of a schema-only deployment, and do not ship a pipeline
  that cannot say "the retrieved context does not answer this".

## References

- [references/pipeline.md](references/pipeline.md): open it while writing step 2 onwards, or when a
  claim above disagrees with what you are seeing. It has the idempotent `MERGE`, the embedding
  loop, the mixed corpus checks, and the `Msg 37579` disagreement in full.
- [VECTOR_SEARCH](https://learn.microsoft.com/sql/t-sql/functions/vector-search-transact-sql): read
  when a filtered retrieval returns fewer rows than asked for, for iterative versus post filtering,
  and for the `ORDER BY` rules behind `Msg 42248` and `Msg 42271`.
- [CREATE VECTOR INDEX limitations](https://learn.microsoft.com/sql/t-sql/statements/create-vector-index-transact-sql#limitations-and-considerations):
  read before promising a policy on an indexed table. As of 2026-09-03 it lists partitioning,
  `TRUNCATE` and package import, and not `Msg 37579`.
- [Row level security](https://learn.microsoft.com/sql/relational-databases/security/row-level-security):
  read before putting a predicate on `dbo.documents`.
- [HASHBYTES](https://learn.microsoft.com/sql/t-sql/functions/hashbytes-transact-sql): read before
  choosing a deduplication key, for the algorithms still supported and the input limit.
