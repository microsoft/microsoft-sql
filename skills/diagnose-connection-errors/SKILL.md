---
name: diagnose-connection-errors
description: >-
  Turns an Azure SQL Database connection error number or message into the cause and the fix, for
  every failure that happens before a credential is ever evaluated: 40615, 40914, 40532, 10928,
  10929, 40501, 40544, 42101, 47072, 47073, and the pre-login, timeout and certificate failures
  that carry no SQL error number at all. Use when a connection attempt has already failed and
  someone pastes the error, or says "client with IP address is not allowed to access the server",
  "the certificate chain was issued by an authority that is not trusted", "pre-login handshake
  failed" or "connection timeout expired". Reach for this before editing a connection string,
  because most of these are not connection-string problems. Nothing past the login is answered
  here: 18456, a login that was evaluated and refused, and 4060, a valid login with no user in the
  database it asked for, belong to entra-id-auth, and 40613 is expected serverless resume and
  belongs to connect-to-azure-sql.
---

# Diagnose an Azure SQL Database connection error

**Read the number before you read the message.** The number names the layer that rejected the
connection, and that layer is usually not the one the message points at.

Verified against Microsoft Learn on 2026-08-27. Every number and message quoted here is sourced in
[references/error-codes.md](references/error-codes.md).

## Triage in one pass

Ask three questions in this order. Stop at the first yes.

1. **Is there a SQL error number?** Look it up in the table below, then in the reference. The
   number is the diagnosis.
