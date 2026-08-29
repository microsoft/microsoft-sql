# Local to cloud parity, measured 2026-08-28

## Contents

- [How this was run](#how-this-was-run)
- [The side by side run](#the-side-by-side-run)
- [Break 1: outbound calls](#break-1-outbound-calls)
- [Break 2: row level security and the vector index](#break-2-row-level-security-and-the-vector-index)
- [Break 3: managed identity](#break-3-managed-identity)
- [The thing that is not an engine difference](#the-thing-that-is-not-an-engine-difference)
- [The offline loop, end to end](#the-offline-loop-end-to-end)
- [Timings](#timings)
- [Claims that did not hold](#claims-that-did-not-hold)
- [Reproducing this](#reproducing-this)

## How this was run

One script, two connections, nothing else different.

- **Local.** The Azure SQL Database container, product version 12.0.2000.8, connected as the
  administrative login over a published port.
- **Cloud.** An Azure SQL Database provisioned for the run: General Purpose serverless, two vCores,
  compatibility level 170, Microsoft Entra authentication only. Deleted after the run.

Both reported `SERVERPROPERTY('EngineEdition')` of 5 and `SERVERPROPERTY('Edition')` of `SQL Azure`.

The corpus was 140 fabricated sentences embedded by a local embedding model producing 768
dimensions. The **same vectors** were inserted into both engines, so any difference in the results
is the engine and not the model.

## The side by side run

| Step | Container | Cloud | Same |
|---|---|---|---|
| `CREATE TABLE` with a `vector(768)` column | OK | OK | yes |
| Insert 140 rows | OK | OK | yes |
| `SELECT TOP (3) ... ORDER BY VECTOR_DISTANCE('cosine', ...)` | 0.387729 / 0.587393 / 0.587521 | 0.387729 / 0.587393 / 0.587521 | **yes, to six decimal places** |
| Top three rows and their order | identical text | identical text | yes |
| `CREATE VECTOR INDEX ... WITH (METRIC='cosine', TYPE='diskann')` | OK | OK | yes |
| The index visible in `sys.vector_indexes` | OK | OK | yes |
| `SELECT TOP (3) WITH APPROXIMATE ... FROM VECTOR_SEARCH(...)` | same three rows, same distances | same three rows, same distances | yes |
| `TRUNCATE TABLE` on the indexed table | `Msg 42232` | `Msg 42232` | yes |
| `AI_GENERATE_CHUNKS(... chunk_type = FIXED ...)` | same chunks, offsets and lengths | same | yes |
| `CREATE EXTERNAL MODEL` against a host that does not exist | OK, DDL validates nothing | OK | yes |
| Calling that model | `Msg 31625`, DNS failure | `Msg 31625`, DNS failure | yes |
| `sp_invoke_external_rest_endpoint` to a public non-Azure host | **HTTP 200 with a body** | **`Msg 31612`** | **no** |

Everything above the last row is the storage and retrieval half of a retrieval pipeline, and it is
the half people doubt. It matched.

Two details worth carrying forward, both properties of the type rather than of either environment:
`SIMILAR_TO` needs a variable rather than an inline cast, and the dimension in a cast is a literal.
Both failed identically on both engines.

## Break 1: outbound calls

| Probe | Container | Cloud |
|---|---|---|
| `sp_invoke_external_rest_endpoint` to `https://api.github.com/rate_limit` | HTTP 200, full body returned | `Msg 31612, Connections to the domain api.github.com are not allowed` |
| `http://` location on an external model | `Msg 31610` | `Msg 31610` |
| Hostname resolving to a private address | `Msg 31624` | not applicable |
| Self signed or untrusted root certificate | `Msg 31608, HRESULT 0x80070008` | not applicable |
| Expired certificate | `Msg 31608, HRESULT 0x80070020` | not applicable |

The container has **no domain allowlist**. The cloud has one, and it refuses before DNS resolution,
so a blocked domain and a non-existent host produce visibly different errors. That is what makes
the cloud allowlist measurable, and the probe belongs to `embeddings-and-external-models`.

The certificate row was pinned down rather than inferred. A private certificate authority was
generated, an HTTPS endpoint was served with it, that authority was installed into the container's
operating system trust store using the distribution's own tooling, and a command line client
running inside the same container then accepted the endpoint. The engine still refused it with
`Msg 31608`, before and after a container restart. The engine does not use the container's trust
store, so there is no supported route from the engine to a locally hosted endpoint.

## Break 2: row level security and the vector index

Same table, same 200 rows, same filter predicate function, run in both orders on both engines.

| Order | Container | Cloud |
|---|---|---|
| Vector index first, then `CREATE SECURITY POLICY` | `Msg 37579, The security policy '<name>' cannot reference tables with vector indexes. Table '<table>' has a vector index` | **OK** |
| Security policy first, then `CREATE VECTOR INDEX` | `Msg 42244, A vector index cannot be created on tables with security policies. Table '<table>' has security policy '<name>'` | **OK** |
| The policy filtering rows before the index exists | OK, 100 of 200 rows visible | OK, 100 of 200 rows visible |

The predicate itself works locally. It is the **combination** with a vector index that the container
refuses, in both directions, so there is no ordering trick that gets both.

This is the parity break that costs the most, because the predicate on the chunk table is the
control that stops a retrieval pipeline putting text into a prompt that the asking user may not
read. It has to be exercised somewhere: on an unindexed local table, or in the cloud.

## Break 3: managed identity

| Attempt | Container | Cloud |
|---|---|---|
| `IDENTITY = 'Managed Identity'` with the `resourceid` secret | `Msg 31644, Server Managed Identity is disabled for this instance of SQL Server. Use sp_configure 'allow server scoped db credentials' to enable it` | embedding returned |
| The `sp_configure` that message names | `Msg 40510, Statement 'CONFIG' is not supported in this version of SQL Server` | not needed |
| A key held in a database scoped credential | embedding returned | embedding returned |

The container's error names a remedy the container cannot execute. Use a key locally and an
identity in the cloud, and keep the difference in the credential object rather than in the code
that names it.

## The thing that is not an engine difference

A local embedding model and a hosted one are different models. Two consequences that the parity
table above cannot show, because the same vectors were used on both sides:

1. **The dimension is usually different.** A common local model emits 768; a widely used hosted
   model defaults to 1536. The declared `vector(n)` cannot be altered afterwards, even on an empty
   table.
2. **Even at the same dimension the geometries are unrelated.** Distances computed across two
   models are meaningless, no statement fails, and the only symptom is that answers get worse. That
   failure and its detection query belong to `rag-on-azure-sql`.

The mitigation is measurable and cheap. A hosted model whose default is 1536 returned a 768
dimension vector when its external model definition carried `PARAMETERS = '{"dimensions":768}'`, and
512 when asked for 512. Asking for the local model's dimension keeps the column, the index and the
migration path intact, and reduces the move to an `UPDATE` that rewrites the vectors.

## The offline loop, end to end

Run on the container with a local embedding model and a local generation model, with no cloud
account and no key:

| Stage | Result |
|---|---|
| Embed 152 fabricated chunks | 0.8 s |
| Insert and build the vector index | index created, 152 rows |
| Filtered approximate search for a question belonging to tenant 2 | returned only the tenant 2 row, distance 0.1898 |
| The same search for tenant 1 | returned only tenant 1 rows, nearest distance 0.5040 |
| Grounded answer from a local generation model | 2.3 s, correct and taken from the retrieved context |

The tenant filter here is the `WHERE` clause inside the retrieval query, not a security policy,
because of break 2. That is the shape to test locally, and the policy is added in the cloud.

## Timings

Same 140 rows, same vectors, same statements.

| Operation | Container | Cloud |
|---|---|---|
| Insert 140 rows with a 768 dimension vector | 766 ms | 16851 ms |
| Exact top three by distance | 16 ms | 150 ms |
| Approximate top three over the vector index | 44 ms | 126 ms |
| `CREATE VECTOR INDEX` over 140 rows | 145 ms | 276 ms |

The insert gap is 22 times, and it is network round trips against a serverless database rather than
an engine difference. It is the honest argument for the inner loop living on the laptop.

## Claims that did not hold

1. **The shipped container skill says `CREATE VECTOR INDEX` is still in development on the container
   and advises full scan search.** Measured on this image the index built in 145 ms, appeared in
   `sys.vector_indexes`, and approximate search over it returned the same rows as the exact query.
   That guidance is stale.
2. **"The container is the same engine, so anything local holds in the cloud."** True for the whole
   storage and retrieval surface, to six decimal places. False for outbound policy, for row level
   security next to a vector index, and for managed identity.
3. **"The container is a subset of the cloud."** It is not. It permits outbound calls the cloud
   refuses, and refuses a combination the cloud allows.
4. **"Only the connection string changes."** True of the code. Not true of the credential, the
   endpoint, the security policy or the stored vectors.

## Reproducing this

The two cheapest checks, and the two most likely to change.

The outbound difference, run the same statement on both:

```sql
DECLARE @response NVARCHAR(MAX), @return INT;
EXEC @return = sp_invoke_external_rest_endpoint
     @url = 'https://api.github.com/rate_limit', @method = 'GET',
     @response = @response OUTPUT;
SELECT @return AS return_code, LEFT(@response, 200) AS response;
```

A body means no allowlist. `Msg 31612` means there is one.

The security policy difference, on a table with at least 100 rows carrying a non null vector:

```sql
CREATE VECTOR INDEX vi_t ON dbo.t (embedding) WITH (METRIC = 'cosine', TYPE = 'diskann');

CREATE FUNCTION dbo.fn_t (@t INT) RETURNS TABLE WITH SCHEMABINDING AS
    RETURN SELECT 1 AS ok WHERE @t = CAST(SESSION_CONTEXT(N'tenant_id') AS INT);
GO
CREATE SECURITY POLICY dbo.p_t
    ADD FILTER PREDICATE dbo.fn_t (tenant_id) ON dbo.t WITH (STATE = ON);
```

The last statement succeeds in the cloud and fails on the container with `Msg 37579`. Reverse the
order and the container fails on the index instead, with `Msg 42244`.
