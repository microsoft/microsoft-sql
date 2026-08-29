---
name: rls-multi-tenant
description: >-
  Builds tenant isolation on Azure SQL Database that a test can prove, with a row level security
  policy whose filter predicate and block predicate are written together, because a filter alone
  still accepts a cross-tenant write and then hides the row from the application that made it.
  Use when asked to add row level security, isolate tenants in a shared table, write a security
  policy or predicate function, set the current tenant through SESSION_CONTEXT or a database user
  per tenant, or prove one tenant cannot read another; and use when a multi-tenant application
  returns the wrong tenant's rows under load, a policy is in place and everything is still
  visible, or error 33504 appears on an insert or update. Covers what pooling does to a session-scoped
  tenant id, who can turn a policy off, the tenant tables a healthy-looking policy
  does not cover, and the isolation test that goes red when any of it breaks. Identity onto a
  working connection is entra-id-auth; the table design under it is design-azure-sql-schema.
license: MIT
---

# Tenant isolation that holds, and the test that proves it

**The deliverable is the test, not the policy.** Anyone can write a security policy. The value is
an assertion that goes red when isolation breaks, because every way isolation breaks here is
silent: no error, no warning, no log line, and a catalog view that still says the policy is
enabled.

Everything below was measured on 2026-08-28 against a live engine where
`SERVERPROPERTY('EngineEdition')` returns `5` and `Edition` is `SQL Azure`. Every statement, count
and message is in [references/verified-behaviour.md](references/verified-behaviour.md).

## The shape of every failure on this page

| | |
|---|---|
| The policy | is created, and `sys.security_policies` says `is_enabled = 1` |
| The demo | shows tenant A seeing only tenant A rows |
| The failure | is a write into another tenant, or a read of another tenant, that raises nothing |

## 1. A filter predicate is not the boundary

The filter predicate governs which rows a statement can *see*. It does not govern which rows a
statement can *create*. Measured, as a low-privilege user holding a tenant id of 1:

| Statement, filter predicate only | Result | What it cost |
|---|---|---|
| `INSERT` a row stamped `tenant_id = 2` | **succeeded** | the row exists, invisible to its author, visible to tenant 2 |
| `UPDATE` one of my own rows to `tenant_id = 2` | **succeeded** | my row moved into another tenant, silently |
| `UPDATE` a row of tenant 2 | 0 rows affected | the filter protects the read behind a write |
| `DELETE` a row of tenant 2 | 0 rows affected | same |
| `INSERT` a key that already exists in tenant 2 | `Msg 2627` | the key space of another tenant is probeable |

The first two rows are the leak. The application that wrote them can never read them back and can
never delete them, because the filter now hides them from their own author. This was observed
directly: a probe row written by tenant 1 during a failing test run was stranded permanently,
retrievable only by disabling the policy.

The last row is worth stating plainly. A filter predicate hides rows, it does not hide their
existence. An insert of an id that exists in another tenant returns `Msg 2627` while an insert of
a free id succeeds, so a caller can enumerate another tenant's keys one attempt at a time. If
identifiers must not be guessable, use a value with no ordering rather than relying on the policy.

## 2. The block predicate, and why it is two predicates

Adding the block predicate turned both cross-tenant writes into:

```text
Msg 33504: The attempted operation failed because the target object '<db>.<schema>.<table>'
has a block predicate that conflicts with this operation.
```

The legitimate write into the caller's own tenant still succeeded.

