-- Copyright (c) Microsoft Corporation.
-- Licensed under the MIT license.

SET NOCOUNT ON;
DECLARE @requested nvarchar(max) = CONVERT(
  nvarchar(max),
  CAST(N'' AS xml).value(
    'xs:base64Binary("{{DATABASE_NAMES_BASE64}}")',
    'varbinary(max)'
  )
);
PRINT '__BACPAC_PREFLIGHT_JSON_BEGIN__';
SELECT (
  SELECT
    CONVERT(bit, HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW ANY DATABASE'))
      AS canViewAllDatabases,
    JSON_QUERY((
      SELECT name
      FROM sys.databases
      WHERE name IN (
        SELECT CONVERT(sysname, [value]) FROM OPENJSON(@requested)
      )
      ORDER BY name
      FOR JSON PATH
    )) AS existingDatabases
  FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
);
PRINT '__BACPAC_PREFLIGHT_JSON_END__';
