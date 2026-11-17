# Step 1 - Event Design

## Translate Intent into Signals

| Intent | Candidate event family | Typical predicate |
|---|---|---|
| Long-running statements | statement completion | duration |
| High-CPU statements | statement completion | CPU time |
| High logical reads | statement completion | logical reads |
| Procedure call totals | RPC completion | duration/CPU/reads |
| Statements inside procedures | SQL/SP statement completion | object or statement |
| Errors | error-reporting events | severity/error number |
| Deadlocks | deadlock report event | normally no text predicate |
| Wait analysis | wait events | wait type and duration |
| Intermittent blocking suspect | statement completion | distinctive statement fragment |

These are candidate families. Validate exact event names at runtime.

## Event Discovery

Run this read-only metadata query for every candidate event after substituting the package and
event names:

```sql
DECLARE @package sysname = N'sqlserver';
DECLARE @event sysname = N'sql_statement_completed';

SELECT c.name AS field_name, c.type_name, c.column_type, c.description
FROM sys.dm_xe_object_columns AS c
JOIN sys.dm_xe_objects AS o
  ON o.name = c.object_name AND o.package_guid = c.object_package_guid
JOIN sys.dm_xe_packages AS p ON p.guid = o.package_guid
WHERE o.object_type = N'event'
  AND p.name = @package
  AND o.name = @event
  AND c.column_type <> N'readonly'
ORDER BY c.column_type, c.name
OPTION (MAXDOP 1);
```

Rules:

- Use only returned events and fields.
- Use returned descriptions to determine units.
- Do not assume all duration or CPU fields use the same units.
- For general query completion, normally include both `sql_statement_completed` and
  `sp_statement_completed`.
- For statements inside one specific stored procedure, use the validated statement event and
  object/statement predicates.
- Use `rpc_completed` only for all-up stored procedure call metrics.
- Prefer completion events; starting events can produce more data and lack final measurements.

## Predicate Discovery

Run this read-only metadata query before using a global predicate:

```sql
SELECT p.name AS package_name, o.name AS field_name, o.type_name, o.description
FROM sys.dm_xe_objects AS o
JOIN sys.dm_xe_packages AS p ON p.guid = o.package_guid
WHERE o.object_type = N'pred_source'
  AND (p.capabilities IS NULL OR p.capabilities & 1 = 0)
  AND (o.capabilities IS NULL OR o.capabilities & 1 = 0)
ORDER BY p.name, o.name
OPTION (MAXDOP 1);
```

Predicates may use only:

- fields returned for the selected event; and
- returned global predicate fields.

For statement matching, use the verified `statement` event field and the
`sqlserver.like_i_sql_unicode_string` comparator rather than assuming `sql_text` is an event
field.

Keep predicates selective. Prefer filtering during collection over capturing everything.

## Actions

Actions execute for every captured event and can increase overhead.

- Add no actions by default.
- Add only information required by the diagnostic question.
- Warn before adding SQL text, application, host, login, database, or session identity.
- Verify actions with the action inventory in Step 0.

## Example Event Clause

This is a shape only. Validate every field, action, comparator, and unit before use.

```sql
ADD EVENT sqlserver.sql_statement_completed(
    ACTION(
        {{ValidatedActions}}
    )
    WHERE (
        [duration] > ({{ValidatedDuration}})
        AND [sqlserver].[like_i_sql_unicode_string](
            [statement], N'%{{EscapedStatementPattern}}%')
    )
),
```

Omit the `ACTION` block when no action is necessary. Never execute unresolved placeholders.

## Input Validation

- Session names must be simple identifiers and escaped with `QUOTENAME` semantics.
- Numeric settings must remain in documented bounds.
- Double every single quote in string predicate values.
- Percent and underscore retain LIKE wildcard behavior only when the user intends it.
- Never paste unescaped user text into DDL.
