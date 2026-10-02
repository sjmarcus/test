# Secret registry

Metadata about which Key Vault secrets are distributed where. **Secret values never go in it** — they stay in Key Vault and are referenced by name.

Stored in Cosmos DB (serverless, Entra-only auth). Read and written only through the registry API in `secret_distributor/` — nothing else touches Cosmos directly.

## Containers

Both are partitioned on `/id`, and `id` is the **Key Vault secret name**, so an Event Grid event resolves with a point read.

| Container | Written by | Holds |
|---|---|---|
| `registry` | People, via the API | Targets, owner, enabled flag |
| `state` | The distributor only | What was last pushed, per target |

They are split by writer so a human edit and a function write-back can never overwrite each other's fields. `state` is read-only through the API.

## Entry shape

```json
{
  "id": "S-EITAAS-ARCYBER",
  "displayName": "S-EITAAS-ARCYBER",
  "owner": "platform-team@example.com",
  "subscriptionId": "4b559122-b31e-47c9-809c-92ef795cb9cc",
  "clientId": "cae6d868-0b8e-4b45-b1be-881b527af014",
  "enabled": true,
  "targets": [
    { "type": "github-environment", "repo": "arcyber",  "environment": "S-EITAAS-ARCYBER", "secretName": "AZURE_CLIENT_SECRET" },
    { "type": "github-environment", "repo": "cas-rbac", "environment": "S-EITAAS-AAD",     "secretName": "AZURE_CLIENT_SECRET" },
    { "type": "github-actions",     "repo": "org/other", "secretName": "ADMIN_PW", "tokenSecret": "github-pat-team-b" }
  ]
}
```

This replaces the original team/repo JSON (`Repos[].Name` / `EnvironmentName`, `SubscriptionID`, `ClientID`). The environment sits on each **target**, not the entry, because one repo can use different environments under different entries (`cas-rbac` uses `S-EITAAS-AAD`).

- **Target types.** `github-environment` writes an environment-scoped secret and needs `environment`. `github-actions` writes a repository-level secret and rejects `environment`.
- **`repo`** can be a bare name (`arcyber`) when `GITHUB_DEFAULT_ORG` is set (Terraform `github_default_org`); otherwise it must be `owner/repo`.
- **`subscriptionId` / `clientId`** are optional reference data (GUIDs). Nothing is pushed or acted on from them.
- `tokenSecret` names a Key Vault secret holding the PAT for that target. Omit it to use the app default (`GITHUB_TOKEN_SECRET_NAME`).
- `enabled: false` pauses distribution without losing the entry.
- `updatedUtc` and `updatedBy` are set by the server (`updatedBy` is the signed-in user); `_etag` is the concurrency token. Anything a client sends for them is ignored.

## Sign-in and roles

> **Phase 3 / current test mode.** Sign-in is not set up yet. With `registry_open_access = true` in `terraform.tfvars` and no `entra_client_id`, Easy Auth is off and the UI/API are open: anyone with the app URL is treated as **Admin**. That is for testing the distribution logic only. To close it, set `registry_open_access = false`, or set `entra_client_id` once the app registration exists (steps below). With `entra_client_id` set, Easy Auth is on and the open mode has no effect.

The distributor app sits behind **App Service Authentication (Easy Auth)** with Entra ID. Nobody reaches the UI or API without signing in, and only people assigned a role on the app registration can sign in at all ("Assignment required").

| Role | Can |
|---|---|
| `Registry.Reader` | View entries and what was last sent |
| `Registry.Editor` | + create and update entries |
| `Registry.Admin` | + delete entries |

Someone with several roles gets the highest. Someone signed in with **no** role gets a 403 with a message saying so.

Easy Auth only proves *who* someone is. The **role checks are in the API handlers** (`RegistryApi.cs`), so they hold even if someone calls the API directly and skips the UI. The UI also hides buttons a user cannot use, but that is a courtesy, not the control.

**Fails closed.** The API reads the signed-in user from the `X-MS-CLIENT-PRINCIPAL` header that Easy Auth adds. With Easy Auth *off*, a client could send a forged header, so when running in Azure without Easy Auth enabled the API refuses every request (503) rather than trust it. That means **before `entra_client_id` is set, the UI does not work** — by design.

**Event Grid is excluded from sign-in.** Event Grid delivers events to `/runtime/webhooks/EventGrid` with the host's system key and cannot sign in as a user. That path is listed in `excluded_paths`; without that, distribution would silently stop.

Role changes apply at the person's **next sign-in** (the role travels in their token), so removing someone is not instant.

### Setting it up

1. **Create the app registration** — needs Application Administrator or similar, so someone other than the Terraform SP usually runs it:
   ```powershell
   az login
   ./scripts/Setup-RegistryAuth.ps1 -AppHostname <distributor-app>.azurewebsites.net -VaultName <kv-name> -AllowAzCli -WhatIf
   ```
   It creates the app with the three roles, turns on assignment-required, and stores the client secret **directly in Key Vault** (never displayed). It prints the client ID. `-AllowAzCli` additionally lets scripts get a token via `az account get-access-token`.
2. Add `entra_client_id = "<the id>"` to `terraform.tfvars` and apply. This turns Easy Auth on and sets the client secret as a Key Vault reference. The distributor's identity needs **Key Vault Secrets User** on the vault to resolve it. For Azure Government also set `entra_authority_host = "https://login.microsoftonline.us"`.
3. **Assign people:**
   ```powershell
   ./scripts/Grant-RegistryRole.ps1 -ClientId <id> -Role Admin  -User you@contoso.com
   ./scripts/Grant-RegistryRole.ps1 -ClientId <id> -Role Reader -User john.doe@contoso.com
   ```
   Assigning a **group** to a role (`-Group`) needs Entra ID **P1 or higher**; on a free tenant assign users individually.

