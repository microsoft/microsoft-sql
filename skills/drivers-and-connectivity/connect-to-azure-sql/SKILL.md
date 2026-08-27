---
name: connect-to-azure-sql
description: >-
  Connects an application to Azure SQL Database correctly and durably: chooses the Microsoft driver
  for the language, sets encryption and certificate validation, sizes the connection pool against
  the worker limit rather than the session limit, and makes retry part of the first version of the
  code instead of later hardening. Use when a user asks "how do I connect to Azure SQL", "which
  driver should I use", "what goes in the connection string", "add retry logic", "handle transient
  faults", "the connection keeps dropping", "should I set TrustServerCertificate", or "my app times
  out connecting to Azure". Also use when a first connection to a free or serverless database fails
  with error 40613, which is documented resume behaviour and not an outage. This is the
  language-neutral doctrine; driver installation, per-language connection string syntax and pooling
  configuration belong to connect-from-dotnet, connect-from-python and
  connect-from-typescript-and-node.
license: MIT
---

# Connect to Azure SQL Database

Opening one connection is easy. The two things that go wrong are that **the first connection is
expected to fail and the code has no retry**, and that **a certificate error gets fixed by turning
verification off**.

Verified against Microsoft Learn and Azure CLI 2.89.1 on 2026-08-27.

## What this skill owns, and what it does not

**Owns**, because it is true in every language: retry and transient-fault handling, encryption and
certificate defaults, what a connection string must and must not carry, how to pick a driver, and
how to size a pool before it becomes an incident.

**Does not own.** Send these elsewhere rather than answering them here:

| Question | Skill |
|---|---|
| Installing the driver, per-language syntax, pool configuration in .NET | `connect-from-dotnet` |
| The same for Python, including ODBC driver installation | `connect-from-python` |
| The same for TypeScript and Node.js | `connect-from-typescript-and-node` |
| Turning a specific error number into a cause | `diagnose-connection-errors` |
| A database already under resource pressure | `diagnose-resource-pressure` |
| Creating the server, database and firewall rule | `provision-azure-sql-db` |
| Getting an application identity working | `entra-id-auth` |

## Retry is part of the first version, not the hardening pass

Azure SQL Database is a multi-tenant service that reconfigures under you. Microsoft's own wording
is that most reconfiguration events complete in under 60 seconds and that applications
**should be built to expect these transient errors** rather than surface them to users.

**The case that makes this non-negotiable is not an edge case.** On a General Purpose serverless
database, which is what the free offer runs on, Microsoft documents this:

> If a serverless database is paused, the first connection attempt resumes the database and returns
> an error stating that the database is unavailable with error code 40613. Once the database
> resumes, retry the connection. Databases generally resume in less than one minute.

The default auto-pause delay is 60 minutes. So a developer who creates a free database, writes an
application, and comes back after lunch gets error 40613 on the first run. Code without retry
reports that as a failure, and the failure looks like a wrong password or a dead server. **An agent
that leaves retry for later has written code that fails the first time it is run.**

### The retry policy

The documented shape, from the transient-errors guidance:

- Wait **5 seconds** before the first retry. Shorter than that risks overwhelming the service.
- Grow the delay **exponentially**, to a maximum of **60 seconds**.
- Cap the number of attempts, so a broken configuration eventually reports itself.
- **A transient error during a query is not retried on the same connection.** Establish a fresh
  connection, then retry the command, and make sure the transaction either completed or rolled
  back before retrying an update.

### Transient, so retry

| Number | What it is |
|---|---|
| `40613` | Database not currently available. Resume of a paused database, reconfiguration, or a dedicated administrator connection already in use |
| `40197` | The service hit an error processing the request. Carries an embedded code worth logging |
| `40501` | The service is currently busy. Engine throttling |
| `40540`, `40143` | Reconfiguration and failover paths |
| `10928`, `10929` | A resource limit was reached. Resource ID 1 is workers, Resource ID 2 is sessions |
| `49918`, `49919`, `49920` | Not enough resources, or too many control-plane operations in flight |
| `233`, `64`, `20`, `10053`, `10054`, `10060` | Transport-level failures during or just after connect |

`4060` also appears in the transient list, but it usually means the database name is wrong or the
login has no user in that database. Retrying it forever hides a real bug; retry it a fixed small
number of times, then report it.

### Not transient, so do not retry

Retrying these burns the user's time and hides the fix.

| Number | Cause | Fix |
|---|---|---|
| `18456` | Login failed | Credential or user problem, not a service problem |
| `40615` | Client IP not allowed | A firewall rule is missing. See `provision-azure-sql-db` |
| `47073` | Public network access is disabled on the server | Connect through the private endpoint |
| `47072` | Login failed with invalid TLS version | The client negotiated below the server's minimum |

