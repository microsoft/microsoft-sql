---
name: connect-from-python
description: >-
  Connects a Python application to Azure SQL Database, choosing between Microsoft's first-party
  mssql-python driver and the incumbent pyodbc, and covering driver installation, the connection
  string each one wants, connection pooling, and Microsoft Entra ID including token-based
  authentication. Use when a user says "connect Python to Azure SQL", "mssql-python", "pyodbc",
  "install the ODBC driver so my Python code can connect", "which Python driver for SQL Server",
  or hits errors such as "data source name not found and no default driver specified" or a
  container image that cannot load the driver. Also use when adding a database layer to a Python
  service, or when it needs a passwordless connection. Covers installation, connection strings,
  pooling and Entra ID for Python only. Encryption doctrine and transient-fault retry belong to
  connect-to-azure-sql; Node and .NET have their own skills.
---
# Connect from Python

The Python answer changed. There are now two supported drivers, and the newer one removes the step
that causes most Python connection failures: installing an ODBC driver into the operating system.

Checked on 2026-09-03 against pyodbc 5.3.0, msodbcsql18 18.6.2.1 and unixODBC 2.3.14 on this
machine, and the current documentation for mssql-python 1.13.0.

This skill owns driver choice, installation, connection string shape, pooling and Entra ID for
Python. Encryption doctrine, retry and the first-connect error on a paused database are the same in
every language and live in `connect-to-azure-sql`. SQLAlchemy is `sqlalchemy-azure-sql`.

## Choose the driver first

| | `mssql-python` 1.13.0 | `pyodbc` 5.3.0 |
|---|---|---|
| Who ships it | Microsoft, first-party | Community, long-standing |
| Python required | 3.10 or later | 3.9 or later |
| Operating system install | **None.** `mssql-python-odbc` carries the driver binaries | `msodbcsql18` and a driver manager, per distribution |
| Entra `ActiveDirectoryDefault` | Yes, and `azure-identity` comes with it | No, see below |

**Use `mssql-python` for new code.** Skipping the operating system install removes a class of
container and CI failures. **Keep `pyodbc` when something above it already requires it**, most often
an ORM dialect such as SQLAlchemy or Django. Use `sqlalchemy-azure-sql` for SQLAlchemy-specific
configuration. Do not rewrite a data access layer just to change driver.

```bash
pip install mssql-python        # first-party path
pip install pyodbc              # incumbent path, plus the driver install below
```

On Python 3.9 the first line fails with `No matching distribution found`, which reads like a network
problem and is not one. Measured here on 3.9.6.

## Installing the ODBC driver, for the pyodbc path only

The package is **`msodbcsql18`**, the connection string names `ODBC Driver 18 for SQL Server`, and
the two have to agree exactly. `pip install pyodbc` succeeds without it and the failure arrives at
the first connect, which is why the first check below exists.

Three things break an unattended build: the licence prompt, Alpine having no Microsoft package
repository, and slim Debian omitting `libgssapi-krb5-2`. Open
[references/odbc-driver-install-on-linux.md](references/odbc-driver-install-on-linux.md) before you
write a Dockerfile or CI step that installs the driver.

## Connection strings

Both take ODBC-style keywords. `mssql_python.connect()` takes the same string with `Driver` left
out, because the driver is inside the package. `pyodbc` needs it named, and the name is the one the
install registered:

```python
import pyodbc

conn = pyodbc.connect(
    "Driver={ODBC Driver 18 for SQL Server};"
    f"Server=tcp:{server},1433;"
    f"Database={database};"
    "Encrypt=yes;"
)
```

Read the server, database and any credential from the environment or a secret store, never a
literal in source, and bind every value in a query rather than formatting it into the text.

## Pooling

**`mssql-python` pools by default**, `max_size` 100 and `idle_timeout` 600 seconds.

```python
import mssql_python

# Call this ONCE, before the first connect. Afterwards it has no effect.
mssql_python.pooling(max_size=25, idle_timeout=300)
```

A `pooling()` call after any connect is silently ignored, which looks exactly like a setting that
did not take. The pool key is the connection string byte for byte, so one extra keyword or a
different capitalisation on one call site produces a second independent pool: build it once as a
constant. Under managed identity, device code or a `token_provider` the identity joins the key.
There is no `ClearPool`, no pool statistics and no minimum size.

