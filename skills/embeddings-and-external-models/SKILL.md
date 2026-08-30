---
name: embeddings-and-external-models
description: >-
  Generates embeddings and chunks inside Azure SQL Database with CREATE EXTERNAL MODEL,
  AI_GENERATE_EMBEDDINGS, AI_GENERATE_CHUNKS and sp_invoke_external_rest_endpoint, including the
  database scoped credential naming rule, the permissions, and the endpoint allowlist that decides
  which hosts the engine is allowed to call at all. Use when someone asks to "create an external
  model", "call AI_GENERATE_EMBEDDINGS", "embed text in T-SQL", "chunk text in the database",
  "call an Azure OpenAI endpoint from SQL", "invoke a REST endpoint from the database", or
  "generate embeddings without an application"; and when an external endpoint call fails on the
  credential, on permissions, on HTTPS, on managed identity or on a domain that is not allowed.
  This skill owns producing the vector and calling out of the engine. Storing and searching it is
  vector-search-azure-sql, the retrieval pipeline around it is rag-on-azure-sql, and embedding
  offline against the local container is rag-local-with-container.
---

# Embeddings and external models in Azure SQL Database

This is how the engine itself produces a vector and how it is allowed to reach a model. It is not
a vector storage or similarity search reference.

Verified on 2026-08-28 by running every statement below against **both** a live Azure SQL Database
(General Purpose serverless, compatibility level 170, Microsoft Entra only) and the local Azure SQL
Database container, against a **real Azure OpenAI deployment created for the run**. The complete
runs, including the domain by domain allowlist probe, are in
[references/measured-external-model.md](references/measured-external-model.md).

## The four objects, and which one is the gate

| Object | What it is | Needs the network |
|---|---|---|
| `AI_GENERATE_CHUNKS` | Splits text into fixed size pieces. A table valued function | **No** |
| `CREATE EXTERNAL MODEL` | A named endpoint plus a credential. Metadata only | No |
| `AI_GENERATE_EMBEDDINGS` | Sends one string to that endpoint and returns a `vector` | Yes |
| `sp_invoke_external_rest_endpoint` | The general outbound call the other two are built on | Yes |

All four exist and work in the container as well as in the cloud. The 2026 catalog note that said
this surface was cloud only was wrong, and the correction was confirmed by running a real embedding
call from inside a container and getting a 1536 dimension `float32` vector back.

## The correction

**`CREATE EXTERNAL MODEL` validates almost nothing.** Measured on both engines, the DDL accepted
an `http://` location, a host that no allowlist would ever permit, a credential whose name can
never match, and a deployment that does not exist. All of it succeeded, and `sys.external_models`
listed it. Every one of those failures surfaces at the first `AI_GENERATE_EMBEDDINGS`, and each
one arrives as a message that names an object rather than the rule that was broken:

| What is actually wrong | What the engine says |
|---|---|
| The location is `http://` | `Msg 31610, Accessing the external endpoint is only allowed via HTTPS` |
| The credential name is not a prefix of the location | `Msg 31630, The database scoped credential '<name>' cannot be used to invoke an external rest endpoint` |
| A managed identity credential with no `SECRET` | `Msg 33047, Fail to obtain or decrypt secret for credential '<name>'` |
| The caller lacks `EXECUTE` on the model | `Msg 15151, Cannot find the external model '<name>', because it does not exist or you do not have permission` |
| The domain is not on the cloud allowlist | `Msg 31612, Connections to the domain <host> are not allowed` |
| The key is wrong, or absent | `Msg 31742, Unrecoverable HTTP error 401 occured` |

Read that table as one fact: **the create statement is not the test. The first call is.** Being
wrong here costs a pipeline that deploys clean, passes schema validation, and fails on the first
row of the first ingest with a message pointing at a credential, a missing object or a permission
that is all present and correct.

The second half of the correction is quieter. **`AI_GENERATE_EMBEDDINGS` is one HTTP round trip per
row and it does not parallelise.** Measured: a single call took 295 ms, and one `UPDATE` over 25
rows took 8963 ms of elapsed time for 235 ms of CPU. A set based `UPDATE` over a real corpus is
therefore a single transaction holding locks for hours, and it is the shape an agent writes first
because it is the shape SQL rewards everywhere else.

## Step 1: chunk, which needs nothing

`AI_GENERATE_CHUNKS` runs in the engine with no endpoint, no credential and no special permission.
A user with nothing but `db_datareader` ran it successfully on both engines.

