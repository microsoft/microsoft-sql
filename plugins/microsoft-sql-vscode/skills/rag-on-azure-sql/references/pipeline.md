# The pipeline, in full

## Contents

- [What was measured](#what-was-measured)
- [Schema](#schema)
- [Idempotent ingest](#idempotent-ingest)
- [Embedding pass](#embedding-pass)
- [Vector index, after the load](#vector-index-after-the-load)
- [Retrieval](#retrieval)
- [Row level security and the vector index](#row-level-security-and-the-vector-index)
- [Detecting a mixed corpus](#detecting-a-mixed-corpus)
- [Changing the model or the chunking](#changing-the-model-or-the-chunking)
- [Failure modes and what they look like](#failure-modes-and-what-they-look-like)

## What was measured

Run on 2026-08-28 against an Azure SQL Database provisioned for it: General Purpose serverless,
two vCores, compatibility level 170, Microsoft Entra authentication only, and re-run 2026-09-03 as
this skill's probes, which is where `Msg 37579` comes from. Statements below ran as written, apart
from the embedding call, which is `embeddings-and-external-models` territory and is a placeholder.

Three results decide the design:

1. A security policy **cannot be created at all** on a table carrying a vector index, `Msg 37579`,
   measured 2026-09-03. This reverses what this file claimed on 2026-08-28 and changes the advice
   in step 6. See below.
2. A vector column's dimension could not be changed by `ALTER COLUMN` even on an empty table, and
   `CREATE VECTOR INDEX` failed on 50 rows and succeeded on 500. Both are `vector-search-azure-sql`
   and are probed there; they are noted here only because they decide the schema.
3. Nothing about the queries changed when the index appeared, which is why an environment can
   silently run without one and only latency says so.

## Schema

The canonical schema is `SKILL.md` step 2, deliberately not repeated here: two copies of a
`CREATE TABLE` drift, and this pair already had, with `embedded_at` declared `NOT NULL` in one file
and `NULL` in the other while the ingest below never supplied it.

`source_hash` is `HASHBYTES('SHA2_256', chunk_text)`. The rest of the reasoning is in that step.

## Idempotent ingest

For a freshly chunked set for one document in `@incoming (ordinal, chunk_text)`:

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

The `WHEN MATCHED` branch is the point: unchanged text is left alone, so a re-run costs nothing. `MERGE` against a table carrying a current vector index is supported, and Learn
lists full `INSERT`, `UPDATE`, `DELETE` and `MERGE` support with real time index maintenance as a
property of the latest index version specifically.

## Embedding pass

The batched `UPDATE` is `SKILL.md` step 4. Loop until it affects zero rows. The filtered index makes the predicate a seek rather than a scan
over a mostly embedded corpus.

## Vector index, after the load

`CREATE VECTOR INDEX`, the statement in `SKILL.md` step 5, fails on the 100 row minimum until the embedding pass has produced 100 non-null vectors. That
minimum is why the index cannot be part of a data-tier package import, which creates objects before
it loads rows.

## Retrieval

The query is `SKILL.md` step 6. The predicate sits inside it on purpose.
[VECTOR_SEARCH](https://learn.microsoft.com/sql/t-sql/functions/vector-search-transact-sql) states
that a current index version applies `WHERE` predicates **during** the search and an earlier one
applies them **after**, so on an earlier index the top eight is chosen first and the filter then
removes some of it. Read `index_version` before trusting a filtered top k to be full. The same page
fixes the `ORDER BY`: the distance column ascending and nothing else, `Msg 42271` otherwise, and
`Msg 42248` with no `ORDER BY`. Sort into reading order in an outer query.

To fetch the neighbours of a hit for a wider grounding window:

```sql
SELECT ordinal, chunk_text
FROM dbo.document_chunks
WHERE document_id = @document_id
  AND ordinal BETWEEN @ordinal - 1 AND @ordinal + 1
ORDER BY ordinal;
```

## Row level security and the vector index

These two statements are **refused** while `dbo.document_chunks` carries a vector index:

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

```output
Msg 37579, Level 16, State 1
The security policy 'dbo.chunk_access' cannot reference tables with vector indexes.
Table 'dbo.document_chunks' has a vector index.
```

The same two statements are correct against `dbo.documents`, which carries no vector index, and
that policy does **not** reach the chunk copy. So on the retrieval path the tenant boundary is the
query's `WHERE` clause and nothing else. Three sourced ways to live with that:

1. Keep the filter in the query and wrap a test around it: run the retrieval with the filter and
   without it, and require different row counts. That test is security code now.
2. Drop the vector index on the tenant-scoped table. `VECTOR_SEARCH` still runs without one as a
   brute force scan and a policy can then be created, which gives back what the index was for.
3. Split the table: the index on an embeddings table with no policy, the chunk text and tenant
   column on a policy-bearing table joined back, the shape of Learn's multi-table example. The
   predicate then sits on the joined table, and Learn labels only the searched table's predicate an
   iterative filter, so expect post-filter behaviour.

**This limitation is not documented.** Learn's `CREATE VECTOR INDEX` limitations list names
partitioning, the clustered primary key, replication, `TRUNCATE TABLE` and package import, and the
`vector` type's limitations page names constraints, indexes, ledger tables and Always Encrypted.
Neither mentions security policies, as of 2026-09-03. `Msg 37579` is this skill's own measurement,
and it contradicts what an earlier revision of this file recorded on 2026-08-28. That entry could
not be re-run, the refusal reproduces, so the refusal stands. Creating the policy **before** the
index was not measured, so do not plan around that order.

## Detecting a mixed corpus

Check 1 in `SKILL.md` is the query. One row is healthy. Two or more means distances are compared across incompatible geometries and no
statement anywhere will have failed. Put this in a scheduled check, not a runbook.

## Changing the model or the chunking

Add a second column, `embedding_v2 VECTOR(1024)` say, with its own provenance columns, because the
existing one cannot be altered to a different dimension even when empty. Backfill it completely
with retrieval still running against the old column, create its vector index, which coexists
because there is one per column, cut the query over, then drop the old index and columns.

For a near total in-place replacement, drop and recreate the vector index after the load: the graph
was built for the previous distribution and recall degrades with no error.

## Failure modes and what they look like

| Symptom | Cause | Where it is caught |
|---|---|---|
| Answers quote documents the user should not see | The retrieval query has no tenant filter, and no policy can supply one | Nowhere, until someone reports it. Only a test on the query catches it |
| Answers get vaguer after a model change | Two models' vectors in one column | The group by above |
| Retrieval is correct but slow, and slows as the corpus grows | The query shape never reaches the vector index | The execution plan. `vector-search-azure-sql` |
| Filtered results return fewer rows than asked for | The filter runs in application code, or the index is an earlier version that post-filters | `index_version`, and the count with the predicate moved into the query |
| Part of the corpus is never retrieved | Rows with a null embedding | The unembedded count above |
| `CREATE SECURITY POLICY` is refused | The target table carries a vector index | `Msg 37579`, at once. There is no policy on the retrieval path; the query's filter is the boundary |
