---
name: sqlpackage-import-export
description: >-
  Chooses the right SqlPackage action, Extract, Publish, Export or Import, to move a whole
  Azure SQL Database as a portable file, and states what each one carries. Extract and Publish
  move schema only by default; Export and Import always move schema plus every table row data;
  the file extension alone does not prove which, since Extract can be told to fold data into a
  dacpac too. Explains why Azure SQL Database has no BACKUP or RESTORE T-SQL and neither file is
  a backup mechanism, and why Import refuses a target holding any object (SQL71659) while Publish
  diffs and reruns safely. Use when asked to export a database to a bacpac, clone a database
  between servers, extract or publish a dacpac outside a SQL project, explain dacpac versus
  bacpac, or diagnose a failed sqlpackage export or import. Does not cover building a dacpac from
  a SQL project or its CI pipeline (sql-database-projects), point-in-time or geo-restore
  (restore-and-recover), or loading rows into an existing table (bulk-load-and-bulk-copy).
---

# Move a whole database with SqlPackage: dacpac and bacpac

**This owns the four-verb decision for moving an entire existing database as a portable file.**
It does not own building a dacpac from a source-controlled SQL project or shipping it through CI,
which is `sql-database-projects`; it does not own Azure SQL Database's own automated backups or
point-in-time and geo-restore, which is `restore-and-recover`; and it does not own loading rows
into a table that already exists, which is `bulk-load-and-bulk-copy`.

Verified on 2026-08-29 against SqlPackage 170.4.83.3, running every action below against a live
engine reporting `EngineEdition` 5, Edition `SQL Azure`, `12.0.2000.8` (the Azure SQL Database
container). The SQL71627 unsupported-element failure and its causes are sourced from Microsoft
Learn and Microsoft support documentation rather than reproduced live, because the container's
permission model accepted a login-mapped user that a real Azure SQL Database logical server
rejects at export time; that gap is called out again below, at the point it matters.

## The fact that the name of the file does not tell you

**Dacpac and bacpac are not "the schema one" and "the data one." The action that produced the
file is what decided that, and one property can override the default.**

| Action | Direction | Default contents | Extension |
|---|---|---|---|
| Extract | live database to file | schema only | `.dacpac` |
| Publish | file to live database | schema only | reads `.dacpac` |
| Export | live database to file | schema and every table's row data | `.bacpac` |
| Import | file to live database | schema and every table's row data | reads `.bacpac` |

Measured: extracting a database with one table (three rows) and one view produced a `.dacpac`
containing exactly `model.xml`, `DacMetadata.xml`, `Origin.xml` and `[Content_Types].xml`, no data
of any kind. Exporting the same database produced a `.bacpac` with those same schema entries plus
`Data/dbo.Widget/TableData-000-00000.BCP`, one entry per base table holding rows. The view carried
no data entry, because a view has no rows of its own to snapshot.

**Then measured again with one property changed.** Running Extract with
`/p:ExtractAllTableData=true` produced a file still named `.dacpac`, still an Extract, and it now
contained `Data/dbo.Widget/TableData-000-00000.BCP` too. Do not infer what is inside a file from
its extension or from which command produced it without reading the property list. Report what
you can see inside the file, not what the name implies.

## There is no BACKUP or RESTORE T-SQL, and a bacpac is not a backup

Measured: `BACKUP DATABASE dq_sqlpackage TO DISK='/tmp/x.bak'` against the engine returns
`Msg 40510, Level 16, State 1 ... 'BACKUP DATABASE' is not supported in this version of SQL
Server`. That is why a bacpac export gets reached for as a substitute. It is not one. Azure SQL
Database already runs automated backups and offers point-in-time and geo-restore with defined
recovery objectives; a bacpac or dacpac is a portable snapshot with none of that, no retention
policy, no restore SLA, and no guarantee it even succeeds against a database large or busy enough
to matter. Route a recovery question to `restore-and-recover`. Use this skill's actions to move a
database between environments, subscriptions, servers, or in and out of the container, not to
satisfy a recovery point objective.

## Import refuses; Publish reruns

Measured against the same target database twice.

**Import**, pointed at a target that already held the objects from a previous import, returned
immediately with no changes attempted:

```text
*** Error importing database: Data cannot be imported into target because it contains one or more
user objects. Import should be performed against a new, empty database.
Error SQL71659: Data cannot be imported into target because it contains one or more user objects.
```

**Publish**, pointed at a target it had already published to, with no source changes since, ran
its full plan-and-apply cycle and reported `Update complete` with nothing to change. Publish also
created the target database outright when it did not exist yet, with no separate provisioning
step: `Creating database dq_from_dacpac...` appeared in its own output before the first object was
created. Do not assume a database has to exist before a Publish; it does have to exist before an
Import, which never creates one.

This asymmetry is the one that costs a rerun after a partial failure. Import is a one-shot
operation into a database with nothing in it yet: retry it against the same target name and it
refuses, every time, until the target is dropped and recreated or a new name is chosen. Publish is
a diffing operation and is the one safe to run again.

## A vector index makes the import fail, and the export looks fine

**Check for vector indexes before you plan anything around a bacpac.**

```sql
SELECT OBJECT_NAME(object_id) AS table_name, name
FROM sys.indexes WHERE type_desc = 'VECTOR';
```

