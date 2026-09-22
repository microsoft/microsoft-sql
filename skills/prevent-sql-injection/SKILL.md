---
name: prevent-sql-injection
description: >-
  Handles SQL injection on Azure SQL Database beyond parameterisation: a typed sp_executesql
  parameter matches nothing where the same input concatenated into EXEC() returns every row;
  QUOTENAME returns NULL above 128 characters, so the batch built from it becomes NULL and does
  nothing; a dynamic ORDER BY built from one CASE over mixed types fails only for the sort key on
  the lower-precedence branch; dynamic SQL breaks the ownership chain, so EXECUTE AS decides what
  it may touch; and Always Encrypted refuses a literal (Msg 206). Use for a general injection
  question or a pre-production review, when a QUOTENAME-built statement returns and raises
  nothing, when a sort-by-column feature throws an operand type clash for one column only, when a
  procedure works until its query becomes dynamic, or when an encrypted column will not take a
  literal. Row level tenant isolation is rls-multi-tenant.
---

# Prevent SQL injection: the value, the identifier, and the context it runs under

Parameterising a value is the part an agent already gets right. Confirm it in a sentence and spend
the answer on what a parameter cannot reach: an identifier, the type of a runtime-chosen sort
expression, the permissions a dynamic batch runs under, and an encrypted column.

Measured 2026-08-29 against an engine reporting `EngineEdition` 5 and Edition `SQL Azure`.
`QUOTENAME`, `PARSENAME`, `sp_executesql`, ownership chaining and Always Encrypted were checked
against Microsoft Learn on 2026-09-03; flags from `sqlcmd` 1.10.0 help.

## 1. A parameter is a value, a concatenation is code, and the difference is measurable

Do not assert this. Run it. Both statements get the same string.

```sql
CREATE TABLE dbo.Users (id int NOT NULL PRIMARY KEY, name nvarchar(50) NOT NULL);
INSERT INTO dbo.Users (id, name) VALUES (1, N'ann'), (2, N'bob');

DECLARE @input nvarchar(100) = N'ann'' OR 1=1--';

-- Typed parameter: the input is one value, and no row holds it. Returns 0.
EXEC sp_executesql N'SELECT COUNT(*) AS matched FROM dbo.Users WHERE name = @n',
                   N'@n nvarchar(100)', @n = @input;

-- Same input concatenated: the input is now part of the statement. Returns 2.
DECLARE @sql nvarchar(max) =
        N'SELECT COUNT(*) AS matched FROM dbo.Users WHERE name = N''' + @input + N'''';
EXEC (@sql);
```

Zero against two, from one string. Learn's rule for `@params` is the discipline in one line: values
can only be constants or variables, never expressions built with operators.

## 2. No parameter binds an identifier, and QUOTENAME's ceiling is a NULL

`EXEC sp_executesql N'SELECT * FROM @t', N'@t sysname', @t = @name` cannot work: `@t` is a value,
not a table. A dynamic identifier has to enter the SQL text, so `QUOTENAME`'s documented edges are
load bearing. Learn: `character_string` is **sysname**, and an input over 128 characters returns
`NULL`, as does an unacceptable quote character. Escaping is not the defect: an embedded `]` is
doubled correctly. Crossing 128 is, because a `NULL` in a batch makes the whole batch `NULL`:

```sql
DECLARE @n129 nvarchar(200) = REPLICATE(N'a', 129);
SELECT LEN(QUOTENAME(REPLICATE(N'a', 128)))       AS len_at_128,      -- 130
       IIF(QUOTENAME(@n129) IS NULL, 1, 0)        AS null_at_129,     -- 1
       IIF(QUOTENAME(N'tbl', N'#') IS NULL, 1, 0) AS null_bad_quote;  -- 1

DECLARE @sql nvarchar(max) = N'SELECT * FROM ' + QUOTENAME(@n129);
EXEC sp_executesql @sql;
SELECT IIF(@sql IS NULL, 1, 0) AS batch_was_null, @@ERROR AS err;     -- 1, 0
```

`EXEC (@sql)` on the same `NULL` behaves identically: this is the `NULL` batch, not one calling
convention. Nothing reports it at any severity:

