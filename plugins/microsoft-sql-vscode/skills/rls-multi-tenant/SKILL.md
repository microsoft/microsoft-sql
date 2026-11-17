---
name: rls-multi-tenant
description: "Use when isolating tenants in a shared Azure SQL Database or checking isolation: row level security, SESSION_CONTEXT, rows leaking or vanishing. Has verified behavior common answers miss, e.g. a filter predicate alone lets a tenant write into another."
---

# Tenant isolation that holds, and the test that proves it

**The deliverable is the test, not the policy.** The value is an assertion that goes red when
isolation breaks, because every way it breaks here is silent: no error, no warning, no log line,
and a catalog view that still reports the policy enabled.

The behavior below is the Azure SQL Database engine's; section 6 notes where it depends on the
build. Open [the runnable checks](references/block-predicates-pooling-and-bypass.md) when you need
the statement behind a message number below, or before changing one.

## 1. A filter predicate is not the boundary

Microsoft Learn states it plainly: the application can `INSERT` rows, even if they will be filtered
during any other operation. For a low-privilege user holding tenant id 1, under a filter predicate
only:

| Statement | Result | What it costs |
|---|---|---|
| `INSERT` a row stamped `tenant_id = 2` | **succeeds** | the row exists, invisible to its author, visible to tenant 2 |
| `UPDATE` one of its own rows to `tenant_id = 2` | **succeeds** | the row moves into another tenant, silently |
| `UPDATE` a row of tenant 2 | 0 rows affected | the filter protects the read behind a write |
| `DELETE` a row of tenant 2 | 0 rows affected | same |
| `INSERT` a key that already exists in tenant 2 | `Msg 2627` | the key space of another tenant is probeable |

The first two rows are the leak. The application that wrote them can never read them back and never
delete them, because the filter now hides them from their own author. Recovering them means
disabling the policy.

The last row is separate and smaller. A filter predicate hides rows, not their existence: `Msg 2627`
on a duplicate key and success on a free one let a caller enumerate another tenant's keys one
attempt at a time. Use identifiers with no guessable ordering.

## 2. The block predicate, and why it is two predicates

Learn defines four block operations: `AFTER INSERT`, `AFTER UPDATE`, `BEFORE UPDATE` and
`BEFORE DELETE`. Adding the first two turns both cross-tenant writes into:

```text
Msg 33504: The attempted operation failed because the target object '<db>.<schema>.<table>'
has a block predicate that conflicts with this operation.
```

The legitimate write into the caller's own tenant still succeeds.

**`AFTER UPDATE` is the one people leave out.** With the filter predicate and `AFTER INSERT` in
place but no `AFTER UPDATE`, the cross-tenant insert is refused and the tenant-move update **still
succeeds**. The row leaves the tenant with no error.

```sql
CREATE FUNCTION sec.fn_tenant(@tenant_id int)
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN SELECT 1 AS ok
       WHERE @tenant_id = CAST(SESSION_CONTEXT(N'tenant_id') AS int);
GO

CREATE SECURITY POLICY sec.p_orders
    ADD FILTER PREDICATE sec.fn_tenant(tenant_id) ON dbo.orders,
    ADD BLOCK PREDICATE sec.fn_tenant(tenant_id) ON dbo.orders AFTER INSERT,
    ADD BLOCK PREDICATE sec.fn_tenant(tenant_id) ON dbo.orders AFTER UPDATE
    WITH (STATE = ON);
GO

-- the other half of the guarantee: the application never rewrites a tenant id
DENY UPDATE ON dbo.orders(tenant_id) TO app_user;
```

If the policy already exists with only a filter predicate, add the block predicates to it in one
statement. Do not drop and recreate the policy on a live database: between the `DROP` and the
`CREATE`, every session reads and writes the table unfiltered.

```sql
ALTER SECURITY POLICY sec.p_orders
    ADD BLOCK PREDICATE sec.fn_tenant(tenant_id) ON dbo.orders AFTER INSERT,
    ADD BLOCK PREDICATE sec.fn_tenant(tenant_id) ON dbo.orders AFTER UPDATE;
```

Learn adds two things. The optimizer skips an `AFTER UPDATE` block predicate when the update changed
no column the predicate reads, so ordinary updates pay nothing for it. And Learn's middle-tier
example omits `AFTER UPDATE` only because it denies `UPDATE` on the tenant column instead. Take
both. `BEFORE UPDATE` and `BEFORE DELETE` are redundant while a filter predicate is present, since
the filter has already removed the other tenant's rows from the statement.

### Moving rows that already left their tenant