```sql
SELECT chunk, chunk_order, chunk_offset, chunk_length
FROM AI_GENERATE_CHUNKS(source = @text, chunk_type = FIXED, chunk_size = 400, overlap = 40);
```

Three things a model gets wrong about it:

- **`chunk_type = FIXED` is a keyword, not a string.** `chunk_type = N'FIXED'` is `Msg 102`.
- **`FIXED` is the only chunk type.** `SENTENCE`, `PARAGRAPH`, `RECURSIVE`, `SEMANTIC`, `TOKEN` and
  `WORD` are all `Msg 102` on both engines. If the design needs sentence or semantic boundaries,
  that work happens outside this function.
- **The sizes are characters, not tokens, and it splits mid word.** Measured with `chunk_size = 40`
  the second chunk began `dog. Azure SQL Database stores vectors n`. `overlap` is also in
  characters and repeats that many characters at the start of the next chunk.

## Step 2: the credential, where the naming rule lives

```sql
CREATE MASTER KEY ENCRYPTION BY PASSWORD = '<a strong password>';   -- once per database

CREATE DATABASE SCOPED CREDENTIAL [https://<resource>.openai.azure.com/]
WITH IDENTITY = 'HTTPEndpointHeaders',
     SECRET   = '{"api-key":"<the key>"}';
```

**The name of the credential is not a label. It is the match key.** The engine picks a credential
by longest URL prefix against the model's `LOCATION`, so the name has to be a prefix of that URL.
Measured, with everything else correct:

| Credential name | Location | Result |
|---|---|---|
| `https://<resource>.openai.azure.com/` | `https://<resource>.openai.azure.com/openai/...` | Works |
| `https://<resource>.openai.azure.com/openai/deployments/<name>/` | the same location | Works, narrower |
| `badcred` | the same location | `Msg 31630` |
| `https://<resource>.openai.azure.com/mi/` | a location with no `/mi/` segment | `Msg 31630` |

`Msg 31630` names the credential and says it "cannot be used", which reads like a broken secret. It
is almost always the name. Check the name first, before the key.

**Managed identity is the production identity, and it needs the resource in the secret.**

```sql
CREATE DATABASE SCOPED CREDENTIAL [https://<resource>.openai.azure.com/]
WITH IDENTITY = 'Managed Identity',
     SECRET   = '{"resourceid":"https://cognitiveservices.azure.com"}';
```

Measured in the cloud: with `IDENTITY = 'Managed Identity'` and no `SECRET`, the call failed with
`Msg 33047, Fail to obtain or decrypt secret`, which sounds like a master key problem and is not.
Adding the `resourceid` secret made the same call succeed. The server also needs an identity
assigned and that identity needs a role on the target resource; without the role the failure is an
HTTP 401 rather than a credential error.

**Managed identity does not work on the container.** It answers `Msg 31644, Server Managed Identity
is disabled for this instance`, and the remedy that message names cannot be run there, because
`sp_configure` itself returns `Msg 40510, Statement 'CONFIG' is not supported`. Use a key locally,
managed identity in the cloud, and change only the credential.

## Step 3: the model

```sql
CREATE EXTERNAL MODEL text_embedder
WITH (
    LOCATION   = 'https://<resource>.openai.azure.com/openai/deployments/<deployment>/embeddings?api-version=2024-10-21',
    API_FORMAT = 'Azure OpenAI',
    MODEL_TYPE = EMBEDDINGS,
    MODEL      = 'text-embedding-3-small',
    CREDENTIAL = [https://<resource>.openai.azure.com/],
    PARAMETERS = '{"dimensions":768}'
);
```

- **`MODEL_TYPE = EMBEDDINGS` is the only value there is.** `CHAT`, `COMPLETION`, `COMPLETIONS` and
  `RERANK` are all `Msg 102`. The engine can produce a vector; it cannot produce an answer, so the
  generation half of a retrieval pipeline stays in the application.
- **`API_FORMAT` is required and is not validated against the location.** `'Azure OpenAI'`,
  `'OpenAI'` and `'Ollama'` were all accepted at create time on both engines, whatever the URL
  pointed at.
- **`PARAMETERS` is where the dimension budget is enforced.** `'{"dimensions":768}'` returned a 768
  dimension vector from a model whose default is 1536, measured. This is the mechanism for fitting
  under the engine's dimension ceiling and for keeping one column type across environments. A value
  the model cannot produce is `Msg 31742, Unrecoverable HTTP error 400`.
- **There is no `DROP EXTERNAL MODEL IF EXISTS`.** `Msg 156`. Guard on `sys.external_models`. A
  credential in use by a model also cannot be dropped, `Msg 46556`, so drop the model first.