The import creates schema objects before it loads data, so a vector index is
created against an empty table. Vector indexes require at least 100 rows with
non-null vectors, measured 2026-08-31 against `12.0.2000.8`: 99 rows is refused
with `Msg 42266` and 100 succeeds. The index cannot be created, and the import
fails.

**The export succeeds.** Nothing warns at export time. The failure lands later,
on the import, on the machine that was counting on it, which is the worst place
to discover a migration will not work.

The documented workaround is to drop the vector indexes before exporting and
recreate them after importing. Recreating needs the data loaded first, so the
order is: drop, export, import, load, recreate.

Note also that `TRUNCATE TABLE` is refused while a vector index exists
(`Msg 42232`), so a reload-in-place plan has the same problem one step earlier.

`azuresql-db-rag` and `vector-search-azure-sql` own vector indexes themselves.
This skill owns the fact that one silently breaks a bacpac round trip.

## Deciding which of the four to run

1. **Decide whether the row data has to move, not just the schema.** If the destination only
   needs the object definitions, an Extract and Publish round trip is smaller, faster, and (unlike
   Import) safe to repeat against a target that already exists.
2. **If data has to move, use Export and Import, and provision the target as new and empty
   first.** Import will not accept anything else. Do not pre-create tables in the target expecting
   Import to fill them.
3. **Before an Export or Extract from a database with any history, scan it for the objects that
   fail SQL71627.** Documented, not reproduced live here: users or logins carrying
   `AuthenticationType` set to Windows authentication (commonly inherited logins such as
   `NT AUTHORITY\SYSTEM`), and permissions left over from an inherited Service Broker or query
   notification use, most often a `RECEIVE` grant on `QueryNotificationErrorsQueue`. Both are
   schema-model elements Azure SQL Database has never supported, and SqlPackage reports them only
   after schema extraction has already completed, discarding the whole file rather than the one
   offending object. `references/preflight-and-sql71627.md` has the queries to find them ahead of
   time and the exact remediation for each.
4. **Run `/Action:DeployReport` or `/Action:Script` before a Publish against a target that already
   has data you care about.** Both write a file and change nothing in the database; read the plan
   before applying it. This is the same guidance `sql-database-projects` gives for a project-built
   dacpac, and it applies just as much to one extracted from a live database.
5. **After an Import or Publish, verify row counts and object counts in the target rather than
   trusting the exit code alone.** A `0` exit code says the action SqlPackage attempted completed;
   it does not say the row count matches, particularly after a retried Import against a
   half-populated target that had to be dropped and recreated first.

## Validation rules

- Whether the row data needs to move was decided before choosing between the dacpac pair and the
  bacpac pair, and the choice is stated, not implied by which file extension got used.
- A source database with any operating history was scanned for Windows-authenticated logins,
  server-login-mapped users and Service Broker permissions before an Export or Extract was run
  against it, or the scan was explicitly skipped with a reason.
- Import was pointed at a target confirmed new and empty, never at a target being reused from a
  previous attempt without first dropping and recreating it.
- A Publish against a target holding data was preceded by `/Action:DeployReport` or
  `/Action:Script`, and the plan was read before the publish ran.
- No claim that a bacpac or dacpac export satisfies a backup or recovery requirement went
  unchallenged; that requirement is routed to `restore-and-recover`.
- Row and object counts in the target were checked after the action, not inferred from a `0` exit
  code.

## Do not

- Do not infer a file's contents from its extension. `.dacpac` is the default for Extract and
  Publish, not a guarantee; `ExtractAllTableData` puts row data in a file still named `.dacpac`.
- Do not present an Export or a Publish as a backup. Neither carries a retention policy or a
  restore SLA, and Azure SQL Database already runs automated backups that do.
- Do not retry a failed Import against the same target name without dropping and recreating it, or
  choosing a new name. It will refuse again with SQL71659 every time.
- Do not run an Export or Extract against a database with real operating history without scanning
  for Windows-authenticated users, login-mapped users and Service Broker permissions first. The
  failure lands after extraction, not before it, and it discards the whole file.
- Do not treat `BlockOnPossibleDataLoss`, the refactorlog, or pre and post deployment scripts as
  this skill's territory when the dacpac came from a tracked SQL project. That mechanics belongs
  to `sql-database-projects`; read it when the source of the dacpac is a project rather than a
  live database.
- Do not assume the target database must exist before a Publish. It does not; SqlPackage creates
  it. An Import target, by contrast, must exist and must be empty.

## References

- [references/measured-behaviour.md](references/measured-behaviour.md): every command run for
  this skill, the exact output, the file listings inside each dacpac and bacpac, and the exit
  codes. Read it to reproduce a claim above or to see the full transcript behind a shortened one.
- [references/preflight-and-sql71627.md](references/preflight-and-sql71627.md): the queries that
  find Windows-authenticated logins, login-mapped users and leftover Service Broker permissions
  before an export runs into them, sourced from Microsoft Learn and Microsoft support content
  rather than measured against this container.
- [SqlPackage Export](https://learn.microsoft.com/en-us/sql/tools/sqlpackage/sqlpackage-export),
  [SqlPackage Import](https://learn.microsoft.com/en-us/sql/tools/sqlpackage/sqlpackage-import),
  [SqlPackage Extract](https://learn.microsoft.com/en-us/sql/tools/sqlpackage/sqlpackage-extract),
  and [SqlPackage Publish](https://learn.microsoft.com/en-us/sql/tools/sqlpackage/sqlpackage-publish):
  the full property reference for each action. Read the property list before assuming a default.
