---
name: connect-to-azure-sql
description: >-
  Connects an application to Azure SQL Database: picks the Microsoft driver for the language,
  sets encryption and certificate validation, sizes the pool against the worker limit not the
  session limit, and makes retry part of the first version of the code. Use when a user asks "how
  do I connect to Azure SQL", "which driver should I use", "what goes in the connection string",
  "add retry logic", "the connection keeps dropping", "should I set TrustServerCertificate", or
  "my app times out connecting to Azure". Also use when a first connection to a free or
  serverless database fails with error 40613, documented resume behaviour, not an outage.
  Azure SQL Database only, not Azure SQL Managed Instance and not self-managed SQL Server. Driver
  installation, connection strings and pooling per language belong to connect-from-dotnet,
  connect-from-python and connect-from-typescript-and-node.
---

# Connect to Azure SQL Database

Opening one connection is easy. Two things go wrong: **the first connection is expected to fail and
the code has no retry**, and **a certificate error gets fixed by turning verification off**.

Flags and defaults below were verified 2026-09-03 against `sqlcmd` 1.10.0 and User Secrets Manager
8.0.27 on this machine; cloud behaviour is from Microsoft Learn.

## Connect once from the command line before writing any code

Settle the server, database, credential and certificate before an application is in the picture, so
every later failure is a failure of the code. Cloud, SQL authentication, password out of the
command line:

```bash
sqlcmd -S <server>.database.windows.net,1433 -d <database> -U <user> -P "$SQL_PASSWORD" \
  -N mandatory -l 30 -Q "SELECT DB_NAME() AS db, encrypt_option FROM sys.dm_exec_connections WHERE session_id = @@SPID"
```

Cloud, Microsoft Entra ID, with no password anywhere:

```bash
az login
sqlcmd -S <server>.database.windows.net,1433 -d <database> -G -N mandatory -l 30 \
  -Q "SELECT SUSER_NAME() AS login"
```

Local Azure SQL Database container. **`-C` is the entire difference**, there because the container
presents a self-signed certificate.

```bash
sqlcmd -S 127.0.0.1,1433 -d <database> -U sa -P "$MSSQL_SA_PASSWORD" \
  -N mandatory -C -l 30 -Q "SELECT DB_NAME() AS db"
```

Each switch is a connection string keyword under another name, so a working command line converts
straight into a working string:

| Switch | Connection string keyword | Note |
|---|---|---|
| `-N mandatory` | `Encrypt=Mandatory` | `-N strict` is TDS 8.0, where trust cannot be bypassed |
| `-C` | `TrustServerCertificate=true` | Container only |
| `-F <name>` | `HostNameInCertificate` | The fix for a name mismatch |
| `-J <file>` | certificate pinning, PEM, DER or CER | Validates one certificate, not none |
| `-l 30` | `Connect Timeout` | Covers the retries inside it |
| `-G` | `Authentication=Active Directory Default` | No `-U`; add `-U` for interactive |

`-N` is validated before any connection is attempted, so a typo is caught for free. Measured
2026-09-03 on 1.10.0: any other value exits 1 with `Argument value has to be one of [m[andatory]
yes 1 t[rue] disable o[ptional] no 0 f[alse] s[trict]]`.

## Container and cloud: the same string with one exception

| | Local container | Azure SQL Database |
|---|---|---|
| Server | `127.0.0.1,<mapped port>` | `<server>.database.windows.net,1433` |
| Encryption | on | on |
| Certificate | self-signed, so `-C` / `TrustServerCertificate=true`, or pin it with `-J` | validated, never `-C` |
| Authentication | SQL login. Microsoft Entra ID only if the container was started with an application registration certificate, a client id and a tenant id: below | SQL login or Entra ID |
| Retry for `40613` | no equivalent; nothing throttles or fails over locally | mandatory, below |
| Pool ceiling | no service tier, so no worker number to size against | size against workers |

