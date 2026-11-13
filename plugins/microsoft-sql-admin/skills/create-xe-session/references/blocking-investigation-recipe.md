# Reusable Recipe - Intermittent Blocking Investigation

## When to Use

Use when:

1. A diagnostic identifies a suspect query.
2. Lock waits indicate blocking.
3. `check-live-blocking` finds no current chain because the problem is intermittent.
4. The user wants passive monitoring until it reproduces.

Blocking is one recipe for `create-xe-session`, not the default behavior.

## Specification

- Events: validated `sql_statement_completed` and `sp_statement_completed`
- Predicate: distinctive `QueryTextPattern` against the verified `statement` field
- Actions: application, host, server principal, database, and session identity
- Startup state: `OFF`
- Start immediately after creation
- Target: bounded `ring_buffer` when using `blocking-root-cause-analysis`

Warn that identity actions and statement data are sensitive and add collection overhead.

## Query Pattern

Choose a stable, distinctive fragment:

- Good: `UPDATE Inventory`, `Orders`, or `sp_UpdateCustomer`
- Bad: `SELECT` or `UPDATE`
- Bad: a transient literal such as `WHERE id = 42`

Double every single quote before substitution. Percent and underscore retain LIKE wildcard
behavior only when intended.

## Downstream Compatibility

When the downstream consumer is `blocking-root-cause-analysis`, use:

```text
session_name = BlockingInvestigation
target = ring_buffer
max_memory = 16384 KB
```

The downstream skill expects this named ring-buffer session on server or database scope.

## SQL Server/MI Event Clause

Substitute the validated database ID and escaped pattern:

```sql
ADD EVENT sqlserver.sql_statement_completed(
    ACTION(
        sqlserver.client_app_name,
        sqlserver.client_hostname,
        sqlserver.database_id,
        sqlserver.server_principal_name,
        sqlserver.session_id
    )
    WHERE (
        [sqlserver].[database_id] = ({{DatabaseId}})
        AND [sqlserver].[like_i_sql_unicode_string](
            [statement], N'%{{EscapedQueryTextPattern}}%')
    )
),
ADD EVENT sqlserver.sp_statement_completed(
    ACTION(
        sqlserver.client_app_name,
        sqlserver.client_hostname,
        sqlserver.database_id,
        sqlserver.server_principal_name,
        sqlserver.session_id
    )
    WHERE (
        [sqlserver].[database_id] = ({{DatabaseId}})
        AND [sqlserver].[like_i_sql_unicode_string](
            [statement], N'%{{EscapedQueryTextPattern}}%')
    )
)
```

Use the ring-buffer template in `step-3-sqlserver-session.md`.

## Azure/Fabric SQL Database Event Clause

Database scope already limits capture to the connected database:

```sql
ADD EVENT sqlserver.sql_statement_completed(
    ACTION(
        sqlserver.client_app_name,
        sqlserver.client_hostname,
        sqlserver.database_id,
        sqlserver.server_principal_name,
        sqlserver.session_id
    )
    WHERE (
        [sqlserver].[like_i_sql_unicode_string](
            [statement], N'%{{EscapedQueryTextPattern}}%')
    )
),
ADD EVENT sqlserver.sp_statement_completed(
    ACTION(
        sqlserver.client_app_name,
        sqlserver.client_hostname,
        sqlserver.database_id,
        sqlserver.server_principal_name,
        sqlserver.session_id
    )
    WHERE (
        [sqlserver].[like_i_sql_unicode_string](
            [statement], N'%{{EscapedQueryTextPattern}}%')
    )
)
```

Use the template in `step-4-database-session.md`.

## Completion

- Wait for the issue to reproduce.
- The ring buffer is circular and overwrites old events.
- `STARTUP_STATE = OFF` means the session does not restart automatically.
- A high event rate overwrites older ring-buffer events sooner; use an `event_file` target for long captures.
- Run `blocking-root-cause-analysis` after capture.
- Do not silently replace an existing `BlockingInvestigation` session.
