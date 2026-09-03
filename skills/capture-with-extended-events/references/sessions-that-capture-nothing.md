# Event sessions that create, start, and capture nothing

The evidence behind the empty-capture cases in SKILL.md.

## Contents

- [Duration units, event by event](#duration-units-event-by-event)
- [ACTION versus no ACTION](#action-versus-no-action-same-event-side-by-side)
- [blocked_process_report captured zero](#blocked_process_report-captured-zero)
- [database_xml_deadlock_report captured zero, and Learn disagrees](#database_xml_deadlock_report-captured-zero-and-learn-disagrees)
- [lock_deadlock captured one](#lock_deadlock-captured-one)
- [There is no system_health session](#there-is-no-system_health-session-to-fall-back-on)

**Read the provenance before you use a number here.** All of it was measured on 2026-08-29 against
a local Azure SQL Database container reporting `EngineEdition` 5, in a scratch database. That is a
different engine build from the cloud service, so where a measurement here contradicts Microsoft
Learn, **the contradiction is stated and Learn wins**.

## Duration units, event by event

Read from `sys.dm_xe_object_columns`, which carries a `description` for every column of every event:

| Event | `duration` column description |
|---|---|
| `sql_statement_completed` | "The time (in microseconds) that it took to execute the statement." |
| `rpc_completed` | "The time (in microseconds) that the remote procedure call took to be completed." |
| `lock_acquired` | "The time (in microseconds) between when the lock was requested and when it was canceled." |
| `wait_completed` | "Wait duration in milliseconds" |
| `wait_info` | "Wait duration in milliseconds" |

Confirmed empirically for `sql_statement_completed`: a session filtering `WHERE duration > 500000`
on that event, with `WAITFOR DELAY '00:00:01'` run against it, captured the statement with
`duration` = `1000292`. A microsecond reading for a one-second wait fits; a millisecond reading
would have been roughly `1000`.

The failure this produces has no symptom. A predicate copied from a `wait_info` session onto a
`sql_statement_completed` session is off by a factor of 1000: it captures far more than intended,
or, more often, nothing at all.

## ACTION versus no ACTION, same event side by side

Two sessions, both on `sqlserver.sql_statement_completed`, both targeting `package0.ring_buffer`,
run against the same kind of statement.

With actions, `ACTION (sqlserver.sql_text, sqlserver.username, sqlserver.client_app_name)`, the
captured XML carried, alongside the native fields:

```xml
<action name="client_app_name" package="sqlserver"><value>SQLCMD</value></action>
<action name="username" package="sqlserver"><value>sa</value></action>
<action name="sql_text" package="sqlserver"><value>SET TEXTSIZE 4096</value></action>
```

Without the `ACTION()` clause the same event shape came back, `statement` field and all, with
**zero** `<action>` elements: no error, no warning, and an identical `eventCount`. Nothing
distinguishes them but the presence of an `<action>` element, which is why "Check it worked" counts
rows in `sys.database_event_session_actions` instead.

## blocked_process_report captured zero

Setup: a table with one row; one session holding an open transaction with an `UPDATE` on that row
for roughly 30 seconds; a second session issuing a conflicting `UPDATE` on the same row shortly
after. Both completed without error, confirming the second genuinely waited behind the first's lock
for most of that window.

```sql
CREATE EVENT SESSION dq_xe_blocking ON DATABASE
ADD EVENT sqlserver.blocked_process_report
ADD TARGET package0.ring_buffer;
ALTER EVENT SESSION dq_xe_blocking ON DATABASE STATE = START;
```

Read back after the blocking episode finished:

```xml
<RingBufferTarget truncated="0" processingTime="0" totalEventsProcessed="0" eventCount="0" droppedCount="0" memoryUsed="0"/>
```

`execution_count` for the target was also `0`, and the session was present in
`sys.dm_xe_database_sessions` throughout. The usual fix, setting the threshold, is not available:

```output
EXEC sp_configure 'blocked process threshold';
Msg 40510, Level 16, State 1
Statement 'CONFIG' is not supported in this version of SQL Server.
```

and `sys.database_scoped_configurations` has no row matching `%BLOCK%` or `%THRESHOLD%`. Learn
corroborates it: the `blocked process threshold` option is documented for SQL Server only, and
40510 is in the error table with exactly that message. The event is not hard to trigger here, there
is no exposed control to trigger it with.

Learn also names the supported route on Azure SQL Database, which is not an event session: the
`Blocks` resource log category, streamed through a diagnostic setting, carries
`blocked_process_filtered_s` (the blocked process report XML), `lock_mode_s`,
`resource_owner_type_s` and `duration_d` in microseconds.

## database_xml_deadlock_report captured zero, and Learn disagrees

Setup: two tables, each with one row. Two sessions each update their own table, wait three seconds,
then attempt to update the other's, guaranteeing a lock-order deadlock. Run twice, independently.

```sql
CREATE EVENT SESSION dq_xe_deadlock ON DATABASE
ADD EVENT sqlserver.database_xml_deadlock_report
ADD TARGET package0.ring_buffer;
ALTER EVENT SESSION dq_xe_deadlock ON DATABASE STATE = START;
```

Both runs produced a real deadlock, each confirmed by the victim receiving `Msg 1205, Level 13`,
naming it the deadlock victim. Both times the ring buffer read back with `eventCount="0"`. `sys.dm_xe_objects` describes the event
as "Produces a deadlock report for a victim, with information scoped to the victim's database" with
`capabilities_desc` = `sds_visible`, so the engine reported it as valid and visible in this scope.
It was created, attached and started without error at any step, and simply did not fire.

**Microsoft Learn documents this exact event as the way to collect deadlock graphs on Azure SQL
Database**, in both the ring buffer and event file forms, with `STARTUP_STATE = ON` and
`MAX_MEMORY = 4 MB`. That is a direct contradiction of the measurement above, and it is not
resolved: the measurement is from the container, not from the cloud service, and nothing here
tests the cloud service. Follow Learn, build the session it documents, and verify it against a
deadlock you cause on purpose before relying on it. Learn also notes that optimized locking is
always on in Azure SQL Database, which makes deadlocks less likely in the first place, so an empty
session is not by itself evidence the event is broken.

## lock_deadlock captured one

Same deadlock setup, a different database-scoped event:

```sql
CREATE EVENT SESSION dq_xe_deadlock2 ON DATABASE
ADD EVENT sqlserver.lock_deadlock
ADD TARGET package0.ring_buffer;
ALTER EVENT SESSION dq_xe_deadlock2 ON DATABASE STATE = START;
```

captured one event on the first attempt, carrying `resource_type` `XACT`, `mode` `S`, `owner_type`
`Transaction`, a `transaction_id`, a `database_id` and a `deadlock_id`. It gives no deadlock graph,
only the resource, the lock mode, the owning transaction and an id grouping the participants of one
deadlock: enough to confirm a deadlock happened and roughly on what. Keep it as the fallback for
when the documented session verifies empty, not as the first choice.

## There is no system_health session to fall back on

An earlier version of this file spent most of its length on `system_health`: the container has one,
visible from `master` through `sys.dm_xe_sessions`, whose ring buffer did capture
`xml_deadlock_report` for a real deadlock. That was correctly measured, and **it is a property of
the container, not of Azure SQL Database.** Learn is unambiguous, and the `system_health`
documentation page applies to SQL Server only: "There's no built-in `system_health` Extended Event
session in Azure SQL Database." There is no baseline session on the cloud service, no `master`
connection that reveals one, and no reason to look. Build the session you need.

The one built-in session, `dl`, comes with a prohibition rather than an invitation: do not read
deadlock events from it, because `sys.fn_xe_file_target_read_file` over a large `dl` file can raise
an out-of-memory error in `master`, affecting login processing and causing an application outage.

Also measured on the container: `sys.dm_xe_database_objects` does not exist, raising `Msg 208`
either way. Learn corroborates it, listing the Extended Events DMVs common to Azure SQL Database as
`sys.dm_xe_map_values`, `sys.dm_xe_object_columns`, `sys.dm_xe_objects` and `sys.dm_xe_packages`,
with no database-prefixed variant. Event, action and target metadata comes from plain
`sys.dm_xe_objects`.
