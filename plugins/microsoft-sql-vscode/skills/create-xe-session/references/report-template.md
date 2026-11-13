# Extended Events Session Report

Populate after execution and verification.

```markdown
## Extended Events Session

| Property | Value |
|---|---|
| Session | {{session name}} |
| Purpose | {{diagnostic intent}} |
| Derived from | {{template session or new}} |
| Platform | {{platform}} |
| Scope | {{ON SERVER or ON DATABASE}} |
| State | {{verified running or stopped}} |
| Events | {{validated events}} |
| Predicates | {{redacted summary}} |
| Actions | {{actions or none}} |
| Target | {{target and bounded settings}} |
| Startup state | {{ON or OFF}} |
| Expected overhead | {{low, medium, or high with reason}} |

### Sensitive Data

{{State whether SQL text, application, host, login, database, session, paths, or other sensitive
values are captured.}}

### Capture Lifecycle

- **Leave running until:** {{completion condition or bounded duration}}
- **Retrieve data with:** {{file/ring-buffer query or downstream skill}}
- **Target behavior:** {{persistent rollover or circular volatile buffer}}
- **Stop command:** {{platform-appropriate command}}
- **Remove command:** {{platform-appropriate command, requiring confirmation}}

### Verification

{{State the catalog row and actual runtime state observed after creation.}}
```

## Report Rules

- Do not report success until verification confirms the session exists.
- Distinguish `created but stopped` from `running`.
- Redact predicate values, file paths, identities, and SQL text unless authorized.
- Explain action overhead and target retention behavior.
- Provide a clear condition for when capture is complete.
