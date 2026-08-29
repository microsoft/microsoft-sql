---
name: connect-from-python
description: >-
  Connects a Python application to Azure SQL Database, choosing between Microsoft's first-party
  mssql-python driver and the incumbent pyodbc, and covering driver installation, the connection
  string each one wants, connection pooling, and Microsoft Entra ID including token-based
  authentication. Use when a user says "connect Python to Azure SQL", "mssql-python", "pyodbc",
  "install the ODBC driver so my Python code can connect", "which Python driver for SQL Server", or
  hits errors such as "data source name not found and no default driver specified" or a container
  image that cannot load the driver. Also use when a Python service needs a passwordless
  connection. Covers installation, connection strings, pooling and Entra ID for Python only.
  Encryption doctrine and transient-fault retry belong to connect-to-azure-sql; Node and .NET have
  their own skills.
license: MIT
---

# Connect from Python

The Python answer changed. There are now two supported drivers, and the newer one removes the
step that causes most Python connection failures: installing an ODBC driver into the operating
system.

Verified on 2026-08-27 against `mssql-python` 1.13.0 and `pyodbc` 5.3.0, from package metadata on
the index and the current driver documentation.

This skill owns the Python-specific half: which driver, how it installs, the connection string
shape, pooling, and how Python does Entra ID. Encryption doctrine, retry and transient-fault
handling, and the first-connect error on a paused database are the same in every language and live
in `connect-to-azure-sql`.

## Choose the driver first

| | `mssql-python` | `pyodbc` |
|---|---|---|
| Who ships it | Microsoft, first-party | Community, long-standing |
| Version verified | 1.13.0 | 5.3.0 |
| Python required | 3.10 or later | 3.9 or later |
| Operating system install | **None.** The wheel depends on `mssql-python-odbc`, which carries the driver binaries | `msodbcsql18` and a driver manager, installed separately per distribution |
| Python dependencies | `azure-identity` comes with it | none |
| Entra `ActiveDirectoryDefault` | Yes | No, see below |

**Use `mssql-python` for new code.** It is what the current Azure SQL Database Python quickstart
uses, and skipping the operating system driver install removes an entire class of container and
CI failures.

**Keep `pyodbc` when something above it already requires it**, most often an ORM or framework whose
dialect is written against `pyodbc`. Those integrations are `sqlalchemy-azure-sql` and
`django-azure-sql`; do not rewrite an application's data access layer just to change driver.

```bash
pip install mssql-python        # first-party path
pip install pyodbc              # incumbent path, plus the driver install below
```

`mssql-python` needs Python 3.10 or later, and on an older interpreter the install fails with
`No matching distribution found`, which reads like a network problem and is not one. Check the
interpreter before debugging the index.

## Installing the ODBC driver, for the pyodbc path only

`pip install pyodbc` succeeds on its own: the project publishes both `manylinux` and `musllinux`
wheels, so there is no compiler step even on a musl-based image. What is missing at runtime is the
**driver itself**, and the error says `data source name not found and no default driver specified`,
which points at the connection string rather than at the missing package.

What to know rather than copy:

- The package is **`msodbcsql18`**, and the connection string names `ODBC Driver 18 for SQL Server`.
  The two have to agree.
- Installation is **non-interactive only if you accept the licence explicitly**: set `ACCEPT_EULA=Y`
  on the install command, or from driver 18.4 create the file
  `/opt/microsoft/msodbcsql18/ACCEPT_EULA`. Without one of those a container build hangs waiting on
  a prompt nobody can answer.
- Most distributions install from the Microsoft package repository. **Alpine does not**: there is
  no repository, so the `.apk` is downloaded and installed with `apk add --allow-untrusted`. A
  Dockerfile that assumes a package manager repository is the usual reason an Alpine image fails.
- Slim Debian images also need `libgssapi-krb5-2`, which the driver links against and slim images
  omit.

