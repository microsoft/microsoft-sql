# Top Blocker Remediation Sources

Use this reference only when the user requests remediation guidance for a listed top blocker.

## Target Catalogs

| Query 3 target | Microsoft Learn rule catalog |
|---|---|
| `AzureSqlDatabase` | `https://learn.microsoft.com/en-us/data-migration/sql-server/database/assessment-rules?view=azuresql` |
| `AzureSqlManagedInstance` | `https://learn.microsoft.com/en-us/data-migration/sql-server/managed-instance/assessment-rules?view=azuresql` |

There is no corresponding compatibility-rule catalog for
`AzureSqlVirtualMachine`.


## Mapping Procedure

1. For SQL DB or SQL MI, use the blocker target to select the catalog. Never use the SQL DB catalog for an SQL MI blocker or vica versa.
2. Fetch the current Microsoft Learn page.
3. Find an exact case-insensitive match between Query 3 `FeatureId` and the **Rule Title** in the page's **Rules summary** table.
4. Locate the detailed section for that matched rule.
5. Extract only:
   - **Description**
   - **Recommendation**
   - **More information** links, when present
6. Include the Microsoft Learn catalog URL as the source.


## Output

```text
REMEDIATION GUIDANCE — <FeatureId> (<SQL DB | SQL MI>)

Description: <published description>
Recommendation: <published recommendation>
Source: <Microsoft Learn catalog URL or Query 3 MoreInformation URL>
```

If the exact `FeatureId` is absent from the selected catalog, say:

```text
No exact published rule match was found for <FeatureId> on <target>.
```

Never use a similarly named rule, another target's recommendation, or general model knowledge as a fallback.
