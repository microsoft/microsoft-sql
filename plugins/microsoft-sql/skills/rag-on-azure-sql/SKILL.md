---
name: rag-on-azure-sql
description: "Use when building a RAG pipeline end to end on Azure SQL Database: chat with my documents, semantic search over my data, keep embeddings in sync, answers worse after switching models, other tenants' chunks returned."
---

# Retrieval augmented generation on Azure SQL Database

What tables exist, what is written when, what the retrieval query has to carry, and how to prove it
worked.

Open [references/pipeline.md](references/pipeline.md) when you sit down to write the ingest or the
re-embed: it holds the `MERGE`, the embedding loop, and how engine builds treat a security policy
on a vector-indexed table.

## What this owns

The tables, the ingest, what the retrieval query carries, and the grounding. Open
`vector-search-azure-sql` before writing any similarity query, for the `vector` type's restrictions
and the shape that reaches the index; `embeddings-and-external-models` before steps 3 and 4, for
the external model and the chunking and embedding functions; `rls-multi-tenant` for predicates,
with step 6's caveat. When no cloud endpoint is available, keep embedding application-side and
validate the production query and security behavior against Azure SQL Database before release.

## The correction

The usual way to build RAG here ports a vector store recipe: one table of chunk text with one
embedding column, retrieved by the application's identity, top k pasted into the prompt. It works
on the first demo. Two things are then wrong and **neither raises an error**.

**1. The chunk table is a second copy of the source text.** Whatever protected the original does
not follow the copy. Row level security on `dbo.documents` does not apply to `dbo.document_chunks`,
and neither do its grants, its tenant column or its soft delete flag. A retrieval that is otherwise
perfect puts text the asking user may not read into a prompt, and the model quotes it back. The
obvious fix, a security policy on the chunk table, cannot be relied on: whether a policy can sit on
a vector-indexed table is undocumented and depends on the engine. Earlier container builds and
SQL Server 2025 refuse the pair (`Msg 37579`, `Msg 42244`); Azure SQL Database and current container
builds accept it and then do not use the vector index under the policy.
Make the retrieval query's `WHERE` clause the boundary and prove it with a test.

**2. Nothing records which model produced a stored vector.** A `vector(n)` column carries a
dimension and a base type and nothing else. The two most widely used embedding models both emit
1536 dimensions, so re-embedding half a corpus with another inserts cleanly and leaves two
incompatible geometries in one column. Distances across them are meaningless, no statement
fails, and the only symptom is that answers get worse.

## 1. Fix the dimension before the schema

The dimension follows the model, the ceiling is 1998 at the default `float32` (3996 at
half-precision `float16`), and it cannot be widened by `ALTER COLUMN` even on an empty table. A 3072
dimension model does not fit a `float32` column: ask it for a shorter vector at generation time, or
declare `vector(3072, float16)` and accept half precision. Write the number twice, as `vector(n)` and as the dimension
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
   SET embedding   = AI_GENERATE_EMBEDDINGS(c.chunk_text USE MODEL text_embedder),
       embed_model = N'text-embedding-3-small',
       embed_dims  = 1536,
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
DECLARE @q VECTOR(1536) =
    AI_GENERATE_EMBEDDINGS(N'the question' USE MODEL text_embedder);

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
- **Do not count on a policy backing that `WHERE` clause up.** Microsoft Learn says nothing about
  a security policy on a vector-indexed table, and engine builds differ. Earlier container builds
  refuse the pair in both orders: `Msg 37579` when the policy is created after the index,
  `Msg 42244` when the index is created after the policy. Container build 18.0.310.0_253 accepts both
  orders and holds the filter through `TOP ... WITH APPROXIMATE`, but does not use the vector index
  under the policy: `WITH (FORCE_ANN_ONLY)` fails with `Msg 8622`, and without the hint the same
  query returns rows from an exact search. Azure SQL Database behaves like that container build:
  the pair is accepted, the filter holds, the index is not used under the policy. SQL Server 2025
  refuses the pair like the earlier builds. Keep the
  policy on `dbo.documents`, where it still guards direct reads, and treat the filter above as
  security code: test that removing it changes the result. If a predicate on the
  retrieval path is non-negotiable, try it on the target database and check three things: the
  policy is created, a cross-tenant approximate query returns none of another tenant's rows, and
  the plan still shows a `Vector Index Seek`. The sourced fallbacks are to drop the vector index,
  since `VECTOR_SEARCH` still runs as a brute force scan without one, or to split the table so the
  index sits on an embeddings table carrying no policy and the protected text joins back, costing
  the filter its place inside the search.
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

-- 2. Which tables have a predicate and which have a vector index. Keep them on different tables.
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
`has_vector_index` `1` and `has_policy` `0`. That zero is the design, not an omission to fix:
depending on the build, a policy there is refused or keeps approximate search off the vector index,
which is why step 6's `WHERE` clause is what needs the test. Check 3 returns one row per vector
index with `index_version` `3`; empty means every retrieval is scanning, and an older version means
step 6's filter runs after the search rather than during it. Check 4 returns `0`; anything else
means the deduplication key is wrong and re-runs are re-embedding unchanged text.

`-m-1` makes a severity 10 message print its number, and `-b` only sets a non-zero exit at severity
11 and above, so `sqlcmd` exiting 0 says nothing about the four. Read the output file.

**`-m-1` is an ODBC `sqlcmd` instruction**, meaning the 18.x build from `mssql-tools18` or the
Microsoft command line utilities. With go-sqlcmd 1.x, the build `brew install sqlcmd` and
`winget install sqlcmd` install, a severity 10 message prints no `Msg` header at any `-m` value, so
it arrives with no number to read. Query `sys.messages` or use the ODBC build when the number
matters.

## Do not

- Do not assume the copy inherits the source's protection, and do not rely on a policy of its own:
  depending on the build it is refused, or it is accepted and approximate search stops using the
  vector index. The query's filter is the boundary and needs a test that fails without it, in the
  database rather than in application code.
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
  loop, the mixed corpus checks, and the security policy and vector index behavior in full.
- [VECTOR_SEARCH](https://learn.microsoft.com/sql/t-sql/functions/vector-search-transact-sql): read
  when a filtered retrieval returns fewer rows than asked for, for iterative versus post filtering,
  and for the `ORDER BY` rules behind `Msg 42248` and `Msg 42271`.
- [CREATE VECTOR INDEX limitations](https://learn.microsoft.com/sql/t-sql/statements/create-vector-index-transact-sql#limitations-and-considerations):
  read before promising a policy on an indexed table. Its limitations list partitioning,
  replication, `TRUNCATE` and package import, and say nothing about security policies.
- [Row level security](https://learn.microsoft.com/sql/relational-databases/security/row-level-security):
  read before putting a predicate on `dbo.documents`.
- [HASHBYTES](https://learn.microsoft.com/sql/t-sql/functions/hashbytes-transact-sql): read before
  choosing a deduplication key, for the algorithms still supported and the input limit.
