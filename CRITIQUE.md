# Critique

Status as of 2026-09-09. The original entry (Event Grid T-30 vs. the T-14
window) is **resolved** and kept at the bottom for history. Everything above
it came out of an adversarial review after the stack was first deployed and
exercised end to end.

---

## RESOLVED

### R1. Rollback deleted by name, so it could destroy a healthy webhook

`New-RenewedWebhook` gained a rollback (delete the webhook if the Key Vault
write fails) to close the unrecoverable-URL window. As first written it
deleted **by name**, without checking the webhook at that name was the one it
had just created.

Failure: two runs overlap (the timer at 06:00 and an Event Grid retry -- see
O1). Run A creates W_A; run B deletes W_A, creates W_B, and stores W_B's URL
successfully. Run A's vault write then fails and its rollback deletes *W_B*.
Key Vault now holds a URL for a webhook that no longer exists.

Fixed: rollback re-reads the webhook and compares `CreationTime` against the
object it created, skipping the delete if they differ.

### R2. Rollback fired on permission errors, creating a destroy/recreate loop

The catch treated every write failure as transient. The most likely failure
is a 403 from Key Vault -- the RBAC grants are manual (see MANUAL-RBAC.md)
and eventually consistent, and a `terraform destroy` + re-apply regenerates
the principal, so a missing grant is the expected state after a rebuild.

Failure: the timer creates a webhook, 403s on the vault, deletes the webhook.
Every day. The secret stays at its placeholder while the automation account
churns, and the "next run will create a replacement" comment made it look
benign.

Fixed: 401/403/404 are treated as permanent -- no rollback, loud error, and
the webhook is deliberately left in place (it still works for anyone holding
the URL, which a deleted one does not).

### R3. `-ErrorAction SilentlyContinue` made every failure look like "not found"

`Get-AzAutomationWebhook` was called with `-ErrorAction SilentlyContinue` in
two places. That suppresses 401/403, 429, 5xx and "no Az context" identically
to a genuine 404 -- and `$null` means "create a replacement", which rotates
the URL every existing consumer holds.

Failure: a transient 503 on the read causes a healthy webhook to be replaced
and its URL invalidated, from a single blip.

Fixed: `Get-AutomationWebhookOrNull` returns `$null` only on a real
not-found and rethrows everything else. Also normalises the multi-result case.

### R4. Managed identity sign-in was skipped on this platform

`profile.ps1` guarded on `$env:MSI_SECRET`, which is the older App Service
variable. Linux Consumption populates `IDENTITY_ENDPOINT`/`IDENTITY_HEADER`,
so the sign-in block was likely never running -- and because the block also
swallows its own failures by design, every Az call would then fail
unauthenticated and (per R3) be read as "webhook missing".

Fixed: the guard now accepts either variable.

### R5. Timer trigger had no error handling

`RenewWebhook` is the reconciliation authority, and timer triggers are not
retried. An unhandled throw was a silently missed renewal.

Fixed: try/catch with explicit logging, rethrow so the invocation is marked
failed, an `IsPastDue` warning, and up-front validation of all eight app
settings -- `[int]$null` silently becomes `0` lead-days, which makes every
webhook look outside the window and the timer no-op forever while appearing
healthy.

### R6. Event Grid failures burned 30 retries destructively

`OnSecretNearExpiry` had no error handling, so any throw triggered up to 30
retries over 24h. For a deterministic fault (403, bad config) that is 30
identical failures, each able to create and roll back a webhook, all racing
the daily timer.

Fixed: permanent-looking errors are logged and swallowed; only plausibly
transient ones rethrow. The handler also now ignores events whose subject is
not the managed secret, and `main.tf` gained a matching `subject_filter` --
previously any secret in the vault nearing expiry triggered a full renewal.

### R7. Half-committed extend path

In the extend branch the ARM PATCH commits first, then Key Vault's expiry
metadata is updated. If the second call failed, the webhook was good for
another 90 days while Key Vault still carried the old expiry -- so
SecretNearExpiry fires on a stale date and never near the real one, silently
killing the Event Grid path.

Fixed: the update is wrapped and throws with an explicit INCONSISTENT STATE
message so the next timer run reconciles it.