Rows written before the block predicates existed stay invisible to the tenant that owns them, and
the policy now refuses to move them back. With the session set to the row's current `tenant_id`, an
`UPDATE` to the right tenant fails with `Msg 33504`. Do not switch the policy off on a live database
to fix this, and do not add an exemption to the predicate. Run the repair as one transaction, as a
principal no application connects as, holding the two permissions in section 4:

```sql
SET XACT_ABORT ON;
BEGIN TRANSACTION;
    ALTER SECURITY POLICY sec.p_orders WITH (STATE = OFF);
    UPDATE dbo.orders SET tenant_id = 42 WHERE id IN (1001, 1002);  -- the reviewed list
    ALTER SECURITY POLICY sec.p_orders WITH (STATE = ON);
COMMIT;
```

While the transaction is open the engine holds a schema-modification lock on the policy. Every other
statement against the protected tables waits, including `NOLOCK` readers and cached plans, and none of
them sees unfiltered rows. Any error rolls the batch back and leaves the policy on. The cost is that
application traffic on those tables stalls for as long as the transaction runs. So decide each
row's owner from the audit trail beforehand, update an explicit list of keys rather than a broad
predicate, and keep the transaction short. Afterwards `sys.security_policies.is_enabled` is 1 and
the catalog sweep in section 5 comes back empty.

## 3. How the tenant reaches the predicate, and what pooling does to it

Two designs, and the difference is in behavior, not style.

### `SESSION_CONTEXT` is a variable, not an identity

Learn is explicit that any user can set a session context for their session: a user granted only
`CONNECT` plus `SELECT`, `INSERT`, `UPDATE` and `DELETE` on one table can set its own tenant id to 2
and read tenant 2's rows. No grant is needed, and none can be revoked to stop it.

So a `SESSION_CONTEXT` design is exactly as strong as the guarantee that nothing
attacker-influenced ever reaches that connection as SQL. `prevent-sql-injection` owns that:
open it whenever any part of a statement here is assembled from input instead of passed as a
parameter, because under this design a successful injection rewrites the tenant boundary itself.

### The failure that reaches production

The tenant id outlives the request, because the connection does. With a small pool serving
concurrent requests that alternate between two tenants:

| Application shape | Cross-tenant reads |
|---|---|
| Set the context in one pooled request, run the query in another | **a large share of requests** |
| Set the context and run the query on one acquired connection | none |
| A database user per tenant, one pool per tenant, no session context | none |

**No caller sees an error.** The rate in a real application depends on its pool and its load; the
point is that the failure is silent. An application can set the tenant on every request and still
leak, when it hands the set and the query to the pool separately and the pool gives them different
connections. Two rules follow:

1. **Set the tenant and read on the same acquired connection**, in one batch, one transaction, or
   one explicitly held connection. Not two calls to a pool.
2. **Never leave the tenant set when a connection returns to the pool.** That failure is open, not
   closed: the next caller that forgets reads the previous tenant's rows.

`@read_only = 1` looks like the fix, and the documentation reads as if it were. Learn presents it as
preventing the value changing again until the connection returns to the pool, which is exactly what
it does. On a reused pooled connection, though, the next tenant's **correct** attempt to claim its
own id is refused with `Msg 15664`, while a request that forgets to set anything still reads the
previous rows. It is safe only where the connection ends with the request.

### A database user per tenant

The predicate reads `USER_NAME()` or `DATABASE_PRINCIPAL_ID()` instead of session state, resolved
through a mapping table:

```sql
CREATE FUNCTION sec.fn_tenant_by_user(@tenant_id int)
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN SELECT 1 AS ok FROM sec.tenant_map m
       WHERE m.db_user = USER_NAME() AND m.tenant_id = @tenant_id;
```

Setting `SESSION_CONTEXT` under this predicate changes nothing, and borrowing another tenant's
identity with `EXECUTE AS USER` is refused with `Msg 15517`, since impersonation is a permission the
tenant does not hold. Connection pools are keyed by connection string, so each
tenant gets its own pool and there is no shared connection to leak through.

The cost is one login, one database user, one connection string and one pool per tenant, which fits
hundreds of tenants and not tens of thousands. Choose it when isolation has to survive an
application bug rather than depend on its absence.

## 4. Who bypasses the policy

| Principal | Reads through the policy | Can turn it off |
|---|---|---|
| A plain application user | no, 0 rows with no tenant set | no, `Msg 33268` |
| The table owner, which is also the database owner | **no**, 0 rows with no tenant set | yes |
| A member of `db_owner` | **no**, 0 rows with no tenant set | yes, in one statement, then reads every row |
| `ALTER ANY SECURITY POLICY` alone | no | **no**, `Msg 33268` |
| `ALTER` on the schema holding the policy alone | no | **no**, `Msg 33268` |
| Both of the above together | no | yes, in one statement, then reads every row |

