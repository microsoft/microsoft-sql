# Azure SQL Database connection error codes

Every entry was checked against Microsoft Learn on 2026-08-27. Message text is quoted as the
documentation writes it, including the `%.*ls` and `{0}` placeholders the engine fills in.

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

Find the number. Read the **Means** column, not the message: the message is written for the person
who configured the server, and it names the component that refused rather than the one that needs
changing.

Numbers marked **retry** are documented transient faults. Everything else is a configuration or
credential problem, and retrying it just fails more slowly.

The index is deliberately wider than the skill. Everything that rejects a connection **before the
login is evaluated** is answered here. `18456`, `4060` and `40613` sit the other side of that line
and are indexed so a number can be identified and then routed: `18456` and `4060` to
`entra-id-auth`, `40613` to `connect-to-azure-sql`. Their rows carry the identification, not the
doctrine.

## Network and gateway: nothing reached the login

| Number | Message text | Means | Fix |
|---|---|---|---|
| `40615` | `Cannot open server '{0}' requested by the login. Client with IP address '{1}' is not allowed to access the server.` | No IP firewall rule covers the address the server saw | Add a server-level or database-level IP rule for that address |
| `40914` | `Cannot open server '[server-name]' requested by the login. Client is not allowed to access the server.` | The client subnet has service endpoints but the server has no virtual network rule for it | Add a virtual network rule for the subnet |
| `47073` | `An instance-specific error occurred while establishing a connection to SQL Server. The public network interface on this server is not accessible. To connect to this server, use the Private Endpoint from inside your virtual network.` | Public network access is set to Disable | Connect through the private endpoint, or set public access to selected networks |
| `42101` | `Unable to create or modify firewall rules when public network interface for the server is disabled. To manage server or database level firewall rules, please enable the public network interface.` | An attempt to change firewall rules while public network access is disabled | Set public network access to selected networks, then change the rules |
| `5` | Cannot connect to the server | Outbound TCP 1433 is blocked between the client and the internet | Open outbound 1433 on every firewall in the path |
| `26`, `40`, `10053` | `A network-related or instance-specific error occurred...`, `A transport-level error has occurred when receiving results from the server` | The server was not found or the connection was aborted | Check the fully qualified server name and port 1433, then work the connectivity steps in order |

Two things that make firewall diagnosis go wrong:

- **Propagation.** Security setting changes have a documented latency of five minutes. Run
  `DBCC FLUSHAUTHCACHE` against the database to refresh sooner.
- **Address translation.** The address the server enforces against is the one it observed, which
  network address translation frequently makes different from the client's configured address.

The `0.0.0.0` to `0.0.0.0` rule is a documented special case meaning "allow Azure services", named
`AllowAllWindowsAzureIps`. Microsoft's own warning is that it admits any Azure resource with
outbound connectivity, **including resources in other customers' subscriptions**. It is not a
wildcard for the public internet, and it is not a substitute for a virtual network rule or a
private endpoint.

## Authentication: the login was rejected

Past that line, apart from `40532`. `18456` and `4060` are here to be recognised from their message
text and handed to `entra-id-auth`, which owns logins, database users and identities. The Fix
column is what that skill will do, recorded so the number can be told apart from `40532`, not an
instruction to do it here.

| Number | Message text | Means | Fix |
|---|---|---|---|
| `18456` | `Login failed for user '<User name>'. This session has been assigned a tracing ID of '<Tracing ID>'.` | The login does not exist, is disabled, or the password is wrong | Confirm the login exists in `sys.sql_logins` and is not disabled, then the password |
| `18456` with `<token-identified principal>` | `Login failed for user '<token-identified principal>'.` | A Microsoft Entra token was presented and accepted, but no matching principal exists in the database | Create the database user for that identity. Route to `entra-id-auth` |
| `4060` | `Cannot open database "%.*ls" requested by the login. The login failed.` | The login is valid; it has no user in the database it asked for, or the database name is wrong | Create the database user, or correct the database name |
| `40532` | `Cannot open server '<name>' requested by the login. The login failed.` | The gateway rejected the login before any database was reached | Check the server name and the login format the client sends |

On Azure SQL Database the client message deliberately hides the reason, and there is no accessible
server error log holding the error state. Diagnose by difference: what changed between the last
working connection and this one.

Microsoft Learn groups `18456`, `40532` and `40615` together for one specific failure shape:
persistent login failures **isolated to particular client networks** while the service is healthy.
The documented cause there is a DNS override, a hosts file entry or a static record pinning the
server name to a retired gateway address. The gateway validates the name it was reached by, and
login attempts sent directly to an IP address fail by design.

## Transient: retry is the fix

All of these are documented transient faults. The documented retry shape is a 5 second delay
before the first retry, growing exponentially to a maximum of 60 seconds.

