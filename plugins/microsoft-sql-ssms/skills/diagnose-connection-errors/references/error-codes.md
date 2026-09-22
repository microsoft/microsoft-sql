# Azure SQL Database connection error codes

Every entry was checked against Microsoft Learn on 2026-09-03. Message text is quoted as the
documentation writes it, including the `%.*ls` and `{0}` placeholders the engine fills in. Severity
comes from the Database Engine error number tables, which are the same text `sys.messages` holds.

**Severity is half the diagnosis.** Learn's levels, in the range that reaches a connection: **10**
informational, and *converted to severity 0 before the error reaches the calling application*; **11**
the given object or entity does not exist; **14** security, such as permission denied; **16** a
general user-correctable error; **17** out of a resource or past a system-administrator limit;
**20 to 24** fatal, the task terminates and the connection usually goes with it. `TRY...CATCH`
catches above 10 and below the levels that kill the connection, so a severity 10 message reaches
neither a `CATCH` block nor, without sqlcmd's `-m-1`, a `Msg` number on the console.

## Contents

- [How to use this file](#how-to-use-this-file)
- [Network and gateway: nothing reached the login](#network-and-gateway-nothing-reached-the-login)
- [Authentication: the login was rejected](#authentication-the-login-was-rejected)
- [Transient: retry is the fix](#transient-retry-is-the-fix)
- [Resource governance: a limit was reached](#resource-governance-a-limit-was-reached)
- [TLS and certificates](#tls-and-certificates)
- [Errors with no SQL number](#errors-with-no-sql-number)
- [Sources](#sources)

## How to use this file

Find the number. Read the **Sev** and **Means** columns, not the message: the message is written for
the person who configured the server, and it names the component that refused rather than the one
that needs changing.

To resolve a number this file does not carry, ask the engine. Microsoft Learn publishes this query
as the way to read the same table these pages are generated from:

```sql
SELECT message_id AS Error,
       severity AS Severity,
       [Event Logged] = CASE is_event_logged WHEN 0 THEN 'No' ELSE 'Yes' END,
       [text] AS [Description]
FROM sys.messages
WHERE language_id = 1033 /* 1033 is US English */
ORDER BY message_id;
```

A `Sev` of `not sourced` means the message text came from a product page that prints no severity and
the number was not in the error number tables. Do not fill one in from memory; run the query above.

Numbers marked **retry** are documented transient faults. Everything else is a configuration or
credential problem, and retrying it just fails more slowly.

The index is deliberately wider than the skill. Everything that rejects a connection **before the
login is evaluated** is answered here. `18456`, `4060` and `40613` sit the other side of that line
and are indexed only so a number can be identified and then routed, `18456` and `4060` to
`entra-id-auth` and `40613` to `connect-to-azure-sql`. Identification, not doctrine.

## Network and gateway: nothing reached the login

| Number | Sev | Message text | Means | Fix |
|---|---|---|---|---|
| `40615` | 16 | `Cannot open server '%.*ls' requested by the login. Client with IP address '%.*ls' is not allowed to access the server. To enable access, use the Azure Management Portal or run sp_set_firewall_rule on the master database to create a firewall rule for this IP address or address range. It may take up to five minutes for this change to take effect.` | No IP firewall rule covers the address the server saw | Add a server-level or database-level IP rule for that address |
| `40914` | not sourced | `Cannot open server '[server-name]' requested by the login. Client is not allowed to access the server.` | The client subnet has service endpoints but the server has no virtual network rule for it | Add a virtual network rule for the subnet |
| `47073` | 10 | Two documented wordings, see below | Public network access is set to Disable | Connect through the private endpoint, or set public access to selected networks |
| `42101` | 10 | Two documented wordings, see below | An attempt to change firewall rules while public network access is disabled | Set public network access to selected networks, then change the rules |
| `40611` / `40614` | 16 | `Azure SQL Database supports a maximum of 256 firewall rules.` / `Start IP address of firewall rule cannot exceed End IP address.` | The rule itself was refused, not the connection | Consolidate ranges, or swap the two addresses |
| `5` | not sourced | Cannot connect to the server | Outbound TCP 1433 is blocked between the client and the internet | Open outbound 1433 on every firewall in the path |
| `26`, `40`, `10053` | not sourced | `A network-related or instance-specific error occurred`, `A transport-level error has occurred when receiving results from the server` | The server was not found or the connection was aborted | Check the fully qualified server name and port 1433, then work the connectivity steps in order |

**Two Microsoft Learn pages disagree about 47073 and 42101, and the difference matters.** The
connectivity settings page prints them as top-level errors:

```output
Error 47073
An instance-specific error occurred while establishing a connection to SQL Server.
The public network interface on this server is not accessible.
To connect to this server, use the Private Endpoint from inside your virtual network.

Error 42101
Unable to create or modify firewall rules when public network interface for the server is disabled.
To manage server or database level firewall rules, please enable the public network interface.
```

The error number table lists both at **severity 10** with different text, beginning `Reason:`, which
is the shape of a sub-message attached to a login failure rather than a standalone error:
`47073 Reason: An instance-specific error occurred while establishing a connection to SQL Server.
Connection was denied because Deny Public Network Access is set to Yes.` and `42101 Reason: Unable
to create or update firewall rules because Deny Public Network Access is set to Yes.`

Both are Microsoft Learn. Take the severity from the table, because it explains the symptom: a
severity 10 message is converted to severity 0 on the way to the client, so a developer whose public
network access was disabled usually reports an unexplained failure or a timeout and never sees the
number. `sqlcmd -m-1` is what makes it visible.

Two things that make firewall diagnosis go wrong:

- **Propagation.** Security setting changes have a documented latency of five minutes. Run
  `DBCC FLUSHAUTHCACHE` in the **user** database to refresh sooner. It does not apply to the logical
  `master`, which is where the logins and firewall rules physically live, and it needs the
  `KILL DATABASE CONNECTION` permission or the admin account. It also needs a connection that
  already works, so it cannot rescue the connection the firewall is refusing.
- **Address translation.** The address the server enforces against is the one it observed, which
  network address translation frequently makes different from the client's configured address.

The `0.0.0.0` to `0.0.0.0` rule is a documented special case meaning "allow Azure services", named
`AllowAllWindowsAzureIps`. Microsoft's own warning is that it admits any Azure resource with
outbound connectivity, **including resources in other customers' subscriptions**. It is not a
wildcard for the public internet, and it is not a substitute for a virtual network rule or a
private endpoint.

## Authentication: the login was rejected

Past that line, apart from `40532` and `40531`. `18456` and `4060` are here to be recognised and
handed to `entra-id-auth`, which owns logins, database users and identities. Their Fix column
records what that skill will do, so the number can be told apart from `40532`.

| Number | Sev | Message text | Means | Fix |
|---|---|---|---|---|
| `18456` | 14 | `Login failed for user '%.*ls'.%.*ls%.*ls` | The login does not exist, is disabled, or the password is wrong | Confirm the login exists in `sys.sql_logins` and is not disabled, then the password |
| `18456` with `<token-identified principal>` | 14 | `Login failed for user '<token-identified principal>'.` | A Microsoft Entra token was presented and accepted, but no matching principal exists in the database | Create the database user for that identity. Route to `entra-id-auth` |
| `4060` | 11 | `Cannot open database "%.*ls" requested by the login. The login failed.` | The login is valid; it has no user in the database it asked for, or the database name is wrong | Create the database user, or correct the database name |
| `40532` | 11 | `Cannot open server "%.*ls" requested by the login. The login failed.` | The gateway rejected the login before any database was reached | Check the server name and the login format the client sends |
| `40531` | 11 | `Server name cannot be determined. It must appear as the first segment of the server's dns name (servername.%.*ls). Some libraries do not send the server name, in which case the server name must be included as part of the user name (username@servername). In addition, if both formats are used, the server names must match.` | The gateway could not work out which server the login was for | Send `username@servername`, or correct the first DNS segment |
| `40608` | 10 | `This session has been assigned a tracing ID of '%.*ls'. Provide this tracing ID to customer support when you need assistance.` | The tracing ID that arrives appended to a login failure. Severity 10, so it is informational, not the error | Quote it in a support case, do not diagnose from it |

**`18456` carries its real reason as a separate severity 10 message that Azure SQL Database does not
send to the client.** The reason strings have their own numbers in the 18300 to 18400 and 47000
ranges: `18301 Could not find a login matching the name provided`, `18307 Password did not match
that for the login provided`, `18395 Authentication was successful, but database was not found on
this logical server`, `18397 Unable to retrieve database firewall rules`, `47070 Azure Active
Directory only authentication is enabled`. Severity 10 is converted to 0 before the calling
application sees it, which is why the client message hides the reason. Do not promise a diagnosis
the platform does not expose.

Diagnose by difference instead: what changed between the last working connection and this one.

Microsoft Learn groups `18456`, `40532` and `40615` together for one specific failure shape:
persistent login failures **isolated to particular client networks** while the service is healthy.
The documented cause there is a DNS override, a hosts file entry or a static record pinning the
server name to a retired gateway address. The gateway validates the name it was reached by, and
login attempts sent directly to an IP address fail by design.

## Transient: retry is the fix

All of these are documented transient faults. The documented retry shape is a 5 second delay
before the first retry, growing exponentially to a maximum of 60 seconds.

| Number | Sev | Message text | Means |
|---|---|---|---|
| `40613` | 17 | `Database '%.*ls' on server '%.*ls' is not currently available. Please retry the connection later. If the problem persists, contact customer support, and provide them the session tracing ID of '%.*ls'.` | The database is resuming, is reconfiguring, or already has a dedicated administrator connection. On a paused serverless database this is the documented response to the first connection attempt. Identification only: the retry doctrine that answers it is `connect-to-azure-sql`'s, and a 40613 that survives a retry on a database that is neither serverless nor free is the dedicated administrator connection instead |
| `40197` | not sourced | `The service has encountered an error processing your request. Please try again. Error code %d.` | A failover or upgrade. The embedded code (40020, 40143, 40166, 40540 are examples) is the detail worth logging |
| `40501` | not sourced | `The service is currently busy. Retry the request after 10 seconds. Incident ID: %ls. Code: %d.` | Engine throttling, meaning resource limits are being exceeded |
| `49918` | not sourced | `Cannot process request. Not enough resources to process request. The service is currently busy. Please retry the request later.` | Control plane is out of capacity for the request |
| `49919` | not sourced | `Cannot process create or update request. Too many create or update operations in progress for subscription "%ld".` | Too many concurrent provisioning operations on the subscription |
| `49920` | not sourced | `Cannot process request. Too many operations in progress for subscription "%ld".` | As above, for operations generally |
| `4221` | not sourced | `Login to read-secondary failed due to long wait on 'HADR_DATABASE_WAIT_FOR_TRANSITION_TO_VERSIONING'.` | A read replica is not yet serving logins |

Severity 17 on `40613` reads correctly against the definition: the service ran out of something or
passed a limit, which is what a paused database resuming is. It is not a defect and it is not
damage.

**Serverless auto-pause and resume are `connect-to-azure-sql`'s, not this file's.** The one fact
needed to identify a `40613` here: any login attempt triggers the resume, and resume latency is
generally on the order of one minute.

## Resource governance: a limit was reached

| Number | Sev | Message text | Means |
|---|---|---|---|
| `10928` | 16 | `Resource ID : %d. The %ls limit for the database is %d and has been reached.` | Resource ID 1 is **workers**, Resource ID 2 is **sessions**. The message says "request limit" for backward compatibility, and the limit actually reached is workers |
| `10929` | 16 | `Resource ID : %d. The %ls minimum guarantee is %d, maximum limit is %d and the current usage for the database is %d. However, the server is currently too busy to support %ls greater than %d for this database.` | The database is over its guaranteed share while the server is saturated |
| `40544` | 20 | `The database '%.*ls' has reached its size quota. Partition or delete data, drop indexes, or consult the documentation for possible resolutions.` | Storage, not compute. Severity 20 is fatal, so the connection is gone and retrying on it cannot work |
| `40549` | 16 | `Session is terminated because you have a long running transaction. Try shortening your transaction.` | One transaction held too long. Batch the work |
| `40550` | not sourced | `The session has been terminated because it has acquired too many locks. Try reading or modifying fewer rows in a single transaction.` | Lock count, not lock time |
| `40551` | not sourced | Terminated for excessive tempdb usage | |
| `40552` | not sourced | Terminated for excessive transaction log space usage | |
| `40553` | not sourced | Terminated for excessive memory usage | |

The 10928 wording is the trap. Workers can far outnumber requests when the degree of parallelism is
above one, so the limit arrives sooner than the word "request" suggests. Sizing the pool against
sessions rather than workers is the standing mistake: `connect-to-azure-sql` owns the preventive
half, `diagnose-resource-pressure` the reactive half.

## TLS and certificates

| Number | Sev | Message text | Means |
|---|---|---|---|
| `47072` | 10 | `Reason: Login failed due to client TLS version being less than minimal TLS version allowed by the server.` in the error number table; `Login failed with invalid TLS version` on the connectivity settings page | The client offered a TLS version below the server's configured minimum. The same two-wordings problem as 47073 |
| `18399` | 10 | `Reason: Unsecured connection to the database is disallowed. The secured connection string should be used instead. [Database: '%.*ls']` | The client asked for an unencrypted connection. Turn encryption on rather than turning validation off |

Current state, and it has moved recently enough to be worth re-checking rather than recalling: TLS
1.0 and 1.1 are retired and no longer available, so the lowest minimum Azure SQL Database supports
is 1.2; the default allows 1.2 and above and **once a minimum is enforced it cannot be reverted to
the default**; and enforcing 1.3 breaks clients whose driver or operating system does not support
it. Read the current value with
`az sql server show -n your-server -g your-resource-group --query "minimalTlsVersion"`.

The certificate failure has no SQL number and reads, in the .NET stack, as `The certificate chain
was issued by an authority that is not trusted`. It became common when driver defaults changed to
encrypt with full certificate validation, so a client that previously never validated now does.

The roots to trust are **DigiCert Global Root G2**, **Microsoft ECC Root Certificate Authority
2017** and **Microsoft RSA Root Certificate Authority 2017**. A driver using the operating system
certificate store on a maintained machine already has them. Turning validation off makes the error
stop and makes the connection unauthenticated: never outside local development.

## Errors with no SQL number

The client library raises these, so the SQL number is `0` and the text belongs to the TCP provider.
Documented examples:

```
A connection was successfully established with the server, but then an error occurred during the
pre-login handshake. (provider: TCP Provider, error: 0 - An existing connection was forcibly
closed by the remote host.)

A transport-level error has occurred when sending the request to the server. (provider: TCP
Provider, error: 0 - An existing connection was forcibly closed by the remote host.)
```

The same sentence also appears with `during the login process` in place of `during the pre-login
handshake`, and means the same thing.

Causes range from the database being briefly unavailable to a firewall or network appliance in the
path. The documented guidance is a **fixed number of retries** before treating them as permanent.

Timeouts sit in the same bucket. `Connection Timeout Expired` while consuming the pre-login
handshake acknowledgement, and the plain `Timeout expired`, both mean the client could not reach the
server, which a blocked port, a missing firewall rule or disabled public network access all produce.
The recommended connection timeout is at least 30 seconds, which is `sqlcmd -l 30`.

To tell connectivity from a slow query, read the stack: frames opening a connection point at
connectivity, frames executing a command point at the query.

## Sources

All Microsoft Learn. The error number tables and the severity definitions were read on 2026-09-03;
the rest on 2026-08-27.

- Database Engine error severities: `/sql/relational-databases/errors-events/database-engine-error-severities`
  (every level, and the rule that severity 10 is converted to 0 before the calling application sees
  it, plus how `TRY...CATCH` treats each range)
- Database Engine events and errors, the range tables carrying severity and the verbatim
  `sys.messages` text, under
  `/sql/relational-databases/errors-events/database-engine-events-and-errors-<range>`:
  `10000-to-10999` (10928, 10929), `18000-to-18999` (18456 and the `Reason:` strings 18301, 18307,
  18395, 18397, 18399), `31000-to-41399` (40531, 40532, 40544, 40549, 40608, 40611, 40613, 40614,
  40615) and `41400-to-49999` (42101, 47070, 47072, 47073)
- Troubleshoot connectivity issues: `/azure/azure-sql/database/troubleshoot-common-errors-issues`
  (transient fault table, resource governance table, DNS override guidance, network termination
  errors, timeout errors)
- Virtual network endpoints and rules: `/azure/azure-sql/database/vnet-service-endpoint-rule-overview`
  (verbatim 40914 and 40615 message text, description and resolution)
- IP firewall rules: `/azure/azure-sql/database/firewall-configure` (rule levels, the five minute
  latency, `DBCC FLUSHAUTHCACHE`, the `0.0.0.0` rule and its warning)
- Connectivity settings: `/azure/azure-sql/database/connectivity-settings` (verbatim 47073, 42101
  and 47072 text, minimum TLS version state and defaults)
- Serverless auto-pause and auto-resume: `/azure/azure-sql/database/serverless-tier-auto-pause-resume`
  (40613 on first connect to a paused database, resume latency, auto-pause triggers)
- Serverless compute tier: `/azure/azure-sql/database/serverless-tier-overview` (auto-pause delay
  default and range)
- Certificate rotation: `/azure/azure-sql/updates/ssl-root-certificate-expiring` (the three roots)
- Error 18456: `/sql/relational-databases/errors-events/mssqlserver-18456-database-engine-error`
- `DBCC FLUSHAUTHCACHE`: `/sql/t-sql/database-console-commands/dbcc-flushauthcache-transact-sql`
  (it does not apply to the logical `master`, it needs `KILL DATABASE CONNECTION` or the admin
  account, and it clears cached Microsoft Entra group membership as well as logins and firewall
  rules)