**`pyodbc` does not pool in Python.** Pooling happens in the ODBC layer, `pyodbc.pooling` reads
`True` out of the box, and it is switched off by assigning `False` **before any connection is
made**. Its context manager is not `mssql-python`'s: `Connection.__exit__` commits, or rolls back on
an exception, and **does not close**, so `with pyodbc.connect(...)` alone never returns the
connection. Call `close()` in a `finally`. Never enable `pyodbc.pooling` and a pool above it at
once.

Pool sizing, and why the binding limit is workers rather than sessions, is `connect-to-azure-sql`.

## Microsoft Entra ID

### With mssql-python

Set the `Authentication` keyword: `ActiveDirectoryDefault` locally, because it picks up a CLI
sign-in, and `ActiveDirectoryMSI` for a managed identity in production.

```python
conn = mssql_python.connect(
    f"Server=tcp:{server},1433;Database={database};"
    "Authentication=ActiveDirectoryMSI;"
    f"UID={client_id};"          # only for a user-assigned managed identity
    "Encrypt=yes;"
)
```

`ActiveDirectoryDefault` walks a chain of providers on the first connection, failures first, so it
costs seconds production has no reason to pay. Name the credential type directly there. Where the
credential is an `azure-identity` object, `token_provider=` takes it whole and refreshes tokens for
pooled connections.

### With pyodbc

**The ODBC driver has no `ActiveDirectoryDefault`.** It is not a slower path, it is a rejected
string, and the driver says so before it opens a socket:

```bash
python3 -c "
import pyodbc
try:
    pyodbc.connect('Driver={ODBC Driver 18 for SQL Server};Server=tcp:127.0.0.1,1;'
                   'Authentication=ActiveDirectoryDefault;Encrypt=yes;', timeout=2)
except pyodbc.Error as e:
    print(e.args[0], e.args[1])
"
```

Measured 2026-09-03: `08001`, `Invalid value specified for connection string attribute
'Authentication'`. Swap in `ActiveDirectoryMsi` and the same command reaches `HYT00`, login timeout,
because that value is accepted. The keyword takes `SqlPassword`, `ActiveDirectoryIntegrated`,
`ActiveDirectoryInteractive`, `ActiveDirectoryMsi`, `ActiveDirectoryServicePrincipal` and the
deprecated `ActiveDirectoryPassword`, and nothing else.

To get the same behaviour, acquire the token in Python and hand it to the driver:

```python
import struct
from azure.identity import DefaultAzureCredential
import pyodbc

# msodbcsql.h: SQL_COPT_SS_BASE_EX (1240) + 16
SQL_COPT_SS_ACCESS_TOKEN = 1256

token = DefaultAzureCredential().get_token("https://database.windows.net/.default").token
packed = token.encode("utf-16-le")
token_struct = struct.pack(f"<I{len(packed)}s", len(packed), packed)

conn = pyodbc.connect(
    "Driver={ODBC Driver 18 for SQL Server};"
    f"Server=tcp:{server},1433;Database={database};Encrypt=yes;",
    attrs_before={SQL_COPT_SS_ACCESS_TOKEN: token_struct},
)
```

Three details that fail silently if missed: the attribute id is **1256**, the token is **UTF-16
little-endian** behind a four-byte length prefix, and the connection string must contain **no**
`UID`, `PWD`, `Authentication` or `Trusted_Connection`. Supplying both is refused as `FA005`,
`Cannot use Access Token with any of the following options`, measured the same day.

Either way the identity needs a database principal first. Creating it, and what the container does
with no Entra configuration at all, is `entra-id-auth`.

## Check it worked

**One: the driver name in your string is a name the driver manager has.** No database needed, and
it settles most Python connection failures:

```bash
python3 -c "import pyodbc; print(pyodbc.version, pyodbc.drivers())"
```

Expect `ODBC Driver 18 for SQL Server` in the list. Measured here on 2026-09-03: `5.3.0 ['ODBC
Driver 18 for SQL Server', 'ODBC Driver 17 for SQL Server']`. An empty list means the package
installed and the driver did not.