**Ownership is not a read-through.** Learn says a `dbo` user, a `db_owner` member and the table
owner are all filtered or blocked as the policy defines, and all three get zero rows with no tenant
set. What they hold is the ability to disable, a separate and auditable statement.

**`ALTER ANY SECURITY POLICY` alone is not enough.** Learn splits the requirement, altering a policy
against that permission and creating or dropping one against `ALTER` on the schema. Disabling one
needs both: either alone fails with `Msg 33268`, reported as a missing object rather than a
permission failure. Grant them as a pair, to a principal no application connects as.

## 5. A policy can be present and not enforcing, in three ways

All three look healthy from the application: rows come back, nothing errors.

| Shape | What the application sees | What gives it away |
|---|---|---|
| `WITH (STATE = OFF)` | every tenant's rows | `sys.security_policies.is_enabled = 0` |
| A predicate that returns a row when the tenant is unset | every tenant's rows, to a session that set nothing | nothing in any catalog view; `is_enabled` is still 1 |
| A second tenant-scoped table nobody added to the policy | that table unfiltered, while the covered table is correct | no predicate rows for that object |

A predicate of the form `WHERE @tenant_id = <context> OR <context> IS NULL` returns every row to a
session with no tenant set, while every catalog view reports a healthy enabled policy. **Predicates
fail closed or they are not predicates.** Never add an escape clause for administrative sessions.

The third is a sweep, not a review. Run it after every migration that adds a table:

```sql
SELECT  QUOTENAME(SCHEMA_NAME(t.schema_id)) + '.' + QUOTENAME(t.name) AS table_name,
        SUM(CASE WHEN sp.predicate_type = 0 THEN 1 ELSE 0 END) AS filter_predicates,
        SUM(CASE WHEN sp.predicate_type = 1 THEN 1 ELSE 0 END) AS block_predicates,
        MIN(CAST(pol.is_enabled AS int))                       AS policy_enabled
FROM sys.tables t
JOIN sys.columns c
  ON c.object_id = t.object_id AND c.name = N'tenant_id'
LEFT JOIN sys.security_predicates sp ON sp.target_object_id = t.object_id
LEFT JOIN sys.security_policies  pol ON pol.object_id = sp.object_id
GROUP BY t.schema_id, t.name
HAVING SUM(CASE WHEN sp.predicate_type = 1 THEN 1 ELSE 0 END) < 2
    OR MIN(CAST(pol.is_enabled AS int)) IS NULL
    OR MIN(CAST(pol.is_enabled AS int)) = 0;
```

`predicate_type` is `0` for filter and `1` for block, read back from `sys.security_predicates`
rather than recalled. Read the list rather than count it: a tenant mapping table carries a
`tenant_id` column, legitimately has no predicate, and is dismissed once. Anything else in it is a
tenant table that is not isolated. To see the sweep work, plant a failure: drop one block predicate
from a correct table and that table appears.

One shape the sweep misses, per Learn: predicates are not replicated to a system-versioned table's
history table, which needs its own predicate by name.

## 6. A security policy beside a vector index depends on the build

A tenant predicate on a chunk table looks like the cheapest defence against a retrieval answering
one tenant with another tenant's text, but **whether a security policy and a vector index can share
a table is not documented** (Microsoft Learn's CREATE VECTOR INDEX, VECTOR_SEARCH and row-level
security pages are silent on it) **and differs between engine builds**:

| Engine | Policy after the index | Index after the policy | Approximate search under the policy |
|---|---|---|---|
| Earlier builds of the Azure SQL Database container image | `Msg 37579` | `Msg 42244` | not reachable |
| SQL Server 2025 (with `PREVIEW_FEATURES = ON`, which `CREATE VECTOR INDEX` needs there) | `Msg 37579` | `Msg 42244` | not reachable |
| Azure SQL Database, Fabric SQL database, and container image build 18.0.310.0_253 | created | created | the filter holds (no cross-tenant rows) and a block predicate refuses a cross-tenant insert (`Msg 33504`), but the vector index is not used: `WITH (FORCE_ANN_ONLY)` fails with `Msg 8622` |

So a policy on the chunk table protects it where the engine accepts the pair, but it turns every
approximate search into an exact scan, and on SQL Server 2025 it cannot be created at all. Make the
retrieval query's own tenant filter the boundary, keep the index, and keep a test that fails when
that filter is removed. If you also put a policy on the chunk table, check on the target database
that it is created, that a cross-tenant approximate query returns none of the other tenant's rows,
and whether the plan still shows a `Vector Index Seek`; expect the fall back to an exact scan.

