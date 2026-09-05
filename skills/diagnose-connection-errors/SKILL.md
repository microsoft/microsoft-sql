---
name: diagnose-connection-errors
description: >-
  Diagnoses an Azure SQL Database connection refused before a credential was evaluated, reading the
  error number and its severity to name the layer that refused: the IP firewall (40615), a virtual
  network rule (40914), public network access disabled (47073, 42101), the gateway declining a
  server name or login format (40532, 40531), a TLS version under the server minimum (47072), plus
  the transport, pre-login, timeout and certificate failures that carry no usable number. Use when
  someone pastes an error naming an IP address, a firewall, the gateway, a certificate chain, the
  pre-login handshake or a bare timeout, and before anyone edits a connection string over one: none
  of them is a connection-string problem. Not for what the server decided after reading the
  credential: a login evaluated and refused, or a valid login with no user in the database, is
  entra-id-auth's, and a database answering that it is not currently available and asking for a
  retry is expected serverless resume, which connect-to-azure-sql owns.
---

# Diagnose an Azure SQL Database connection error

**Read the number, then read its severity.** The number names the layer that refused, and the
severity says what kind of layer it was. Microsoft Learn defines the levels: **11** is an object or
entity that does not exist, **14** is security, **16** is user-correctable configuration, **17** is
the service out of some resource, **20 and above** is fatal and usually takes the connection with
it, and **10** is informational and is *converted to severity 0 before it reaches the calling
application*. That last one is why the worst-explained connection failures look like they carry no
number at all.

Sourced from Microsoft Learn on 2026-09-03, and checked against sqlcmd 1.10.0 and Azure CLI 2.90.0.

## Step 1: make the number visible

`-b` sets a non-zero exit only at severity 11 and above. Without `-m-1` a severity 10 message prints
its text with no `Msg` number, which is the class 47072, 47073 and 42101 belong to.

**`-m-1` is an ODBC `sqlcmd` instruction**, meaning the 18.x build from `mssql-tools18` or the
Microsoft command line utilities. Measured 2026-09-05, go-sqlcmd 1.10.0, the 1.x build
`brew install sqlcmd` and `winget install sqlcmd` install, prints no `Msg` header on a severity 10
message at any `-m` value, so on that build those three numbers never appear at all, and `sys.messages` is the way to get them. `build-app-on-azure-sql` tells the two
builds apart in one table.

```bash
sqlcmd -S your-server.database.windows.net,1433 -d your-database -U your-login -P "$SQL_PASSWORD" \
  -N -l 30 -b -m-1 -Q "SELECT 1"
```

`-N` requests an encrypted connection and `-l 30` is the connection timeout Learn recommends as a
floor. Then resolve the number on the engine rather than from memory, with the
catalog view Learn publishes for exactly this:

```sql
SELECT message_id, severity, is_event_logged, [text]
FROM sys.messages
WHERE language_id = 1033 AND message_id IN (4060, 18456, 40532, 40613, 40615)
ORDER BY message_id;
```

## The severity column is the diagnosis

| Number | Sev | What refused, and what the severity says about it | First move |
|---|---|---|---|
| `40615` | 16 | No IP rule covers the address the server saw | Add the IP rule, then allow five minutes |
| `40914` | not sourced | The client subnet has service endpoints and the server has no virtual network rule | Add the virtual network rule for the subnet |
| `47073` | 10 | Public network access is Disable, and severity 10 means the client may see no number | Use the private endpoint, or set public access to selected networks |
| `42101` | 10 | A firewall rule change while public network access is Disable | Set public access to selected networks first |
| `47072` | 10 | The client offered a TLS version below the server minimum | Raise the client to TLS 1.2 or higher |
| `40532` | 11 | 11 is "the given object does not exist", and the object is the **server**, not the login | Check the server name and login format |
| `40531` | 11 | The gateway could not determine the server name from the connection | Send `username@servername`, or fix the first DNS segment |
| `18456` | 14 | Security: the login was evaluated and refused | Named here, answered by `entra-id-auth` |
| `4060` | 11 | The object that does not exist is the **user in that database** | Named here, answered by `entra-id-auth` |
| `40613` | 17 | The service is out of something. On a paused serverless or free database it is the expected first answer | `connect-to-azure-sql` owns the retry doctrine |
| `10928` / `10929` | 16 | A limit was reached. Resource ID 1 is workers, 2 is sessions | See `diagnose-resource-pressure` |
| `40544` | 20 | Size quota, and 20 is fatal, so the connection is gone and retrying on it cannot work | Free space or scale up |
| `40501` / `49918` / `40197` | 16 | Busy or reconfiguring. Transient | Retry with backoff |

`18456`, `4060` and `40613` keep a row so a pasted number resolves, and nothing more.

## 47072, 47073 and 42101 are severity 10, and Learn disagrees with itself

The connectivity settings page prints them as top-level errors, for example `Error 47073`. The
error number tables list all three at **severity 10** with text beginning `Reason:`, the shape of a
sub-message attached to a login failure rather than a standalone error. Both are Microsoft Learn and
they do not agree.

Take the tables as operative: they explain the symptom. Severity 10 becomes 0 on the way to
the client, so a developer whose public network access was disabled reports a timeout and never sees
`47073`. `-m-1` on ODBC `sqlcmd` is what makes it visible. On go-sqlcmd 1.10.0 nothing does, so
look the number up in `sys.messages` on a connection that works.

## 40615 and 40914 are the firewall, and no connection string fixes them

The address to allow is **the address the server observed**, which network address translation
usually makes different from the client's configured address. `40615` names it in the message, so
read it there rather than guessing.