There is also a case that **looks** transient and is not: a free-offer database whose monthly
allowance is exhausted under the auto-pause behaviour is inaccessible **until the start of the next
calendar month**. Retry will never succeed. If connections to a free database fail persistently,
check the remaining allowance before adding more retries.

### Do not stack retry on retry without doing the arithmetic

Drivers have their own connection resiliency, and it multiplies with application-level retry. The
documented .NET example is exact: application logic that retries 4 times, combined with a driver
configured for 3 connection retries, produces **12** attempts, which is almost never what the
author intended.

Two arithmetic rules that hold whatever the language:

- The **connect timeout must be at least the retry count multiplied by the retry interval**, or the
  outer timeout cancels the last retry before it happens. With 3 retries at 10 seconds, a 29 second
  timeout never reaches the third.
- For reconnection during command execution, the **command timeout** governs instead, and its
  default is usually shorter than people assume.

Pick one layer to own retry. Configure the other deliberately, or turn it off.

## Encryption is not a knob to turn off

Microsoft's recommendation for every connection to Azure SQL Database, in every driver:

- `Encrypt = On`
- `TrustServerCertificate = Off`
- optionally `HostNameInCertificate = <full hostname of the service>` when the client connects
  through a different name, such as a DNS alias

Together those make the driver verify the server's identity. Setting `TrustServerCertificate=true`
keeps the traffic encrypted but **stops the client checking who it is talking to**, which is the
part that matters on a public endpoint.

**The rule for an agent: a certificate error is a name problem, not a trust problem.** Fix the
hostname, or set the hostname-in-certificate option. Never resolve it by disabling verification, and
never set `Encrypt=false`.

The one legitimate exception is a local Azure SQL Database container, which presents a self-signed
certificate; that case belongs to `azuresql-db-container`, not here.

Two facts that change under the model's feet, so check rather than recall:

- **The default flipped.** `Microsoft.Data.SqlClient` changed `Encrypt` from `false` to `true` in
  version 4.0, as a declared breaking change. Other drivers made equivalent moves at their own
  version boundaries. A connection that worked before an upgrade and fails after it is usually this.
- **TLS 1.0 and 1.1 are retired and no longer available.** The lowest minimum a server can be set to
  is TLS 1.2. The default is to allow TLS 1.2 and above, and enforcing a specific minimum cannot be
  reverted. Enforcing 1.3 will break clients whose driver or operating system does not support it.

Some drivers additionally offer a strict mode (TDS 8.0, `Encrypt=Strict` in SqlClient) in which
certificate trust cannot be bypassed at all.

## Choosing a driver

Use the driver Microsoft publishes for the language. Anything else is a support problem later, and
non-Microsoft drivers may not use TLS by default.

| Language | Driver |
|---|---|
| C# and .NET | `Microsoft.Data.SqlClient` |
| Python | `mssql-python` |
| Node.js and TypeScript | the Node.js driver for SQL Server |
| Java | the Microsoft JDBC driver |
| Go | `go-mssqldb` |
| C and C++ | ODBC Driver 18 for SQL Server |
| PHP | the Microsoft PHP drivers |
| Ruby | the Ruby driver for SQL Server |

For the three stacks with their own skill, stop here and hand off: `connect-from-dotnet`,
`connect-from-python`, `connect-from-typescript-and-node` own installation, syntax and pooling.

## What the connection string carries

**Must have:**

- the fully qualified server name and port `1433`
- the **user database**, never `master`. A string left on `master` connects and then fails on the
  first real query
- encryption on and certificate trust off
- a connect timeout with room for the retries configured inside it

**Must not have:**

- a password literal. The secret comes from a secret store or the environment at run time
- `TrustServerCertificate=true`, outside a local container
- `Encrypt=false`
- `Authentication=Active Directory Password`. That mode is **deprecated** in the Microsoft SQL
  drivers, is incompatible with mandatory Microsoft Entra multifactor authentication, and is marked
  obsolete in `Microsoft.Data.SqlClient` 7.0. Use managed identity for Azure-hosted workloads, a
  service principal off Azure, and interactive when a human is present

### Gotcha: the generated connection string is not a finished one

`az sql db show-connection-string` is a useful starting point, and on 2.89.1 three things about its
output need correcting by hand:

```bash
az sql db show-connection-string -c ado.net -s <server> -n <database>
```

1. **The ODBC template names a driver five major versions out of date.** It emits
   `Driver={ODBC Driver 13 for SQL Server}`. The current driver is **ODBC Driver 18**, and version
   13 packages are the legacy `msodbcsql-*` line.
2. **`--auth-type ADPassword` emits the deprecated mode.** It produces
   `Authentication="Active Directory Password"`. Do not accept that output.