2. **Does the message name TCP, SSL, the pre-login handshake, or a certificate?** These carry
   **error number 0** because they are raised by the client, not the engine. Go to
   [Errors with no number](#errors-with-no-number).
3. **Does it only say "timeout"?** A timeout is a symptom of the first two, not a cause. Check the
   firewall rule and public network access first, because both fail as a timeout.

| Number | What it actually means | First move |
|---|---|---|
| `40613` | The database is not currently available. On a paused serverless or free database this is the **expected** first-connect response, not a fault | Retry, and take the doctrine from `connect-to-azure-sql`, which owns this error |
| `40615` | The client IP has no firewall rule | Add a server-level or database-level IP rule |
| `40914` | The client subnet has no virtual network rule | Add the virtual network rule for that subnet |
| `47073` | Public network access is set to Disable, so only a private endpoint can connect | Connect privately, or re-enable public access |
| `42101` | Firewall rules cannot be changed while public network access is disabled | Set public access to selected networks first |
| `18456` | Login failed. The login does not exist, is disabled, or the credential is wrong | Named here, answered by `entra-id-auth`, which owns logins and database users |
| `4060` | The login is valid, but it cannot open **that database**, which after a deployment is almost always a missing database user | Named here, answered by `entra-id-auth` |
| `40532` | The gateway rejected the login before it reached a database | Check the server name and the login format |
| `47072` | The client negotiated a TLS version below the server minimum | Raise the client to TLS 1.2 or higher |
| `10928` / `10929` | A resource limit was reached. Resource ID 1 is workers, 2 is sessions | See `diagnose-resource-pressure` |
| `40501` / `49918` / `40197` | The service is busy or reconfiguring. Transient | Retry with backoff |
| `40544` | The database reached its size quota | Free space or scale up |

## Three numbers named here only to hand on

**The split, stated once: this skill owns every failure that happens before a credential is
evaluated, and `entra-id-auth` owns every failure after it.** Everything else in that table is a
rejection in front of the login, which is why one skill can answer them all. `40613`, `18456` and
`4060` fall the other side of that line. They stay in the table so a pasted error still resolves to
a number, and the answer to each of them is somewhere else.

### 40613 belongs to connect-to-azure-sql

It is the expected first response from a paused serverless or free database, not a fault, and the
answer is retry rather than configuration. **That is `connect-to-azure-sql`'s correction and its
doctrine, so send the reader there** rather than repeating it. Do not scale the database, do not
recreate it, and do not report a single occurrence as an outage.

One cause of `40613` does belong here, because it is a diagnosis rather than a retry policy: another
session already holds the dedicated administrator connection for that database, and only one may. A
`40613` against a database that is neither serverless nor free, and that survives a retry, is that
one.

### 18456 and 4060 belong to entra-id-auth

Both are past the login, and the fix for either is a login, a password or a database user rather
than anything on the connection path. **`4060` after a successful deployment is almost always a
missing database user**, not a missing login: a login lives on the server, a user lives in the
database and has to be created there. That work is `entra-id-auth`'s.

The diagnosis that does belong here is telling them apart from `40532`, which reads identically and
is a gateway rejection rather than a login failure. The section below on `40532` does that, and it
is the only reason either number keeps a row here at all.

**`18456` naming the literal user `<token-identified principal>`** is not a message that failed to
fill in a placeholder. The token was accepted and no matching principal exists in the database, so
the identity needs a database user. Route it to `entra-id-auth` and do not diagnose it further
here.

## 40615 and 40914 are the firewall, and no connection string fixes them

- **40615**: `Cannot open server '{0}' requested by the login. Client with IP address '{1}' is not allowed to access the server.`
- **40914**: `Cannot open server '[server-name]' requested by the login. Client is not allowed to access the server.`

The two are the same refusal from different rule types: 40615 is IP rules, 40914 is virtual
network rules. Read the message to tell them apart, because 40615 names an IP address and 40914
does not.

Three things worth knowing before proposing a fix:

- **Firewall rule changes take up to five minutes to take effect.** A rule that looks correct and
  still fails may simply be young. `DBCC FLUSHAUTHCACHE` on the database refreshes it sooner.
- **The address to allow is the address the server sees**, which network address translation
  usually makes different from the client's own configured address.
- **A rule from `0.0.0.0` to `0.0.0.0` is not a wildcard for the internet.** It is the documented
  special case meaning Azure-internal traffic, and it admits Azure resources in *other*
  subscriptions. Prefer a private endpoint or a virtual network rule when that matters.

An IP that is allowed and still fails, on some client networks only, is worth one more check: a
hosts file or a private DNS zone pinning the server name to a retired gateway address produces
persistent 18456, 40532 and 40615 failures, because the gateway validates the name it was reached
by. Login attempts sent straight to an IP address fail by design.

## 40532 is not 18456 and it is not 4060

All three read as "login failed" and they are routinely answered as one thing. Only `40532` is
answered here, and telling it from the other two is the diagnosis this skill exists to make,
because `40532` is fixed by correcting the connection target and the other two never are.

| | Rejected by | Means | Answered by |
|---|---|---|---|
| `40532` | The gateway | The login never reached a database at all | Here |
| `18456` | The login | The login was evaluated and refused | `entra-id-auth` |
| `4060` | The database | The login is fine and has no user in the database it asked for | `entra-id-auth` |

A `40532` is a server name the gateway cannot route, or a login written in a format the gateway
does not accept, so the thing to check is the server name and the login format rather than the
credential.

On Azure SQL Database the client message deliberately withholds the reason, and there is no server
error log to read the state from, so do not promise a diagnosis the platform does not expose.
Narrow it by what changed instead: a new server, a new password, a new database name, a new
deployment slot.

## Errors with no number

When the remote host terminates the TCP connection, the client library raises the error, so there
is no SQL number: the number is `0` and the text comes from the TCP provider. These are the ones
that look most alarming and mean least.

```
A connection was successfully established with the server, but then an error occurred during the
pre-login handshake. (provider: TCP Provider, error: 0 - An existing connection was forcibly
closed by the remote host.)
```

Microsoft's guidance is to treat these as possibly transient and possibly permanent, and to use a
**fixed number of retry attempts** before declaring failure. They are also the usual shape of a
firewall or network appliance dropping the connection in the middle.

**The certificate failure is a different animal.**
`The certificate chain was issued by an authority that is not trusted` against Azure SQL Database
means the client does not trust the public root that the service certificate chains to, or is not
reaching the service at all. The roots to have in the trust store are DigiCert Global Root G2,
Microsoft ECC Root Certificate Authority 2017 and Microsoft RSA Root Certificate Authority 2017.

Do not resolve it by trusting the server certificate. That disables the validation the error is
reporting and keeps the encrypted connection unauthenticated, which is exactly the attack the
check exists to prevent. Fix the trust store, or find out what the client is really connecting to.

## Local container differences

Against the local Azure SQL Database container the whole `40xxx` family cannot occur: there is no
gateway, no IP firewall and no resource governance in front of it. An agent chasing a firewall rule
to explain a local failure is chasing something that does not exist there. What is left locally is
the numberless class above, which behaves the same way in both places.

The reverse is also useful. A connection that works against the container and fails in the cloud
with a `40xxx` number had no local equivalent to fail on, so a clean local run is not evidence
about it either way. A connection that instead fails in the cloud on the login is not a network
problem, and is `entra-id-auth`'s rather than this skill's.

## Before reporting a diagnosis

- [ ] The error number was read, and named the layer, before any file was edited
- [ ] A `40xxx` gateway error was not blamed on the connection string
- [ ] `40613` against a serverless or free database was called expected, and handed to `connect-to-azure-sql` rather than answered here
- [ ] `18456` and `4060` were named, then handed to `entra-id-auth` rather than answered here
- [ ] `40532` was told apart from both rather than merged into "login failed"
- [ ] A certificate error was not answered by turning off certificate validation
- [ ] Any claim about a firewall rule accounted for the five minute propagation delay

## References

- [references/error-codes.md](references/error-codes.md): every number in the table above with its
  verbatim message text, its cause, its fix, and the Microsoft Learn page it came from. The three
  handed on above are indexed there too, so a number can be identified before it is routed. Read it
  when the number is not in the short table, or when the exact wording matters.
