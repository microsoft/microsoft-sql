# Extended Events quirks, with the measured evidence

## Contents

- [Duration units, event by event](#duration-units-event-by-event)
- [ACTION() versus no ACTION(), same event side by side](#action-versus-no-action-same-event-side-by-side)
- [The blocked_process_report zero-capture case](#the-blocked_process_report-zero-capture-case)
- [The database_xml_deadlock_report zero-capture case](#the-database_xml_deadlock_report-zero-capture-case)
- [The lock_deadlock working case](#the-lock_deadlock-working-case)
- [system_health exists, and a user database connection cannot see it](#system_health-exists-and-a-user-database-connection-cannot-see-it)

All of this was produced against a single local Azure SQL Database container engine, reporting
`EngineEdition` 5 and Edition `SQL Azure`, on 2026-08-29, working in a dedicated scratch database
created and dropped for the purpose. None of it depends on data specific to that database; every
result here is a property of the event or the platform, not of the sample rows.

## Duration units, event by event

Read directly from `sys.dm_xe_object_columns`, which carries a human-readable `description` for
every column of every event:

| Event | `duration` column description |
|---|---|
| `sql_statement_completed` | "The time (in microseconds) that it took to execute the statement." |
| `rpc_completed` | "The time (in microseconds) that the remote procedure call took to be completed." |
| `lock_acquired` | "The time (in microseconds) between when the lock was requested and when it was canceled." |
| `wait_completed` | "Wait duration in milliseconds" |
| `wait_info` | "Wait duration in milliseconds" |

Confirmed empirically for `sql_statement_completed`: a session filtering
`WHERE duration > 500000` on that event, with a `WAITFOR DELAY '00:00:01'` run against it, captured
the statement with `duration` = `1000292`. A microsecond reading for a one-second wait is
consistent with that description; a millisecond reading would have shown roughly `1000`.

The practical failure this produces: a predicate copied from a `wait_info` session onto a
`sql_statement_completed` session (or the reverse) is off by a factor of 1000, and the session gives
no signal that anything is wrong. It either captures far more than intended or, more often, nothing
at all, because a threshold meant as milliseconds reads a thousand times larger when the column is
actually microseconds.

## ACTION() versus no ACTION(), same event side by side

Two sessions, both on `sqlserver.sql_statement_completed`, both targeting `package0.ring_buffer`,
run against the same kind of statement.

**With actions:**

```sql
ADD EVENT sqlserver.sql_statement_completed(
    ACTION (sqlserver.sql_text, sqlserver.username, sqlserver.client_app_name)
)
```

captured, among the native fields:

```xml
<action name="client_app_name" package="sqlserver"><value>SQLCMD</value></action>
<action name="username" package="sqlserver"><value>sa</value></action>
<action name="sql_text" package="sqlserver"><value>SET TEXTSIZE 4096</value></action>
```

**Without actions:**

```sql
ADD EVENT sqlserver.sql_statement_completed
```

captured the same event shape, `statement` field and all, but zero `<action>` elements. There was
no error, no warning and no difference in `eventCount` between the two sessions. The only way to
tell them apart is to actually look at whether an `<action>` element is present in the captured XML.

## The blocked_process_report zero-capture case

Setup: a table with one row, one session holding an open transaction with an `UPDATE` on that row
for roughly 30 seconds, a second session issuing a conflicting `UPDATE` against the same row shortly
after the first began. Both sessions completed without either raising an error, confirming the
second genuinely waited behind the first's lock for most of that 30 seconds.

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

`execution_count` for the target, read from `sys.dm_xe_database_session_targets`, was also `0`. The
session was confirmed running (present in `sys.dm_xe_database_sessions` throughout). Attempting the
usual fix, raising or checking the blocked process threshold, fails outright:

```
EXEC sp_configure 'blocked process threshold';
Msg 40510, Level 16, State 1
Statement 'CONFIG' is not supported in this version of SQL Server.
```

and `sys.database_scoped_configurations` has no row matching `%BLOCK%` or `%THRESHOLD%` at all. The
event is not merely hard to trigger here; there is no exposed control to trigger it with.

## The database_xml_deadlock_report zero-capture case

Setup: two tables, each with one row. Two sessions each update their own table first, wait three
seconds, then attempt to update the other session's table, guaranteeing a lock-order deadlock. This
was run twice, independently.

**This section is about `database_xml_deadlock_report` specifically, a database-scoped event.** It is not the same event as `xml_deadlock_report`, the server-scoped event wired into `system_health`, which is covered separately below and which does fire. The two names differ by one word and are easy to conflate; the measurements in this section apply only to the database-scoped one.

```sql
CREATE EVENT SESSION dq_xe_deadlock ON DATABASE
ADD EVENT sqlserver.database_xml_deadlock_report
ADD TARGET package0.ring_buffer;
ALTER EVENT SESSION dq_xe_deadlock ON DATABASE STATE = START;
```

Both runs produced a real deadlock, confirmed by the victim session receiving:

```
Msg 1205, Level 13, State 72
Transaction (Process ID nn) was deadlocked on lock resources with another process and has been
chosen as the deadlock victim. Rerun the transaction.
```

Both times, the ring buffer target read back as:

```xml
<RingBufferTarget truncated="0" processingTime="0" totalEventsProcessed="0" eventCount="0" droppedCount="0" memoryUsed="0"/>
```

`sys.dm_xe_objects` describes `database_xml_deadlock_report` as
"Produces a deadlock report for a victim, with information scoped to the victim's database" with
`capabilities_desc` = `sds_visible`, meaning the engine itself reports the event as valid and
visible for a database-scoped session. It was created, attached and started without any error at
any step. It simply did not fire for either confirmed deadlock.

## The lock_deadlock working case

Same deadlock setup, this time with:

```sql
CREATE EVENT SESSION dq_xe_deadlock2 ON DATABASE
ADD EVENT sqlserver.lock_deadlock
ADD TARGET package0.ring_buffer;
ALTER EVENT SESSION dq_xe_deadlock2 ON DATABASE STATE = START;
```

captured one event on the first attempt:

```xml
<event name="lock_deadlock" package="sqlserver" timestamp="2026-08-29T08:30:03.219Z">
  <data name="resource_type"><value>16</value><text>XACT</text></data>
  <data name="mode"><value>3</value><text>S</text></data>
  <data name="owner_type"><value>1</value><text>Transaction</text></data>
  <data name="transaction_id"><value>1784825</value></data>
  <data name="database_id"><value>9</value></data>
  <data name="deadlock_id"><value>17</value></data>
  ...
</event>
```

This does not carry the full deadlock graph text that `xml_deadlock_report` gives on SQL Server; it
gives the resource, lock mode, owning transaction and a `deadlock_id` that groups the participants
of the same deadlock together. That is enough to confirm a deadlock happened, when, and roughly on
what, which is more than the zero events the richer report produced.

## system_health exists, and a user database connection cannot see it

The first version of this file concluded there was no baseline session anywhere on Azure SQL
Database, reasoning from two observations: `sys.database_event_sessions` queried against `master`
returned zero rows, and `sys.dm_xe_sessions` failed with `Msg 208`. Both observations were correctly
measured. The conclusion drawn from them was wrong, and the corrected version is a better finding
than the one it replaces.

**`sys.database_event_sessions` is the *database-scoped* catalog view.** Querying it against
`master` asks "does `master` have any database-scoped sessions of its own," which is a real question
with a real answer of zero, and an unrelated question to whether anything server-scoped is running
anywhere. **`sys.dm_xe_sessions` is the server-scoped DMV**, and it is not exposed from a connection
to a user database at all, which is a visibility boundary, not evidence of absence.

Queried correctly, from a connection to `master` itself, on the same engine:

```sql
SELECT name FROM sys.dm_xe_sessions;
```

returns three rows: `hkenginexesession`, `system_health`, `sp_server_diagnostics session`. And:

```sql
SELECT name FROM sys.server_event_sessions;
```

returns `system_health` and `AlwaysOn_health`. Joining `sys.server_event_sessions` to
`sys.server_event_session_events` for `system_health` lists roughly twenty wired-in events,
including `xml_deadlock_report`, `wait_info`, `error_reported`, `connectivity_ring_buffer_recorded`
and `process_killed` among others: this is the same kind of always-on diagnostic baseline
`system_health` provides on SQL Server, running here too.

Reading its ring buffer from `master`, after two real deadlocks had already been produced against a
user database elsewhere in this testing (each confirmed by the victim receiving `Msg 1205`):

```sql
SELECT CAST(t.target_data AS xml) AS target_xml
FROM sys.dm_xe_session_targets AS t
JOIN sys.dm_xe_sessions AS s ON s.address = t.event_session_address
WHERE s.name = 'system_health' AND t.target_name = 'ring_buffer';
```

returned a ring buffer containing multiple `xml_deadlock_report` events, captured with no session
built for the purpose at all.

Now the contrast, run from a connection to a user database, same login:

```sql
SELECT COUNT(*) FROM sys.dm_xe_sessions;
-- Msg 208, Invalid object name 'sys.dm_xe_sessions'

SELECT COUNT(*) FROM sys.database_event_sessions;
-- 0 rows, correctly: no database-scoped session had been created in that database
```

Both failures are real. Neither one means `system_health` is not running. The variable that decides
whether it is visible is which database the connection was made to, not a missing permission and not
an absent session. In the cloud service, `master` is administrative and most application identities
are never connected to it at all; whether the identity you are using here can reach `master` is worth
confirming before relying on this path, since it was tested here with an administrative login.

Also confirmed, from both `master` and a user database: `sys.dm_xe_database_objects` does not exist.
`Msg 208, Invalid object name 'sys.dm_xe_database_objects'` is raised either way. There is no
database-scoped counterpart to `sys.dm_xe_objects`; event, action and target metadata is read from
the one `sys.dm_xe_objects` view, in whichever scope the connection happens to be in.