```bash
sqlcmd -S <server-name>.database.windows.net,1433 -d <database> -U <user> -C -b -m-1 \
  -Q "DECLARE @s nvarchar(max)=N'SELECT 1 FROM '+QUOTENAME(REPLICATE(N'x',129)); EXEC sp_executesql @s; SELECT @@ERROR AS err;"
```

`-b` exits non-zero at severity 11 and above and `-m-1` lowers the print level, but there is no
message at any level: `err` is 0 and so is the exit code. The `NULL` has to be the check.

**Neither helper checks that the object exists.** `QUOTENAME` brackets a string and `PARSENAME`
splits a qualified name; Learn says each part is **sysname**, a part over 256 bytes comes back
`NULL`, and it does not indicate whether an object of that name exists. Only a catalog lookup
decides existence, so resolve the caller's string against the catalog and build from what it
returned:

```sql
DECLARE @requested nvarchar(400) = N'dbo.Users', @safe nvarchar(300);
SELECT @safe = QUOTENAME(s.name) + N'.' + QUOTENAME(o.name)
FROM sys.objects AS o JOIN sys.schemas AS s ON s.schema_id = o.schema_id
WHERE s.name = PARSENAME(@requested, 2) AND o.name = PARSENAME(@requested, 1) AND o.type = 'U';
IF @safe IS NULL THROW 50001, 'No row in the catalog matched that name.', 1;

DECLARE @sql nvarchar(max) = N'SELECT COUNT(*) AS n FROM ' + @safe;
EXEC sp_executesql @sql;
```

The rejection there is the lookup's, not `QUOTENAME`'s: an over-long name matches no row because no
table can carry one. Where the legal identifiers are known in advance, an allowlist is simpler.

## 3. One CASE over mixed types in a dynamic ORDER BY fails for some sort keys and not others

A single `CASE` forces every branch to one common type chosen by type precedence, not by the branch
the sort key selects. Measured on `dbo.T (i int, d date, s nvarchar(50))`:

| Branches | sort key selects | Result |
|---|---|---|
| `THEN i` / `THEN d` | anything, including neither | `Msg 206`, operand type clash, int against date |
| `THEN s` / `THEN d` | `d`, the higher-precedence side | runs clean |
| `THEN s` / `THEN d` | `s`, the lower-precedence side | `Msg 241`, conversion failed from character string |
| `THEN i` / `THEN s` | `s`, the lower-precedence side | `Msg 245`, conversion failed converting nvarchar to int |

`int` and `date` have no implicit conversion, so that pairing is refused at compile time and a
surrounding `BEGIN TRY` does not catch it. The string pairings are the sharper trap: the identical
statement passes for one sort key and fails for another, so it survives a test against whichever
column the author tried. One `CASE` per candidate column, each carrying a single type, has no common
type to coerce toward; non-matching columns evaluate to `NULL` and tie, so this composes with
`OFFSET`/`FETCH` and a direction toggle:

```sql
DECLARE @col sysname = N'created', @dir char(1) = N'A';
SELECT id, name, created FROM dbo.Grid
ORDER BY CASE WHEN @col = N'id'      AND @dir = N'A' THEN id      END ASC,
         CASE WHEN @col = N'id'      AND @dir = N'D' THEN id      END DESC,
         CASE WHEN @col = N'created' AND @dir = N'A' THEN created END ASC
OFFSET 0 ROWS FETCH NEXT 10 ROWS ONLY;
```

## 4. Dynamic SQL breaks the ownership chain, so EXECUTE AS is part of the answer

Learn: dynamic SQL in procedural code breaks the ownership chain, so the engine checks the caller's
permissions against every object the statement touches. A procedure a caller could run yesterday
stops working the day its query becomes dynamic, and parameterising does not bring it back.

