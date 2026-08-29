# Measured behaviour of the external model surface, 2026-08-28

## Contents

- [How this was run](#how-this-was-run)
- [What the DDL accepts without complaint](#what-the-ddl-accepts-without-complaint)
- [The credential naming matrix](#the-credential-naming-matrix)
- [Managed identity](#managed-identity)
- [The permission matrix](#the-permission-matrix)
- [The cloud allowlist, probed host by host](#the-cloud-allowlist-probed-host-by-host)
- [Outbound rules measured on the container](#outbound-rules-measured-on-the-container)
- [AI_GENERATE_CHUNKS](#ai_generate_chunks)
- [AI_GENERATE_EMBEDDINGS](#ai_generate_embeddings)
- [Cost and concurrency](#cost-and-concurrency)
- [Claims that did not hold](#claims-that-did-not-hold)
- [Reproducing this](#reproducing-this)

## How this was run

Two engines, the same statements, on the same day.

- **Cloud.** An Azure SQL Database provisioned for the run: General Purpose serverless, two vCores,
  compatibility level 170, Microsoft Entra authentication only, `SERVERPROPERTY('EngineEdition')`
  returning 5. Deleted after the run.
- **Local.** The Azure SQL Database container, product version 12.0.2000.8, also reporting
  `EngineEdition` 5.

An Azure OpenAI resource with a `text-embedding-3-small` deployment was created for the run and
deleted after it, so the embedding calls below are real calls that returned real vectors, not
placeholder failures.

Where the two engines agreed, the result is stated once. Every disagreement is called out.

## What the DDL accepts without complaint

All of these `CREATE EXTERNAL MODEL` statements **succeeded** on both engines and appeared in
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

Everything else held constant: a real endpoint, a real key, a real deployment.

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

`CREATE MASTER KEY ENCRYPTION BY PASSWORD` was required once per database before the first
credential on both engines.

## Managed identity

| Attempt | Cloud | Container |
|---|---|---|
| `IDENTITY = 'Managed Identity'` with no `SECRET` | `Msg 33047, Fail to obtain or decrypt secret for credential '<name>'` | `Msg 31644` |
| `IDENTITY = 'Managed Identity'`, `SECRET = '{"resourceid":"https://cognitiveservices.azure.com"}'` | **Embedding returned** | `Msg 31644, Server Managed Identity is disabled for this instance of SQL Server. Use sp_configure 'allow server scoped db credentials' to enable it` |
| The `sp_configure` the container's message names | not applicable | `Msg 40510, Statement 'CONFIG' is not supported in this version of SQL Server` |

The cloud path additionally needed a system assigned identity on the logical server and a role
assignment for that identity on the target resource. Without the role the failure is an HTTP 401,
not a credential error, which is the same symptom as a wrong key.

The container row is a hard parity break: the error names a remedy the container cannot execute.

## The permission matrix

Tested with a login and a database user holding `db_datareader` and `db_datawriter` and nothing
else, then re-tested after each grant.

| Action | Without the permission | Permission that fixes it |
|---|---|---|
| `CREATE EXTERNAL MODEL` | `Msg 262, CREATE EXTERNAL MODEL permission denied in database '<db>'` | `GRANT CREATE EXTERNAL MODEL TO <user>` |
| `AI_GENERATE_EMBEDDINGS ... USE MODEL m` | `Msg 15151, Cannot find the external model 'm', because it does not exist or you do not have permission` | `GRANT EXECUTE ON EXTERNAL MODEL::m TO <user>` |
| `sp_invoke_external_rest_endpoint` | `Msg 8189, You do not have permission to run 'sys.sp_invoke_external_rest_endpoint'` | `GRANT EXECUTE ANY EXTERNAL ENDPOINT TO <user>` |
| `AI_GENERATE_CHUNKS` | ran successfully with no grant at all | none |

`sys.fn_builtin_permissions(DEFAULT)` lists `CREATE EXTERNAL MODEL`, `ALTER ANY EXTERNAL MODEL` and
`EXECUTE ANY EXTERNAL ENDPOINT` as database permissions.
`sys.fn_builtin_permissions('EXTERNAL MODEL')` lists `VIEW DEFINITION`, `ALTER`, `TAKE OWNERSHIP`,
`EXECUTE` and `CONTROL` as the object level set.

After the grants, `sys.database_permissions` showed `CREATE EXTERNAL MODEL` and
`EXECUTE ANY EXTERNAL ENDPOINT` at class `DATABASE` and `EXECUTE` at class `EXTERNAL_MODEL`.

## The cloud allowlist, probed host by host

Method: call `sp_invoke_external_rest_endpoint` against `https://zzz-not-real.<domain>/`. A domain
on the allowlist gets far enough to attempt a DNS lookup and fails with
`Msg 31625, DNS resolution of the hostname has failed with windows sockets error 11001`. A domain
that is not on it fails earlier with `Msg 31612`.

| Domain probed | Cloud result |
|---|---|
| `openai.azure.com` | allowed, reached DNS |
| `cognitiveservices.azure.com` | allowed, reached DNS |
| `services.ai.azure.com` | allowed, reached DNS |
| `inference.ai.azure.com` | allowed, reached DNS |
| `search.windows.net` | allowed, reached DNS |
| `vault.azure.net` | allowed, reached DNS |
| `blob.core.windows.net` | allowed, reached DNS |
| `queue.core.windows.net` | allowed, reached DNS |
| `table.core.windows.net` | allowed, reached DNS |
| `servicebus.windows.net` | allowed, reached DNS |
| `eventgrid.azure.net` | allowed, reached DNS |
| `azure-api.net` | allowed, reached DNS |
| `azurewebsites.net` | allowed, reached DNS |
| `documents.azure.com` | **`Msg 31612`** |
| `management.azure.com` | **`Msg 31612`** |
| `azureml.ms` | **`Msg 31612`** |
| `api.github.com` | **`Msg 31612`** |

Reaching DNS is evidence the domain is permitted, not evidence a real host under it will answer.
Treat this table as a snapshot of a policy that is expected to change, and re-probe rather than
quoting it.

## Outbound rules measured on the container

The same probes on the container behave differently, and the difference is not a subset
relationship.

| Probe | Container result |
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

The certificate row was pinned down rather than assumed. A private certificate authority was
generated, installed into the container's operating system trust store with that distribution's own
tooling, and confirmed accepted by a command line client running inside the same container. The
engine still returned `Msg 31608`, before and after a restart. **The engine does not use the
container's trust store**, so there is no supported way to point an external model at a locally
hosted endpoint.

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
- Sizes and overlap are characters. Word boundaries are not respected.

## AI_GENERATE_EMBEDDINGS

Against the real deployment, both engines returned a vector.

| Input | Result |
|---|---|
| `N'the quick brown fox'`, default model dimensions | 1536 dimensions, base type `float32` |
| the same model with `PARAMETERS = '{"dimensions":512}'` | 512 dimensions |
| the same model with `PARAMETERS = '{"dimensions":768}'` | 768 dimensions |
| `PARAMETERS = '{"dimensions":9999}'` | `Msg 31742, Unrecoverable HTTP error 400` |
| `NULL` | `Msg 8116, Argument data type NULL is invalid for argument 2 of ai_generate_embeddings function` |
| `N''` | a real vector |
| a 768 dimension result assigned to `VECTOR(1536)` | `Msg 42204, The vector dimensions 1536 and 768 do not match` |

The cloud and container vectors for the same input agreed to roughly four decimal places, which is
the embedding service's own non-determinism rather than an engine difference.

## Cost and concurrency

Measured on the container against the real endpoint, with `SET STATISTICS TIME ON`.

| Statement | Elapsed | CPU |
|---|---|---|
| One `AI_GENERATE_EMBEDDINGS` call | 295 ms | 7 ms |
| `UPDATE` embedding 25 rows in one statement | 8963 ms | 235 ms |

25 rows at 358 ms each is the single call time repeated. There is no batching and no parallelism
inside the statement, so a one million row corpus is roughly one hundred hours in a single
transaction. Batch it, and drive the batches from a filtered index on the unembedded rows.

## Claims that did not hold

1. **The catalog note said this surface was cloud only and unavailable in the container.** Wrong on
   every count. All four objects exist locally, and a real embedding call completed from inside a
   container.
2. **The natural reading of `Msg 31630` is that the secret is broken.** It is almost always the
   credential's name not being a URL prefix of the location. That distinction is not in the message.
3. **The natural reading of `Msg 33047` is a database master key problem.** Measured, it is a
   managed identity credential missing its `resourceid` secret, and the master key was present and
   working for other credentials in the same database.
4. **The natural reading of `Msg 15151` is that the model was never created.** It is also what a
   missing `EXECUTE` grant looks like, and the object is right there in `sys.external_models`.
5. **"Azure endpoints are allowed" is not the rule.** The resource manager and Cosmos DB endpoints
   are refused, and something outside `azure.com` entirely is allowed.
6. **The container is not a subset of the cloud here.** It permits outbound calls the cloud refuses
   and refuses an identity the cloud accepts.

## Reproducing this

The allowlist probe is the cheapest of these to re-run and the one most likely to have moved:

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

The credential naming rule reproduces with two credentials over one endpoint: one named for the
endpoint URL and one named anything else, both holding the same key. The first returns a vector and
the second returns `Msg 31630`.
