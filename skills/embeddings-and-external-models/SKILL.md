---
name: embeddings-and-external-models
description: >-
  Generates embeddings and chunks inside Azure SQL Database with CREATE EXTERNAL MODEL,
  AI_GENERATE_EMBEDDINGS, AI_GENERATE_CHUNKS and sp_invoke_external_rest_endpoint, covering the
  database scoped credential naming rule, the permissions, the dimension budget that decides which
  embedding model can be used at all, and the outbound allowlist. Use when someone asks to "create an
  external model", "call AI_GENERATE_EMBEDDINGS", "embed text in T-SQL", "chunk text in the
  database", or "call an Azure OpenAI endpoint from SQL"; and when such a call fails on the
  credential, on permissions, on HTTPS, on managed identity or on a blocked domain. This skill owns
  producing the vector and calling out of the engine; storing and searching it is
  vector-search-azure-sql, the pipeline around it is rag-on-azure-sql, and embedding offline is
  rag-local-with-container.
---

# Embeddings and external models in Azure SQL Database

How the engine itself produces a vector, and how it is allowed to reach a model. Verified 2026-08-28
against **both** a live Azure SQL Database (General Purpose serverless, compatibility level 170) and
the local container, using a **real Azure OpenAI deployment created for the run**. Option lists and
limits were re-sourced from Microsoft Learn on 2026-09-03.

`AI_GENERATE_CHUNKS` splits text and `CREATE EXTERNAL MODEL` registers an endpoint; neither touches
the network. `AI_GENERATE_EMBEDDINGS` and `sp_invoke_external_rest_endpoint`, the call it builds
on, both do, and that is where everything below goes wrong. All four work in the container
as well as in the cloud: the 2026 catalog note calling this surface cloud only was wrong, and a real
embedding call completed from inside a container.

## The correction

**`CREATE EXTERNAL MODEL` validates almost nothing.** Measured on both engines, the DDL accepted an
`http://` location, a host no allowlist permits, a credential whose name can never match, and a
deployment that does not exist. All of it succeeded and appeared in `sys.external_models`. Each
failure surfaces at the first `AI_GENERATE_EMBEDDINGS`, naming an object rather than the broken
rule:

| What is actually wrong | What the engine says |
|---|---|
| The location is `http://` | `Msg 31610, Accessing the external endpoint is only allowed via HTTPS` |
| The credential name is not a prefix of the location | `Msg 31630, The database scoped credential '<name>' cannot be used` |
| A managed identity credential with no `SECRET` | `Msg 33047, Fail to obtain or decrypt secret for credential '<name>'` |
| The caller lacks `EXECUTE` on the model | `Msg 15151, Cannot find the external model, or you do not have permission` |
| The domain is not on the cloud allowlist | `Msg 31612, Connections to the domain <host> are not allowed` |
| The key is wrong, or absent | `Msg 31742, Unrecoverable HTTP error 401 occured` |

**The create statement is not the test. The first call is.** Being wrong costs a pipeline that
deploys clean, passes every schema gate, and fails on the first row of the first ingest, pointing at
a credential, object or permission that is present and correct.

## Which model fits, and it is not the best one

A `vector` column holds at most **1998 dimensions** at the default `float32` base type. Learn's
Azure OpenAI model table gives the outputs:

| Model | Output dimensions | Fits a vector column |
|---|---|---|
| `text-embedding-3-small` | 1536 | Yes |
| `text-embedding-ada-002` | 1536 | Yes, and it accepts no `dimensions` parameter |
| `text-embedding-3-large` | 3072 | **No, not at its default** |

`text-embedding-3-large` is what an agent reaches for because Learn's benchmark table scores it
highest, and its 3072 dimension output fits no column this engine can declare. Only third generation
models accept `dimensions`, so the fix is one JSON property on the model,
`PARAMETERS = '{"dimensions":1536}'`, not a comment. Learn's `float16` base type doubles the ceiling
to 3996, on a page that excludes Azure SQL Database and behind `PREVIEW_FEATURES`, so do not design
around it. `vector-search-azure-sql` owns the column and the ceiling; this skill owns making the
model return a number that fits.

## Step 1: chunk, which needs nothing but compatibility level 170

`AI_GENERATE_CHUNKS` runs with no endpoint, no credential and no permission: a user holding only
`db_datareader` ran it on both engines. Below compatibility level 170 Learn states the engine cannot
find the function, which reads as a missing feature rather than a setting.

```sql
SELECT t.doc_id, c.chunk_set_id, c.chunk_order, c.chunk_offset, c.chunk
FROM dbo.documents AS t
CROSS APPLY AI_GENERATE_CHUNKS(source = t.body, chunk_type = FIXED, chunk_size = 400,
                               overlap = 10, enable_chunk_set_id = 1) AS c;
```