## Step 4: permissions, all four of them

| Action | Permission | Failure when missing |
|---|---|---|
| `CREATE EXTERNAL MODEL` | `CREATE EXTERNAL MODEL` on the database | `Msg 262` |
| Alter or drop someone else's | `ALTER ANY EXTERNAL MODEL` | `Msg 15151` or `Msg 262` |
| `AI_GENERATE_EMBEDDINGS ... USE MODEL m` | `EXECUTE ON EXTERNAL MODEL::m` | `Msg 15151`, the object appears not to exist |
| `sp_invoke_external_rest_endpoint` | `EXECUTE ANY EXTERNAL ENDPOINT` | `Msg 8189` |
| `AI_GENERATE_CHUNKS` | none | it just runs |

```sql
GRANT EXECUTE ON EXTERNAL MODEL::text_embedder TO [app_user];
GRANT EXECUTE ANY EXTERNAL ENDPOINT TO [app_user];   -- only if the app calls REST directly
```

**The `EXECUTE` denial is the one that wastes an afternoon.** A caller without it is told the model
"does not exist or you do not have permission", so the obvious next move is to recreate the model,
which changes nothing. Confirm with `SELECT name FROM sys.external_models` as the owner, then grant.

## Step 5: the allowlist, which is a cloud rule and not a local one

**Azure SQL Database only calls hosts on a fixed allowlist.** Everything else is
`Msg 31612, Connections to the domain <host> are not allowed`, before any DNS lookup or TLS
handshake. Probed host by host in the cloud on 2026-08-28, a non-existent name under an allowed
domain fails DNS (`Msg 31625`) while a blocked domain fails with `Msg 31612`, which makes the
allowlist directly measurable:

| Allowed, reached DNS | Blocked with `Msg 31612` |
|---|---|
| `*.openai.azure.com`, `*.cognitiveservices.azure.com`, `*.services.ai.azure.com`, `*.inference.ai.azure.com` | `*.documents.azure.com` |
| `*.search.windows.net`, `*.vault.azure.net`, `*.azure-api.net`, `*.azurewebsites.net` | `management.azure.com` |
| `*.blob.core.windows.net`, `*.queue.core.windows.net`, `*.table.core.windows.net` | `*.azureml.ms` |
| `*.servicebus.windows.net`, `*.eventgrid.azure.net` | any host outside Azure |

Two of those are worth pausing on. **The list is not "all of Azure":** the Cosmos DB and resource
manager endpoints are refused. And **the container enforces no allowlist at all.** The same call to
a public non-Azure host returned HTTP 200 with a body locally and `Msg 31612` in the cloud. A
pipeline proved against the container can therefore fail on its first cloud run, and the failure is
a policy decision that no amount of retrying fixes.

Two more outbound rules, both measured on the container and both worth knowing before designing a
local endpoint:

- **A hostname that resolves to a private address is refused**, `Msg 31624`.
- **The certificate must chain to a root the engine trusts**, and the engine does not read the
  container's own trust store. A private certificate authority installed with the operating
  system's own tooling, trusted well enough that a command line client accepted it, still produced
  `Msg 31608, HRESULT 0x80070008`. An expired certificate gives the same message with HRESULT
  `0x80070020`.

## Step 6: embed, in batches, never in one statement

```sql
UPDATE TOP (200) c
   SET embedding   = AI_GENERATE_EMBEDDINGS(c.chunk_text USE MODEL text_embedder),
       embed_model = 'text-embedding-3-small',
       embedded_at = SYSUTCDATETIME()
  FROM dbo.document_chunks AS c
 WHERE c.embedding IS NULL;
```

Loop until it affects zero rows. At the measured 358 ms per row, 200 rows is roughly a 70 second
transaction, and the whole corpus is never one transaction. Also:

- **`NULL` input is an error, not a `NULL` result.** `Msg 8116, Argument data type NULL is invalid`.
  Filter the nulls; an empty string is accepted and returns a real vector.
- **The returned dimension must match the target.** A 768 dimension result assigned to a
  `vector(1536)` is `Msg 42204`, which is the one loud failure in the whole surface and the reason
  the dimension belongs in `PARAMETERS` rather than in a comment.
- Record which model produced each vector. The reason belongs to `rag-on-azure-sql` and it is the
  single most expensive omission in this pipeline.

## Step 7: the general REST call, when no model type fits

`sp_invoke_external_rest_endpoint` is the escape hatch, and the same allowlist, HTTPS and
certificate rules apply.