The scripts have **not been run against a live tenant**. Read them once and expect to adjust.

## API

Base: `https://<distributor-app>.azurewebsites.net/api`. Browsers authenticate with the Easy Auth session; scripts send `Authorization: Bearer <token>` (see below).

| | | Needs |
|---|---|---|
| `GET` | `/me` | Any signed-in user. Returns your name and role |
| `GET` | `/registry` | Reader. List entries |
| `GET` | `/registry/{id}` | Reader. One entry; the ETag is in the body and the `ETag` header |
| `PUT` | `/registry/{id}` | Editor. **Create** with no `If-Match` (412 if it already exists); **update** with `If-Match: <etag>` (412 if it changed) |
| `DELETE` | `/registry/{id}` | Admin. Remove the entry and its state |
| `GET` | `/state/{id}` | Reader. Last pushed version / time / key id per target |

Update flow: `GET`, change, `PUT` with the ETag you got. A 412 means someone else wrote first — re-fetch and reapply.

**Tokens for scripts** (needs `-AllowAzCli` at setup, and a role assigned to the account):
```powershell
$token = az account get-access-token --scope api://<client-id>/access_as_user --query accessToken -o tsv
Invoke-RestMethod "$api/registry" -Headers @{ Authorization = "Bearer $token" }
```

## UI

`https://<distributor-app>.azurewebsites.net/api/ui`

A single page (`secret_distributor/ui/index.html`, embedded in the assembly). You sign in with your normal Entra account; the header shows who you are and your role. Left: the list of secrets with a filter. Right: the selected secret — its Key Vault name, whether it is switched on, and where it goes (repository, optional environment, GitHub secret name). Optional details (display name, owner, subscription and client IDs) are folded away, as is the per-target "use a different GitHub token" override.

- **Target type is inferred:** an environment means an environment secret; no environment means a repository secret. There is no type dropdown.
- **Readers** see everything but every field is disabled and there are no Save / Delete buttons.
- **Conflicts:** saving an entry someone else changed since you opened it shows a message with a "discard my changes and reload" button, rather than overwriting.
- **Deleting** (Admin) asks you to type the name. It removes the registry entry and its state, not the Key Vault secret.
- **Expired session:** shows "Sign in again" instead of failing quietly.
- Locked down with a nonce-based CSP, and all server text is written with `textContent`, so a hostile value in an entry cannot inject script. No external scripts or fonts, so it works with no internet egress.

## How distribution uses it

`DistributeSecret` looks up the entry for the event's secret name:

1. **Entry exists** → push to every target. If it is disabled or has none, do nothing.
2. **No entry** → fall back to the legacy `GITHUB-*` tags (logged as a warning), so nothing breaks before the import.
3. **Neither** → not a distributed secret; ignore it.

A failed target retries the whole event (pushes are idempotent). Targets that succeeded are recorded in `state` first.

Cosmos errors are **not** swallowed — throttling and not-yet-propagated RBAC clear on retry, and swallowing them would lose the one event a version produces.

## Deploying

1. Set `enable_secret_distribution = true` and apply. This creates the Cosmos account, database, containers and the app's data-plane role (`cosmos.tf`). If a region is out of Cosmos capacity, set `cosmos_location`.
2. Publish `secret_distributor/`.
3. Set up sign-in (see **Sign-in and roles** above), apply again, and assign yourself Admin.
4. Import existing config, `-WhatIf` first (needs a token and the Editor role — see **API**):
   - From the original JSON: `scripts/Import-LegacyJsonToRegistry.ps1 -Path teams.json`. It assumes each top-level key **is** the Key Vault secret name and that every target uses one GitHub secret name (`-SecretName`, default `AZURE_CLIENT_SECRET`). Use `-IdMap` if the names differ.
   - From Key Vault tags: `scripts/Import-TagsToRegistry.ps1` (repo-level targets only).

Environment secrets need the PAT to be able to read the repository and write secrets in the environment. **I have not verified the exact fine-grained permissions GitHub requires for the environment endpoints** — test one target before importing everything, and check the log line `Could not read the public key ... environment exists`.

The Cosmos role assignment is a `Microsoft.DocumentDB/.../sqlRoleAssignments` resource, **not** `Microsoft.Authorization`, so it should not hit the missing `roleAssignments/write`. If the apply 403s anyway, grant it by hand:

```bash
az cosmosdb sql role assignment create -g <rg> -a <cosmos-account> \
  --role-definition-id 00000000-0000-0000-0000-000000000002 \
  --principal-id <distributor-principal-id> \
  --scope "/dbs/secret-registry"
```

Local dev: with key auth disabled, `DefaultAzureCredential` uses your own `az login`, so your user needs the same data-plane role.

## Not done yet

- **The PowerShell app does not use the registry.** Its config is still app settings. When it needs registry data it should call this API, not Cosmos — which now means a token, since Easy Auth covers the API. That is a design question to settle before it needs to.
- **Audit is `updatedBy` only.** The last writer is recorded on the entry, and writes are logged with the caller, but there is no history of past versions.
- **Nothing here has run against live Azure yet.** The build passes, Terraform validates, and the identity/role parsing and the UI have been tested locally (including a forged-header case). The Easy Auth settings, the setup scripts, the Cosmos calls and the ETag handling are unexercised against a real tenant.
- **The Easy Auth client secret expires** (about a year). Recreate it before then; the Key Vault secret carries the expiry.
- **Public network access** on Cosmos, like the rest of the spike. Private endpoint with the networking work.
