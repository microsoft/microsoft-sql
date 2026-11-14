# Verify a deployed Data API builder endpoint

Run against `https://<host>` after every new revision. Each step names the answer that counts as a
pass. The status codes and bodies were observed on Data API builder 2.1.5.

```bash
BASE=https://<host>
ENTITY=<Entity>
AUDIENCE=<application-id-uri-or-client-id>   # the API's app registration
```

## 1. Process only

```bash
curl -s $BASE/
```

Pass: `{"status":"Healthy","version":"2.1.5",...}`. This answer is identical with the database
down, so it proves nothing beyond a running process.

## 2. Denied paths

```bash
curl -s -o /dev/null -w '%{http_code}\n' "$BASE/api/$ENTITY"                              # 403
curl -s -o /dev/null -w '%{http_code}\n' -H 'Authorization: Bearer x' "$BASE/api/$ENTITY" # 401
```

A 200 on the first line means `anonymous` reaches the entity, directly or by inheritance. Stop
unless public read was the requirement.

## 3. A real token, and what it carries

```bash
TOKEN=$(az account get-access-token --scope "$AUDIENCE/.default" --query accessToken -o tsv)
python3 - "$TOKEN" <<'PY'
import base64, json, sys
p = sys.argv[1].split('.')[1]; p += '=' * (-len(p) % 4)
c = json.loads(base64.urlsafe_b64decode(p))
print({k: c.get(k) for k in ('aud', 'iss', 'ver', 'roles')})
PY
```

`aud` and `iss` must equal `runtime.host.authentication.jwt.audience` and `.issuer`. If
`az account get-access-token` fails with AADSTS65001, the API's registration has not authorized
the Azure CLI as a client; use the calling application's own token instead.

## 4. Allowed path

```bash
curl -s -H "Authorization: Bearer $TOKEN" "$BASE/api/$ENTITY?\$first=1"
# a named role: add -H "X-MS-API-ROLE: <role>"; the role must be in the token's roles claim
```

Pass: a `value` array with one row. 403 `AuthorizationCheckFailed` means the effective role lacks
`read`.

## 5. Health, read from the body

```bash
curl -s -H "Authorization: Bearer $TOKEN" -H 'X-MS-API-ROLE: monitoring' "$BASE/health" \
  | python3 -c "import json,sys; r=json.load(sys.stdin); print(r['status']); [print(c['status'], c['name'], c.get('exception','')) for c in r['checks']]"
```

Pass: `Healthy`, with the data source check `Healthy`. The HTTP status is 200 whatever the body
says. An entity check failing with `Forbidden` means the health role cannot read that entity, not
that the database is down.

## 6. MCP, if enabled

```bash
curl -s -D - -X POST "$BASE/mcp" \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"verify","version":"1.0"}}}'
```

Pass: HTTP 200, an `Mcp-Session-Id` response header, and an `event: message` body whose
`serverInfo.name` is `SQL MCP Server` and whose `instructions` match `runtime.mcp.description`. No
`instructions` means the image was built without a description. A 403 naming the Host or Origin
header means `runtime.mcp.allowed-hosts` is missing this host. `tools/list` and a first tool call
are in `dab-mcp-endpoint`.

## PowerShell equivalents

```powershell
$base = 'https://<host>'
(Invoke-WebRequest "$base/" -UseBasicParsing).Content
$token = az account get-access-token --scope "<audience>/.default" --query accessToken -o tsv
$h = @{ Authorization = "Bearer $token"; 'X-MS-API-ROLE' = 'monitoring' }
(Invoke-RestMethod "$base/health" -Headers $h).status
```

`Invoke-WebRequest` throws on 401 and 403; wrap denied-path checks in `try`/`catch` and read
`$_.Exception.Response.StatusCode`.
