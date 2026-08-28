# The pipeline, in full

## Contents

- [What was measured](#what-was-measured)
- [Schema](#schema)
- [Idempotent ingest](#idempotent-ingest)
- [Embedding pass](#embedding-pass)
- [Vector index, after the load](#vector-index-after-the-load)
- [Retrieval](#retrieval)
- [Row level security on the chunk table](#row-level-security-on-the-chunk-table)
- [Detecting a mixed corpus](#detecting-a-mixed-corpus)
- [Changing the model or the chunking](#changing-the-model-or-the-chunking)
- [Failure modes and what they look like](#failure-modes-and-what-they-look-like)

## What was measured

Run on 2026-08-28 against an Azure SQL Database provisioned for the purpose: General Purpose
serverless, two vCores, compatibility level 170, Microsoft Entra authentication only. The
statements below were executed as written, apart from the embedding call itself, which is
`embeddings-and-external-models` territory and is shown as a placeholder.

Three results are worth stating because they decide the design:

1. A row level security filter predicate on the chunk table **was enforced through approximate
   vector search**. A policy restricting a test corpus to half its rows returned 100 of 200 on a
   plain count, and approximate search over the vector index returned only rows from the permitted
   half.
2. `ALTER TABLE ... ALTER COLUMN` to change a vector dimension failed **on an empty table**. There
   is no widening path.
3. `CREATE VECTOR INDEX` on a table with 50 rows failed on the 100 row minimum, and the same
   statement on 500 rows succeeded. Nothing about the queries changed when the index appeared,
   which is why an environment can silently run without one.

## Schema

```sql
CREATE TABLE dbo.documents (
    document_id   INT           NOT NULL IDENTITY PRIMARY KEY,
    tenant_id     INT           NOT NULL,
    title         NVARCHAR(400) NOT NULL,
    body          NVARCHAR(MAX) NOT NULL,
    updated_at    DATETIME2(3)  NOT NULL CONSTRAINT df_documents_updated DEFAULT SYSUTCDATETIME()
);

CREATE TABLE dbo.document_chunks (
    chunk_id      INT           NOT NULL IDENTITY PRIMARY KEY,
    document_id   INT           NOT NULL REFERENCES dbo.documents (document_id),
    tenant_id     INT           NOT NULL,
    ordinal       INT           NOT NULL,
    chunk_text    NVARCHAR(MAX) NOT NULL,
    source_hash   BINARY(32)    NOT NULL,
    embed_model   SYSNAME       NOT NULL,
    embed_dims    SMALLINT      NOT NULL,
    embedded_at   DATETIME2(3)  NULL,
    embedding     VECTOR(1536)  NULL
);

CREATE UNIQUE INDEX ux_chunks_identity ON dbo.document_chunks (document_id, ordinal);
CREATE INDEX ix_chunks_tenant  ON dbo.document_chunks (tenant_id);
CREATE INDEX ix_chunks_pending ON dbo.document_chunks (embedded_at) WHERE embedding IS NULL;
```

`source_hash` is `HASHBYTES('SHA2_256', chunk_text)`. It exists because there is no equality
operator on a vector, so the embedding itself can never be a deduplication key.

## Idempotent ingest

Given a freshly chunked set for one document in `@incoming (ordinal, chunk_text)`:

```sql
MERGE dbo.document_chunks AS target
USING (
    SELECT @document_id AS document_id,
           @tenant_id   AS tenant_id,
           i.ordinal,
           i.chunk_text,
           HASHBYTES('SHA2_256', i.chunk_text) AS source_hash
    FROM @incoming AS i
) AS source
   ON target.document_id = source.document_id
  AND target.ordinal     = source.ordinal
WHEN MATCHED AND target.source_hash <> source.source_hash THEN
    UPDATE SET chunk_text  = source.chunk_text,
               source_hash = source.source_hash,
               embedding   = NULL,          -- text changed, so the vector is stale
               embedded_at = NULL
WHEN NOT MATCHED BY TARGET THEN
    INSERT (document_id, tenant_id, ordinal, chunk_text, source_hash, embed_model, embed_dims)
    VALUES (source.document_id, source.tenant_id, source.ordinal, source.chunk_text,
            source.source_hash, @embed_model, @embed_dims)
WHEN NOT MATCHED BY SOURCE AND target.document_id = @document_id THEN
    DELETE;                                 -- the document got shorter
```

The `WHEN MATCHED` branch is the whole point: unchanged text is left alone, so a re-run costs
nothing. `MERGE` against a table carrying a vector index is supported and the changes are
searchable after the transaction commits.

## Embedding pass

```sql
UPDATE TOP (200) c
   SET embedding   = /* embeddings-and-external-models: the model call for c.chunk_text */,
       embed_model = @embed_model,
       embed_dims  = @embed_dims,
       embedded_at = SYSUTCDATETIME()
  FROM dbo.document_chunks AS c
 WHERE c.embedding IS NULL;
```

Loop until it affects zero rows. The filtered index makes the predicate a seek rather than a scan
over a corpus that is mostly already embedded.

## Vector index, after the load

```sql
CREATE VECTOR INDEX vi_document_chunks
    ON dbo.document_chunks (embedding)
    WITH (METRIC = 'cosine', TYPE = 'diskann');
```

Fails with the 100 row minimum until the embedding pass has produced 100 non-null vectors. Because
of that minimum, the index cannot be part of a data-tier package import, which creates objects
before loading rows.

## Retrieval

```sql
DECLARE @q VECTOR(1536) = /* the question, embedded with @embed_model */;

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

To fetch the neighbours of a hit for a wider grounding window:

```sql
SELECT ordinal, chunk_text
FROM dbo.document_chunks
WHERE document_id = @document_id
  AND ordinal BETWEEN @ordinal - 1 AND @ordinal + 1
ORDER BY ordinal;
```

## Row level security on the chunk table

```sql
CREATE FUNCTION dbo.fn_chunk_tenant (@tenant_id INT)
RETURNS TABLE
WITH SCHEMABINDING
AS
    RETURN SELECT 1 AS is_visible
           WHERE @tenant_id = CAST(SESSION_CONTEXT(N'tenant_id') AS INT);
GO

CREATE SECURITY POLICY dbo.chunk_access
    ADD FILTER PREDICATE dbo.fn_chunk_tenant (tenant_id) ON dbo.document_chunks
    WITH (STATE = ON);
```

Measured: with an equivalent policy in place, approximate vector search returned only rows the
predicate allowed. The policy on `dbo.documents` does **not** cover `dbo.document_chunks`, because
they are different tables. Both need one.

## Detecting a mixed corpus

```sql
SELECT embed_model, embed_dims, COUNT(*) AS chunks, MIN(embedded_at) AS first_seen
FROM dbo.document_chunks
WHERE embedding IS NOT NULL
GROUP BY embed_model, embed_dims;
```

One row is healthy. Two or more means distances are being compared across incompatible geometries,
and no statement anywhere will have failed. Put this query in a scheduled check, not in a runbook.

```sql
SELECT COUNT(*) AS unembedded FROM dbo.document_chunks WHERE embedding IS NULL;
```

Non-zero after an ingest means part of the corpus is invisible to retrieval, silently.

## Changing the model or the chunking

1. Add a second column, for example `embedding_v2 VECTOR(1024)`, with its own provenance columns.
   The existing column cannot be altered to a different dimension, even when empty.
2. Backfill it completely, with retrieval still running against the old column.
3. Create the new vector index. One vector index per column, so the two coexist.
4. Cut the retrieval query over.
5. Drop the old index, then the old columns.

For a near total replacement of embeddings in place, drop and recreate the vector index after the
load. The graph was built for the previous distribution and recall degrades without any error.

## Failure modes and what they look like

| Symptom | Cause | Where it is caught |
|---|---|---|
| Answers quote documents the user should not see | No predicate on the chunk table | Nowhere, until someone reports it. The security policy above is the gate |
| Answers get vaguer after a model change | Two models' vectors in one column | The group by above |
| Retrieval is correct but slow, and slows as the corpus grows | The query shape never reaches the vector index | The execution plan. `vector-search-azure-sql` |
| Filtered results return fewer rows than asked for | The filter is being applied after retrieval in application code | Compare row counts with the predicate moved into the query |
| Part of the corpus is never retrieved | Rows with a null embedding | The unembedded count above |
| The whole ingest fails at `CREATE TABLE` | A 3072 dimension model against the 1998 ceiling | Immediately, and after the pipeline was written |
| Deployment fails on import | The vector index is in the schema package | The import, on the 100 row minimum |
