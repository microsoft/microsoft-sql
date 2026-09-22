# Local SQL Server Connection

## How to Collect Connection Info

Three mutually exclusive paths:

1. **Connection string** — user provides a connection string (or a reference to one) → use as-is
2. **Config file** — user provides a config file path → use `--config-file-path`
3. **Server + auth mode** — user gives a server name → ask which auth mode → collect only what that mode needs

## Open-Ended Prompt (ask only for what's missing)

Don't use a fixed script. Ask the connection question using the self-contained **Question text** below — it already embeds the security guidance, so do NOT separately append the *⚠️ Security* block on top of it (that block below is the canonical reference for follow-ups and other password moments — don't duplicate it into this initial ask twice).

> 🚫 **HARD RULE — pass exactly ONE explicit picker choice if no credentials exist in context: `Windows Authentication (Integrated Security)` (pre-selected default). The picker UI AUTOMATICALLY appends a free-text field — do NOT add an "Enter custom answer" / "Custom" / "Other" choice yourself, or it appears twice (a dead "Enter custom answer" row PLUS the real text box).**
>
> Rendered picker must be exactly:
> 1. `Windows Authentication (Integrated Security) Default`  ← the ONLY choice you pass, pre-selected default
> 2. *(free-text field — added automatically by the UI; you do NOT pass this)*
>
> **NEVER add a selectable row for SQL Login, Microsoft Entra, connection string, config file path, "Enter custom answer", or any variant.** Those are typed into the auto-added field.
>
> ✅ **Concrete example — the `choices` array MUST contain EXACTLY ONE string:**
> ```
> ask_user(
>   question: "How do you connect to {server}? ...",
>   choices:  ["Windows Authentication (Integrated Security)"]   ← exactly one element, nothing else
> )
> ```
> The UI renders that single pre-selected row PLUS a free-text field. SQL login, Entra, connection string, and config file path are **typed into that field** — they are NEVER extra `choices` entries. If your `choices` array has more than one element, you did it wrong.

**Question text (self-contained — put ALL of this in the single picker question so the user sees every option, including the 4 secure password options, upfront):**

> How do you connect to **{server}**? Select **Windows Authentication (Integrated Security)** below to use the current Windows user (no password). To use anything else, **type it into the free-text field** shown beneath the choice — for example a **SQL login** (include the username, plus the password via a secure option — never plaintext), **Microsoft Entra / Azure AD**, a full **connection string**, or a **config file path**.
>
> *(Then include the **⚠️ Security 4-option block** below — the four secure password options — as part of this same question, verbatim.)*

Rules:
- **Pass exactly ONE picker choice: `Windows Authentication` (pre-selected default). The UI adds the free-text field itself — never add your own custom/other option.**
- **The picker question must be self-contained:** the typeable options above **plus** the *⚠️ Security* 4-option block (below), so the user sees everything in one prompt. Do NOT re-type the 4 options anywhere else — that block is the single source.
- **Windows Authentication is the pre-selected default** — submitting without typing selects Windows / Integrated (current Windows user, no password).
- **If the user chooses SQL login** but omitted the username or password, ask
  only for the missing value.
- If the user's reply already includes everything needed, proceed — don't re-ask.
- Do not ask for details already present in context.

---

## ⚠️ Security: Warn Before a Password Is Typed — but Never Refuse to Proceed

**This is a warning to show up front, not a hard block.** When a password could be involved (SQL Login or a connection string containing `Password=...`), **recommend** one of the secure options below *before* the user answers, so they can avoid typing a plaintext password into chat.

**Whenever you ask for or discuss connection details where a password could be involved, include this warning, in full, as its own visually distinct block — not merged into other text, not paraphrased down:**

```
⚠️ Security: If a password is involved (SQL Login or a connection string with a password), don't type it directly here. Instead use one of:
1. Config file path — password stays in the file, never enters chat
2. Connection string with password masked — e.g. Server=X;User Id=sa;Password=<masked>;... then tell me where the real password lives (Key Vault)
3. Key Vault — just give me the vault name + secret name
4. Windows Credential Manager (Windows only) — just give me the credential target name
```

Omit it only when auth type is already confirmed as Windows/Integrated or Entra default (no password possible).

If the user types a plaintext password anyway, warn once that it is now in chat
history, use it for the requested operation, and do not ask for a different
credential source. Do not repeat the password in the assistant response.

### Details for each option

**Option 1 — Config file**
```
📁 Config file: provide a path like C:\config\assessment.json
   (password stays in the file, never typed here)
```
If the user wants to create one, ALWAYS show this format:
```json
{
    "action": "Assess",
    "outputFolder": "C:\\Output",
    "overwrite": "True",
    "sqlConnectionStrings": [
        "Data Source=YOUR_SERVER;Initial Catalog=master;User Id=sa;Password=<YOUR_PASSWORD_HERE>;TrustServerCertificate=True;Encrypt=True;"
    ]
}
```
Tell the user: *"Save this as a `.json` file anywhere on disk, fill in your server and password, then give me the file path."*