### R8. Boundary and null-safety in the decision logic

- `-le 0` meant an expiry seconds away took the extend path, whose PATCH then
  raced the actual expiry and returned a deterministic 400 instead of falling
  through to create. Now `-lt 0.5`.
- `$webhook.ExpiryTime` was dereferenced without a null check; a webhook with
  no expiry crashed the run. Now treated as unrenewable and replaced.

### R9. Credential leakage in errors

The webhook URL is a bearer credential (token in the query string).
`Set-AutomationWebhookExpiryViaRest` threw with the raw `$response.Content`,
which for this API echoes the webhook's own properties; `ManualRenewCheck`
returned raw Az exception text to the caller, which routinely embeds
subscription IDs and principal object IDs.

Fixed: the REST error surfaces status plus a bounded error code only, and the
HTTP trigger logs the full exception but returns a generic message.

---

## OPEN

### O1. No concurrency guard (highest remaining risk)

Nothing serialises `Invoke-WebhookRenewalCheck`. Event Grid's retry policy
(`max_delivery_attempts = 30`, `event_time_to_live = 1440`) spreads retries
across a full 24 hours, so overlap with the 06:00 timer is a design
consequence, not bad luck. R1's `CreationTime` check narrows the damage but
does not eliminate the race.

Fix: take a blob lease on the existing storage account at the top of
`Invoke-WebhookRenewalCheck` and release it in a `finally`. Roughly 15 lines,
and it subsumes R1.

### O2. Nothing detects a failed renewal

There is no assertion anywhere that the expiry actually moved. Dead-lettering
covers failed *deliveries*, not logic failures in a successful invocation
(main.tf says as much), and dead-lettering itself needs a manual RBAC grant
that does not exist on a fresh deploy. The timer now logs failures, but no
alert rule consumes them.

Fix: read the expiry back after writing and throw if it did not move; add an
alert on "webhook expiry did not advance in N days".

### O3. Event Grid bootstrap may never fire

The placeholder secret is created with a 24h expiry to "force a near-expiry
state". SecretNearExpiry fires at T-30, which for a 24h secret is already in
the past -- so the event may fire immediately or never. If it never fires,
the design silently depends entirely on the timer.

### O4. Terraform does not create the webhook

`initial_webhook_expiry_days` is defined but referenced nowhere, and there is
no `azurerm_automation_webhook` resource. The first invocation therefore
always takes the create path -- the one with the unrecoverable-URL window in
it. The variable misrepresents what the stack provisions.

### O5. Integration tests still missing

Both the `-lt 0.5` boundary and the `-TriggeredByExpiryEvent` bypass are
effectively untestable against live Azure on a sane timescale. Pester tests
with mocked Az cmdlets are the only practical way to cover all four branches.
This was the original critique's closing ask and it remains unmet.

### O6. Secret hygiene

`terraform/.env.ps1` holds a live SP client secret (gitignored, but on disk
and used by `deploy.ps1`). `terraform.tfstate` is local and unencrypted and
contains the storage account key. `MANUAL-RBAC.md` hardcodes real principal
and subscription IDs and is *not* gitignored. Acceptable for a spike;
must not survive into anything shared. Rotate that SP secret.

### O7. Application Insights is not managed by Terraform

The original component was removed from `main.tf` after a `workspace_id`
state conflict, then recreated by hand. Terraform will not manage or destroy
it, and its auto-created Log Analytics workspace lives in a separate
`ai_..._managed` resource group that `terraform destroy` will not clean up.
`host.json` also still configures App Insights sampling with
`excludedTypes: "Request"` -- sampling can discard the very warnings this
design relies on as its only failure signal.

---

## RESOLVED (original entry, 2026-09-04)

### The Event Grid-only renewal path cannot renew a healthy webhook

`SecretNearExpiry` fires once at T-30, but the renewal window was 14 days, so
the event hit the `$daysRemaining -gt $RenewalLeadDays` guard and returned
without doing anything -- a successful invocation Event Grid would not retry,
for an event that never repeats.

Resolved by `-TriggeredByExpiryEvent`, which bypasses the window check on the
Event Grid path only. The timer is now documented as the renewal authority
and the event as an early fast path, which is the first of the two coherent
contracts the original critique asked for.
