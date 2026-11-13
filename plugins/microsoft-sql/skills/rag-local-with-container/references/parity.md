# Container and cloud parity: what holds, what breaks, and checks you can run

## Contents

- [Comparing the two engines](#comparing-the-two-engines)
- [Storage and retrieval behave the same](#storage-and-retrieval-behave-the-same)
- [Break 1: the container has no outbound allowlist](#break-1-the-container-has-no-outbound-allowlist)
- [Break 2: row level security beside a vector index depends on the build](#break-2-row-level-security-beside-a-vector-index-depends-on-the-build)
- [Break 3: the container refuses managed identity](#break-3-the-container-refuses-managed-identity)
- [The thing that is not an engine difference](#the-thing-that-is-not-an-engine-difference)
- [The offline loop runs end to end](#the-offline-loop-runs-end-to-end)
- [The container is faster, and why](#the-container-is-faster-and-why)
- [Claims that do not hold](#claims-that-do-not-hold)

## Comparing the two engines

Run one script over two connections, the Azure SQL Database container and an Azure SQL Database,
with nothing else different. Both report `SERVERPROPERTY('EngineEdition')` of 5 and
`SERVERPROPERTY('Edition')` of `SQL Azure`. Insert the **same vectors** into both engines, so any
difference in the results is the engine and not the model.

## Storage and retrieval behave the same

| Step | Container | Cloud | Same |
|---|---|---|---|
| `CREATE TABLE` with a `vector(768)` column | OK | OK | yes |
| Insert the rows | OK | OK | yes |
| `SELECT TOP (3) ... ORDER BY VECTOR_DISTANCE('cosine', ...)` | identical distances | identical distances | **yes** |
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
the half people doubt. It matches.

Two details worth carrying forward, both properties of the type rather than of either environment:
`SIMILAR_TO` needs a variable rather than an inline cast, and the dimension in a cast is a literal.
Both fail identically on both engines.

## Break 1: the container has no outbound allowlist

| Call | Container | Cloud |
|---|---|---|
| `sp_invoke_external_rest_endpoint` to `https://api.github.com/rate_limit` | HTTP 200, full body returned | `Msg 31612, Connections to the domain api.github.com are not allowed` |
| `http://` location on an external model | `Msg 31610` | `Msg 31610` |
| Hostname resolving to a private address | `Msg 31624` | not applicable |
| Self signed or untrusted root certificate | `Msg 31608, HRESULT 0x80070008` | not applicable |
| Expired certificate | `Msg 31608, HRESULT 0x80070020` | not applicable |

The container has **no domain allowlist**. The cloud has one, and it refuses before DNS resolution,
so a blocked domain and a non-existent host produce visibly different errors. That is what makes
the cloud allowlist testable, and the check belongs to `embeddings-and-external-models`.

A private certificate authority does not help. Install it into the container's operating system
trust store with the distribution's own tooling, and a command line client inside the same
container accepts the endpoint, but the engine still refuses it with `Msg 31608`, before and after a
container restart. The engine does not use the container's trust store, so there is no supported
route from the engine to a locally hosted endpoint.

To see the outbound difference, run the same statement on both:

```sql
DECLARE @response NVARCHAR(MAX), @return INT;
EXEC @return = sp_invoke_external_rest_endpoint
     @url = 'https://api.github.com/rate_limit', @method = 'GET',
     @response = @response OUTPUT;
SELECT @return AS return_code, LEFT(@response, 200) AS response;
```

The container returns a body, because it has no allowlist. Azure SQL Database returns `Msg 31612`,
because it has one.

## Break 2: row level security beside a vector index depends on the build

The same table and filter predicate function, in both orders, on both engines:

| Order | Earlier container builds | Cloud |
|---|---|---|
| Vector index first, then `CREATE SECURITY POLICY` | `Msg 37579, The security policy '<name>' cannot reference tables with vector indexes. Table '<table>' has a vector index` | succeeds |
| Security policy first, then `CREATE VECTOR INDEX` | `Msg 42244, A vector index cannot be created on tables with security policies. Table '<table>' has security policy '<name>'` | succeeds |
| The policy filtering rows before the index exists | OK, only the session's tenant rows visible | OK, only the session's tenant rows visible |

The predicate itself works locally. It is the **combination** with a vector index that earlier
container builds refuse, in both directions, so there is no ordering trick that gets both.

On container build 18.0.310.0_253 both orders are accepted. The filter holds through
`TOP (n) WITH APPROXIMATE` with no cross-tenant rows, but the vector index is not used under the
policy: `WITH (FORCE_ANN_ONLY)` fails with `Msg 8622`, while the same tenant test as a `WHERE` clause
on a table without a policy gets a `Vector Index Seek`. Azure SQL Database behaves the same way:
both orders succeed, the filter holds, and `WITH (FORCE_ANN_ONLY)` under the policy fails with
`Msg 8622`. SQL Server 2025 refuses the pair in both orders, like the earlier container builds.
Microsoft Learn documents none of these outcomes. On a current build the container rehearses the
cloud's behaviour, including the cost: retrieval under the policy is an exact scan. Rehearse the
query's own filter as the boundary either way, and confirm the policy on the target database.

To check a build, on a table with at least 100 rows carrying a non null vector:

```sql
CREATE VECTOR INDEX vi_t ON dbo.t (embedding) WITH (METRIC = 'cosine', TYPE = 'diskann');

GO
CREATE FUNCTION dbo.fn_t (@t INT) RETURNS TABLE WITH SCHEMABINDING AS
    RETURN SELECT 1 AS ok WHERE @t = CAST(SESSION_CONTEXT(N'tenant_id') AS INT);
GO
CREATE SECURITY POLICY dbo.p_t
    ADD FILTER PREDICATE dbo.fn_t (tenant_id) ON dbo.t WITH (STATE = ON);
```

On earlier container builds the last statement fails with `Msg 37579`, and reversing the order fails
on the index instead, with `Msg 42244`. On container build 18.0.310.0_253 both orders succeed,
without the index being used under the policy, and Azure SQL Database matches it. Of the checks here, this and the outbound call are the most likely to change between
builds.

This is the parity break that costs the most, because the predicate on the chunk table is the
control that stops a retrieval pipeline putting text into a prompt that the asking user may not
read. It has to be exercised somewhere: on an unindexed local table, or in the cloud.

## Break 3: the container refuses managed identity

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
table above cannot show, because it uses the same vectors on both sides:

1. **The dimension is usually different.** A common local model emits 768; a widely used hosted
   model defaults to 1536. The declared `vector(n)` cannot be altered afterwards, even on an empty
   table.
2. **Even at the same dimension the geometries are unrelated.** Distances computed across two
   models are meaningless, no statement fails, and the only symptom is that answers get worse. That
   failure and its detection query belong to `rag-on-azure-sql`.

The mitigation is cheap. A hosted model whose default is 1536 returns a 768 dimension vector when
its external model definition carries `PARAMETERS = '{"dimensions":768}'`, and 512 when asked for
512. Asking for the local model's dimension keeps the column, the index and the migration path
intact, and reduces the move to an `UPDATE` that rewrites the vectors.

## The offline loop runs end to end

In the container, with a local embedding model and a local generation model and no cloud account
or key, the whole loop runs: embed the chunks, insert them and build the vector index, run a
filtered approximate search, and ground an answer in the retrieved context. A filtered search for
a question belonging to one tenant returns only that tenant's rows.

The tenant filter here is the `WHERE` clause inside the retrieval query, not a security policy,
because of break 2. That is the shape to test locally, and the policy is added in the cloud.

## The container is faster, and why

With the same rows, vectors and statements, every operation is faster in the container than
against a serverless cloud database: row by row inserts by far the most, exact and approximate
top three less so, and `CREATE VECTOR INDEX` least. The insert gap is network round trips rather
than an engine difference. It is the honest argument for the inner loop living on the laptop.

## Claims that do not hold

1. **`CREATE VECTOR INDEX` is not "still in development" in the container, and full scan search is
   not the only option there.** The index builds, appears in `sys.vector_indexes`, and approximate
   search over it returns the same rows as the exact query. Guidance saying otherwise is stale.
2. **"The container is the same engine, so anything local holds in the cloud."** True for the whole
   storage and retrieval surface. False for outbound policy, for row level security next to a
   vector index, and for managed identity.
3. **"The container is a subset of the cloud."** It is not. It permits outbound calls the cloud
   refuses, and earlier builds refuse a combination the cloud can allow.
4. **"Only the connection string changes."** True of the code. Not true of the credential, the
   endpoint, the security policy or the stored vectors.