**`AFTER INSERT` and `AFTER UPDATE` are separately required, and the second is the one people
leave out.** Measured: with the filter predicate and `AFTER INSERT` in place but no `AFTER
UPDATE`, the cross-tenant insert was refused and the tenant-move update **still succeeded**. One
row left the tenant with no error.

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
```

`BEFORE UPDATE` and `BEFORE DELETE` are redundant while a filter predicate is present, because the
filter already removes the other tenant's rows from the statement. Add them when the design has no
filter predicate, or as belt and braces. They cost nothing and they change nothing here.

## 3. How the tenant reaches the predicate, and what pooling does to it

Two designs. They are not equivalent, and the difference is measurable rather than stylistic.

### `SESSION_CONTEXT` is a variable, not an identity

It is per-connection state that **any caller on that connection can rewrite, with no permission at
all**. Measured: a user granted only `CONNECT` plus `SELECT`, `INSERT`, `UPDATE` and `DELETE` on
one table set its own tenant id to 2 and read tenant 2's rows. No grant was needed to call
`sp_set_session_context`, and none can be revoked to stop it.

So a `SESSION_CONTEXT` design is exactly as strong as the guarantee that nothing attacker-influenced
ever reaches that connection as SQL. Parameterise every statement and never concatenate user input
into one, or the tenant boundary is a variable the caller controls.

### The failure that reaches production

The tenant id outlives the request, because the connection does. Measured over a five connection
pool, 200 concurrent requests alternating between two tenants:

| Application shape | Cross-tenant reads in 200 requests |
|---|---|
| Set the context in one pooled request, run the query in another | **103**, then **91** on a repeat |
| Set the context and run the query on one acquired connection | 0 |
| A database user per tenant, one pool per tenant, no session context | 0 |

Half the requests returned another tenant's rows and **no caller saw an error**. The application
was not obviously wrong: it set the tenant on every request. It just handed the set and the query
to the pool separately, and the pool gave them different connections.

Two rules follow, and both are testable:

1. **The statement that sets the tenant and the statement that reads must run on the same acquired
   connection**, in one batch, one transaction, or one explicitly held connection. Not two calls
   to a pool.
2. **Never leave the tenant set at the end of a request.** A connection returned to the pool
   carrying a tenant id will hand it to the next request that forgets, and the measured direction
   of that failure is open, not closed: the next caller reads the previous tenant's rows.

`@read_only = 1` looks like the fix and is not. Measured: it makes the *correct* path fail. On a
reused pooled connection the next tenant's attempt to set its own id was refused with `Msg 15664`,
while a request that forgot to set anything still read the previous tenant's rows. It is safe only
where the connection genuinely ends with the request.

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

Measured: setting `SESSION_CONTEXT` under this predicate changed nothing, and reassigning identity
with `EXECUTE AS USER` was refused, since impersonation is a permission the tenant does not hold.
Connection pools are keyed by connection string, so each tenant gets its own pool and there is no
shared connection to leak through.

The cost is real: one login and one database user per tenant, a connection string per tenant, and
a pool per tenant. It fits tens or hundreds of tenants, not tens of thousands. Choose it when the
tenant count is bounded and the isolation has to survive an application bug rather than depend on
its absence.

## 4. Who bypasses the policy, confirmed rather than recalled

| Principal | Reads through the policy | Can turn it off |
|---|---|---|
| A plain application user | no, 0 rows with no tenant set | no, `Msg 33268` |
| The table owner, which is also the database owner | **no**, 0 rows with no tenant set | yes |
| A member of `db_owner` | **no**, 0 rows with no tenant set | yes, in one statement, then reads every row |
| `ALTER ANY SECURITY POLICY` alone | no | **no**, `Msg 33268` |
| `ALTER` on the schema holding the policy alone | no | **no**, `Msg 33268` |
| Both of the above together | no | yes, in one statement, then reads every row |

Two corrections here. **Ownership is not a read-through.** The table owner and `db_owner` are
subject to the predicate exactly like anyone else, and both returned zero rows with no tenant set.
What they hold is the ability to disable, which is a separate, single, auditable statement.

And **`ALTER ANY SECURITY POLICY` on its own is not enough** to disable an existing policy. It has
to be paired with `ALTER` permission on the schema that holds the policy. Either permission alone
failed with `Msg 33268`, reported as though the policy did not exist. Grant them as a pair, to a
principal an application never uses, and treat that pairing as the thing to review.

## 5. A policy can be present and not enforcing, in three ways

All three look healthy from the application: rows come back, nothing errors.

| Shape | What the application sees | What gives it away |
|---|---|---|
| `WITH (STATE = OFF)` | every tenant's rows | `sys.security_policies.is_enabled = 0` |
| A predicate that returns a row when the tenant is unset | every tenant's rows, to a session that set nothing | nothing in any catalog view; `is_enabled` is still 1 |
| A second tenant-scoped table nobody added to the policy | that table unfiltered, while the covered table is correct | no predicate rows for that object |

The second is the one to write carefully. A predicate of the form `WHERE @tenant_id = <context> OR
<context> IS NULL` was measured returning all four rows to a session with no tenant set, while
every catalog view reported a healthy enabled policy. **Predicates fail closed or they are not
predicates.** Never add an escape clause for administrative sessions.

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

Every row returned is a candidate, and the list has to be read rather than counted: a tenant
mapping table carries a `tenant_id` column and legitimately has no predicate on it, so it appears
here and is dismissed once. Anything else in the list is a tenant table that is not isolated.
Verified by planting a failure: with one block predicate dropped from a correctly configured
table, that table appeared in the results. `predicate_type` is `0` for filter and `1` for block,
read back from `sys.security_predicates` rather than recalled.

## 6. The local rehearsal gap, which matters most for retrieval

A tenant predicate on a chunk table is the cheapest defence against a retrieval answering one
tenant with another tenant's text. **On the Azure SQL Database container it cannot be rehearsed on
an indexed table.** Reproduced here on a table of 300 rows with a real vector index, in both
orders:

| Order | Container | Azure SQL Database |
|---|---|---|
| Vector index first, then `CREATE SECURITY POLICY` | `Msg 37579`, the policy cannot reference tables with vector indexes | both coexist |
| Security policy first, then `CREATE VECTOR INDEX` | `Msg 42244`, a vector index cannot be created on tables with security policies | both coexist |

This confirms what `rag-local-with-container` already measured, and it is the reason to say it
here: the isolation control is exactly the part of a retrieval design that does not get exercised
locally, so it ships having never run next to the index it will run next to.

What does work locally, and what to do: the filter predicate applies correctly to exact search over
`VECTOR_DISTANCE` with no vector index. Measured, two tenants over 300 chunks, each top-k returned
only its own rows. So rehearse the predicate on an unindexed chunk table, keep the index creation
out of the local path, and run the isolation test again after the index exists. `rag-on-azure-sql`
and `vector-search-azure-sql` cover retrieval itself.

## 7. The isolation test

Run it as the application's own database user, not as an administrator, on every deployment. It
exits non-zero when isolation breaks.

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

**The test was verified by planting each failure and watching it go red**, which is the only
evidence that an assertion asserts anything:

| Planted | What went red |
|---|---|
| Dropped the `AFTER INSERT` block predicate | 3 |
| Dropped the `AFTER UPDATE` block predicate | 4 |
| `WITH (STATE = OFF)` | 1, 2, 4, 5 |
| Swapped in the predicate that returns rows when the tenant is unset | 5 |

Assertions 1 and 2 are the same claim from two angles on purpose. Assertion 2 is what catches a
predicate that filters a direct scan and not an aggregate. Add the pooling case in application test
code: issue concurrent requests for two tenants against one pool and assert every response carries
only its own tenant, which is the shape that measured 103 wrong answers in 200.

## Validation rules

- Every tenant-scoped table carries a filter predicate **and** block predicates for both
  `AFTER INSERT` and `AFTER UPDATE`. A filter alone is not finished.
- The predicate function is `WITH SCHEMABINDING` and returns no row when the tenant is unset.
- No predicate contains an `OR` clause that lets an unset or administrative session through.
- The statement that sets the tenant and the statement that reads run on one acquired connection,
  and the tenant is not left set when the connection returns to the pool.
- The sweep query in section 5 returns no rows after every migration that adds a table.
- The isolation test runs as the application's own database user on every deployment, and it has
  been seen to fail with a predicate deliberately removed.
- `ALTER ANY SECURITY POLICY` and `ALTER` on the policy's schema are held together by no principal
  an application connects as.
- On a retrieval table, the isolation test runs again after the vector index exists, because it
  could not run beside one locally.

## Do not

- Do not ship a filter predicate on its own. A cross-tenant insert succeeds under it, and the row
  becomes unreadable and undeletable by the application that wrote it.
- Do not add `AFTER INSERT` and stop. The tenant-move update was measured succeeding with that
  block predicate in place.
- Do not set the tenant in one pooled call and query in another. Measured, that returned another
  tenant's rows about half the time with no error raised.
- Do not reach for `@read_only = 1` to make session context safe under pooling. It refuses the
  next tenant's correct attempt to set its own id and leaves the forgetful path leaking.
- Do not treat `SESSION_CONTEXT` as an identity. Any caller on the connection can rewrite it with
  no permission, so a statement built by string concatenation defeats the whole policy.
- Do not assume the table owner or `db_owner` reads through the policy. They do not. They disable
  it, which is a different, visible act.
- Do not grant `ALTER ANY SECURITY POLICY` believing it is inert on its own. Paired with `ALTER`
  on the policy's schema it is a full read of every protected table, in one statement.
- Do not read `is_enabled = 1` as proof of isolation. A fail-open predicate and an uncovered table
  both leave it at 1.
- Do not conclude row level security is unavailable because the container refuses it beside a
  vector index. The refusal is about the index, not about the policy.
- Do not put the tenant column in a nullable column or leave it without a default. A row that
  arrives with no tenant is invisible to every tenant and belongs to none.

## References

- [references/verified-behaviour.md](references/verified-behaviour.md): every statement run, the
  session counts, the exact messages, the four planted failures and the pooling harness. Read it
  when a number here is disputed, or before changing one.
- [Row-level security](https://learn.microsoft.com/sql/relational-databases/security/row-level-security):
  the reference for predicate syntax, the full list of block predicate operations, and the
  performance guidance. Read it before designing a predicate more complex than a single column.
- [sp_set_session_context](https://learn.microsoft.com/sql/relational-databases/system-stored-procedures/sp-set-session-context-transact-sql):
  the size limit, the `@read_only` argument, and the connection lifetime. Read it before choosing
  session context over a user per tenant.
- `entra-id-auth`: getting an identity onto a working connection, which is the step before this one.
- `design-azure-sql-schema`: the tenant column, its type, and where it belongs in the key.
- `t-sql-correctness`: dialect rules for the predicate function and the sweep query.
- `rag-on-azure-sql` and `vector-search-azure-sql`: retrieval itself, and the vector index this
  policy cannot sit beside locally.
- `rag-local-with-container`: the full container against cloud parity measurement this page's
  section 6 confirms.
- `least-privilege-database-roles`: the roles an application connects as, and keeping the two
  disabling permissions away from them.
