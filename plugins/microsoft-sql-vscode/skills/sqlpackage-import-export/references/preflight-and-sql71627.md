# The pre-flight scan for SQL71627, sourced from documentation

This file is sourced from Microsoft Learn, Microsoft support content and the SqlPackage issue
tracker, not reproduced against a live engine. The container used to verify the rest of this
skill accepted a Windows-style login-mapped user without complaint, because its permission model
is looser than a real Azure SQL Database logical server on this specific point; the failure below
is real and documented, but it was not observed running locally. Treat the queries as a starting
point, and treat a clean scan on the container as inconclusive rather than as proof the same
export will succeed against a real Azure SQL Database.

## What SQL71627 means

`sqlpackage /Action:Export` and `/Action:Extract` build a schema model of the source database
before writing anything, then validate that model against the target platform. SQL71627 is that
validation failing: an element in the model has a property set to a value Azure SQL Database has
never supported. The message names the element and the property, but the failure surfaces only
after the full schema model has already been built, and the whole export is discarded, not just
the offending object.

## The two most common causes

**Windows-authenticated users and logins.** A user or login created `FOR LOGIN` against a Windows
principal, or one whose `AuthenticationType` or `IsMappedToWindowsLogin` property is set, has no
equivalent in Azure SQL Database, which supports only SQL authentication and Microsoft Entra
authentication. Accounts such as `NT AUTHORITY\SYSTEM` or `NT AUTHORITY\NETWORK SERVICE`, left
over from an inherited source or a migrated instance, are the usual carriers.

Find them before exporting:

```sql
SELECT dp.name AS principal_name, dp.type_desc, sp.name AS login_name
FROM sys.database_principals AS dp
LEFT JOIN sys.server_principals AS sp ON dp.sid = sp.sid
WHERE dp.type IN ('U', 'G')          -- Windows user or group principals
   OR sp.type IN ('U', 'G');
```

Remediation: drop the user, or recreate it as a contained database user (`CREATE USER ... WITH
PASSWORD = ...` or a Microsoft Entra principal) before exporting again.

**Leftover Service Broker and query notification permissions.** A database that once used SQL
Server query notification or Service Broker outside Azure SQL Database can carry a `RECEIVE` grant on
`QueryNotificationErrorsQueue` or another Service Broker object. Azure SQL Database's Service
Broker support does not include that surface, and the permission alone is enough to fail the
model.

Find them before exporting:

```sql
SELECT grantee_principal_id, permission_name, class_desc, major_id
FROM sys.database_permissions
WHERE permission_name IN ('RECEIVE', 'SEND')
   OR major_id IN (
       SELECT object_id FROM sys.objects WHERE name = 'QueryNotificationErrorsQueue'
   );
```

Remediation: revoke the permission (`REVOKE RECEIVE ON QueryNotificationErrorsQueue FROM
<principal>;`) before exporting again.

## Reading the error when it happens anyway

The message names the element type and the unsupported property directly, for example:

```text
Error SQL71627: The element User has property AuthenticationType set to a value that is not
supported in Microsoft Azure SQL Database v12.
```

Search the model for that element type and fix it, rather than re-running the export unchanged
and hoping it was transient. It is not transient; the object is still there.

## Sources

- [Error SQL71627 exporting BACPAC file in Azure SQL Database](https://techcommunity.microsoft.com/blog/azuredbsupport/error-sql71627-exporting-bacpac-file-in-azure-sql-database/4266029), Microsoft Tech Community.
- [SqlPackage Export](https://learn.microsoft.com/en-us/sql/tools/sqlpackage/sqlpackage-export) and [SqlPackage Extract](https://learn.microsoft.com/en-us/sql/tools/sqlpackage/sqlpackage-extract), Microsoft Learn, for the full property and permission reference.