What does work: the filter predicate applies correctly to exact search over `VECTOR_DISTANCE` with
no vector index, and each tenant gets back only its own rows.

## Check it worked

Three checks, cheapest first, against the reference file's setup script: `dbo.orders` holding four
rows, two each for tenants 1 and 2, and `app_user` granted only `CONNECT` and the four table
permissions.

**One: the filtered count is smaller than the table, and the administrator is not exempt.** Run it
on an administrative connection, which is the only one that can impersonate:

```sql
EXEC sys.sp_set_session_context @key = N'tenant_id', @value = 1;
SELECT COUNT(*) AS admin_tenant_1 FROM dbo.orders;
EXECUTE AS USER = 'app_user';
SELECT COUNT(*) AS app_tenant_1 FROM dbo.orders;
EXEC sys.sp_set_session_context @key = N'tenant_id', @value = 2;
SELECT COUNT(*) AS app_tenant_2 FROM dbo.orders;
EXEC sys.sp_set_session_context @key = N'tenant_id', @value = NULL;
SELECT COUNT(*) AS app_no_tenant FROM dbo.orders;
REVERT;
```

Expected against four seeded rows: `2`, `2`, `2`, `0`, and the two twos are different rows. A `4`
anywhere means the policy is not enforcing, which is section 5; zero everywhere means the predicate
is not reading the key you set.

**Two: a cross-tenant write raises rather than vanishing.**

```sql
EXECUTE AS USER = 'app_user';
EXEC sys.sp_set_session_context @key = N'tenant_id', @value = 1;
INSERT INTO dbo.orders (order_id, tenant_id, customer, amount) VALUES (901, 2, N'probe', 1.00);
REVERT;
```

Expect `Msg 33504`. If it succeeds you have the leak in section 1, and the row is already invisible
to the connection that wrote it.

**Three: the isolation test, as the application's own user, on every deployment**, saved as
`tenant-isolation.sql`:

```sql
SET NOCOUNT ON;
DECLARE @mine int = 1, @theirs int = 2, @fail int = 0, @n int;
-- unique per run: a failing run strands a probe row it can no longer see or delete
DECLARE @probe int = 900000 + ABS(CHECKSUM(NEWID())) % 90000;

EXEC sp_set_session_context @key = N'tenant_id', @value = 1;

-- 1. every visible row is mine
SELECT @n = COUNT(*) FROM dbo.orders WHERE tenant_id <> @mine;
IF @n <> 0 BEGIN PRINT 'FAIL 1: the filter predicate leaks another tenant''s rows'; SET @fail = 1; END

-- 2. an unfiltered aggregate cannot see more than the filtered set
SELECT @n = COUNT(*) FROM dbo.orders;
IF @n <> (SELECT COUNT(*) FROM dbo.orders WHERE tenant_id = @mine)
   BEGIN PRINT 'FAIL 2: aggregate disagrees with the filtered set'; SET @fail = 1; END

-- 3. a write addressed to another tenant is REFUSED, not silently accepted
BEGIN TRY
    INSERT INTO dbo.orders (order_id, tenant_id, customer, amount)
    VALUES (@probe, @theirs, N'probe', 1.00);
    PRINT 'FAIL 3: cross-tenant INSERT accepted, no BLOCK PREDICATE AFTER INSERT';
    SET @fail = 1;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() <> 33504 BEGIN PRINT CONCAT('FAIL 3: unexpected error ', ERROR_NUMBER()); SET @fail = 1; END
END CATCH

-- 4. moving one of my own rows into another tenant is REFUSED
INSERT INTO dbo.orders (order_id, tenant_id, customer, amount) VALUES (@probe + 1, @mine, N'probe', 1.00);
BEGIN TRY
    UPDATE dbo.orders SET tenant_id = @theirs WHERE order_id = @probe + 1;
    PRINT 'FAIL 4: tenant-move UPDATE accepted, no BLOCK PREDICATE AFTER UPDATE';
    SET @fail = 1;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() <> 33504 BEGIN PRINT CONCAT('FAIL 4: unexpected error ', ERROR_NUMBER()); SET @fail = 1; END
END CATCH
DELETE FROM dbo.orders WHERE order_id = @probe + 1;

-- 5. no tenant set means no rows: the predicate fails closed
EXEC sp_set_session_context @key = N'tenant_id', @value = NULL;
SELECT @n = COUNT(*) FROM dbo.orders;
IF @n <> 0 BEGIN PRINT 'FAIL 5: the predicate fails OPEN when no tenant is set'; SET @fail = 1; END

IF @fail = 1 THROW 50001, 'tenant isolation test FAILED', 1;
PRINT 'tenant isolation: ALL PASS';
```

