# Block predicates, pooling and bypass: the runs behind tenant isolation

## Contents

- [How this was measured](#how-this-was-measured)
- [The fixture](#the-fixture)
- [Run 1: filter predicate only](#run-1-filter-predicate-only)
- [Run 2: the block predicate](#run-2-the-block-predicate)
- [Run 3: AFTER INSERT without AFTER UPDATE](#run-3-after-insert-without-after-update)
- [Run 4: the duplicate key probe](#run-4-the-duplicate-key-probe)
- [Run 5: session context under connection pooling](#run-5-session-context-under-connection-pooling)
- [Run 6: read only session context](#run-6-read-only-session-context)
- [Run 7: a database user per tenant](#run-7-a-database-user-per-tenant)
- [Run 8: who bypasses the policy](#run-8-who-bypasses-the-policy)
- [Run 9: present but not enforcing](#run-9-present-but-not-enforcing)
- [Run 10: the vector index conflict](#run-10-the-vector-index-conflict)
- [Run 11: the isolation test, and the four planted failures](#run-11-the-isolation-test-and-the-four-planted-failures)
- [Run 12: the published snippets, run verbatim](#run-12-the-published-snippets-run-verbatim)
- [What is documented rather than measured](#what-is-documented-rather-than-measured)
- [How to reproduce](#how-to-reproduce)

## How this was measured

One local Azure SQL Database container, started from the preview registry image, reporting:

```text
EngineEdition  Edition
5              SQL Azure
```

Every statement was run through the command line client inside the container. The concurrency
runs used a Node client with an explicit pool size against the same engine over a mapped port.

Two client identities were used throughout:

- `sa`, which maps to `dbo` in the user database. `IS_ROLEMEMBER('db_owner')` returned `1` and
  `IS_SRVROLEMEMBER('sysadmin')` returned `0`, which is the Azure SQL Database shape.
- a login and matching database user granted only `CONNECT` plus `SELECT`, `INSERT`, `UPDATE` and
  `DELETE` on one table. This is the application principal in every run below.

A contained user was not used, because the container refuses one. Create the login on `master`
and the user in the application database.

## The fixture

```sql
CREATE SCHEMA sec;
GO
CREATE TABLE dbo.orders (
    order_id  int           NOT NULL PRIMARY KEY,
    tenant_id int           NOT NULL,
    customer  nvarchar(50)  NOT NULL,
    amount    decimal(10,2) NOT NULL
);
INSERT INTO dbo.orders VALUES
 (1, 1, N'acme',   100.00),
 (2, 1, N'acme',   200.00),
 (3, 2, N'globex', 300.00),
 (4, 2, N'globex', 400.00);
GO
CREATE FUNCTION sec.fn_tenant(@tenant_id int)
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN SELECT 1 AS ok
       WHERE @tenant_id = CAST(SESSION_CONTEXT(N'tenant_id') AS int);
GO
CREATE SECURITY POLICY sec.p_orders
    ADD FILTER PREDICATE sec.fn_tenant(tenant_id) ON dbo.orders
    WITH (STATE = ON);
```

`sys.security_policies` then reported `p_orders`, `is_enabled = 1`, `is_schema_bound = 1`.

## Run 1: filter predicate only

As the application user, with `sp_set_session_context @key = N'tenant_id', @value = 1`.

| Statement | Server response | Rows the writer could then see |
|---|---|---|
| `SELECT order_id, tenant_id FROM dbo.orders` | 2 rows: 1, 2 | correct |
| `INSERT INTO dbo.orders VALUES (5, 2, N'globex', 500.00)` | **succeeded, no error** | 1, 2. Row 5 vanished |
| `UPDATE dbo.orders SET tenant_id = 2 WHERE order_id = 1` | **succeeded, 1 row** | 2 only. Row 1 vanished |
| `UPDATE dbo.orders SET amount = 999 WHERE order_id = 3` | 0 rows affected | unchanged |
| `DELETE FROM dbo.orders WHERE order_id = 3` | 0 rows affected | unchanged |

Ground truth, read back with the tenant set to 2 as `dbo`:

```text
order_id  tenant_id  amount
1         2          100.00     <- moved out of tenant 1 by tenant 1
3         2          300.00
4         2          400.00
5         2          500.00     <- created by tenant 1
```

A separate observation from a later run: a probe row inserted into another tenant during a failing
test could not be deleted afterwards by its author, because the filter predicate hides it from the
`DELETE` as well. It was recoverable only by disabling the policy. A cross-tenant write under a
filter-only policy is not just a leak, it is unrecoverable from the application side.

Note also that the same filter applies to `dbo`. `SELECT COUNT(*) FROM dbo.orders` as `sa` with no
session context returned `0`. See [run 8](#run-8-who-bypasses-the-policy).

## Run 2: the block predicate

```sql
ALTER SECURITY POLICY sec.p_orders
    ADD BLOCK PREDICATE sec.fn_tenant(tenant_id) ON dbo.orders AFTER INSERT,
    ADD BLOCK PREDICATE sec.fn_tenant(tenant_id) ON dbo.orders AFTER UPDATE,
    ADD BLOCK PREDICATE sec.fn_tenant(tenant_id) ON dbo.orders BEFORE UPDATE,
    ADD BLOCK PREDICATE sec.fn_tenant(tenant_id) ON dbo.orders BEFORE DELETE;
```

The same two statements from run 1, as the same application user with tenant 1:

| Statement | Result |
|---|---|
| `INSERT` a row stamped tenant 2 | `Msg 33504` |
| `UPDATE` my own row to tenant 2 | `Msg 33504` |
| `INSERT` a row stamped tenant 1 | succeeded |

Full text:

```text
Msg 33504: The attempted operation failed because the target object 'appdb.dbo.orders' has a
block predicate that conflicts with this operation. If the operation is performed on a view, the
block predicate might be enforced on the underlying table. Modify the operation to target only
the rows that are allowed by the block predicate.
```

## Run 3: AFTER INSERT without AFTER UPDATE

`BEFORE UPDATE`, `BEFORE DELETE` and `AFTER UPDATE` dropped, leaving the filter predicate and
`AFTER INSERT`. As the application user with tenant 1:

```sql
UPDATE dbo.orders SET tenant_id = 2 WHERE order_id = 1;
```

```text
UPDATE SUCCEEDED, rows = 1
```

The row left the tenant. This is the reason both block operations are named separately in the
skill body: an author who reasons "the block predicate stops cross-tenant writes" and adds one has
closed half the hole.

## Run 4: the duplicate key probe

Filter predicate only, application user with tenant 1. Row 3 belongs to tenant 2.

| Statement | Result |
|---|---|
| `SELECT COUNT(*) FROM dbo.orders WHERE order_id = 3` | `0`, correctly hidden |
| `INSERT INTO dbo.orders VALUES (3, 1, N'acme', 1.00)` | `Msg 2627`, violation of PRIMARY KEY, duplicate key value is (3) |
| `INSERT INTO dbo.orders VALUES (99, 1, N'acme', 1.00)` | succeeded |

The policy hides rows. Constraints are evaluated on the whole table, so the difference between the
two attempts tells a caller whether an id exists in some other tenant. This is a property of unique
constraints rather than a defect in the policy, and the mitigation is an identifier with no
guessable ordering.

## Run 5: session context under connection pooling

Node client, one pool, `max` and `min` both set so the physical connections are stable. Each
"request" acquires a connection from the pool, runs one statement, and returns it.

**Pool of 1, sequential.** The tenant id survived the request boundary:

```text
request 1: sets tenant_id=1          spid=69 ctx=1 rows=2 ids=1,2
request 2: sets NOTHING              spid=69 ctx=1 rows=2 ids=1,2
request 3: sets tenant_id=2          spid=69 ctx=2 rows=2 ids=3,4
request 4: sets NOTHING              spid=69 ctx=2 rows=2 ids=3,4
```

Requests 2 and 4 read a tenant they never claimed to be, with no error. The client's pool did not
reset the session between acquisitions. `sp_reset_connection` cannot be called from T-SQL to check
this by hand: it is a protocol level reset and the attempt returned `Msg 208, Invalid object name`.
Whether a given driver issues it on reuse is a driver property, so the safe assumption is that the
context survives.

**Pool of 5, 200 concurrent requests alternating tenant 1 and tenant 2.** Two shapes, same engine,
same policy, same second:

| Shape | Cross-tenant reads | Empty results |
|---|---|---|
| `EXEC sp_set_session_context ...` as one pool request, `SELECT` as another | **103 of 200**, then **91 of 200** on a repeat | 0 |
| both in one batch on one acquired connection | **0 of 200**, twice | 0 |

Nothing raised an error in either shape. The first shape is what an application produces when the
context is set by middleware holding a reference to the pool rather than to a connection.

## Run 6: read only session context

```sql
EXEC sp_set_session_context @key = N'tenant_id', @value = 1, @read_only = 1;
EXEC sp_set_session_context @key = N'tenant_id', @value = 2;
```

```text
Msg 15664: Cannot set key 'tenant_id' in the session context. The key has been set as read_only
for this session.
```

Replayed through the pool of 1:

```text
req1 tenant 1 sets ctx read_only               ctx=1 ids=1,2
req2 tenant 2 sets ctx read_only (correctly)   ERROR 15664
req3 tenant 2 forgets                          ctx=1 ids=1,2
```

`@read_only = 1` refused the correct caller and did not stop the incorrect one. It is safe only
where a connection is not reused across tenants.

## Run 7: a database user per tenant

```sql
CREATE TABLE sec.tenant_map (db_user sysname PRIMARY KEY, tenant_id int NOT NULL);
INSERT INTO sec.tenant_map VALUES (N'tenant_acme', 1), (N'tenant_globex', 2);
GO
CREATE FUNCTION sec.fn_tenant_by_user(@tenant_id int)
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN SELECT 1 AS ok FROM sec.tenant_map m
       WHERE m.db_user = USER_NAME() AND m.tenant_id = @tenant_id;
```

| Check | Result |
|---|---|
| `tenant_acme` selects | rows 1 and 2 only |
| `tenant_globex` selects | rows 3 and 4 only |
| `tenant_acme` inserts a row stamped tenant 2 | `Msg 33504` |
| `tenant_acme` runs `sp_set_session_context @value = 2` then selects | still rows 1 and 2 |
| `tenant_acme` runs `EXECUTE AS USER = 'tenant_globex'` | `Msg 15517`, cannot execute as the database principal |
| 200 concurrent requests, one pool per tenant login | 0 cross-tenant reads |

For contrast, under the session context predicate the same application user reset its own tenant id
and read the other tenant's rows, holding only `CONNECT` and the four table permissions. Nothing
had to be granted to call `sp_set_session_context`.

## Run 8: who bypasses the policy

All reads below are with no tenant set in session context.

| Principal | `SELECT COUNT(*) FROM dbo.orders` | `ALTER SECURITY POLICY ... WITH (STATE = OFF)` |
|---|---|---|
| application user, `CONNECT` and four table permissions | `0` | `Msg 33268` |
| `sa`, which is `dbo` and a `db_owner` member | `0` | succeeded, then `4` |
| a user added to `db_owner` | `0` | succeeded, then `4` |
| a user with `ALTER ANY SECURITY POLICY` and `ALTER ON SCHEMA::sec` | `0` | succeeded, then `4` |
| the same user with `ALTER ANY SECURITY POLICY` only | `0` | `Msg 33268` |
| the same user with `ALTER ON SCHEMA::sec` only | `0` | `Msg 33268` |

```text
Msg 33268: Cannot find the object "sec.p_orders" because it does not exist or you do not have
permissions.
```

Two results worth keeping. Nobody read through the policy, ownership included. And the permission
pair matters: the two halves were granted and revoked independently and each half alone produced
`Msg 33268`, which reports as a missing object rather than as a permission failure.

## Run 9: present but not enforcing

**`STATE = OFF`.** `sys.security_policies` reported `is_enabled = 0`. The application user with
tenant 1 set selected all four rows, no error, no warning.

**A predicate that fails open.**

```sql
CREATE FUNCTION sec.fn_tenant_failopen(@tenant_id int)
RETURNS TABLE WITH SCHEMABINDING AS
RETURN SELECT 1 AS ok
       WHERE @tenant_id = CAST(SESSION_CONTEXT(N'tenant_id') AS int)
          OR SESSION_CONTEXT(N'tenant_id') IS NULL;
```

Installed with `ALTER SECURITY POLICY ... ALTER FILTER PREDICATE`. `is_enabled` stayed `1`. The
application user with **no** session context selected all four rows. No catalog view distinguishes
this from a correct policy.

**A table the policy never covered.** `dbo.invoices` created with a `tenant_id` column and never
added to any policy. The application user with tenant 1 set:

```text
orders   (covered)      1|1   2|1
invoices (NOT covered)  1|1   2|2
```

The sweep query in section 5 of the skill body returned exactly this, at a moment when `orders`
carried one filter predicate and no block predicates:

```text
table_name        tenant_column  filter_predicates  block_predicates  policy_enabled
[dbo].[invoices]  tenant_id      0                  0                 NULL
[dbo].[orders]    tenant_id      1                  0                 1
```

`predicate_type` values were read back from `sys.security_predicates` and are `0` for `FILTER` and
`1` for `BLOCK`.

The sweep query exactly as published in the skill body was then run against the full fixture, with
`dbo.orders` correctly configured:

```text
table_name           filter_predicates  block_predicates  policy_enabled
[dbo].[chunks]       1                  0                 1
[dbo].[invoices]     0                  0                 NULL
[sec].[tenant_map]   0                  0                 NULL
```

`dbo.orders` was absent, which is the intended result. `sec.tenant_map` is the false positive to
expect: a mapping table carries a `tenant_id` column and needs no predicate. Dropping the
`AFTER UPDATE` block predicate from `dbo.orders` then made it appear with
`block_predicates = 1`, and restoring it removed it again.

## Run 10: the vector index conflict

A table of 300 rows with a `vector(4)` column. Both `SET QUOTED_IDENTIFIER ON` and
`SET ANSI_NULLS ON` are required, or `CREATE VECTOR INDEX` fails with `Msg 1934` about SET options,
which is a different failure and not the one being tested. A first attempt on a two row table
returned `Msg 42266`, at least 100 rows with non-null vectors are required.

With a genuine index built:

| Order | Statement | Result on the container |
|---|---|---|
| A | `CREATE VECTOR INDEX vi_chunks ON dbo.chunks(emb) WITH (METRIC='cosine', TYPE='diskann')` | created |
| A | `CREATE SECURITY POLICY sec.p_chunks ADD FILTER PREDICATE ... ON dbo.chunks` | `Msg 37579` |
| B | index dropped, `CREATE SECURITY POLICY` | created, `is_enabled = 1` |
| B | `CREATE VECTOR INDEX` | `Msg 42244` |

```text
Msg 37579: The security policy 'sec.p_chunks' cannot reference tables with vector indexes.
Table 'dbo.chunks' has a vector index.

Msg 42244: A vector index cannot be created on tables with security policies.
Table 'dbo.chunks' has security policy 'p_chunks'.
```

This reproduces the prior parity result on a fresh container and a fresh table.

**What does work locally.** With the policy on `dbo.chunks` and no vector index, exact search
returned correctly isolated results:

```text
tenant 1 top-k   chunk_id 150, 152, 148   all tenant_id 1   150 rows visible in total
tenant 2 top-k   chunk_id 151, 149, 147   all tenant_id 2
```

Both cloud coexistence claims in the table above are carried from the paired cloud/container
measurement and were not re-run here. Nothing else on this page depends on them.

## Run 11: the isolation test, and the four planted failures

The test in section 7 of the skill body was run as the application user against a correct policy
and printed five passes and `ALL PASS`, exit code `0`.

Each failure was then planted one at a time, the test re-run, and the policy restored:

| Planted | Output | Exit |
|---|---|---|
| `DROP BLOCK PREDICATE ON dbo.orders AFTER INSERT` | `FAIL 3: cross-tenant INSERT accepted` | 1 |
| `DROP BLOCK PREDICATE ON dbo.orders AFTER UPDATE` | `FAIL 4: tenant-move UPDATE accepted` | 1 |
| `WITH (STATE = OFF)` | `FAIL 1`, `FAIL 2`, `FAIL 4`, `FAIL 5` | 1 |
| `ALTER FILTER PREDICATE sec.fn_tenant_failopen(...)` | `FAIL 5: the predicate fails OPEN when no tenant is set` | 1 |

The first version of the test used fixed probe ids and produced a false `FAIL 3: unexpected error
2627` on the run after any failing run, because a probe row written into the other tenant during
the failing run could no longer be seen or deleted by the test. That is the run 1 result showing up
inside the test itself. The fix is the randomised `@probe` in the published version, and the lesson
is that a test for a filter predicate cannot clean up rows the filter predicate hides from it.

## Run 12: the published snippets, run verbatim

The two SQL blocks in the skill body were extracted from the published file and run as written,
rather than retyped, because a snippet that was edited after it was measured is a snippet nobody
has run.

| Snippet | Correct policy | With `AFTER UPDATE` dropped |
|---|---|---|
| the sweep query | `dbo.orders` absent, three candidates listed | `dbo.orders` listed, `block_predicates = 1` |
| the isolation test | `tenant isolation: ALL PASS`, exit `0` | `FAIL 4`, `Msg 50001`, exit `1` |

## What is documented rather than measured

- That row level security behaves identically in Azure SQL Database. Every run on this page is
  against the local container. The predicate, block and permission mechanics are engine features
  rather than container features, and nothing observed here contradicts the published behaviour,
  but the cloud side was not re-run.
- The published guidance to avoid predicate functions that join extra tables, and to index the
  columns a predicate filters on. Not measured here; this page makes no performance claim.
- That a policy applied to a view is enforced on the underlying table. This is stated inside the
  `Msg 33504` text quoted above and was not separately exercised.

## How to reproduce

1. Start the Azure SQL Database container and create an application database. The engine does not
   create one for you.
2. Create the login on `master` and the user in the application database. A contained user is
   refused.
3. Apply the fixture above, then work down runs 1 to 4 with two client sessions.
4. For run 5, use any client that exposes an explicit pool size. Set the minimum and maximum to
   the same number so the physical connections are stable, then issue the two shapes described.
5. For run 10, seed at least 100 rows with non-null vectors and set `QUOTED_IDENTIFIER` and
   `ANSI_NULLS` on before creating the index.
6. Remove the container when finished.