**Option 2 — Connection string with masked password**
Share the string with `****` in place of the password:
```
🔗 Connection string: Server=SQLAGVM15;User Id=sa;Password=<masked>;TrustServerCertificate=True;
   Then tell me where the real password is stored (Key Vault vault name + secret name)
```

**Option 3 — Key Vault reference**
```
🔐 Key Vault: vault name = my-vault, secret name = sql-password
   (resolved at execution time, AI never sees the actual password)
```

**Key Vault setup (one-time, user runs outside chat):**
```bash
az keyvault secret set --vault-name <vault> --name <secret-name> --value "the-actual-password"
```

**Option 4 — Windows Credential Manager (Windows only)**
```
🔒 Windows Credential Manager: just give me the credential target name (e.g. SQLMigration_TargetServer)
   (resolved locally at execution time, AI never sees the actual password)
```

**Setup (one-time, user runs outside chat) — either method:**

*GUI:*
1. Open **Control Panel → Credential Manager → Windows Credentials**
2. Click **Add a generic credential**
3. **Internet or network address:** a target name of your choice, e.g. `SQLMigration_TargetServer`
4. **User name:** the SQL login username
5. **Password:** the actual password
6. Click **OK**

*PowerShell (requires the `CredentialManager` module):*
```powershell
Install-Module CredentialManager -Scope CurrentUser -Force
New-StoredCredential -Target "SQLMigration_TargetServer" -UserName "sa" -Password "the-actual-password" -Persist LocalMachine
```

**At runtime, resolved inline via PowerShell — AI only ever sees the target name, never the retrieved value:**

First, check whether the `CredentialManager` module is available. If not, install it yourself — this is a one-time, non-sensitive step (no elevation needed, nothing secret involved) and does not require asking the user to run it manually:
```powershell
if (-not (Get-Module -ListAvailable -Name CredentialManager)) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
    Install-Module CredentialManager -Scope CurrentUser -Force -AllowClobber -SkipPublisherCheck -ErrorAction Stop
}
```
Then resolve the credential and build the connection string locally:
```powershell
$cred = Get-StoredCredential -Target "SQLMigration_TargetServer"
$plainPassword = $cred.GetNetworkCredential().Password
$connectionString = "Server={server};Initial Catalog=master;User Id=$($cred.UserName);Password=$plainPassword;TrustServerCertificate=True;Encrypt=True;"
```
### If user types a plaintext password in chat:
- **Do NOT refuse to proceed** — the user has made their choice. Use it to complete the task.
- Warn them (briefly, once): "⚠️ This password is now in chat history. I'd recommend rotating it after this session."
- Do NOT echo the password back in your response or repeat it unnecessarily.
- In any command output shown to the user, mask it: `Password=<masked>`.
- Proceed with the assessment using the provided credentials.

## Build Connection String

| Auth mode | Connection string |
|---|---|
| Windows / Integrated | `Server={server};Initial Catalog=master;Integrated Security=True;TrustServerCertificate=True;Encrypt=True;` |
| SQL Server login (Key Vault) | Resolve the secret locally, then build the SQL login connection string |
| SQL Server login (Windows Credential Manager) | Build via the PowerShell pattern in Option 4 above — password substituted from `Get-StoredCredential`, never inlined literally |
| Microsoft Entra | `Server={server};Initial Catalog=master;Authentication=Active Directory Default;TrustServerCertificate=True;Encrypt=True;` |

- `TrustServerCertificate=True` is included because local/on-prem servers commonly use self-signed certificates. Without it, connections fail. For production or network-exposed servers with valid certificates, set `TrustServerCertificate=False`.
- `Encrypt=True` is always on — do not disable encryption.
- Use user-specified values for `TrustServerCertificate` and `Encrypt` if they explicitly provide them.
- Named instance: `Server=SQLAGVM15\INST01`
- Custom port: `Server=SQLAGVM15,1444`

Return the completed `$connectionString` to the invoking skill.

---

## Config File Path

If the user provides a config file path, use it directly — no connection string needed:
```bash
az datamigration get-assessment --config-file-path "{path}"
```

If the user wants to **create** a config file, share the format shown in Option 1 of the Security section above.

| Field | Required | Description |
|---|---|---|
| `action` | ✅ Yes | Must be `"Assess"` |
| `sqlConnectionStrings` | ✅ Yes | Array of connection strings (supports multiple servers) |
| `outputFolder` | No | Where to save report (defaults to OS-specific path) |
| `overwrite` | No | `"True"` to overwrite existing reports |

---

## Error Handling

| Error | What to do |
|---|---|
| Connection failed (server not found) | Ask to verify server name/IP and network access |
| Login failed | Ask to re-check username, and that the Key Vault secret / Credential Manager entry / config file has the correct password |
| Certificate error | Ask about `TrustServerCertificate`/`Encrypt` values |
| Timeout | Suggest checking firewall rules, port 1433, SQL Browser service |
| Entra auth failed | Suggest running `az login` first |
| Key Vault access denied | Ask user to verify `az login` identity has access-policy/RBAC permission on the vault |
| Credential Manager target not found | Ask user to verify the target name matches exactly what they stored (case-sensitive) |
