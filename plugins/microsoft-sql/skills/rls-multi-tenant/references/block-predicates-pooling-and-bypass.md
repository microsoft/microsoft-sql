# Block predicates, pooling and bypass: tenant isolation checks you can run

## Contents

- [Setup](#setup)
- [A filter predicate alone lets cross-tenant writes through](#a-filter-predicate-alone-lets-cross-tenant-writes-through)
- [The block predicate refuses both cross-tenant writes](#the-block-predicate-refuses-both-cross-tenant-writes)
- [AFTER INSERT without AFTER UPDATE lets a row change tenant](#after-insert-without-after-update-lets-a-row-change-tenant)
- [A duplicate key reveals another tenant's ids](#a-duplicate-key-reveals-another-tenants-ids)
- [Session context survives pooled connection reuse](#session-context-survives-pooled-connection-reuse)
- [Read only session context refuses the correct caller](#read-only-session-context-refuses-the-correct-caller)
- [A database user per tenant ignores session context](#a-database-user-per-tenant-ignores-session-context)
- [Who bypasses the policy](#who-bypasses-the-policy)
- [A policy can be present and not enforcing](#a-policy-can-be-present-and-not-enforcing)
- [A security policy beside a vector index depends on the build](#a-security-policy-beside-a-vector-index-depends-on-the-build)
- [The isolation test catches each planted failure](#the-isolation-test-catches-each-planted-failure)
- [The SKILL.md snippets, run as written](#the-skillmd-snippets-run-as-written)
- [Predicate performance and views](#predicate-performance-and-views)

## Setup

The scripts below run on the local Azure SQL Database container. The behavior Microsoft Learn's
row-level security pages document applies to Azure SQL Database; re-check the rest, such as exact
error numbers, on the service before relying on it. The vector index section depends on the build.

Use two client identities:

- `sa` below is an administrative login that maps to `dbo` in the user database:
  `IS_ROLEMEMBER('db_owner')` returns `1` and `IS_SRVROLEMEMBER('sysadmin')` returns `0`, which is
  the Azure SQL Database shape.
- a login and matching database user granted only `CONNECT` plus `SELECT`, `INSERT`, `UPDATE` and
  `DELETE` on one table. This is the application principal in every check below.

The Azure SQL Database container image does not create an application database for you, and it
refuses a contained user. There, create the database first, the login on `master`, and the user in
the application database.

The setup script:

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

`sys.security_policies` then shows `p_orders` with `is_enabled = 1` and `is_schema_bound = 1`.

## A filter predicate alone lets cross-tenant writes through

Under a filter-only policy the application can insert a row into another tenant and move its own
row out, with no error, while the other tenant's existing rows stay out of reach.

As the application user, with `sp_set_session_context @key = N'tenant_id', @value = 1`.

| Statement | Server response | Rows the writer can then see |
|---|---|---|
| `SELECT order_id, tenant_id FROM dbo.orders` | 2 rows: 1, 2 | correct |
| `INSERT INTO dbo.orders VALUES (5, 2, N'globex', 500.00)` | **succeeds, no error** | 1, 2. Row 5 vanishes |
| `UPDATE dbo.orders SET tenant_id = 2 WHERE order_id = 1` | **succeeds, 1 row** | 2 only. Row 1 vanishes |
| `UPDATE dbo.orders SET amount = 999 WHERE order_id = 3` | 0 rows affected | unchanged |
| `DELETE FROM dbo.orders WHERE order_id = 3` | 0 rows affected | unchanged |

Read back as `dbo` with the tenant set to 2, and you will see:

```text
order_id  tenant_id  amount
1         2          100.00     <- moved out of tenant 1 by tenant 1
3         2          300.00
4         2          400.00
5         2          500.00     <- created by tenant 1
```

A row inserted into another tenant this way cannot be deleted afterwards by its author, because
the filter predicate hides it from the `DELETE` as well. Only disabling the policy recovers it. A
cross-tenant write under a filter-only policy is not just a leak, it is unrecoverable from the
application side.

The same filter applies to `dbo`: `SELECT COUNT(*) FROM dbo.orders` as `sa` with no session
context returns `0`. See [who bypasses the policy](#who-bypasses-the-policy).

## The block predicate refuses both cross-tenant writes

`AFTER INSERT` and `AFTER UPDATE` block predicates turn both writes above into `Msg 33504`, and a
write into the caller's own tenant still succeeds.

```sql
ALTER SECURITY POLICY sec.p_orders
    ADD BLOCK PREDICATE sec.fn_tenant(tenant_id) ON dbo.orders AFTER INSERT,
    ADD BLOCK PREDICATE sec.fn_tenant(tenant_id) ON dbo.orders AFTER UPDATE,
    ADD BLOCK PREDICATE sec.fn_tenant(tenant_id) ON dbo.orders BEFORE UPDATE,
    ADD BLOCK PREDICATE sec.fn_tenant(tenant_id) ON dbo.orders BEFORE DELETE;
```

Run the same two statements as the application user with tenant 1:

| Statement | Result |
|---|---|
| `INSERT` a row stamped tenant 2 | `Msg 33504` |
| `UPDATE` its own row to tenant 2 | `Msg 33504` |
| `INSERT` a row stamped tenant 1 | succeeds |

The full message:

```text
Msg 33504: The attempted operation failed because the target object 'appdb.dbo.orders' has a
block predicate that conflicts with this operation. If the operation is performed on a view, the
block predicate might be enforced on the underlying table. Modify the operation to target only
the rows that are allowed by the block predicate.
```

## AFTER INSERT without AFTER UPDATE lets a row change tenant

With the filter predicate and `AFTER INSERT` but no `AFTER UPDATE`, a tenant-move update succeeds.

Drop `BEFORE UPDATE`, `BEFORE DELETE` and `AFTER UPDATE`, leaving the filter predicate and
`AFTER INSERT`. As the application user with tenant 1:

```sql
UPDATE dbo.orders SET tenant_id = 2 WHERE order_id = 1;
```

```text
UPDATE SUCCEEDED, rows = 1
```

The row leaves the tenant. This is why SKILL.md names both block operations separately: reasoning
"the block predicate stops cross-tenant writes" and adding one closes half the hole.

## A duplicate key reveals another tenant's ids

The policy hides rows, not their keys: a duplicate key error tells the caller an id exists in
another tenant.

Filter predicate only, application user with tenant 1. Row 3 belongs to tenant 2.

| Statement | Result |
|---|---|
| `SELECT COUNT(*) FROM dbo.orders WHERE order_id = 3` | `0`, correctly hidden |
| `INSERT INTO dbo.orders VALUES (3, 1, N'acme', 1.00)` | `Msg 2627`, violation of PRIMARY KEY, duplicate key value is (3) |
| `INSERT INTO dbo.orders VALUES (99, 1, N'acme', 1.00)` | succeeds |

The policy hides rows. Constraints are evaluated on the whole table, so the difference between the
two attempts tells a caller whether an id exists in some other tenant. This is a property of unique
constraints rather than a defect in the policy, and the mitigation is an identifier with no
guessable ordering.

## Session context survives pooled connection reuse

The tenant id set on a pooled connection is still set when the next request gets that connection.

Use any client that exposes an explicit pool size, with `max` and `min` both set so the physical
connections are stable. Each "request" acquires a connection from the pool, runs one statement,
and returns it.

**Pool of 1, sequential.** The tenant id survives the request boundary:

```text
request 1: sets tenant_id=1          spid=69 ctx=1 rows=2 ids=1,2
request 2: sets NOTHING              spid=69 ctx=1 rows=2 ids=1,2
request 3: sets tenant_id=2          spid=69 ctx=2 rows=2 ids=3,4
request 4: sets NOTHING              spid=69 ctx=2 rows=2 ids=3,4
```

Requests 2 and 4 read a tenant they never claimed to be, with no error, because the pool does not
reset the session between acquisitions. `sp_reset_connection` cannot be called from T-SQL to check
this by hand: it is a protocol level reset and the attempt returns `Msg 208, Invalid object name`.
Whether a given driver issues it on reuse is a driver property, so the safe assumption is that the
context survives.

**Pool of 5, 200 concurrent requests alternating tenant 1 and tenant 2.** Two shapes, same engine,
same policy, same second:

| Shape | Cross-tenant reads | Empty results |
|---|---|---|
| `EXEC sp_set_session_context ...` as one pool request, `SELECT` as another | **a large share of requests**, varying between repeats | none |
| both in one batch on one acquired connection | none | none |

Neither shape raises an error. The first shape is what an application produces when the context is
set by middleware holding a reference to the pool rather than to a connection.

## Read only session context refuses the correct caller

`@read_only = 1` stops the value changing on that connection, including when a pool hands the
connection to the next tenant.

```sql
EXEC sp_set_session_context @key = N'tenant_id', @value = 1, @read_only = 1;
EXEC sp_set_session_context @key = N'tenant_id', @value = 2;
```

```text
Msg 15664: Cannot set key 'tenant_id' in the session context. The key has been set as read_only
for this session.
```

Through a pool of 1:

```text
req1 tenant 1 sets ctx read_only               ctx=1 ids=1,2
req2 tenant 2 sets ctx read_only (correctly)   ERROR 15664
req3 tenant 2 forgets                          ctx=1 ids=1,2
```

`@read_only = 1` refuses the correct caller and does not stop the incorrect one. It is safe only
where a connection is not reused across tenants.

## A database user per tenant ignores session context

When the predicate reads the database user instead of session state, setting `SESSION_CONTEXT`
changes nothing and impersonating another tenant is refused.

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
| 200 concurrent requests, one pool per tenant login | no cross-tenant reads |

For contrast, under the session context predicate the same application user can reset its own
tenant id and read the other tenant's rows, holding only `CONNECT` and the four table permissions.
Nothing has to be granted to call `sp_set_session_context`.

## Who bypasses the policy

Nobody reads through the policy, ownership included. Turning it off takes `dbo` or `db_owner`
membership, or `ALTER ANY SECURITY POLICY` together with `ALTER` on the policy's schema.

All reads below are with no tenant set in session context.

| Principal | `SELECT COUNT(*) FROM dbo.orders` | `ALTER SECURITY POLICY ... WITH (STATE = OFF)` |
|---|---|---|
| application user, `CONNECT` and four table permissions | `0` | `Msg 33268` |
| `sa`, which is `dbo` and a `db_owner` member | `0` | succeeds, then `4` |
| a user added to `db_owner` | `0` | succeeds, then `4` |
| a user with `ALTER ANY SECURITY POLICY` and `ALTER ON SCHEMA::sec` | `0` | succeeds, then `4` |
| the same user with `ALTER ANY SECURITY POLICY` only | `0` | `Msg 33268` |
| the same user with `ALTER ON SCHEMA::sec` only | `0` | `Msg 33268` |

```text
Msg 33268: Cannot find the object "sec.p_orders" because it does not exist or you do not have
permissions.
```

The permission pair matters: grant and revoke the two halves independently and each half alone
produces `Msg 33268`, which reports as a missing object rather than as a permission failure.

## A policy can be present and not enforcing

Three shapes leave a policy in place that does not isolate tenants, and the application sees no
error from any of them.

**`STATE = OFF`.** `sys.security_policies` reports `is_enabled = 0`. The application user with
tenant 1 set selects all four rows, no error, no warning.

**A predicate that fails open.**

```sql
CREATE FUNCTION sec.fn_tenant_failopen(@tenant_id int)
RETURNS TABLE WITH SCHEMABINDING AS
RETURN SELECT 1 AS ok
       WHERE @tenant_id = CAST(SESSION_CONTEXT(N'tenant_id') AS int)
          OR SESSION_CONTEXT(N'tenant_id') IS NULL;
```

Install it with `ALTER SECURITY POLICY ... ALTER FILTER PREDICATE`. `is_enabled` stays `1`. The
application user with **no** session context selects all four rows. No catalog view distinguishes
this from a correct policy.

**A table the policy never covered.** Create `dbo.invoices` with a `tenant_id` column and add it
to no policy. The application user with tenant 1 set sees:

```text
orders   (covered)      1|1   2|1
invoices (NOT covered)  1|1   2|2
```

A sweep over the same catalog views as the one in section 5 of SKILL.md, with an extra
`tenant_column` column, returns this when `orders` carries one filter predicate and no block
predicates:

```text
table_name        tenant_column  filter_predicates  block_predicates  policy_enabled
[dbo].[invoices]  tenant_id      0                  0                 NULL
[dbo].[orders]    tenant_id      1                  0                 1
```

`predicate_type` in `sys.security_predicates` is `0` for `FILTER` and `1` for `BLOCK`.

The sweep query exactly as written in SKILL.md, against the full fixture with `dbo.orders`
correctly configured, returns:

```text
table_name           filter_predicates  block_predicates  policy_enabled
[dbo].[chunks]       1                  0                 1
[dbo].[invoices]     0                  0                 NULL
[sec].[tenant_map]   0                  0                 NULL
```

`dbo.orders` is absent, which is the intended result. `sec.tenant_map` is the false positive to
expect: a mapping table carries a `tenant_id` column and needs no predicate. Drop the
`AFTER UPDATE` block predicate from `dbo.orders` and it appears with `block_predicates = 1`;
restore it and it disappears again.

## A security policy beside a vector index depends on the engine

Earlier builds of the Azure SQL Database container image, and SQL Server 2025, refuse a security
policy and a vector index on the same table, in either order. Azure SQL Database, Fabric SQL
database and newer container builds allow both, but the vector index is not used
under the policy.

Use a table of 300 rows with a `vector(4)` column. Both `SET QUOTED_IDENTIFIER ON` and
`SET ANSI_NULLS ON` are required, or `CREATE VECTOR INDEX` fails with `Msg 1934` about SET options,
which is a different failure from this one. On a two row table it fails with `Msg 42266`: at least
100 rows with non-null vectors are required.

With a genuine index built, on earlier builds:

| Order | Statement | Result |
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

**Newer builds.** On container image build 18.0.310.0_253 the same pair succeeds in **both**
orders, with version 3 vector indexes. The filter predicate holds through `TOP (n) WITH
APPROXIMATE` (every row returned is from the session's tenant), and a block predicate on a
vector-indexed table refuses a cross-tenant insert with `Msg 33504`. But the index is not used
under the policy: adding `WITH (FORCE_ANN_ONLY)` fails with `Msg 8622`, while the same query on an
identical table with no policy, the tenant test written as a `WHERE` clause, gets a `Vector Index
Seek`. `Msg 37579` and `Msg 42244` are still in that build's `sys.messages`; they are no longer
raised. The collision is build-dependent, not a fixed engine rule.

**Azure SQL Database and Fabric SQL database** behave like build 18.0.310.0_253: both orders are
created, the filter holds through `TOP (n) WITH APPROXIMATE`, a block predicate refuses a
cross-tenant insert with `Msg 33504`, and `WITH (FORCE_ANN_ONLY)` under the policy fails with
`Msg 8622`. Fabric builds the index graph in the background, so right after `CREATE VECTOR INDEX`
the hint fails with `Msg 42286` (graph not built yet) before it fails with `Msg 8622`.

**SQL Server 2025** refuses the pair like the earlier container builds: `Msg 37579` for the policy
after the index, `Msg 42244` for the index after the policy. `CREATE VECTOR INDEX` itself needs
`ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = ON` there, and fails with `Msg 343`
without it.

**Exact search is isolated correctly.** With the policy on `dbo.chunks` and no vector index, exact
search returns only the session's tenant:

```text
tenant 1 top-k   chunk_id 150, 152, 148   all tenant_id 1   150 rows visible in total
tenant 2 top-k   chunk_id 151, 149, 147   all tenant_id 2
```

## The isolation test catches each planted failure

Run the isolation test from SKILL.md's "Check it worked" as the application user against a correct
policy: it prints `tenant isolation: ALL PASS` and exits `0`.

Then plant each failure one at a time, re-run the test, and restore the policy:

| Plant | Output | Exit |
|---|---|---|
| `DROP BLOCK PREDICATE ON dbo.orders AFTER INSERT` | `FAIL 3: cross-tenant INSERT accepted` | 1 |
| `DROP BLOCK PREDICATE ON dbo.orders AFTER UPDATE` | `FAIL 4: tenant-move UPDATE accepted` | 1 |
| `WITH (STATE = OFF)` | `FAIL 1`, `FAIL 2`, `FAIL 4`, `FAIL 5` | 1 |
| `ALTER FILTER PREDICATE sec.fn_tenant_failopen(...)` | `FAIL 5: the predicate fails OPEN when no tenant is set` | 1 |

Probe ids must be unique per run. With fixed probe ids, the run after any failing run reports a
false `FAIL 3: unexpected error 2627`, because a probe row written into the other tenant during the
failing run can no longer be seen or deleted by the test: the filter-only leak above, showing up
inside the test itself. The randomised `@probe` in SKILL.md prevents it. A test for a filter
predicate cannot clean up rows the filter predicate hides from it.

## The SKILL.md snippets, run as written

Copy the sweep query and the isolation test out of SKILL.md rather than retyping them, and run
them against a correct policy and then with `AFTER UPDATE` dropped. You will see:

| Snippet | Correct policy | With `AFTER UPDATE` dropped |
|---|---|---|
| the sweep query | `dbo.orders` absent, three candidates listed | `dbo.orders` listed, `block_predicates = 1` |
| the isolation test | `tenant isolation: ALL PASS`, exit `0` | `FAIL 4`, `Msg 50001`, exit `1` |

## Predicate performance and views

- Learn advises avoiding predicate functions that join extra tables, and indexing the columns a
  predicate filters on. This page makes no performance claim.
- An operation performed on a view can be blocked by the block predicate on the underlying table,
  as the `Msg 33504` text above states.
