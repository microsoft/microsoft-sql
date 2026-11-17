# The pipeline, in full

## Contents

- [What decides the design](#what-decides-the-design)
- [Schema](#schema)
- [Idempotent ingest](#idempotent-ingest)
- [Embedding pass](#embedding-pass)
- [Vector index, after the load](#vector-index-after-the-load)
- [Retrieval](#retrieval)
- [Row level security and the vector index](#row-level-security-and-the-vector-index)
- [Detecting a mixed corpus](#detecting-a-mixed-corpus)
- [Changing the model or the chunking](#changing-the-model-or-the-chunking)
- [Failure modes and what they look like](#failure-modes-and-what-they-look-like)

## What decides the design

The statements below run as written, apart from the embedding call, which is
`embeddings-and-external-models` territory and is a placeholder.

Three facts decide the design:

1. Whether a security policy can sit on a table carrying a vector index is **build-dependent and
   undocumented**: earlier container builds and SQL Server 2025 refuse it (`Msg 37579`, or
   `Msg 42244` for the index after the policy); Azure SQL Database and container build
   18.0.310.0_253 accept it in either order, but approximate search under the policy does not use
   the index. The advice in step 6 does not depend on which is true. See below.
2. A vector column's dimension cannot be changed by `ALTER COLUMN` even on an empty table, and
   `CREATE VECTOR INDEX` fails below 100 rows. Both are `vector-search-azure-sql`, which has checks
   for them; they are noted here only because they decide the schema.
3. Nothing about the queries changes when the index appears, which is why an environment can
   silently run without one and only latency says so.

## Schema

The canonical schema is `SKILL.md` step 2, deliberately not repeated here: two copies of a
`CREATE TABLE` drift. `embedded_at` is nullable there because the ingest below never supplies it.

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

On earlier container builds these two statements are **refused** while `dbo.document_chunks`
carries a vector index:

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

On container build 18.0.310.0_253 the same statements **succeed**, in this order and in the
reverse one, and the filter holds through `TOP (n) WITH APPROXIMATE` with no cross-tenant rows.
But the index is not used under the policy: the same query with `WITH (FORCE_ANN_ONLY)` fails with
`Msg 8622`, and without the hint it returns rows from an exact search, while an identical table
with no policy and the tenant test written as a `WHERE` clause gets a `Vector Index Seek`. Azure SQL
Database behaves the same way: the pair is accepted in both orders, the filter holds, and
`WITH (FORCE_ANN_ONLY)` under the policy fails with `Msg 8622`. SQL Server 2025 refuses the pair
with the two numbers above.

The policy on `dbo.documents` does **not** reach the chunk copy either way. So on the retrieval path
treat the query's `WHERE` clause as the tenant boundary. Three sourced ways to live with that:

1. Keep the filter in the query and wrap a test around it: run the retrieval with the filter and
   without it, and require different row counts. That test is security code now.
2. Drop the vector index on the tenant-scoped table. `VECTOR_SEARCH` still runs without one as a
   brute force scan and a policy can then be created, which gives back what the index was for.
3. Split the table: the index on an embeddings table with no policy, the chunk text and tenant
   column on a policy-bearing table joined back, the shape of Learn's multi-table example. The
   predicate then sits on the joined table, and Learn labels only the searched table's predicate an
   iterative filter, so expect post-filter behaviour.

**None of this is documented.** Learn's `CREATE VECTOR INDEX` limitations list names
partitioning, replication, `TRUNCATE TABLE` and package import, the `vector` type's limitations
page names constraints, indexes, ledger tables and Always Encrypted, and row-level security's
cross-feature list does not mention vectors; none mentions security policies on vector-indexed
tables. `Msg 37579` and `Msg 42244` both exist in the engine's `sys.messages`, but build
18.0.310.0_253 and Azure SQL Database do not raise them for this pair. Because nothing documents
the behaviour it can change without notice, so run the three checks in `SKILL.md` step 6 on the
target database before promising a reviewer anything.

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
| Answers quote documents the user should not see | The retrieval query has no tenant filter, and no verified policy supplies one | Nowhere, until someone reports it. Only a test on the query catches it |
| Answers get vaguer after a model change | Two models' vectors in one column | The group by above |
| Retrieval is correct but slow, and slows as the corpus grows | The query shape never reaches the vector index | The execution plan. `vector-search-azure-sql` |
| Filtered results return fewer rows than asked for | The filter runs in application code, or the index is an earlier version that post-filters | `index_version`, and the count with the predicate moved into the query |
| Part of the corpus is never retrieved | Rows with a null embedding | The unembedded count above |
| `CREATE SECURITY POLICY` is refused | The target table carries a vector index, on an engine build that refuses the pair | `Msg 37579`, at once (or `Msg 42244` for the index after the policy). The query's filter is the boundary |
| Approximate retrieval under a policy is slow | The policy is accepted but the search no longer uses the vector index | The plan has no `Vector Index Seek`; `WITH (FORCE_ANN_ONLY)` fails with `Msg 8622` |
