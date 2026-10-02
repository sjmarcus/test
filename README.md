# Webhook Renewal Spike

Keeps an Azure Automation runbook webhook from silently expiring, and publishes the current URL to Key Vault so callers always have a live reference.

Commercial subscription, public networking — proving the logic before the DoD/Gov networked build-out.

**Status:** all four renewal paths verified against live Azure, September 2026.

## The problem

An Automation webhook URL is returned exactly once, at creation — Azure never shows it again. And an expired webhook can't be revived, only replaced, which mints a new URL and breaks every caller holding the old one.

So renewing *before* expiry keeps the URL. Missing the window means an outage plus coordinating a new URL to everyone.

## Triggers

| | | |
|---|---|---|
| `RenewWebhook` | Timer, 06:00 UTC daily | The authority. Applies the 14-day window, so it no-ops cheaply most days. Guarantees renewal if everything else fails. |
| `OnSecretNearExpiry` | Event Grid, `SecretNearExpiry` | Fast path — renews ~16 days earlier. Passes `-TriggeredByExpiryEvent`. |
| `ManualRenewCheck` | HTTP POST, function key | Test-only. Delete once Event Grid is confirmed. |

None hold renewal logic; all three call `Invoke-WebhookRenewalCheck` in `Modules/WebhookRenewal/`.

## Decision logic

Four checks, first match wins:

1. **Webhook missing?** → create one, 90-day expiry
2. **No expiry date?** → unrenewable, replace
3. **More than 14 days left?** → stop. *Event Grid skips this check*
4. **Under 12 hours left?** → replace. Otherwise → **extend in place**

Extending preserves the URL via an ARM REST `PATCH` (`Az.Automation` has no cmdlet for it) and only updates the secret's expiry attribute — no new version. Replacing writes a new secret version and breaks existing consumers.

### Why Event Grid skips the window check

`SecretNearExpiry` fires **once per secret version**, at T-30. It doesn't repeat. Applying the 14-day window to a 30-day-out event would dismiss it as too early and consume the only notification that path ever gets.

Don't "fix" this by raising the window to 30 — days-remaining is fractional, so the event lands either side of that boundary depending on delivery latency. That trades a deterministic bug for an intermittent one.

## Layout

```
terraform/          RG, storage, plan, Function App, Key Vault, Automation
                     Account + placeholder runbook, Event Grid topic +
                     subscriptions, dead-letter container
function_app/
  RenewWebhook/           Daily timer
  OnSecretNearExpiry/     Event Grid trigger
  ManualRenewCheck/       Test-only HTTP trigger
  Modules/WebhookRenewal/ All decision logic
  Modules/Az.*/           Vendored — see below
```

Fully greenfield: the Automation Account and runbook are created by this Terraform. The runbook body is a `Write-Output` placeholder.

## Deploy

Three things make this not a single-pass deploy.

**1. RBAC is manual.** The deploying service principal lacks `Microsoft.Authorization/roleAssignments/write`, so the four role assignments are commented out in `main.tf`. See `MANUAL-RBAC.md` — three grants before the first apply, one after (the Event Grid topic's identity doesn't exist until it's created).

**2. Az modules are vendored.** Managed Dependencies are unsupported on Linux Consumption (Legion). Anything in `requirements.psd1` makes the worker throw at function-load time, failing *every* function before any code runs — surfacing as an empty HTTP 500. The modules ship in the package instead (~44 MB). To refresh:

```powershell
Save-Module Az.Accounts,Az.Automation,Az.KeyVault -Path ./function_app/Modules
```

**3. Order matters.** Event Grid validates the function endpoint live when creating a subscription, so the code must be deployed and the host healthy first:

```bash
cd terraform && terraform apply     # fails on the subscription — expected
cd ../function_app                  # publish via Core Tools, VS Code, or zip deploy
cd ../terraform && terraform apply   # now the subscription can be created
```

Key Vault RBAC is eventually consistent — a 403 on the secret right after granting usually clears on a re-run.

## Testing

```bash
curl -X POST "https://<app>.azurewebsites.net/api/ManualRenewCheck?code=<key>"
```

A 200 means no error was thrown, not that anything was renewed — check App Insights for which branch ran.

To exercise each path: **extend** by PATCHing the webhook's expiry inside the 14-day window; **replace** by setting it within 12 hours; **create** by deleting the webhook first. For the Event Grid path, set the *secret's* expiry inside 30 days and wait up to 24h for Key Vault's evaluation.

The signal that the fast path worked is the log line `but SecretNearExpiry fired -- renewing anyway` — nothing else produces it.

## Azure Government

`terraform/terraform.tfvars` is set for Gov: `azure_environment = "usgovernment"`, an existing resource group (`create_resource_group = false`) and an existing Key Vault (`existing_key_vault_name`). Terraform reads both and never creates or deletes them. The vault must use Azure RBAC. Gov vault URIs end in `.vault.usgovcloudapi.net`.

```powershell
./deploy.ps1          # plan
./deploy.ps1 -Apply
```

The old commercial state is parked in `terraform/old-commercial-state/`. `deploy.ps1` also takes `-Workspace` and `-VarFile` if you ever need two clouds side by side.

Before running the registry scripts, point the CLI at Gov: `az cloud set --name AzureUSGovernment`, then `az login`, and pass `-GraphHost https://graph.microsoft.us`. Set `entra_authority_host = "https://login.microsoftonline.us"` in tfvars. In Az PowerShell use `Connect-AzAccount -Environment AzureUSGovernment`.

**Not verified for Gov:** Linux Consumption plans, Cosmos serverless, and Event Grid system topics on Key Vault in your region; that the Azure CLI client id pre-authorised by `Setup-RegistryAuth.ps1 -AllowAzCli` is the same in Gov. Run a `plan` first and check.

## Known gaps

- **No concurrency guard.** Event Grid retries spread over 24h, so overlapping with the 06:00 timer is a design consequence, not bad luck. A blob lease closes it in ~15 lines.
- **Nothing verifies a renewal happened.** No check asserts the expiry moved. Event Grid fires once and treats a silent no-op as success.
- **No tests.** Every branch was validated by hand against live Azure.
- **`Automation Contributor` is too broad** — should be a custom role scoped to `automationAccounts/webhooks/*`.
- **No networking.** Function App and Key Vault are both public. VNet integration and private endpoints are the next step.
- **App Insights isn't in Terraform** — removed after a `workspace_id` conflict, recreated by hand. A `terraform apply` will drop its connection string from app settings.
- **`ManualRenewCheck` is scaffolding** — remove it once the Event Grid path is trusted.

Secret distribution config now lives in a Cosmos-backed registry rather than Key Vault tags — see `REGISTRY.md`.

Full findings from the adversarial review, including nine resolved defects, are in `CRITIQUE.md`.

## Where this is going

Event Grid can invoke a Function App directly, with no webhook in the path at all. That's the target architecture — it removes the component this spike exists to keep alive. This work becomes the interim safety net for webhooks already in the estate.

See `PHASE-1-SUMMARY.md` for the full record and phase 2 direction.
