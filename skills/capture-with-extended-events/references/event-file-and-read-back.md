# The event_file target: reaching blob storage, and reading it back

## Contents

- [What was measured here and what was not](#what-was-measured-here-and-what-was-not)
- [Why event_file exists at all next to the ring buffer](#why-event_file-exists-at-all-next-to-the-ring-buffer)
- [The credential path](#the-credential-path)
- [The managed identity path](#the-managed-identity-path)
- [Reading the .xel files back](#reading-the-xel-files-back)
- [The read-back failure mode](#the-read-back-failure-mode)

## What was measured here and what was not

Measured, against the local container: a local filesystem path is rejected at `CREATE` time; a
syntactically valid `https://` blob URL is accepted at `CREATE` time regardless of whether anything
real exists at that address; and starting a session with no working credential against that URL
fails with an operating-system-flavoured error rather than a storage-specific one. Those three facts
are in the main SKILL.md body and are not repeated here.

**Not measured**: an actual successful write of a `.xel` file to a real Azure Storage account, and
an actual successful read of that file back with a working credential. Both need a real storage
account and a real SAS token or managed identity role assignment, which the local container does
not have. The syntax below is written the way Microsoft Learn documents it and follows the same
credential mechanism this repository's other skills already use for blob access, but treat it as
unverified until you have run it once against your own storage account.

## Why event_file exists at all next to the ring buffer

The ring buffer target is in-memory, fixed size, and gone the moment the session stops or the
memory wraps. `event_file` is the only target on Azure SQL Database that survives a session restart
or a long capture window, because it is the only target that writes somewhere durable. The cost is
that "somewhere durable" is Azure Blob Storage specifically: there is no local disk to write to, the
container running the engine is not addressable as a filesystem path from T-SQL, and the local path
rejection in the main body is not a bug to work around, it is the actual boundary.

## The credential path

A database scoped credential needs a master key first. Without one:

```
Msg 15581, Level 16, State 6
Please create a master key in the database or open the master key in the session before performing
this operation.
```

confirmed by attempting the credential create with no master key present. Once a master key exists,
the credential is created with a shared access signature scoped to at least read, write and list on
the target blob container:

```sql
CREATE MASTER KEY ENCRYPTION BY PASSWORD = 'a strong, generated passphrase, not one reused elsewhere';

CREATE DATABASE SCOPED CREDENTIAL xe_capture_credential
WITH IDENTITY = 'SHARED ACCESS SIGNATURE',
     SECRET = 'the SAS token string, without a leading question mark';
```

The credential's name has no fixed relationship to the storage account or container name; what ties
it to a specific blob URL is that `event_file`'s `filename` points inside the container the SAS was
issued for. A credential scoped to the wrong container produces the same `Msg 25602` / OS error 86
failure at `START` as having no credential at all, because from the engine's point of view both are
"cannot open this path."

## The managed identity path

The alternative to a SAS token is granting the server's identity `Storage Blob Data Contributor` on
the storage account (or narrower, on the specific container) through Azure role-based access
control, and then creating the credential with `IDENTITY = 'Managed Identity'` instead of a SAS
secret. This removes the SAS token's expiry as an operational concern, at the cost of the role
assignment being an Azure-level change rather than a database-level one. Neither path was exercised
here; choose the SAS token for a quick, time-boxed capture, and the managed identity for something
you intend to leave running.

## Reading the .xel files back

`sys.fn_xe_file_target_read_file` reads one or more `.xel` files and returns each event as raw
`event_data` XML, one row per event, in the same shape a ring buffer read produces:

```sql
SELECT
    CAST(event_data AS xml) AS event_xml,
    file_name,
    file_offset,
    timestamp_utc
FROM sys.fn_xe_file_target_read_file(
    'https://youraccount.blob.core.windows.net/xevents/capture_statements*.xel',
    NULL, NULL, NULL
);
```

The first parameter accepts a wildcard so a single call can read every rollover file a session
produced, which matters because `event_file` rolls to a new file once the configured `max_file_size`
is reached. The three trailing `NULL` parameters are for a metadata file (not used by
`event_file` targets on Azure SQL Database), an initial file to resume from, and an initial offset;
leave all three `NULL` for a plain full read.

## The read-back failure mode

Confirmed locally, without a real blob file to read: calling
`sys.fn_xe_file_target_read_file` with a filename that does not exist returns **zero rows**, with no
error of any kind. This matters because it means a typo in the blob URL, a wrong container name, or
reading before the file has actually been written all look identical to "the session captured
nothing." Before concluding a capture was empty, confirm the file itself exists (through the storage
account, not through this function) rather than trusting a zero-row result from the read function
alone.
