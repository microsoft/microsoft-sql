# Event sessions that create, start, and capture nothing

Checks you can run for the empty-capture cases in the Azure SQL guidance.

## Contents

- [Duration units, event by event](#duration-units-event-by-event)
- [ACTION versus no ACTION](#action-versus-no-action-same-event-side-by-side)
- [blocked_process_report captures nothing](#blocked_process_report-captures-nothing)
- [database_xml_deadlock_report: follow Learn, then verify](#database_xml_deadlock_report-follow-learn-then-verify)
- [lock_deadlock as the fallback](#lock_deadlock-as-the-fallback)
- [There is no system_health session](#there-is-no-system_health-session-to-fall-back-on)

Run them in a scratch database. A local Azure SQL Database container (`EngineEdition` 5) is a
different engine build from the cloud service; where it contradicts Microsoft Learn, **the
difference is stated and Learn wins**.

## Duration units, event by event

Read from `sys.dm_xe_object_columns`, which carries a `description` for every column of every event:

| Event | `duration` column description |
|---|---|
| `sql_statement_completed` | "The time (in microseconds) that it took to execute the statement." |
| `rpc_completed` | "The time (in microseconds) that the remote procedure call took to be completed." |
| `lock_acquired` | "The time (in microseconds) between when the lock was requested and when it was canceled." |
| `wait_completed` | "Wait duration in milliseconds" |
| `wait_info` | "Wait duration in milliseconds" |

To confirm it for `sql_statement_completed`, run `WAITFOR DELAY '00:00:01'` against a session
filtering `WHERE duration > 500000` on that event. The statement is captured with a `duration` of
just over `1000000`, a microsecond reading for a one-second wait; a millisecond reading would be
roughly `1000`.

The failure this produces has no symptom. A predicate copied from a `wait_info` session onto a
`sql_statement_completed` session is off by a factor of 1000: it captures far more than intended,
or, more often, nothing at all.

## ACTION versus no ACTION, same event side by side

Create two sessions, both on `sqlserver.sql_statement_completed`, both targeting
`package0.ring_buffer`, and run the same kind of statement against them.

With actions, `ACTION (sqlserver.sql_text, sqlserver.username, sqlserver.client_app_name)`, the
captured XML carries, alongside the native fields:

```xml
<action name="client_app_name" package="sqlserver"><value>SQLCMD</value></action>
<action name="username" package="sqlserver"><value>sa</value></action>
<action name="sql_text" package="sqlserver"><value>SET TEXTSIZE 4096</value></action>
```

Without the `ACTION()` clause the same event shape comes back, `statement` field and all, with
**zero** `<action>` elements: no error, no warning, and an identical `eventCount`. Nothing
distinguishes them but the presence of an `<action>` element, which is why "Check it worked" counts
rows in `sys.database_event_session_actions` instead.

## blocked_process_report captures nothing

A session on `blocked_process_report` starts cleanly and captures nothing, because the threshold
that makes the event fire cannot be set. To see it, use a table with one row: one session holds an
open transaction with an `UPDATE` on that row for about 30 seconds, and a second session issues a
conflicting `UPDATE` on the same row shortly after, so it waits behind the first's lock for most of
that window. Both complete without error. Start this session before the block:

```sql
CREATE EVENT SESSION dq_xe_blocking ON DATABASE
ADD EVENT sqlserver.blocked_process_report
ADD TARGET package0.ring_buffer;
ALTER EVENT SESSION dq_xe_blocking ON DATABASE STATE = START;
```

Read back after the blocking episode finishes, the ring buffer is empty:

```xml
<RingBufferTarget truncated="0" processingTime="0" totalEventsProcessed="0" eventCount="0" droppedCount="0" memoryUsed="0"/>
```

`execution_count` for the target is also `0`, and the session is present in
`sys.dm_xe_database_sessions` throughout. The usual fix, setting the threshold, is not available:

On an Azure SQL Database **logical server** there is no `sp_configure` to call at all:

```output
EXEC sys.sp_configure N'blocked process threshold', 5;
Msg 2812, Level 16, State 62
Could not find stored procedure 'sys.sp_configure'.
```

`OBJECT_ID('sys.sp_configure')` is `NULL` there, and the unqualified name answers the same way.
A **local Azure SQL Database container** answers `Msg 2812` from a user database too, and on
current container builds from `master` as well, with `OBJECT_ID('sys.sp_configure')` `NULL`.
Where the procedure does exist, it refuses this option instead:

```output
EXEC sp_configure 'blocked process threshold';
Msg 15123
The configuration option 'blocked process threshold' does not exist, or it may be an advanced
option.
```

`Msg 40510` is a third refusal and comes from `RECONFIGURE`, not from `sp_configure`:

```output
RECONFIGURE;
Msg 40510, Level 16, State 1
Statement 'CONFIG' is not supported in this version of SQL Server.
```

They are not the same refusal, so matching only on `40510` misses the `sp_configure` one, whether
`2812` or `15123`.
`sys.database_scoped_configurations` has no row matching `%BLOCK%` or `%THRESHOLD%` on either.
Learn documents the option itself, `blocked process threshold`, for SQL Server only, and lists
40510 in the error table with exactly that message. The event is not hard to trigger here; there is
no exposed control to trigger it with.

Learn also names the supported route on Azure SQL Database, which is not an event session: the
`Blocks` resource log category, streamed through a diagnostic setting, carries
`blocked_process_filtered_s` (the blocked process report XML), `lock_mode_s`,
`resource_owner_type_s` and `duration_d` in microseconds.

## database_xml_deadlock_report: follow Learn, then verify

Learn documents a database-scoped session on `sqlserver.database_xml_deadlock_report` as the way to
collect deadlock graphs on Azure SQL Database. A local Azure SQL Database container can leave that
session empty, so verify it against a deadlock you cause before relying on it. Use two tables, each
with one row. Two sessions each update their own table, wait three seconds, then attempt to update
the other's, guaranteeing a lock-order deadlock. Start this session first:

```sql
CREATE EVENT SESSION dq_xe_deadlock ON DATABASE
ADD EVENT sqlserver.database_xml_deadlock_report
ADD TARGET package0.ring_buffer;
ALTER EVENT SESSION dq_xe_deadlock ON DATABASE STATE = START;
```

The deadlock is real: the victim receives `Msg 1205, Level 13`, naming it the deadlock victim. In a
local container the ring buffer can still read back with `eventCount="0"`. `sys.dm_xe_objects`
describes the event as "Produces a deadlock report for a victim, with information scoped to the
victim's database" with `capabilities_desc` = `sds_visible`, so the engine reports it as valid and
visible in this scope. The session creates, attaches and starts without error at every step, and
the event does not fire.

**Microsoft Learn documents this exact event as the way to collect deadlock graphs on Azure SQL
Database**, in both the ring buffer and event file forms, with `STARTUP_STATE = ON` and
`MAX_MEMORY = 4 MB`. The empty container result contradicts that, and it is a container result,
not evidence about the cloud service. Follow Learn, build the session it documents, and verify it
against a deadlock you cause on purpose before relying on it. Learn also notes that optimized
locking is always on in Azure SQL Database, which makes deadlocks less likely in the first place,
so an empty session is not by itself evidence the event is broken.

## lock_deadlock as the fallback

Same deadlock setup, a different database-scoped event:

```sql
CREATE EVENT SESSION dq_xe_deadlock2 ON DATABASE
ADD EVENT sqlserver.lock_deadlock
ADD TARGET package0.ring_buffer;
ALTER EVENT SESSION dq_xe_deadlock2 ON DATABASE STATE = START;
```

In a local container, where the documented session can stay empty, this one captures the deadlock.
The event carries `resource_type` `XACT`, `mode` `S`, `owner_type` `Transaction`, a
`transaction_id`, a `database_id` and a `deadlock_id`. It gives no deadlock graph,
only the resource, the lock mode, the owning transaction and an id grouping the participants of one
deadlock: enough to confirm a deadlock happened and roughly on what. Keep it as the fallback for
when the documented session verifies empty, not as the first choice.

## There is no system_health session to fall back on

A local Azure SQL Database container has a `system_health` session, visible from `master` through
`sys.dm_xe_sessions`, whose ring buffer captures `xml_deadlock_report` for a real deadlock. **That
is a property of the container, not of Azure SQL Database.** Learn is unambiguous, and the
`system_health` documentation page applies to SQL Server only: "There's no built-in
`system_health` Extended Event session in Azure SQL Database." There is no baseline session on the
cloud service, no `master` connection that reveals one, and no reason to look. Build the session
you need.

The one built-in session, `dl`, comes with a prohibition rather than an invitation: do not read
deadlock events from it, because `sys.fn_xe_file_target_read_file` over a large `dl` file can raise
an out-of-memory error in `master`, affecting login processing and causing an application outage.

`sys.dm_xe_database_objects` does not exist, and querying it raises `Msg 208`. Learn lists the
Extended Events DMVs common to Azure SQL Database as `sys.dm_xe_map_values`,
`sys.dm_xe_object_columns`, `sys.dm_xe_objects` and `sys.dm_xe_packages`, with no database-prefixed
variant. Event, action and target metadata comes from plain `sys.dm_xe_objects`.
