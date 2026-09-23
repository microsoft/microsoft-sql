---
name: run-migration-assessment
description: "Route generic or unresolved SQL Server assessment, readiness, compatibility, cost, and SKU recommendation requests. Use for bare server names or whenever Azure versus local/on-premises is not explicit; ask which source applies, then delegate."
allowed-tools: Grep View
---

# Run Migration Assessment

These claims were checked on 2026-09-15 against the bundled `skill-contract.yml` and the routing
contracts for Azure, local readiness, and local SKU sizing.

## When to Use

Use as the entry point for migration assessment requests when Azure versus Local,
or readiness versus SKU, still needs to be determined.

## Workflow

### Step 1: Identify the Server

Reuse known inputs. Determine only whether the source is Azure or Local:

- Azure identifiers or an Azure SQL Server resource URI -> Azure.
- IP, connection string, config file, or explicit on-premises/local wording ->
  Local.
- Bare server or instance name -> ask:
  **"Is `{serverName}` a Local/on-premises SQL Server or an Azure
  SQL Server?"**

Wait for the answer when the path is ambiguous. Do not resolve Azure resources,
check Local prerequisites, request credentials, select output folders, inspect
existing results, or run commands in this skill.

### Step 2: Route Azure

Delegate to `evaluate-azure-migration-assessment` with all known context and the
user's original intent. That skill owns resource resolution, existing-result
handling, fresh execution, and output.

### Step 3: Route Local

- Readiness or general assessment request -> delegate to
  `evaluate-offline-migration-readiness`.
- Explicit performance collection or SKU-sizing request -> delegate to
  `recommend-sku-sizing`.

Pass all known context and the user's original intent. The delegated skill owns
host checks, prerequisites, connection details, output-folder selection,
existing-result handling, execution, and output.

## Check it worked

- **Positive verification:** Confirm exactly one owning skill was selected from the known source
  type and intent, and that all existing context was passed to it unchanged.
- **Cleanup verification:** Confirm this router created no credentials, temporary files, resources,
  or command executions before delegation.

## Notes

- Ask only whether the source is Azure or Local when that choice is ambiguous.
- Do not duplicate delegated-skill prerequisites or workflows here.
- Delegated skills own commands, errors, follow-up choices, and output
  formatting.

## Error Handling

- Cannot determine Azure versus Local -> ask the user to select Azure or Local.
- Missing details after routing -> let the delegated skill request them.