- **`overlap` is a percentage of `chunk_size`, not a character count.** Learn states a whole number
  from 0 to 50, applied to `chunk_size`. Measured at `chunk_size = 40, overlap = 10` the second chunk
  started at offset 37: four characters back, not ten. Read as characters it silently changes how
  much context every chunk carries, and 50 is a hard ceiling.
- **`chunk_type = FIXED` is a keyword, and the only one.** `chunk_type = N'FIXED'` is `Msg 102`, and
  so are `SENTENCE`, `PARAGRAPH`, `RECURSIVE`, `SEMANTIC`, `TOKEN` and `WORD`. Learn lists `FIXED`
  alone, so semantic boundaries are work done outside this function.
- **`chunk_size` is characters, is required with `FIXED`, and splits mid word.** Measured at 40 the
  second chunk began `azy dog. Azure SQL Database stores vecto`. It also keeps a chunk under the
  model's 8192 token limit.
- **`enable_chunk_set_id = 1` is what makes a `CROSS APPLY` usable.** Without it `chunk_order`
  restarts at 1 per row and nothing records which row a chunk came from.

## Step 2: the credential, where the naming rule lives

```sql
CREATE MASTER KEY ENCRYPTION BY PASSWORD = '<a strong password>';   -- once per database

CREATE DATABASE SCOPED CREDENTIAL [https://<resource>.openai.azure.com/]
WITH IDENTITY = 'HTTPEndpointHeaders', SECRET = '{"api-key":"<the key>"}';
```

**The name of the credential is not a label. It is the match key.** Learn requires a valid URL on an
allowed domain, no query string, matching the called URL on protocol, fully qualified domain name
and every path segment, and more generic than it: a longest prefix match. So both
`https://<resource>.openai.azure.com/` and the fuller `.../openai/deployments/<name>/` work, while
`badcred` and a path segment the location lacks are both `Msg 31630`. That message reads like a
broken secret and is almost always the name instead. **The engine resolves the hostname before it
judges the name**, so an unresolvable host answers `Msg 31625` and hides the credential bug. Check
the prefix against the catalog offline, before regenerating any key.

**Managed identity is the production identity, and needs a resource in the secret.**

```sql
CREATE DATABASE SCOPED CREDENTIAL [https://<resource>.openai.azure.com/]
WITH IDENTITY = 'Managed Identity', SECRET = '{"resourceid":"https://cognitiveservices.azure.com"}';
```

Measured in the cloud: with no `SECRET` the call failed with `Msg 33047, Fail to obtain or decrypt
secret`, which sounds like a master key problem and is not. Adding `resourceid` fixed it. The server
also needs an identity holding a role on the target resource, and without it the failure is an HTTP
401, indistinguishable from a wrong key. **On the container managed identity does not work at all**:
`Msg 31644, Server Managed Identity is disabled for this instance`, whose named remedy cannot run
there either because `sp_configure` returns `Msg 40510`. Use a key locally and managed identity in
the cloud, changing only the credential.

## Step 3: the model

```sql
CREATE EXTERNAL MODEL text_embedder
WITH (
    LOCATION   = 'https://<resource>.openai.azure.com/openai/deployments/<deployment>/embeddings?api-version=2024-10-21',
    API_FORMAT = 'Azure OpenAI',
    MODEL_TYPE = EMBEDDINGS,
    MODEL      = 'text-embedding-3-small',
    CREDENTIAL = [https://<resource>.openai.azure.com/],
    PARAMETERS = '{"dimensions":1536, "sql_rest_options": {"retry_count": 3}}'
);
```

- **`MODEL_TYPE = EMBEDDINGS` is the only value there is.** Learn lists no other; `CHAT`,
  `COMPLETION`, `COMPLETIONS` and `RERANK` are all `Msg 102`. The engine makes a vector, never an
  answer, so the generation half of a pipeline stays in the application.
- **`API_FORMAT` is required and is not validated against the location.** Learn's four values are
  `Azure OpenAI`, `OpenAI`, `Ollama` and `ONNX Runtime`, the last a local runtime for a different
  engine. The first three were accepted whatever the URL pointed at. Omitting it is `Msg 46505`, an
  unlisted value `Msg 46508`.
- **`PARAMETERS` carries the dimension budget.** `'{"dimensions":768}'` returned a 768 dimension
  vector from a model defaulting to 1536, measured; a value the model cannot produce is
  `Msg 31742, Unrecoverable HTTP error 400`.
- **`PARAMETERS` also carries the retries.** `sql_rest_options.retry_count` takes 0 to 10 and retries
  HTTP 408, 429, 500, 502, 503 and 504, honouring `Retry-After`. It defaults to 0, so a model without
  it fails a whole batch on one rate limit response.