| Number | Message text | Means |
|---|---|---|
| `40613` | `Database '%.*ls' on server '%.*ls' is not currently available. Please retry the connection later. If the problem persists, contact customer support, and provide them with the session tracing ID of '%.*ls'.` | The database is resuming, is reconfiguring, or already has a dedicated administrator connection. On a paused serverless database this is the documented response to the first connection attempt. Identification only: the retry doctrine that answers it is `connect-to-azure-sql`'s, and a 40613 that survives a retry on a database that is neither serverless nor free is the dedicated administrator connection instead |
| `40197` | `The service has encountered an error processing your request. Please try again. Error code %d.` | A failover or upgrade. The embedded code (40020, 40143, 40166, 40540 are examples) is the detail worth logging |
| `40501` | `The service is currently busy. Retry the request after 10 seconds. Incident ID: %ls. Code: %d.` | Engine throttling, meaning resource limits are being exceeded |
| `49918` | `Cannot process request. Not enough resources to process request. The service is currently busy. Please retry the request later.` | Control plane is out of capacity for the request |
| `49919` | `Cannot process create or update request. Too many create or update operations in progress for subscription "%ld".` | Too many concurrent provisioning operations on the subscription |
| `49920` | `Cannot process request. Too many operations in progress for subscription "%ld".` | As above, for operations generally |
| `4221` | `Login to read-secondary failed due to long wait on 'HADR_DATABASE_WAIT_FOR_TRANSITION_TO_VERSIONING'.` | A read replica is not yet serving logins |

**Serverless specifics worth quoting.** Auto-pause requires zero sessions and zero user CPU for
the whole auto-pause delay, which defaults to 60 minutes and can be set from 15 minutes to seven
days, or disabled with `-1`. Resume latency is generally on the order of one minute. Any login
attempt triggers the resume.

## Resource governance: a limit was reached

| Number | Message text | Means |
|---|---|---|
| `10928` | `Resource ID: %d. The %s limit for the database is %d and has been reached.` | Resource ID 1 is **workers**, Resource ID 2 is **sessions**. The message says "request limit" for backward compatibility, and the limit actually reached is workers |
| `10929` | `Resource ID: %d. The %s minimum guarantee is %d, maximum limit is %d, and the current usage for the database is %d. However, the server is currently too busy to support requests greater than %d for this database.` | The database is over its guaranteed share while the server is saturated |
| `40544` | `The database has reached its size quota. Partition or delete data, drop indexes, or consult the documentation for possible resolutions.` | Storage, not compute |
| `40549` | `Session is terminated because you have a long-running transaction. Try shortening your transaction.` | One transaction held too long. Batch the work |
| `40550` | `The session has been terminated because it has acquired too many locks. Try reading or modifying fewer rows in a single transaction.` | Lock count, not lock time |
| `40551` | Terminated for excessive tempdb usage | |
| `40552` | Terminated for excessive transaction log space usage | |
| `40553` | Terminated for excessive memory usage | |

The 10928 wording is the trap. Because the number of workers can be much higher than the number of
requests when the degree of parallelism is above one, the limit can be reached far sooner than the
word "request" suggests. Sizing the pool against sessions rather than workers is the standing
mistake; `connect-to-azure-sql` owns the preventive half and `diagnose-resource-pressure` the
reactive half.

## TLS and certificates

| Number | Message text | Means |
|---|---|---|
| `47072` | `Login failed with invalid TLS version` | The client offered a TLS version below the server's configured minimum |

Current state, and it has moved recently enough to be worth re-checking rather than recalling:

- **TLS 1.0 and 1.1 are retired and no longer available.** The lowest minimum version Azure SQL
  Database supports is TLS 1.2.
- The default is to allow TLS 1.2 and above. **Once a minimum version is enforced, it cannot be
  reverted to the default.**
- Enforcing a minimum of TLS 1.3 can break clients, because not every driver and operating system
  supports it.

The certificate failure has no SQL number and reads, in the .NET stack, as
`The certificate chain was issued by an authority that is not trusted`. It became common when
driver defaults changed to encrypt connections by default with full certificate validation, which
means a client that previously never validated now does.

The roots to trust are **DigiCert Global Root G2**, **Microsoft ECC Root Certificate Authority
2017** and **Microsoft RSA Root Certificate Authority 2017**. A client driver that uses the
operating system certificate store on a maintained machine already has them.

Turning off certificate validation makes the error stop and makes the connection unauthenticated.
Never do it outside local development, and never as the answer to this error in a deployed system.

## Errors with no SQL number

The client library raises these, so the SQL number is `0` and the text belongs to the TCP provider.
Documented examples:

```
A connection was successfully established with the server, but then an error occurred during the
pre-login handshake. (provider: TCP Provider, error: 0 - An existing connection was forcibly
closed by the remote host.)

A transport-level error has occurred when sending the request to the server. (provider: TCP
Provider, error: 0 - An existing connection was forcibly closed by the remote host.)

A connection was successfully established with the server, but then an error occurred during the
login process. (provider: TCP Provider, error: 0 - An existing connection was forcibly closed by
the remote host.)
```

Causes range from the database being briefly unavailable to a firewall or network appliance in the
path. The documented guidance is a **fixed number of retries** before treating them as permanent.

Timeouts sit in the same bucket. `Connection Timeout Expired ... while attempting to consume the
pre-login handshake acknowledgement` and the plain `Timeout expired` both mean the client could
not reach the server, which a blocked port, a missing firewall rule or disabled public network
access all produce. The recommended connection timeout is at least 30 seconds.

To confirm an exception is connectivity rather than a slow query, read the stack: frames opening a
connection point at connectivity, frames executing a command point at the query.

## Sources

All Microsoft Learn, all read on 2026-08-27.

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