A clean local run is therefore no evidence the retry story works.

### Microsoft Entra ID on the container is configured, not default

The image reads the certificate path, the application (client) id and the tenant id from three
`MSSQL_AAD_` environment variables set when the container is created. Learn documents that trio for
SQL Server on Linux containers and does not document this image, so here it is measured, not cited:

```bash
docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' <container> | grep -c '^MSSQL_AAD_'
```

`3` or more means Entra ID was configured. Measured 2026-09-03 on a container created without it:
`0`, exit 1. **That state refuses the login, not the mode**, so `-G` or
`Authentication=Active Directory Default` returns `18456`, `Login failed for user ''` (measured
2026-08-28 in `connect-from-dotnet`), naming neither Entra ID nor the missing configuration, and no
connection string edit fixes it. Open `entra-id-auth` once the three are set and the identity needs
a database user, or when an `18456` names a token-identified principal rather than an empty one.

## What this skill does not own

Driver installation, per-language syntax and pool configuration are `connect-from-dotnet`,
`connect-from-python`, `connect-from-typescript-and-node`. An error number needing a cause is
`diagnose-connection-errors`, except 40613, which stays here. Resource pressure is
`diagnose-resource-pressure`, and creating the server and its firewall rule is
`provision-azure-sql-db`.

## Retry is part of the first version, not the hardening pass

Azure SQL Database reconfigures under you. Microsoft's wording: most reconfiguration events
complete in under 60 seconds, and applications **should be built to expect these transient errors**
rather than surface them to users.

On General Purpose serverless, which is what the free offer runs on, Microsoft documents this:

> If a serverless database is paused, the first connection attempt resumes the database and returns
> an error stating that the database is unavailable with error code 40613. Once the database
> resumes, retry the connection. Databases generally resume in less than one minute.

The default auto-pause delay is 60 minutes, so a developer back from lunch gets 40613 on the first
run and reads it as a wrong password or a dead server. **Code that leaves retry for later fails the
first time it is run.**

### The retry policy

- Wait **5 seconds** before the first retry. Shorter risks overwhelming the service.
- Grow the delay **exponentially**, to a maximum of **60 seconds**, and cap the attempts so a broken
  configuration eventually reports itself.
- **A transient error during a query is not retried on the same connection.** Open a fresh
  connection, then retry the command, and confirm the transaction committed or rolled back first.

### Transient, so retry

| Number | What it is |
|---|---|
| `40613` | Database not available: resume of a paused database, reconfiguration, or the dedicated administrator connection already in use |
| `40197` | The service hit an error processing the request. Carries an embedded code worth logging |
| `40501` | The service is busy. Engine throttling |
| `40540`, `40143` | Reconfiguration and failover paths |
| `10928`, `10929` | A resource limit was reached. Resource ID 1 is workers, Resource ID 2 is sessions |
| `49918`, `49919`, `49920` | Not enough resources, or too many control-plane operations in flight |
| `233`, `64`, `20`, `10053`, `10054`, `10060` | Transport-level failures during or just after connect |

`4060` is on the transient list too, but usually means the database name is wrong or the login has
no user there. Retry it a small fixed number of times, then report it.

### Not transient, so do not retry

| Number | Cause | Fix |
|---|---|---|
| `18456` | Login failed | Credential or user problem, not a service problem |
| `40615` | Client IP not allowed | A firewall rule is missing. See `provision-azure-sql-db` |
| `47073` | Public network access is disabled on the server | Connect through the private endpoint |
| `47072` | Login failed with invalid TLS version | The client negotiated below the server's minimum |

One case **looks** transient and is not: a free-offer database whose monthly allowance is exhausted
is inaccessible **until the start of the next calendar month**, so retry never succeeds.

### Do not stack retry on retry without doing the arithmetic

Driver connection resiliency multiplies with application-level retry. The documented .NET example:
application logic retrying 4 times over a driver configured for 3 connection retries is **12**
attempts.