```sql
CREATE TABLE dbo.Ledger (id int NOT NULL PRIMARY KEY);
INSERT INTO dbo.Ledger (id) VALUES (1);
CREATE USER app_reader WITHOUT LOGIN;
GO
CREATE PROCEDURE dbo.CountLedgerDynamic AS
  EXEC sp_executesql N'SELECT COUNT(*) AS n FROM dbo.Ledger';
GO
CREATE PROCEDURE dbo.CountLedgerAsOwner WITH EXECUTE AS OWNER AS
  EXEC sp_executesql N'SELECT COUNT(*) AS n, CURRENT_USER AS running_as FROM dbo.Ledger';
GO
GRANT EXECUTE ON dbo.CountLedgerDynamic TO app_reader;
GRANT EXECUTE ON dbo.CountLedgerAsOwner TO app_reader;
GO
EXECUTE AS USER = 'app_reader';
EXEC dbo.CountLedgerDynamic;   -- Msg 229, SELECT permission denied on 'Ledger'
EXEC dbo.CountLedgerAsOwner;   -- 1, dbo
REVERT;
```

Learn names two remedies. `EXECUTE AS` replaces the caller's permissions for the whole module,
nested modules inherit the proxy context, and the identity functions report the proxy, which is what
`running_as` returning `dbo` shows, so anything keyed to the caller must arrive as a parameter.
Certificate signing merges the certificate user's permissions with the caller's and leaves the
execution context alone, at the cost of re-signing on every change. Open `rls-multi-tenant` before
putting `EXECUTE AS` on a module touching a table under a security policy: the proxy context is what
a tenant predicate reads. Neither remedy substitutes for parameterising.

## 5. On an Always Encrypted column a literal does not run at all

Learn lists it under Always Encrypted's limitations: comparing an encrypted column to a literal, or
inserting one, fails with `Msg 206, Level 16, State 2, Operand type clash`. Only a value bound as a
parameter over a connection with `Column Encryption Setting=Enabled` is encrypted before it leaves
the driver, so parameterising is the only thing that returns a row. Documented, not reproduced here:
it needs a column master key provisioned outside the database.

## Check it worked

```sql
-- Every module that builds SQL, and the context it runs under. A NULL principal id means the
-- caller's permissions apply to whatever the dynamic statement touches.
SELECT o.name, m.execute_as_principal_id
FROM sys.sql_modules AS m JOIN sys.objects AS o ON o.object_id = m.object_id
WHERE m.definition LIKE N'%sp_executesql%' OR m.definition LIKE N'%EXECUTE (%';
```

```sql
-- No dynamic batch executes while NULL. Expect the rejection, not zero rows.
DECLARE @batch nvarchar(max) = N'SELECT * FROM ' + QUOTENAME(REPLICATE(N'x', 129));
IF @batch IS NULL SELECT 'rejected before execution' AS result ELSE EXEC sp_executesql @batch;
```

Then re-run section 1's pair against the real table: parameterised matches zero rows, concatenated
every row. Run the generated `ORDER BY` once per sort key a caller may send, not only the one
tested: any raising `Msg 206`, `241` or `245` means a mixed-type `CASE` is still there.

## Do not

- Do not present `QUOTENAME` as sufficient for a caller-supplied identifier without checking its
  result for `NULL`, and do not say it truncates a long name. It returns `NULL`.
- Do not say either helper checks that an object exists. Neither reads the catalog.
- Do not build a caller-chosen `ORDER BY` from one `CASE` spanning columns of different types, even
  when the columns tried in testing share a type.
- Do not add `WITH EXECUTE AS OWNER` to clear a permission error without saying what the module can
  now reach and that the caller's identity is no longer visible inside it.
- Do not tell a developer an agent-composed statement is made safe by parameterising the one value
  inside it. The model authored the whole statement, so the control is the permission boundary its
  connection runs under.
- Do not warn about `xp_cmdshell`, linked servers or `OPENROWSET` against arbitrary providers. None
  exist on Azure SQL Database to escalate to.

## References

- Open [the measured runs](references/quotename-null-and-order-by-clashes.md) when a claim above
  disagrees with what you see, or to look up the message a column-type pairing produces.
- Microsoft Learn, if a number above looks stale:
  [QUOTENAME](https://learn.microsoft.com/sql/t-sql/functions/quotename-transact-sql),
  [PARSENAME](https://learn.microsoft.com/sql/t-sql/functions/parsename-transact-sql),
  [secure dynamic SQL](https://learn.microsoft.com/sql/connect/ado-net/sql/writing-secure-dynamic-sql).
