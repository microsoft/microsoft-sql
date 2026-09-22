# The event_file target: reaching blob storage, and reading it back

From Microsoft Learn's Azure SQL Database Extended Events pages and its Database Engine error
tables, checked 2026-09-03, except where a line says it was measured. The container this repository
tests against has no Azure Storage account, so **no write to a real blob and no read back from one
was exercised here.** Treat the syntax as documented, not measured, and prove it with one successful
`START` against your own storage account.

## Contents

- [Storage account settings that fail at START](#storage-account-settings-that-fail-at-start)
- [The credential name is the container URL](#the-credential-name-is-the-container-url)
- [Managed identity, the option with no expiry](#managed-identity-the-option-with-no-expiry)
- [SAS token, the option with a secret](#sas-token-the-option-with-a-secret)
- [Every error START can raise](#every-error-start-can-raise-and-what-each-one-means)
- [Reading the .xel files back](#reading-the-xel-files-back)

`event_file` is the only target that survives a session stop or a failover, and "durable" here means
an Azure Storage blob specifically. There is no local disk to fall back to: a local path is refused
at `CREATE` with `Msg 40538`.

## Storage account settings that fail at START

**Hierarchical namespace enabled**, and **an immutability policy on the container**, are both
unsupported and both surface as operating system error 13. **The storage account firewall must be
off** if you authenticate with a SAS token, which Learn states plainly is unsupported behind a
firewall. The full account requirements, including tier, region and redundancy matching, are on
[Create an event session with an event_file target in Azure Storage](https://learn.microsoft.com/azure/azure-sql/database/xevent-code-event-file);
read them there rather than from a copy that can go stale.

## The credential name is the container URL

**The database scoped credential must be named exactly the blob container URL, with no trailing
slash.** Not the session name, not the storage account name, not a friendly label. A name that does
not match the container URL is the documented first cause of operating system error 86 at `START`,
and a trailing slash on an otherwise correct name is the documented second.

```sql
-- the name is the container URL. The event_file filename then points INSIDE that container.
CREATE DATABASE SCOPED CREDENTIAL
    [https://<storage-account-name>.blob.core.windows.net/<container-name>]
WITH IDENTITY = 'MANAGED IDENTITY';
```

Creating the credential requires `CONTROL` on the database, held by `dbo`, `db_owner` and the
server administrator. Creating the *event session* afterwards does not, so an administrator can
create the credential once and a lower-privileged principal can create sessions against it later.

## Managed identity, the option with no expiry

Assign the **Storage Blob Data Contributor** role on the container to the managed identity of the
logical server: the system assigned identity if it is enabled, otherwise the user assigned identity
designated as primary. Create the credential with `WITH IDENTITY = 'MANAGED IDENTITY'` and no
secret, as above. Prefer this path for anything meant to keep running, because there is no SAS token
to expire underneath it.

## SAS token, the option with a secret

Three requirements, all exact, or `START` fails: permissions `rwdl` (`Read`, `Write`, `Delete`,
`List`, and Read plus Write alone is not enough); start and expiry times spanning the whole lifetime
of the event session; and **no IP address restrictions**.

```sql
IF NOT EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name = '##MS_DatabaseMasterKey##')
    CREATE MASTER KEY;

CREATE DATABASE SCOPED CREDENTIAL
    [https://<storage-account-name>.blob.core.windows.net/<container-name>]
WITH IDENTITY = 'SHARED ACCESS SIGNATURE',
     SECRET = '<sas-token>';
```

The master key comes first: without one, the credential create fails with `Msg 15581`, asking for a
master key in the database, measured on the container. Treat the SAS token as a password.

## Every error START can raise, and what each one means

`CREATE EVENT SESSION` with an `https://` blob target succeeds with no credential check at all. The
credential is not evaluated until `START`, which is where all of this surfaces:

| At `START` | Meaning |
|---|---|
| `Msg 25739` | No credential at all for writing session output to the blob |
| `Msg 40539` | The named Azure Storage credential was not found |
| `Msg 25602` + operating system error 86, "The specified network password is not correct" | No credential whose **name matches the container URL**, or a credential name ending in a slash |
| `Msg 25602` + operating system error 5, "Access is denied" | Managed identity missing the role assignment; or the storage firewall is on and either the `Microsoft.Sql/servers` resource instance is not granted access, or SAS token authentication is in use, which the firewall does not support |
| `Msg 25602` + operating system error 3, "The system cannot find the path specified" | The container in the URL does not exist |
| `Msg 25602` + operating system error 13, "The data is invalid" | An immutability policy on the container, or hierarchical namespace enabled on the account |
| `Msg 25738` or `Msg 25740` | The system is busy. Retry later; nothing is misconfigured |

Operating system error 86 names a Windows network error because the engine is reporting the file
system layer under the blob mount. There is no password to fix.

## Reading the .xel files back

```sql
SELECT CAST(event_data AS xml) AS event_xml, file_name, file_offset, timestamp_utc
FROM sys.fn_xe_file_target_read_file(
    'https://<storage-account-name>.blob.core.windows.net/<container-name>/capture_statements*.xel',
    NULL, NULL, NULL);
```

The wildcard matters: `event_file` rolls to a new blob once `max_file_size` is reached, and one
call reads every rollover file. The three trailing `NULL` arguments are a metadata file, a file to
resume from, and an offset; leave all three `NULL` for a full read. Reading from a database other
than the one that wrote the files needs that database to hold its own credential on the container.

**A wrong or missing filename returns zero rows, with no error of any kind**, measured on the
container. So does a read blocked by a network security perimeter, which may instead raise
`Msg 25759` or `Msg 25717`. Before concluding a capture was empty, confirm the blob itself exists
through the storage account rather than trusting a zero-row result from this function.