```bash
export SQLCMDPASSWORD='<app-user-password>'
sqlcmd -S <server-name>.database.windows.net,1433 -d <database> -U app_user -C \
  -b -m-1 -V 16 -i tenant-isolation.sql -o tenant-isolation.out
echo "exit $?"
grep -nE '^FAIL |^Msg ' tenant-isolation.out
```

Expect exit `0`, `tenant isolation: ALL PASS` in the file, and no output from `grep`. `THROW` sets
severity 16, above the severity 10 `-b` ignores, so a failed assertion does set a non-zero exit;
`-m-1` puts every message in the file, including the `PRINT` naming which assertion went red.

**`-m-1` is an ODBC `sqlcmd` instruction**, the 18.x build from `mssql-tools18`. With go-sqlcmd
1.10.0, no `Msg` header is printed on a severity 10 message at any `-m` value, so there the `PRINT`
lines arrive with no number.

**Plant each failure and watch the test go red**, which is the only evidence an assertion asserts
anything:

| Plant | Assertions that fail |
|---|---|
| Drop the `AFTER INSERT` block predicate | 3 |
| Drop the `AFTER UPDATE` block predicate | 4 |
| `WITH (STATE = OFF)` | 1, 2, 4, 5 |
| Swap in the predicate that returns rows when the tenant is unset | 5 |

Assertions 1 and 2 are the same claim from two angles: 2 catches a predicate that filters a direct
scan and not an aggregate. Add the pooling case in application test code, because no single
connection reproduces it: issue concurrent requests for two tenants against one pool and assert
every response carries only its own tenant, the shape that in section 3 returns another tenant's
rows for a large share of requests.

## Do not

- Do not ship a filter predicate on its own. A cross-tenant insert succeeds under it and the row is
  then unreadable and undeletable by the application that wrote it.
- Do not add `AFTER INSERT` and stop. The tenant-move update still succeeds with only that block
  predicate in place.
- Do not set the tenant in one pooled call and query in another, and do not reach for
  `@read_only = 1` to make that safe. It refuses the correct caller and leaves the forgetful one
  leaking.
- Do not treat `SESSION_CONTEXT` as an identity. Any caller on the connection rewrites it with no
  permission, so one concatenated statement defeats the whole policy.
- Do not assume the table owner or `db_owner` reads through the policy. They do not. They disable
  it, which is a different and visible act.
- Do not grant `ALTER ANY SECURITY POLICY` believing it is inert alone. Paired with `ALTER` on the
  policy's schema it is a full read of every protected table, in one statement.
- Do not read `is_enabled = 1` as proof of isolation. A fail-open predicate and an uncovered table
  both leave it at 1.
- Do not conclude row level security is unavailable because an engine build refuses it beside a
  vector index. The refusal is about the index, not about the policy.
- Do not leave the tenant column nullable. A row that arrives with no tenant is invisible to every
  tenant and belongs to none.
- Do not repair misplaced rows by turning the policy off outside a transaction. Until it is back
  on, every connection reads every tenant's rows.

## References

- Open [the runnable checks](references/block-predicates-pooling-and-bypass.md) when a message
  number above is disputed, before changing one, or to rerun the pooling check and the four planted
  failures.
- Read [Row-level security](https://learn.microsoft.com/sql/relational-databases/security/row-level-security)
  before designing a predicate more complex than one column, for the block operations, the
  permission split, and the cross-feature list that names indexed views and temporal tables.
- Read [sp_set_session_context](https://learn.microsoft.com/sql/relational-databases/system-stored-procedures/sp-set-session-context-transact-sql)
  before choosing session context over a user per tenant: the 8,000 byte value limit, the 1 MB
  session total, and the `@read_only` argument.
- Read [sqlcmd utility](https://learn.microsoft.com/sql/tools/sqlcmd/sqlcmd-utility) when wiring
  the isolation test into a pipeline, for what `-b`, `-m` and `-V` do.
- `prevent-sql-injection` when any statement here is assembled rather than parameterised, which is
  what a session context design depends on. `entra-id-auth` for getting an identity onto a working
  connection; use a custom least-privilege role for the permissions that identity receives.
- `design-azure-sql-schema` for the tenant column and its place in the key, `t-sql-correctness` for
  the predicate function as T-SQL, and `rag-on-azure-sql` with `vector-search-azure-sql` for the
  retrieval this policy sits under.