The two failures look nothing alike and only one is the one everybody quotes. On unixODBC 2.3.14 a
`Driver={...}` naming something unregistered raises `01000`, `Can't open lib '<name>' : file not
found`. `IM002`, `Data source name not found and no default driver specified`, is a string that
named no driver at all. Installing `msodbcsql18` answers the first and nothing about the second.

**Two: encrypted, as the principal you meant, against the database you meant.** Save this as
`check_connection.py`:

```python
import os, sys, pyodbc

CONN = (
    "Driver={ODBC Driver 18 for SQL Server};"
    f"Server=tcp:{os.environ['SQL_SERVER']},1433;Database={os.environ['SQL_DATABASE']};"
    f"UID={os.environ['SQL_USER']};PWD={os.environ['SQL_PASSWORD']};"
    "Encrypt=yes;TrustServerCertificate=no;"
)

conn = pyodbc.connect(CONN, timeout=15)
try:
    db, login, user, enc = conn.cursor().execute(
        "SELECT DB_NAME(), SUSER_SNAME(), USER_NAME(),"
        " (SELECT encrypt_option FROM sys.dm_exec_connections WHERE session_id = @@SPID)"
    ).fetchone()
finally:
    conn.close()

print(f"database={db} login={login} user={user} encrypted={enc}")
sys.exit(0 if (enc == "TRUE" and db == os.environ["SQL_DATABASE"]
               and login == os.environ["SQL_EXPECT_LOGIN"]) else 1)
```

```bash
export SQL_SERVER=<server-name>.database.windows.net SQL_DATABASE=<database> \
       SQL_USER=<user> SQL_PASSWORD=<password> SQL_EXPECT_LOGIN=<user>
python3 check_connection.py; echo "exit $?"
```

Expect exit `0` and a line ending `encrypted=TRUE`. Read the fields, not only the exit code:

- `encrypted=FALSE` is driver 17, whose `Encrypt` default is `no`. Driver 18 defaults to `yes`.
- `login` is who authenticated. A credential chain that picked up your own sign-in instead of the
  managed identity shows up here and nowhere else.
- `user` is the database principal that login mapped to. Anything but the one you granted means the
  grant landed in a different database.
- `TrustServerCertificate=yes` still prints `TRUE`: it keeps encryption and drops validation. Azure
  SQL Database needs no such exemption; the container's self-signed certificate does, and
  `connect-to-azure-sql` owns which.
- A permissions error from `sys.dm_exec_connections` is `VIEW DATABASE STATE`, not encryption: on
  Basic, S0, S1 and elastic pool databases only an administrator can read it.

## Do not

- Do not assume `pyodbc` is the only Python driver. That was true and is not.
- Do not add an operating system ODBC driver install to a `mssql-python` deployment.
- Do not put `Authentication=ActiveDirectoryDefault` in a `pyodbc` string, or an access token
  alongside `UID`, `PWD` or `Authentication`.
- Do not use `ActiveDirectoryPassword`, or `ActiveDirectoryDefault` in production.
- Do not build SQL text with string formatting. Bind parameters.
- Do not write retry loops here. Transient-fault handling is one policy for every language, in
  `connect-to-azure-sql`.

## References

- [Microsoft Python driver for SQL Server](https://learn.microsoft.com/sql/connect/python/mssql-python/python-sql-driver-mssql-python):
  read it before writing new Python data access.
- [Microsoft Entra authentication with mssql-python](https://learn.microsoft.com/sql/connect/python/mssql-python/entra-authentication):
  read it when choosing a mode, for the authoritative list and `token_provider`.
- [Using Microsoft Entra ID with the ODBC driver](https://learn.microsoft.com/sql/connect/odbc/using-azure-active-directory):
  read it before claiming the driver supports a mode. Carries the access token structure.
- [DSN and connection string keywords](https://learn.microsoft.com/sql/connect/odbc/dsn-connection-string-attribute):
  read it before changing an encryption or certificate keyword. `Encrypt` defaults to `yes` from
  version 18.
- `connect-to-azure-sql`: encryption doctrine, retry, pool sizing, and the first-connect error on a
  paused database.
