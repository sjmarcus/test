# Phase 1 summary and phase 2 direction

Status: **complete**. All four renewal paths proven against live Azure on
2026-09-09 through 2026-09-11.

This document is the handoff record: what was built, what it cost to get
working, why the target architecture is changing, and what carries forward.

---

## 1. What phase 1 set out to do

Azure Automation webhooks expire on a fixed date. Two properties make that
awkward:

- The webhook URL is returned **exactly once**, at creation. Azure never
  reveals it again through any API or the portal.
- An **expired webhook cannot be revived**. It can only be replaced, which
  mints a different URL and breaks every caller holding the old one.

Phase 1 built a function that renews a webhook before it lapses and keeps its
URL published in Key Vault, so callers always have a live reference.

Scope was deliberately narrow: one webhook, one secret, commercial
subscription, public networking, ahead of the DoD/Gov networked build-out.

---

## 2. What was built

### Three triggers, one decision function

| Function | Trigger | Role |
|---|---|---|
| `RenewWebhook` | Timer, `0 0 6 * * *` (06:00 UTC daily) | The authority. Applies the 14-day lead window, so it no-ops cheaply on most days. Guarantees renewal even if everything else fails. |
| `OnSecretNearExpiry` | Event Grid, `Microsoft.KeyVault.SecretNearExpiry` | Fast path. Renews ~16 days earlier than the timer would. Passes `-TriggeredByExpiryEvent`. |
| `ManualRenewCheck` | HTTP POST, function-key auth | Test-only. Exercises the same logic on demand. Intended for deletion. |

None contain renewal logic. All three call `Invoke-WebhookRenewalCheck` in
`Modules/WebhookRenewal/WebhookRenewal.psm1`.

### The decision logic

Four guards, checked in order; the first match decides:

1. **Does the webhook exist?** No -> create one (90-day expiry), write URL to
   Key Vault.
2. **Does it have an expiry date?** No -> unrenewable, replace it.
3. **More than 14 days left?** Yes -> stop, nothing to do.
   **Event Grid skips this check** -- see below.
4. **Under 12 hours left?** Yes -> replace. No -> **extend in place**.

Extending preserves the URL (ARM REST `PATCH`; `Az.Automation` has no cmdlet
for this). Only the secret's expiry attribute updates -- no new version.
Replacing mints a new URL, written as a new secret version, and breaks
consumers holding the old one.

### Why Event Grid skips the window check

`SecretNearExpiry` fires **once per secret version**, at a fixed T-30 mark
tied to the secret's current expiry. It is not recurring.

Applying the 14-day window to a 30-day-out event would dismiss it as "too
early", return success, and consume the only notification that path ever
receives. `-TriggeredByExpiryEvent` bypasses the check.

Do **not** "fix" this by raising the lead window to 30 instead. Days-remaining
is fractional, so the event lands either side of that boundary depending on
delivery latency -- trading a deterministic bug for an intermittent one.

---

## 3. Proven behaviour

All four verified against live Azure:

| Path | Result |
|---|---|
| Create when missing | Webhook created, URL captured and stored as a new secret version |
| Extend in place | Expiry moved out 90 days, **URL preserved, no new secret version** |
| Replace when expired | Old deleted, new one created, new URL written as a new version |
| Event Grid fast path | Real `SecretNearExpiry` event fired, bypassed the lead window, renewed unattended |

The Event Grid test is the most significant: it ran with nobody watching,
triggered by Key Vault itself, and both the webhook and secret expiry moved to
the same date.

---

## 4. What it cost to get working

Seven distinct deployment problems, none of them the renewal logic. Recorded
because most will recur for anyone deploying a PowerShell function on this
platform.

1. **Service principal lacked `roleAssignments/write`.** Terraform cannot
   create the four role assignments this stack needs. Moved to manual, in two
   passes -- see `MANUAL-RBAC.md`.
2. **App Insights `workspace_id` state drift.** Classic App Insights retired
   Feb 2024; Azure auto-provisions a workspace and `azurerm` 3.x did not
   reconcile it. Removed from Terraform, recreated by hand.
3. **Event Grid system topic `location = "global"`.** Must match the source
   resource's region. Only globally-scoped sources use `global`.
4. **Em-dashes in a BOM-less `.psm1`.** PowerShell read the file as ANSI,
   mangling every em-dash into broken string terminators. The module failed to
   parse, so the host indexed **zero** functions -- while the portal still
   listed them, because that reads deployed metadata rather than runtime
   state. Presented as an empty HTTP 500 and a 404 from the SCM site.
5. **`managedDependency` missing from `host.json`.** The `Az` modules were
   never installing.
6. **`managedDependency` is unsupported on Linux Consumption (Legion).**
   The fix for (5) was wrong for this platform. Any entry in
   `requirements.psd1` makes the worker throw at function-load time, before
   any code runs. Resolved by vendoring `Az.Accounts`, `Az.Automation` and
   `Az.KeyVault` into the package (~44 MB).
7. **`Remove-AzAutomationWebhook` has no `-Force`** in Az.Automation 1.12.1
   (unlike `New-`, which does). Surfaced by the version jump when vendoring.

### Deployment is not one pass

Event Grid validates the function endpoint live when creating a subscription,
so the code must be deployed and the host healthy *before* that resource can
exist. The order is: `terraform apply` -> publish function code -> `apply`
again. This is inherent to endpoint validation, not a bug.

---

## 5. Adversarial review

A full adversarial review after first deployment found 20 defects. Nine are
fixed; details in `CRITIQUE.md`. The most serious:

- **The first rollback fix was a net negative.** Added to close the
  unrecoverable-URL window, it deleted the webhook **by name** without
  checking it was the one it had just created -- so a concurrent run's healthy
  webhook could be destroyed. It also fired on permission errors, which would
  have produced a daily create-then-destroy loop that never stores a usable
  URL. Now gated on `CreationTime` and on error type.