3. **`--client` accepts only `ado.net`, `jdbc`, `odbc`, `php`, `php_pdo` and `sqlcmd`.** There is no
   Node.js, Python or Go template. Asking the CLI for one and paraphrasing the answer is how a wrong
   string gets invented.

None of the templates include retry settings. Add them.

## Size the pool against workers, not sessions

The number an agent reaches for is the session limit, which is **30,000 on every vCore size** and
therefore never the binding constraint. The limit that actually throttles a workload is
**concurrent workers**:

| Compute | Concurrent workers |
|---|---|
| General Purpose provisioned, standard-series | **100 per vCore** (200 at 2 vCores, 1000 at 10) |
| General Purpose serverless, standard-series | **75 per max vCore** (75 at 1, 300 at 4) |

And workers are not requests. The default `MAXDOP` for a new database in Azure SQL Database is
**8**, the limit applies **per task**, and each task uses one worker. A single parallel request can
therefore consume several workers, so the worker ceiling arrives far sooner than a count of
application connections suggests.

Practical consequences:

- Set an explicit maximum pool size. A default of unlimited turns a traffic spike into `10928`.
- Sum the pools across **every** instance that talks to the database, including background workers
  and scheduled jobs, and keep the total under the worker limit with headroom.
- In serverless and short-lived compute, create **one pool per process** and reuse it. A pool per
  request or per invocation is the classic source of exhausted outbound ports and connection storms.

Per-language pool configuration lives in the three language skills. A database already failing with
`10928` or `10929` is `diagnose-resource-pressure`, not this skill.

## The network path, when it works from one place and not another

The server's connection policy decides the route, and the default differs by where the client is:

- **From outside Azure** the default is `Proxy`: everything goes through the gateway, and the client
  needs outbound `1433` only.
- **From inside Azure** the default is `Redirect`: after the initial gateway handshake the session
  moves to the node hosting the database, and the client needs outbound `1433` **plus the range
  11000 to 11999** to the region's Azure SQL addresses.

That asymmetry is why an application can work from a laptop and time out from a virtual machine
behind a restrictive network security group. `Redirect` is the recommended policy for latency and
throughput; the cost is the wider outbound range. The current setting is readable with
`az sql server conn-policy show`, and `az sql server conn-policy update --connection-type` accepts
`Default`, `Proxy` and `Redirect`.

## Read the source when

- **A specific error number needs a cause**: the common connection errors guidance on Microsoft
  Learn, and `diagnose-connection-errors`.
- **The retry numbers matter to a design**: the transient errors article, which carries the delay
  guidance and the driver-level retry arithmetic.
- **A resource limit is close**: the vCore resource limits reference, which is the only current
  source for worker counts per compute size.
- **A TLS decision is being made**: the connectivity settings article, which carries the minimum
  version rules and their irreversibility.

## Validation rules

- Retry exists in the first version of the code, not in a follow-up task.
- The retry policy waits at least 5 seconds before the first attempt and backs off to no more than
  60 seconds.
- A transient failure during a command opens a fresh connection before retrying.
- Non-transient errors are reported, not retried.
- Driver-level and application-level retry are not both enabled by accident, and the connect timeout
  covers the retries inside it.
- Encryption is on, certificate trust is off, and the connection string names the user database.
- No secret appears in the connection string, in source, or in the transcript.
- The pool has an explicit ceiling, justified against the worker limit for the compute size.

## Do not

- Do not present retry as an optional later step. On this service it is part of connecting.
- Do not treat `40613` on a first connect as an outage. It is the documented resume path, and the
  answer is to retry, not to escalate.
- Do not retry a login failure, a firewall rejection, or an exhausted free allowance. None of them
  gets better with time.
- Do not set `TrustServerCertificate=true` or `Encrypt=false` to clear a certificate error, and do
  not suggest it as a temporary measure. It is the one change that survives to production.
- Do not use `Authentication=Active Directory Password`, and do not copy it out of generated output.
- Do not size a pool against the 30,000 session limit.
- Do not create a connection pool per request, per invocation, or per module import.
- Do not paste a generated ODBC connection string without correcting the driver name.
- Do not answer driver installation or per-language syntax here. Hand off to the language skill.
- Do not apply any of this to Azure SQL Managed Instance or SQL database in Fabric. Different
  connectivity model, different limits.

## Checklist before reporting success

- [ ] Retry wraps the connect path, with backoff and a cap
- [ ] The transient list is a list, not an exception-type catch-all that also swallows `18456`
- [ ] A command retry establishes a new connection first
- [ ] Connect timeout is at least retry count multiplied by retry interval
- [ ] Encryption on, certificate trust off, hostname correct
- [ ] The connection string names the user database and carries no password
- [ ] The driver is the Microsoft driver for that language, at a current major version
- [ ] Maximum pool size is set, and the total across instances fits under the worker limit
- [ ] If the target is serverless or free, the first-connect 40613 path was actually exercised