The .NET defaults an unconfigured string already has: `ConnectRetryCount` **1**,
`ConnectRetryInterval` **10** seconds, `Connection Timeout` **15** seconds, `Command Timeout` **30**
seconds. Learn states two inequalities that hold whatever the language:

- New connection: `Connection Timeout >= ConnectRetryCount * ConnectRetryInterval`, or the outer
  timeout cancels the last retry. At 3 retries of 10 seconds, a timeout of 29 never reaches the
  third.
- Reconnect during command execution: `Command Timeout > (ConnectRetryCount - 1) *
  ConnectRetryInterval`, plus time for the command itself.

Pick one layer to own retry and turn the other off deliberately. **Two Learn pages disagree about
what `ConnectRetryCount` covers**: the transient-errors article puts the initial `Open()` inside it,
the SqlClient overview calls it idle resiliency only. Assume the narrower reading and write your own
retry around the first connect.

## Encryption is not a knob to turn off

Microsoft's recommendation for every connection to Azure SQL Database, in every driver:
`Encrypt = On`, `TrustServerCertificate = Off`, plus `HostNameInCertificate = <full hostname>` when
the client connects through another name such as a DNS alias. Together they make the driver verify
the server's identity. `TrustServerCertificate=true` keeps the traffic encrypted but **stops the
client checking who it is talking to**, the part that matters on a public endpoint. Encryption and identity are
separate settings, and login credentials are encrypted whatever `Encrypt` says.

**The rule for an agent: a certificate error is a name problem, not a trust problem.** Fix the
hostname or set the hostname-in-certificate option. Never disable verification, never set
`Encrypt=false`; the one exception is the container's self-signed certificate above.

Two facts that change under the model's feet:

- **The defaults flipped.** `Microsoft.Data.SqlClient` 4.0 changed `Encrypt` from `false` to `true`
  and ODBC Driver 18 made the same change, both declared breaking. Code that worked before an
  upgrade and fails after it is usually this, surfacing as
  `SSL Provider: The certificate chain was issued by an authority that is not trusted`.
- **TLS 1.0 and 1.1 are retired.** The lowest minimum a server accepts is TLS 1.2, enforcing a
  specific minimum cannot be reverted, and enforcing 1.3 breaks clients whose driver or operating
  system does not support it.

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

## What the connection string carries

**Must have:** the fully qualified server name and port `1433`, the **user database** and never
`master`, encryption on with certificate trust off, and a connect timeout with room for the retries
inside it.

**Must not have:**

- a password literal. The secret comes from a secret store or the environment at run time: User
  Secrets locally, a vault in production, never a checked-in file.

  ```bash
  dotnet user-secrets init --project ./src/Api
  dotnet user-secrets set "ConnectionStrings:Default" \
    "Server=tcp:<server>.database.windows.net,1433;Initial Catalog=<database>;Authentication=Active Directory Default;Encrypt=Mandatory;Connect Timeout=60" \
    --project ./src/Api
  ```

- `TrustServerCertificate=true` outside the local container, or `Encrypt=false` anywhere
- `Authentication=Active Directory Password`. That mode is **deprecated** in the Microsoft SQL
  drivers, incompatible with mandatory Microsoft Entra multifactor authentication, and obsolete in
  `Microsoft.Data.SqlClient` 7.0. Use managed identity for Azure-hosted workloads, a service
  principal off Azure, and interactive when a human is present

### Gotcha: the generated connection string is not finished

```bash
az sql db show-connection-string -c ado.net -s <server> -n <database>
```

On 2.89.1 the output needs correcting by hand. The ODBC template emits
`Driver={ODBC Driver 13 for SQL Server}`, five major versions out of date. `--auth-type ADPassword`
emits the deprecated `Authentication="Active Directory Password"`. `--client` accepts only
`ado.net`, `jdbc`, `odbc`, `php`, `php_pdo` and `sqlcmd`, so asking it for a Node.js, Python or Go
template and paraphrasing the answer invents a string. And no template carries retry settings.