```bash
az sql server firewall-rule list -g your-resource-group -s your-server -o table
az sql server firewall-rule create -g your-resource-group -s your-server \
  -n AllowDevWorkstation --start-ip-address 192.168.1.0 --end-ip-address 192.168.1.255
```

Two things that go wrong here:

- **Changes take up to five minutes.** A rule that looks correct and still fails may simply be
  young. `DBCC FLUSHAUTHCACHE;` refreshes it sooner, but it runs **in the user database**, never in
  the logical `master` where the rules physically live, needs `KILL DATABASE CONNECTION` or the
  admin account, and needs a connection that already works. It is a tool for the second database,
  not the one locking you out.
- **A rule from `0.0.0.0` to `0.0.0.0` is not a wildcard for the internet.** It is the documented
  `AllowAllWindowsAzureIps` special case, and Microsoft warns it admits Azure resources in *other
  customers' subscriptions*. Prefer a virtual network rule or a private endpoint.

## 40532 is not 18456 and it is not 4060

All three read as "login failed" and are routinely answered as one thing. Telling them apart is the
diagnosis this skill exists to make, because `40532` is fixed by correcting the connection target
and the other two never are. The severity table above splits them: `40532` is the gateway refusing
before any database was reached, `18456` is the login refused at severity 14, and `4060` is a valid
login with no user in the database it asked for.

Check the login format before the credential. `40531` documents the rule: the server name must be
the first segment of the DNS name, and some libraries do not send it at all, in which case it travels
as `username@servername`. If both are sent they must match.

Azure SQL Database withholds the reason from the client and there is no server error log to read the
state from, so do not promise a diagnosis the platform does not expose. Narrow it by what changed: a
new server, a new password, a new database name, a new deployment slot.

One more check when it fails on some client networks only. A hosts file or a private DNS zone
pinning the server name to a retired gateway address produces persistent 18456, 40532 and 40615
failures, because the gateway validates the name it was reached by, and logins sent straight to an
IP address fail by design.

## Public network access and the minimum TLS version

Both are server properties and both refuse at severity 10, so read them rather than infer them:

```bash
az sql server show -n your-server -g your-resource-group \
  --query "{publicNetworkAccess:publicNetworkAccess, minimalTlsVersion:minimalTlsVersion}"
```

TLS 1.0 and 1.1 are retired, the lowest minimum Azure SQL Database supports is 1.2, and **once a
minimum is enforced it cannot be reverted to the default**. Enforcing 1.3 breaks clients whose
driver or operating system does not support it.

## Errors with no number, and the certificate case

When the remote host terminates the TCP connection the client library raises the error, so the SQL
number is `0` and the text belongs to the TCP provider. The one to recognise names the **pre-login
handshake** and a TCP provider error 0. Microsoft's guidance is a **fixed number of
retry attempts** before declaring failure. This is also the usual shape of a firewall or network
appliance dropping the connection mid-stream.

**The certificate failure is a different animal.** `The certificate chain was issued by an authority
that is not trusted` means the client does not trust the public root the service certificate chains
to, or is not reaching the service at all. The roots to have are DigiCert Global Root G2, Microsoft
ECC Root Certificate Authority 2017 and Microsoft RSA Root Certificate Authority 2017.

Test it with encryption on and no trust override. If this succeeds, the chain validates and the
certificate is not your problem:

```bash
sqlcmd -S your-server.database.windows.net,1433 -U your-login -P "$SQL_PASSWORD" \
  -N -l 30 -b -m-1 -Q "SELECT 1"
```

Do not resolve it with `-C` or `TrustServerCertificate=true` outside local development. That
disables the validation the error is reporting and leaves the connection encrypted but
unauthenticated, which is the attack the check exists to prevent. Fix the trust store instead.

## Local container differences

The `40xxx` family is the gateway, the IP firewall and the service's resource governance, and the
local Azure SQL Database container has none of the three, so an agent chasing a firewall rule to
explain a local failure is chasing something that is not there. What remains locally is the
numberless class above, which behaves the same in both places. A `40xxx` failure in the cloud had no
local equivalent to fail on, so a clean local run is not evidence either way.

## Check it worked

Run the same command that failed, `-b -m-1` still on, and check three things in order.

```bash
sqlcmd -S your-server.database.windows.net,1433 -d your-database -U your-login -P "$SQL_PASSWORD" \
  -N -l 30 -b -m-1 -Q "SELECT DB_NAME() AS db, SUSER_SNAME() AS login_name;"
echo "exit=$?"
```

- **Exit 0 and one row** naming the database and login you expected. Exit 0 with no row means the
  statement never ran.
- **A different number is progress, not failure.** `40615` becoming `18456` means the firewall fix
  worked and the credential is the next problem, which is `entra-id-auth`'s.
- **The same number after a firewall change** is most likely the five minute propagation delay, not
  a wrong rule. Confirm the rule with `az sql server firewall-rule list` before changing anything
  else.

## Before reporting a diagnosis

- [ ] The number and its severity were both read before any file was edited
- [ ] `-m-1` was on, so a severity 10 refusal could not hide as a timeout
- [ ] A `40xxx` error was not blamed on the connection string
- [ ] `40532` was told apart from `18456` and `4060`, not merged into "login failed"
- [ ] A certificate error was not answered by trusting the server certificate
- [ ] Nothing past the credential was answered here

## References

- [references/error-codes.md](references/error-codes.md): open it when the number is not in the
  table above, or when the exact documented wording matters, because it carries the verbatim text,
  the severity and the Microsoft Learn page each number came from.