```sql
DECLARE @response NVARCHAR(MAX), @return INT;
EXEC @return = sp_invoke_external_rest_endpoint
     @url      = 'https://<resource>.openai.azure.com/openai/deployments/<deployment>/embeddings?api-version=2024-10-21',
     @method   = 'POST',
     @payload  = @body,
     @credential = [https://<resource>.openai.azure.com/],
     @response = @response OUTPUT;
```

- **The response has to be JSON.** A `200` carrying plain text is
  `Msg 11558, The @result JSON string could not be parsed`, which looks like a bug in the query and
  is a content type mismatch.
- A supplied `User-Agent` header is replaced by the engine and a warning says so.
- The result carries the status, the response headers and the body, so read
  `@response` as JSON rather than assuming a bare payload.

## Validation rules

- Every external model was called once, successfully, immediately after it was created. A model
  that has only been created has not been tested.
- The database scoped credential's name is a URL prefix of the model's `LOCATION`, and this was
  checked before any key was regenerated.
- The production credential uses managed identity with a `resourceid` secret, the server has an
  identity, and that identity holds a role on the target resource.
- No key, endpoint host name or resource name appears in source control. The credential holds the
  secret and the code names the credential.
- The dimension is set in `PARAMETERS` and equals the declared column dimension, and there is a
  test that fails if they diverge.
- Embedding runs in bounded batches with a null filter, and no statement embeds a whole table.
- The application caller holds `EXECUTE` on the model and nothing more; it does not own the model
  and does not hold `CREATE EXTERNAL MODEL`.
- Every endpoint the design depends on was checked against the cloud allowlist from a cloud
  database, not from the container.
- Chunking uses `chunk_type = FIXED` with sizes stated in characters, and the design does not
  assume a sentence or semantic boundary.

## Do not

- Do not treat a successful `CREATE EXTERNAL MODEL` as evidence that anything works. It validates
  neither the URL, the domain, the credential nor the deployment.
- Do not regenerate the key when the credential error appears. Check the credential name first.
- Do not use a bare managed identity credential with no secret and conclude the master key is
  broken.
- Do not expect managed identity to work against the container, and do not follow the remedy its
  error message names.
- Do not embed a whole table in one statement. One row is one HTTP call and one transaction is one
  long lock.
- Do not pass `NULL` text to the embedding function.
- Do not quote `FIXED`, and do not ask for a chunk type that does not exist.
- Do not assume an endpoint is reachable because it is an Azure endpoint. Two well known Azure
  domains are refused.
- Do not validate outbound access against the container. It has no allowlist, so it proves nothing
  about the cloud.
- Do not point an external model at a local endpoint with a private certificate. It is refused, and
  the local answer is `rag-local-with-container`.
- Do not teach the vector type, the distance function or the retrieval query here. Those belong to
  `vector-search-azure-sql` and `rag-on-azure-sql`.

## References

- [references/measured-external-model.md](references/measured-external-model.md): every statement
  run on both engines, the full allowlist probe, the credential naming matrix, the permission
  matrix, the timings behind the per row cost, and how to reproduce the whole set. Read it when a
  claim here needs re-verifying, which for a surface this new is often.
- [CREATE EXTERNAL MODEL](https://learn.microsoft.com/sql/t-sql/statements/create-external-model-transact-sql):
  the first party statement of the option list, the supported formats and the credential
  requirements. Read it before changing `API_FORMAT` or `PARAMETERS`.
- [AI_GENERATE_EMBEDDINGS](https://learn.microsoft.com/sql/t-sql/functions/ai-generate-embeddings-transact-sql):
  the function contract and its current availability.
- [AI_GENERATE_CHUNKS](https://learn.microsoft.com/sql/t-sql/functions/ai-generate-chunks-transact-sql):
  the chunk types that exist at the time you read it, which is the part most likely to grow.
- [sp_invoke_external_rest_endpoint](https://learn.microsoft.com/sql/relational-databases/system-stored-procedures/sp-invoke-external-rest-endpoint-transact-sql):
  the current allowlist, the credential forms and the response shape. Read this rather than
  trusting the table above, which is a measurement and not a contract.
- `vector-search-azure-sql`: storing the vector this skill produces, its dimension ceiling, and the
  query shape that searches it.
- `rag-on-azure-sql`: the pipeline this call sits inside, and why provenance matters.
- `rag-local-with-container`: embedding offline against the local container, where this in-database
  path is not available.
- `azuresql-db-rag`: the shipped container recipe that embeds from application code.