## Size the pool against workers, not sessions

The number an agent reaches for is the session limit, **30,000 on every vCore size**, never the
binding constraint. What throttles a workload is **concurrent workers**:

| Compute, standard-series | Concurrent workers |
|---|---|
| General Purpose provisioned | **100 per vCore** (200 at 2 vCores, 1000 at 10) |
| General Purpose serverless | **75 per max vCore** (75 at 1, 300 at 4) |

And workers are not requests. Default `MAXDOP` for a new database is **8**, the limit is **per
task**, and each task takes a worker, so one parallel request consumes several and the ceiling
arrives sooner than a count of connections suggests.

Set an explicit maximum pool size: unlimited turns a traffic spike into `10928`. Sum the
pools across **every** instance, background workers and scheduled jobs included, and keep the total
under the worker limit with headroom. In serverless and short-lived compute create **one pool per
process** and reuse it; one per request or per invocation exhausts outbound ports and causes
connection storms. A database already failing with `10928` is `diagnose-resource-pressure`.

## The network path, when it works from one place but not another

The connection policy decides the route and its default differs by where the client is. **Outside
Azure** it is `Proxy`: everything goes through the gateway and the client needs outbound `1433`
only. **Inside Azure** it is `Redirect`: after the gateway handshake the session moves to the node
hosting the database, so the client needs outbound `1433` **plus 11000 to 11999** to the region's
Azure SQL Database addresses. That asymmetry is why an application works from a laptop and times out
from a virtual machine behind a restrictive network security group. `Redirect` is recommended; the cost is the wider
outbound range.

```bash
az sql server conn-policy show -g <resource-group> -n <server>
az sql server conn-policy update -g <resource-group> -n <server> --connection-type Redirect
```

`--connection-type` accepts `Default`, `Proxy` and `Redirect`.

## Check it worked

Three checks, run against the target the application will use, with `-C` added only for the
container.

**1. The connection is encrypted and landed in the user database.** The first command above asks
the engine itself, so it settles encryption without trusting the client. Expected: `db` is the user
database and not `master`, `encrypt_option` is `TRUE`, and the command succeeding with no `-C` is
itself the proof that the certificate validated.

**2. A string left on `master` cannot be corrected at run time**, which is why the database belongs
in the connection string:

```sql
USE master;
```

Expected: `Msg 40508, USE statement is not supported to switch between databases.`

**3. No secret reached the repository.**

```bash
git grep -nEi "(password|pwd)=[^;\"']" -- . ":!*.md"
```

Expected: no output, exit 1. Any hit is a secret in source, whatever else works.

A fourth check on serverless or free: leave the database idle past the auto-pause delay, run the
application cold, and confirm the code survives `40613`.

## Read the source when

Fetch the Microsoft Learn article rather than recalling it when an error number needs a cause (then
`diagnose-connection-errors`), when the retry delays matter to a design (the transient errors
article), when a resource limit is close (the vCore resource limits reference, the only current
source for worker counts), or when a TLS minimum is being set (the connectivity settings article).

## Do not

- Do not present retry as an optional later step. `40613` on a first connect is the documented
  resume path, not an outage.
- Do not set `TrustServerCertificate=true` or `Encrypt=false` to clear a certificate error against
  the cloud, not even temporarily. That change survives to production.
- Do not carry the container's `-C` into the cloud string. It is the one line that must not travel.
- Do not use `Authentication=Active Directory Password`, or copy it out of generated output, and do
  not paste a generated ODBC connection string without correcting the driver name.
- Do not size a pool against the 30,000 session limit, or create one per request or per invocation.
- Do not apply any of this to Azure SQL Managed Instance or SQL database in Fabric. Different
  connectivity model, different limits.