- **There is no `DROP EXTERNAL MODEL IF EXISTS`.** `Msg 156`; guard on `sys.external_models`. A
  credential a model still uses cannot be dropped either, `Msg 46556`: drop the model first.

## Step 4: permissions

| Action | Permission | Failure when missing |
|---|---|---|
| Create a model, or alter someone else's | `CREATE EXTERNAL MODEL`, `ALTER ANY EXTERNAL MODEL` | `Msg 262` |
| `AI_GENERATE_EMBEDDINGS ... USE MODEL m` | `EXECUTE ON EXTERNAL MODEL::m` | `Msg 15151`, the object appears not to exist |
| `sp_invoke_external_rest_endpoint` | `EXECUTE ANY EXTERNAL ENDPOINT` | `Msg 8189` |
| Naming a credential on a direct REST call | `REFERENCES` on that credential | denied on the credential |
| `AI_GENERATE_CHUNKS` | none | it just runs |

```sql
GRANT EXECUTE ON EXTERNAL MODEL::text_embedder TO [app_user];
-- the two below only if the caller invokes REST directly
GRANT EXECUTE ANY EXTERNAL ENDPOINT TO [app_user];
GRANT REFERENCES ON DATABASE SCOPED CREDENTIAL::[https://<resource>.openai.azure.com/] TO [app_user];
```

**The `EXECUTE` denial is the one that wastes an afternoon.** A caller without it is told the model
"does not exist or you do not have permission", so the obvious move is to recreate it, which changes
nothing. A caller going through `AI_GENERATE_EMBEDDINGS` needs neither of the other two grants,
because the model holds the credential: that is why to prefer it over raw REST.

## Step 5: the allowlist, which is a cloud rule and not a local one

**Azure SQL Database only calls hosts on a fixed allowlist**, and everything else is
`Msg 31612, Connections to the domain <host> are not allowed`, raised before DNS or TLS. Learn's
`sp_invoke_external_rest_endpoint` page carries the list and is the contract, so read it there and
not from any table, this skill's included. Two things that list is not:

- **Not "all of Azure".** Probed host by host in the cloud on 2026-08-28, `documents.azure.com`,
  `management.azure.com` and `azureml.ms` were refused while `openai.azure.com` and
  `blob.core.windows.net` were reached. Learn's route to a host off the list is API Management in
  front of it, since `*.azure-api.net` is on it.
- **Not enforced on the container at all.** The same call to a public non-Azure host returned HTTP
  200 locally and `Msg 31612` in the cloud, so a pipeline proved locally can be refused on its first
  cloud run by a policy no retry fixes.

Re-probe rather than quote: call a host that does not exist under that domain. `Msg 31625` means
the domain is permitted; `Msg 31612` means it is not.

Local hosting is closed off by two more container rules: a private address is `Msg 31624`, and a
certificate not chaining to a root the engine trusts is `Msg 31608`, a private authority in the
container's own trust store included, because the engine does not read that store. Learn's
`https://localhost:11435/api/embed` Ollama example is written for a differently hosted engine, so
embedding against a model server on the developer's machine is `rag-local-with-container`.

## Step 6: embed, in batches, never in one statement

```sql
UPDATE TOP (200) c
   SET embedding   = AI_GENERATE_EMBEDDINGS(c.chunk_text USE MODEL text_embedder),
       embed_model = 'text-embedding-3-small',
       embedded_at = SYSUTCDATETIME()
  FROM dbo.document_chunks AS c
 WHERE c.embedding IS NULL;
```

**One row is one HTTP round trip, and it does not parallelise.** One call took 295 ms and a 25 row
`UPDATE` took 8963 ms elapsed for 235 ms of CPU. So loop the statement above until it affects zero
rows: 200 rows is roughly a 70 second transaction, and the corpus is never one. Also:

- **`NULL` input is an error, not a `NULL` result.** `Msg 8116, Argument data type NULL is invalid`.
  Filter the nulls; an empty string is accepted and returns a real vector.
- **The returned dimension must match the target.** A 768 dimension result into a `vector(1536)` is
  `Msg 42204`, the one loud failure in this surface.
- **A per call override exists** when a job needs a different dimension or retry budget than the
  model carries: `AI_GENERATE_EMBEDDINGS(@t USE MODEL text_embedder PARAMETERS N'{"dimensions":768}')`.
- **Concurrency is capped**, at 10% of worker threads to a maximum of 150, and `Msg 10928` past it.
  Learn's query for the per database number reads `sys.dm_user_db_resource_governance`, cloud only
  and `Msg 208` on the container, so size parallelism in the cloud or not at all.
- Record which model produced each vector. The reason belongs to `rag-on-azure-sql`.

## Step 7: the general REST call, when no model type fits

