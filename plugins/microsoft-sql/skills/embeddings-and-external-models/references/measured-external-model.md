# The external model surface: error matrices and checks you can run

## Contents

- [What the checks need](#what-the-checks-need)
- [What the DDL accepts without complaint](#what-the-ddl-accepts-without-complaint)
- [The credential naming matrix](#the-credential-naming-matrix)
- [Managed identity](#managed-identity)
- [The permission matrix](#the-permission-matrix)
- [The cloud allowlist, host by host](#the-cloud-allowlist-host-by-host)
- [Outbound rules in the container](#outbound-rules-in-the-container)
- [AI_GENERATE_CHUNKS](#ai_generate_chunks)
- [AI_GENERATE_EMBEDDINGS](#ai_generate_embeddings)
- [Cost: one round trip per row](#cost-one-round-trip-per-row)
- [Claims that do not hold](#claims-that-do-not-hold)

## What the checks need

The statements below behave the same on Azure SQL Database at compatibility level 170 and on the
Azure SQL Database container, both reporting `SERVERPROPERTY('EngineEdition')` 5, unless a table
separates them. The embedding calls need a real Azure OpenAI resource with a
`text-embedding-3-small` deployment, so that a call returns a real vector rather than a placeholder
failure.

## What the DDL accepts without complaint

All of these `CREATE EXTERNAL MODEL` statements **succeed** on both engines and appear in
`sys.external_models`. None of them can ever produce an embedding.

| Statement | Why it can never work |
|---|---|
| `LOCATION = 'http://host:11434/api/embed'` | Plain HTTP is refused at call time |
| `LOCATION = 'https://api.github.com/rate_limit'`, `API_FORMAT = 'OpenAI'` | Not an embedding endpoint, and blocked in the cloud |
| `API_FORMAT = 'Ollama'` against an Azure OpenAI URL | Format is never compared with the location |
| `CREDENTIAL = badcred` where the name is not a URL prefix | The credential can never be selected |
| A deployment name that does not exist | Discovered as an HTTP 404 at call time |

What the DDL **does** reject:

| Statement | Error |
|---|---|
| `API_FORMAT` omitted | `Msg 46505, Missing required external DDL option 'API_FORMAT'` |
| `API_FORMAT = 'NotAFormat'` | `Msg 46508, Incorrect syntax on external DDL option 'API_FORMAT'` |
| `MODEL_TYPE = CHAT`, `COMPLETION`, `COMPLETIONS`, `RERANK` | `Msg 102`. `EMBEDDINGS` is the only value |
| `DROP EXTERNAL MODEL IF EXISTS m` | `Msg 156, Incorrect syntax near the keyword 'IF'` |
| Dropping a credential still referenced by a model | `Msg 46556, Cannot drop the credential '<name>' because it is used by an external model` |

`sys.external_models` carries `location`, `api_format`, `model_type_desc`, `model`, `credential_id`
and a `parameters` column of type `json`, so everything above is readable back without parsing DDL.

## The credential naming matrix

Hold everything else constant: a real endpoint, a real key, a real deployment.

| Credential name | Model `LOCATION` | Result |
|---|---|---|
| `https://<res>.openai.azure.com/` | `https://<res>.openai.azure.com/openai/deployments/<d>/embeddings?api-version=...` | Embedding returned |
| `https://<res>.openai.azure.com/openai/deployments/<d>/` | the same | Embedding returned |
| `badcred` | the same | `Msg 31630` |
| `micred` | the same | `Msg 31630` |
| `https://<res>.openai.azure.com/mi/` | a location with no `/mi/` segment | `Msg 31630` |
| `https://<res>.openai.azure.com/openai/deployments/<d>/` with a deliberately wrong key | the same | `Msg 31742, Unrecoverable HTTP error 401` |
| no `CREDENTIAL` clause at all | the same | `Msg 31742, Unrecoverable HTTP error 401` |

The last two rows are what makes the rule testable. A wrong **name** never reaches the network and
gives `Msg 31630`. A wrong **key** reaches the network and gives a 401. If the message is 31630 the
key is irrelevant.

The cheapest check is two credentials over one endpoint: one named for the endpoint URL and one
named anything else, both holding the same key. The first returns a vector and the second returns
`Msg 31630`.

`CREATE MASTER KEY ENCRYPTION BY PASSWORD` is required once per database before the first
credential on both engines.

## Managed identity

| Attempt | Cloud | Container |
|---|---|---|
| `IDENTITY = 'Managed Identity'` with no `SECRET` | `Msg 33047, Fail to obtain or decrypt secret for credential '<name>'` | `Msg 31644` |
| `IDENTITY = 'Managed Identity'`, `SECRET = '{"resourceid":"https://cognitiveservices.azure.com"}'` | **Embedding returned** | `Msg 31644, Server Managed Identity is disabled for this instance of SQL Server. Use sp_configure 'allow server scoped db credentials' to enable it` |
| The `sp_configure` the container's message names | not applicable | `Msg 40510, Statement 'CONFIG' is not supported in this version of SQL Server` |

The cloud path additionally needs a system assigned identity on the logical server and a role
assignment for that identity on the target resource. Without the role the failure is an HTTP 401,
not a credential error, which is the same symptom as a wrong key.

The container row is a hard parity break: the error names a remedy the container cannot execute.

## The permission matrix

Start from a login and a database user holding `db_datareader` and `db_datawriter` and nothing
else, and repeat each action after each grant.

| Action | Without the permission | Permission that fixes it |
|---|---|---|
| `CREATE EXTERNAL MODEL` | `Msg 262, CREATE EXTERNAL MODEL permission denied in database '<db>'` | `GRANT CREATE EXTERNAL MODEL TO <user>` |
| `AI_GENERATE_EMBEDDINGS ... USE MODEL m` | `Msg 15151, Cannot find the external model 'm', because it does not exist or you do not have permission` | `GRANT EXECUTE ON EXTERNAL MODEL::m TO <user>` |
| `sp_invoke_external_rest_endpoint` | `Msg 8189, You do not have permission to run 'sys.sp_invoke_external_rest_endpoint'` | `GRANT EXECUTE ANY EXTERNAL ENDPOINT TO <user>` |
| `AI_GENERATE_CHUNKS` | runs with no grant at all | none |

`sys.fn_builtin_permissions(DEFAULT)` lists `CREATE EXTERNAL MODEL`, `ALTER ANY EXTERNAL MODEL` and
`EXECUTE ANY EXTERNAL ENDPOINT` as database permissions.
`sys.fn_builtin_permissions('EXTERNAL MODEL')` lists `VIEW DEFINITION`, `ALTER`, `TAKE OWNERSHIP`,
`EXECUTE` and `CONTROL` as the object level set.

After the grants, `sys.database_permissions` shows `CREATE EXTERNAL MODEL` and
`EXECUTE ANY EXTERNAL ENDPOINT` at class `DATABASE` and `EXECUTE` at class `EXTERNAL_MODEL`.

## The cloud allowlist, host by host

Call `sp_invoke_external_rest_endpoint` against `https://zzz-not-real.<domain>/`. A domain on the
allowlist gets far enough to attempt a DNS lookup and fails with
`Msg 31625, DNS resolution of the hostname has failed with windows sockets error 11001`. A domain
that is not on it fails earlier with `Msg 31612`.

| Domain | Cloud result |
|---|---|
| `openai.azure.com` | allowed, reaches DNS |
| `cognitiveservices.azure.com` | allowed, reaches DNS |
| `services.ai.azure.com` | allowed, reaches DNS |
| `inference.ai.azure.com` | allowed, reaches DNS |
| `search.windows.net` | allowed, reaches DNS |
| `vault.azure.net` | allowed, reaches DNS |
| `blob.core.windows.net` | allowed, reaches DNS |
| `queue.core.windows.net` | allowed, reaches DNS |
| `table.core.windows.net` | allowed, reaches DNS |
| `servicebus.windows.net` | allowed, reaches DNS |
| `eventgrid.azure.net` | allowed, reaches DNS |
| `azure-api.net` | allowed, reaches DNS |
| `azurewebsites.net` | allowed, reaches DNS |
| `documents.azure.com` | **`Msg 31612`** |
| `management.azure.com` | **`Msg 31612`** |
| `azureml.ms` | **`Msg 31612`** |
| `api.github.com` | **`Msg 31612`** |

Reaching DNS is evidence the domain is permitted, not evidence a real host under it will answer.
Treat this table as a snapshot of a policy that is expected to change, and probe rather than
quoting it. The probe is the cheapest check here and the one most likely to have moved:

```sql
DECLARE @response NVARCHAR(MAX), @return INT;
BEGIN TRY
    EXEC @return = sp_invoke_external_rest_endpoint
         @url = 'https://zzz-not-real.openai.azure.com/', @method = 'GET',
         @response = @response OUTPUT;
    SELECT 'reached the network' AS verdict;
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS error_number, ERROR_MESSAGE() AS message;
END CATCH;
```

`31625` means the domain is permitted. `31612` means it is not. Swap the host and repeat.

## Outbound rules in the container

The same calls in the container behave differently, and the difference is not a subset
relationship.

| Call | Container result |
|---|---|
| `sp_invoke_external_rest_endpoint` to `https://api.github.com/rate_limit` | **HTTP 200 with the full response body.** No allowlist |
| A `200` response whose body is not JSON | `Msg 11558, The @result JSON string could not be parsed` |
| A supplied `User-Agent` header | replaced, with a warning that says so |
| `http://` location | `Msg 31610, Accessing the external endpoint is only allowed via HTTPS` |
| A hostname resolving to a private address | `Msg 31624, Connection to the external endpoint IP is not allowed. URL contains a hostname that is resolved to a blocked IP` |
| A self signed certificate | `Msg 31608, HRESULT 0x80070008` |
| A certificate from an untrusted root | `Msg 31608, HRESULT 0x80070008` |
| An expired certificate | `Msg 31608, HRESULT 0x80070020` |
| A valid publicly trusted certificate | the call completes |

A private certificate authority does not help. Install it into the container's operating system
trust store with that distribution's own tooling, and a command line client inside the same
container accepts the endpoint, but the engine still returns `Msg 31608`, before and after a
restart. **The engine does not use the container's trust store**, so there is no supported way to
point an external model at a locally hosted endpoint.

## AI_GENERATE_CHUNKS

Identical on both engines, including the offsets.

```sql
SELECT chunk, chunk_order, chunk_offset, chunk_length
FROM AI_GENERATE_CHUNKS(source = N'The quick brown fox jumps over the lazy dog. Azure SQL Database stores vectors natively.',
                        chunk_type = FIXED, chunk_size = 40, overlap = 10);
```

| chunk | chunk_order | chunk_offset | chunk_length |
|---|---|---|---|
| `The quick brown fox jumps over the lazy ` | 1 | 1 | 40 |
| `azy dog. Azure SQL Database stores vecto` | 2 | 37 | 40 |
| `ectors natively.` | 3 | 73 | 16 |

- `chunk_type = N'FIXED'` quoted: `Msg 102, Incorrect syntax near 'FIXED'`.
- `SENTENCE`, `PARAGRAPH`, `RECURSIVE`, `SEMANTIC`, `TOKEN`, `WORD`: all `Msg 102` on both engines.
- `chunk_size` is characters. `overlap` is a percentage of `chunk_size`, a whole number from 0 to
  50, default 0: `overlap = 10` at `chunk_size = 40` is 4 characters, which is why the second chunk
  starts at offset 37. Word boundaries are not respected.

## AI_GENERATE_EMBEDDINGS

Against a real deployment, both engines return a vector.

| Input | Result |
|---|---|
| `N'the quick brown fox'`, default model dimensions | 1536 dimensions, base type `float32` |
| the same model with `PARAMETERS = '{"dimensions":512}'` | 512 dimensions |
| the same model with `PARAMETERS = '{"dimensions":768}'` | 768 dimensions |
| `PARAMETERS = '{"dimensions":9999}'` | `Msg 31742, Unrecoverable HTTP error 400` |
| `NULL` | `Msg 8116, Argument data type NULL is invalid for argument 2 of ai_generate_embeddings function` |
| `N''` | a real vector |
| a 768 dimension result assigned to `VECTOR(1536)` | `Msg 42204, The vector dimensions 1536 and 768 do not match` |

Cloud and container vectors for the same input agree closely but not exactly. The difference is
the embedding service's own non-determinism rather than an engine difference.

## Cost: one round trip per row

Run the batched `UPDATE` from `SKILL.md` step 6 with `SET STATISTICS TIME ON`. Its elapsed time is
the single call time repeated once per row, and its CPU time is a small fraction of that. There is
no batching and no parallelism inside the statement, so a one million row corpus in one statement
is a single transaction lasting days. Batch it, and drive the batches from a filtered index on the
unembedded rows.

## Claims that do not hold

1. **This surface is not cloud only.** All four objects exist in the container, and an embedding
   call to a real deployment completes from inside a container.
2. **The natural reading of `Msg 31630` is that the secret is broken.** It is almost always the
   credential's name not being a URL prefix of the location. That distinction is not in the message.
3. **The natural reading of `Msg 33047` is a database master key problem.** It is a managed
   identity credential missing its `resourceid` secret, and it is raised even while the master key
   is present and working for other credentials in the same database.
4. **The natural reading of `Msg 15151` is that the model was never created.** It is also what a
   missing `EXECUTE` grant looks like, and the object is right there in `sys.external_models`.
5. **"Azure endpoints are allowed" is not the rule.** The resource manager and Cosmos DB endpoints
   are refused, and something outside `azure.com` entirely is allowed.
6. **The container is not a subset of the cloud here.** It permits outbound calls the cloud refuses
   and refuses an identity the cloud accepts.