- **`-ErrorAction SilentlyContinue` masked auth failures as "not found".**
  A transient 503 or a missing RBAC grant looked identical to a missing
  webhook, so the function would replace a healthy one and invalidate its URL.
- **Managed identity sign-in was likely never running.** `profile.ps1` guarded
  on `$env:MSI_SECRET`, the older App Service variable; Linux Consumption
  populates `IDENTITY_ENDPOINT`.
- **The timer had no error handling at all** -- the one component the design's
  correctness rests on.

### Open items

| # | Item |
|---|---|
| O1 | **No concurrency guard.** Event Grid's 24h retry window means overlap with the daily timer is a design consequence, not bad luck. A blob lease closes it in ~15 lines. |
| O2 | **Nothing detects a failed renewal.** No check asserts the expiry actually moved. Event Grid fires once and treats a silent no-op as success. |
| O3 | Event Grid bootstrap may never fire (24h placeholder expiry is already past T-30). |
| O4 | Terraform does not create the webhook; `initial_webhook_expiry_days` is unused. |
| O5 | **No test suite.** Every branch was validated by hand against live Azure. |
| O6 | Secret hygiene: live SP secret on disk, unencrypted local state, real IDs in a non-gitignored file. |
| O7 | App Insights is not managed by Terraform, and its sampling config could discard the warnings this design relies on. |

---

## 6. Phase 2 direction

### The target architecture removes the webhook

**Event Grid can invoke a Function App directly.** Moving the rotation
runbook logic into a Function App eliminates the webhook entirely -- no
expiry, nothing to renew, and none of the machinery phase 1 built.

This is the goal going forward. Phase 1's cost is the evidence for it: seven
deployment problems and twenty review findings, almost all of them machinery
for keeping a webhook alive. The single most fragile component is the one the
target architecture does not need.

**Two things would rule this out and should be confirmed early:**

- **Hybrid workers.** If any runbook runs on a hybrid worker to reach on-prem
  or VNet-joined resources, a consumption Function App cannot replace it.
  Elastic Premium with VNet integration would be required.
- **Long-running work.** Automation runbooks can run for hours; functions on
  Y1 cap at 10 minutes.

### Phase 1 becomes the interim safety net

Webhooks do not disappear from the estate on day one. Anything already
triggering runbooks that way still has an expiry. The renewal function covers
those until they are migrated or retired.

This reframes the open items as a scoping question: if webhooks have a known
short end date, the concurrency lease (O1) may not be worth building. If they
will be around for a year, it is.

### Expanding beyond webhooks

Phase 2 also widens scope to Key Vault secrets for service principals and VM
passwords, across many teams -- e.g. `Team1VMPassword`, `Team5SPN`.

**What generalizes:** the four-check decision shape, the Key Vault
integration, the managed identity pattern, the timer-plus-event architecture,
and the `-TriggeredByExpiryEvent` insight (which becomes *more* important --
with many secrets, scanning everything daily gets expensive).

**What does not:**

- **"Renew" means something different per type.** A webhook extends in place.
  An SPN secret, per current understanding, is just a new version in Key Vault
  created by someone else -- so the system is *distributing* a rotation, not
  performing one. A VM password is a reset with no overlap window and an
  immediate blast radius. These are three different operations sharing a
  trigger, not variations on one algorithm.
- **Blast radius.** Today the worst case is one webhook URL breaking. A
  botched SPN rotation locks a team out; a VM password is worse. The current
  failure handling -- throw, log, retry tomorrow -- is not adequate for that.
- **Permissions.** One managed identity that can rotate every team's SPN
  credentials and reset every VM password is a very high-value target, more
  privileged than most humans in the subscription. Decide early whether it is
  one identity or one per team; it shapes everything else.

### Two decisions worth making before writing phase 2 code

1. **What happens to consumers when a credential rotates?** Phase 1 punted --
   a new webhook URL breaks callers, and that was accepted. SPNs and VM
   passwords cannot punt. Do consumers re-read from Key Vault on every use, or
   is the value cached in app settings, pipeline variables, or config files?
   If cached, the real work is enumerating and updating those copies, and that
   is a larger problem than the rotation itself.

2. **Naming convention versus tags.** Parsing type and owner out of
   `Team5SPN` is convenient and fragile -- a typo means a secret silently
   never rotates, or is handled as the wrong type. Key Vault **tags**
   (`type=spn`, `team=team5`, `rotation=auto`) are the durable answer. Names
   for humans, tags for logic.

### Suggested sequencing

- **SPN secrets first.** If the rotation itself happens elsewhere, the
  function's job is distribution and alerting -- a much smaller and safer
  scope than it sounds. Subscribe to `SecretNewVersionCreated` alongside
  `SecretNearExpiry`; a near-expiry event with no corresponding new version
  means a team is heading for an outage and does not know.
- **VM passwords separately.** No overlap window, no rollback. Deserves its
  own design rather than being folded into a shared code path.
- **An inventory view** of what exists and when it expires. Under the option-3
  plan this measures migration progress as well as monitoring -- which
  webhooks still need the renewal function, and which are already migrated.

---

## 7. Reference

| Document | Contents |
|---|---|
| `README.md` | Original design intent and renewal mechanics |
| `CRITIQUE.md` | Full review findings, 9 resolved and 7 open |
| `MANUAL-RBAC.md` | The four manual role assignments and the two-pass order |
| `terraform/main.tf` | Infrastructure; note the four commented-out `azurerm_role_assignment` blocks |
| `function_app/Modules/WebhookRenewal/WebhookRenewal.psm1` | All decision logic |