The per-distribution commands change with releases, so fetch them rather than reciting them:
[Install the Microsoft ODBC driver for SQL Server on
Linux](https://learn.microsoft.com/sql/connect/odbc/linux-mac/installing-the-microsoft-odbc-driver-for-sql-server).

## Connection strings

`mssql-python` takes ODBC-style keywords and needs no `Driver` keyword, because there is only one
driver and it is inside the package:

```python
import mssql_python

conn = mssql_python.connect(
    f"Server=tcp:{server},1433;"      # <server>.database.windows.net
    f"Database={database};"
    "Encrypt=yes;"
)
```

`pyodbc` needs the driver named, and the name is the one the install registered:

```python
import pyodbc

conn = pyodbc.connect(
    "Driver={ODBC Driver 18 for SQL Server};"
    f"Server=tcp:{server},1433;"
    f"Database={database};"
    "Encrypt=yes;"
)
```

Read the server, database and any credential from the environment or a secret store. Never assemble
a literal one into source.

## Pooling

**`mssql-python` pools by default.** Verified defaults: `max_size` 100 connections per unique
connection string, `idle_timeout` 600 seconds.

```python
import mssql_python

# Call this ONCE, before the first connect. Afterwards it has no effect.
mssql_python.pooling(max_size=25, idle_timeout=300)
```

Three properties that decide whether the pool works:

- **Configuration must precede the first connection.** A `pooling()` call after any connect is
  silently ignored, which looks exactly like a setting that did not take.
- **The pool key is the connection string, byte for byte.** Different capitalisation, or an extra
  keyword on one call site, produces a second independent pool. Build the string once as a constant.
- **Connections must be returned.** Use the connection as a context manager so an exception still
  releases it.

There is no `ClearPool`, no pool statistics and no minimum size in the current implementation. Do
not write code that assumes them.

**`pyodbc` does not pool in Python.** Pooling happens in the ODBC layer, it is **on by default**,
and it is switched off with the module attribute `pyodbc.pooling = False` set **before any
connection is made**. When something above `pyodbc` runs its own pool, the two layers should not
both be enabled; the framework's documentation says which to turn off.

How large the pool should be, and why the binding limit is workers rather than sessions, is
`connect-to-azure-sql`.

## Microsoft Entra ID

### With mssql-python

Set the `Authentication` keyword. The accepted values are:

| Value | Use it for |
|---|---|
| `ActiveDirectoryDefault` | Local development. Uses `DefaultAzureCredential`, so a prior CLI sign-in is picked up |
| `ActiveDirectoryMSI` | A managed identity in production |
| `ActiveDirectoryServicePrincipal` | A registered application, client id in `UID` and secret in `PWD` |
| `ActiveDirectoryInteractive` | A person at a browser |
| `ActiveDirectoryDeviceCode` | A shell or container with no browser |
| `ActiveDirectoryIntegrated` | A domain-joined Windows client with Kerberos |
| `ActiveDirectoryPassword` | Nothing. Microsoft has deprecated this flow |

```python
conn = mssql_python.connect(
    f"Server=tcp:{server},1433;Database={database};"
    "Authentication=ActiveDirectoryMSI;"
    f"UID={client_id};"          # only for a user-assigned managed identity
    "Encrypt=yes;"
)
```

`ActiveDirectoryDefault` walks a chain of credential providers on the first connection and the
providers that fail come first, so it costs seconds of latency that a production workload has no
reason to pay. Name the credential type directly in production. `ActiveDirectoryDefault`,
`ActiveDirectoryInteractive` and `ActiveDirectoryDeviceCode` need `azure-identity` present, which it
already is as a dependency.

### With pyodbc

**The ODBC driver has no `ActiveDirectoryDefault`.** Its `Authentication` keyword accepts
`SqlPassword`, `ActiveDirectoryIntegrated`, `ActiveDirectoryInteractive`, `ActiveDirectoryMsi`,
`ActiveDirectoryServicePrincipal` and the deprecated `ActiveDirectoryPassword`, and nothing else. An
agent that writes `Authentication=ActiveDirectoryDefault` into a `pyodbc` connection string has
invented a value.

To get the same behaviour, acquire the token in Python and hand it to the driver:

```python
import struct
from azure.identity import DefaultAzureCredential
import pyodbc

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

Three details that make this fail silently if missed: the attribute id is **1256**, the token is
encoded **UTF-16 little-endian** behind a four-byte length prefix, and the connection string must
contain **no** `UID`, `PWD`, `Authentication` or `Trusted_Connection`. Supplying both is an error,
not a preference.

Either way the identity needs a database principal before it can connect. Creating it is
`entra-id-auth`.

## Validation rules

- New code uses `mssql-python`, and the reason is written down if it does not.
- A `pyodbc` deployment installs `msodbcsql18`, accepts the licence non-interactively, and names
  `ODBC Driver 18 for SQL Server` in the connection string.
- `mssql_python.pooling()` is called before the first connection, or not at all.
- The connection string is built once as a constant and reused, so the pool is not split.
- Connections are used as context managers.
- Entra ID on the `pyodbc` path goes through `SQL_COPT_SS_ACCESS_TOKEN`, and that connection string
  carries no `UID`, `PWD` or `Authentication`.
- No credential, server hostname or token appears in source.
- Every value in a query is a bound parameter.

## Do not

- Do not assume `pyodbc` is the only Python driver. That was true and is not.
- Do not add an operating system ODBC driver install to a `mssql-python` deployment. It carries its
  own.
- Do not write `Authentication=ActiveDirectoryDefault` into a `pyodbc` connection string. The ODBC
  driver does not accept it.
- Do not combine an access token with `UID`, `PWD` or `Authentication` in the same connection.
- Do not use `ActiveDirectoryPassword`. Microsoft has deprecated the flow it is built on.
- Do not call `mssql_python.pooling()` after opening a connection and expect it to apply.
- Do not use `ActiveDirectoryDefault` in production and then treat the chain latency as a network
  fault.
- Do not build SQL text with string formatting. Bind parameters.
- Do not write retry loops here. Transient-fault handling is one policy for every language, in
  `connect-to-azure-sql`.

## References

- [Microsoft Python driver for SQL Server](https://learn.microsoft.com/sql/connect/python/mssql-python/python-sql-driver-mssql-python):
  the driver's front door, including installation, pooling and the migration guide from `pyodbc`.
  Read it before writing new Python data access.
- [Microsoft Entra authentication with mssql-python](https://learn.microsoft.com/sql/connect/python/mssql-python/entra-authentication):
  the authoritative list of authentication modes and when to use each. Read it when choosing a mode.
- [Using Microsoft Entra ID with the ODBC driver](https://learn.microsoft.com/sql/connect/odbc/using-azure-active-directory):
  the ODBC `Authentication` values and the access token attribute. Read it before claiming the
  driver supports a mode.
- [Install the ODBC driver on Linux](https://learn.microsoft.com/sql/connect/odbc/linux-mac/installing-the-microsoft-odbc-driver-for-sql-server):
  current per-distribution commands. Fetch it rather than recalling the package names.
- [pyodbc, features beyond the DB API](https://github.com/mkleehammer/pyodbc/wiki/Features-beyond-the-DB-API):
  the project's own statement that ODBC pooling is on by default and how to turn it off. Read it
  before changing pooling on the `pyodbc` path.
- `connect-to-azure-sql`: encryption doctrine, retry and transient faults, pool sizing, and the
  first-connect error on a paused database.