The escape hatch, under the same allowlist, HTTPS and certificate rules.

```sql
DECLARE @response NVARCHAR(MAX), @return INT;
EXEC @return = sp_invoke_external_rest_endpoint
     @url         = 'https://<resource>.openai.azure.com/openai/deployments/<d>/embeddings?api-version=2024-10-21',
     @method = 'POST', @payload = @body, @headers = N'{"Accept":"application/json"}',
     @timeout = 60, @retry_count = 3,
     @credential = [https://<resource>.openai.azure.com/],
     @response = @response OUTPUT;

SELECT @return AS http_status, JSON_VALUE(@response, '$.response.status.http.code') AS code;
```

- **`@timeout` defaults to 30 seconds**, accepts 1 to 230, and becomes the cumulative budget once
  `@retry_count` is set; a slow endpoint fails on that default first.
- **`@return` is 0 for a 2xx and otherwise the HTTP status code.** Only a call that could not be made
  at all throws, so a procedure never reading `@return` treats a 429 as success. An unparseable `200`
  body is `Msg 11558`, which looks like a query bug and is a content type mismatch.

## Check it worked

Run these in the target database in order: each fails faster than the next.

```sql
-- 1. The model is registered. Expect one row per model, with the dimensions
--    you set visible in the parameters column, without parsing any DDL.
SELECT name, api_format, model_type_desc, model, parameters FROM sys.external_models;

-- 2. The credential name is a prefix of the location. The engine will not
--    report this until the host resolves, so check it here. Expect 'prefix ok'.
SELECT m.name, c.name AS credential,
       CASE WHEN c.name IS NULL THEN 'no credential, expect HTTP 401'
            WHEN LEFT(m.location, LEN(c.name)) = c.name THEN 'prefix ok'
            ELSE 'WILL FAIL WITH 31630' END AS naming
FROM sys.external_models AS m
LEFT JOIN sys.database_scoped_credentials AS c ON c.credential_id = m.credential_id;

-- 3. The application user holds EXECUTE and nothing wider. Expect one
--    EXTERNAL_MODEL row for it and no CREATE EXTERNAL MODEL row.
SELECT class_desc, permission_name, USER_NAME(grantee_principal_id) AS grantee
FROM sys.database_permissions
WHERE permission_name IN ('EXECUTE', 'CREATE EXTERNAL MODEL', 'EXECUTE ANY EXTERNAL ENDPOINT');

-- 4. Last, because it is the only one that leaves the engine: the endpoint
--    answers and its dimension matches the column. Expect one row reading
--    1536; a mismatch prints nothing and fails on Msg 42204, as it should.
DECLARE @v vector(1536) = AI_GENERATE_EMBEDDINGS(N'probe text' USE MODEL text_embedder);
SELECT COUNT(*) AS dimensions FROM OPENJSON(CAST(@v AS nvarchar(max)));
```

Run the file rather than pasting it, so a failure stops a pipeline instead of scrolling by:

```bash
# cloud, Microsoft Entra; use -U and -P against the container instead of -G
sqlcmd -S "$SQL_SERVER" -d "$SQL_DB" -G -b -m-1 -i check-embeddings.sql
```

`-b` sets a non-zero exit only at severity 11 and above, and this surface emits severity 10 messages:
`Msg 31616`, the overwritten `User-Agent` header, is one. Without `-m-1` those print their text with
no `Msg` number and the run looks clean, so use both.

## References

- [references/measured-external-model.md](references/measured-external-model.md): open it when a
  claim above needs re-verifying, or for the naming, permission, allowlist and certificate matrices
  and the statements reproducing them.
- [CREATE EXTERNAL MODEL](https://learn.microsoft.com/sql/t-sql/statements/create-external-model-transact-sql):
  read before changing `API_FORMAT`, `PARAMETERS` or `retry_count`.
- [AI_GENERATE_EMBEDDINGS](https://learn.microsoft.com/sql/t-sql/functions/ai-generate-embeddings-transact-sql):
  read for the extended events to turn on when a call fails without saying why.
- [AI_GENERATE_CHUNKS](https://learn.microsoft.com/sql/t-sql/functions/ai-generate-chunks-transact-sql):
  read before choosing a chunk type, the part of this surface most likely to grow.
- [sp_invoke_external_rest_endpoint](https://learn.microsoft.com/sql/relational-databases/system-stored-procedures/sp-invoke-external-rest-endpoint-transact-sql):
  read before depending on any host, for the current allowlist and the payload and header limits.
- `vector-search-azure-sql`: storing and searching the vector this skill produces.
- `rag-on-azure-sql`: the pipeline this call sits inside, and why provenance matters.
- `rag-local-with-container` and `azuresql-db-rag`: embedding offline from application code, where
  this in-database path is not available.
