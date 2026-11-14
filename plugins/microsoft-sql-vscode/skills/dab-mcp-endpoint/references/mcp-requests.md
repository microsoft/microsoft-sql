# MCP requests for verifying a Data API builder endpoint

Raw JSON-RPC over Streamable HTTP, as verified against a Data API builder 2.1.5 container.
Run them as the agent's own identity so the answers show what the agent will see.

## Bash

```bash
MCP=https://<host>/mcp
AUTH="Authorization: Bearer $TOKEN"        # omit for an Unauthenticated provider
ROLE="X-MS-API-ROLE: <role>"               # omit to run as authenticated
H=(-H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -H "$AUTH" -H "$ROLE")

# 1. initialize: expect 200, an Mcp-Session-Id header, serverInfo.name "SQL MCP Server",
#    and instructions equal to runtime.mcp.description
SID=$(curl -s -D - -o /tmp/init.txt -X POST "$MCP" "${H[@]}" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"verify","version":"1.0"}}}' \
  | tr -d '\r' | awk -F': ' 'tolower($1)=="mcp-session-id"{print $2}')
cat /tmp/init.txt; echo; echo "session=$SID"

S=(-H "Mcp-Session-Id: $SID" -H 'MCP-Protocol-Version: 2025-06-18')

# 2. initialized notification, then the tool list
curl -s -X POST "$MCP" "${H[@]}" "${S[@]}" -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'
curl -s -X POST "$MCP" "${H[@]}" "${S[@]}" -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'

# 3. what this role can see
curl -s -X POST "$MCP" "${H[@]}" "${S[@]}" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"describe_entities","arguments":{}}}'

# 4. one record
curl -s -X POST "$MCP" "${H[@]}" "${S[@]}" \
  -d '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"read_records","arguments":{"entity":"<Entity>","first":1}}}'
```

The read tool also accepts `select`, `filter`, `orderby` (an array) and `after`; only `entity` is
required.

## Reading the answers

Every reply is an `event: message` frame whose `data:` line is the JSON-RPC response. Tool results
are text content holding a JSON document; inside it, `"status": "error"` with an `error.type` is a
failure even though the HTTP status was 200.

| Answer | Meaning |
|---|---|
| HTTP 403, body names the `Host` header | The host is missing from `runtime.mcp.allowed-hosts` |
| HTTP 403, body names the `Origin` header | A browser-based client's origin is not listed |
| HTTP 401 | No valid token, or its `aud` or `iss` does not match |
| HTTP 404, `"code":-32001`, `Session not found` | The session was issued by a different process; initialize again |
| `initialize` result has no `instructions` | `runtime.mcp.description` is unset or blank |
| `instructions` differ from the file | The running revision was built from an older configuration; DAB reads it at startup |
| `error.type` `NoEntitiesConfigured` | This role can see no entity |
| `error.type` `PermissionDenied` | This role lacks the action on that entity |

## PowerShell

```powershell
$mcp = 'https://<host>/mcp'
$h = @{ Accept = 'application/json, text/event-stream'; Authorization = "Bearer $token" }
function Send-Mcp($body, $session) {
    $hh = $h.Clone(); if ($session) { $hh['Mcp-Session-Id'] = $session; $hh['MCP-Protocol-Version'] = '2025-06-18' }
    Invoke-WebRequest $mcp -Method Post -Headers $hh -ContentType 'application/json' -Body $body -UseBasicParsing
}
$r = Send-Mcp '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"verify","version":"1.0"}}}'
$sid = $r.Headers['Mcp-Session-Id']; $r.Content
Send-Mcp '{"jsonrpc":"2.0","method":"notifications/initialized"}' $sid | Out-Null
(Send-Mcp '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"describe_entities","arguments":{}}}' $sid).Content
```

`Invoke-WebRequest` throws on 401, 403 and 404; catch the exception and read its response to see
which row of the table applies.
