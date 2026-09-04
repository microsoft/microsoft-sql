# Installing msodbcsql18 on Linux, for the pyodbc path

Only the `pyodbc` path needs this. `mssql-python` carries the driver binaries in its own wheel and
an operating system install added alongside it is dead weight.

`pip install pyodbc` never needs a compiler: the project publishes both `manylinux` and
`musllinux` wheels, so a musl based image builds as cleanly as a glibc one. What is missing at
runtime is the driver the connection string names.

## The name has to match, exactly

The package is `msodbcsql18`. The connection string keyword is
`Driver={ODBC Driver 18 for SQL Server}`. A registered driver under any other name is not found,
and the failure is `01000`, `Can't open lib '<name>' : file not found`, not `IM002`.

Confirm what the driver manager actually registered:

```bash
python3 -c "import pyodbc; print(pyodbc.drivers())"
odbcinst -q -d
```

## Three things that break an unattended build

**The licence prompt.** The install is non interactive only if the licence is accepted explicitly.
Either set `ACCEPT_EULA=Y` on the install command, or, from driver 18.4, create the file
`/opt/microsoft/msodbcsql18/ACCEPT_EULA` before installing. Without one of the two, a container
build hangs on a prompt nobody can answer and eventually times out with no useful message.

**Alpine has no Microsoft package repository.** Every other supported distribution installs from
`packages.microsoft.com`. On Alpine the `.apk` is downloaded and installed with
`apk add --allow-untrusted`, and the signature check is skipped because there is no repository key
to check it against.

**Slim Debian and Ubuntu images omit `libgssapi-krb5-2`.** The driver links against it. Install it
alongside `msodbcsql18` or the driver loads and then fails at connect time.

## Do not recite the per distribution commands

They change with releases, and a stale `apt` source line for the wrong Debian version is one of the
more common ways this fails. Fetch the current ones:

[Install the Microsoft ODBC driver for SQL Server on Linux](https://learn.microsoft.com/sql/connect/odbc/linux-mac/installing-the-microsoft-odbc-driver-for-sql-server)

## Checking a built image

Run this as the last step of the build, not the first step of the application:

```bash
docker run --rm <image> python3 -c "import pyodbc, sys; \
  ok = 'ODBC Driver 18 for SQL Server' in pyodbc.drivers(); \
  print(pyodbc.drivers()); sys.exit(0 if ok else 1)"
```

Exit `0` means the driver is present and named as the connection string expects. Exit `1` means
`pip install pyodbc` succeeded and the operating system install did not, which is the same state
that produces `01000` at the first connect and gets misread as a network problem.
