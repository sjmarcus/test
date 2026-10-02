# VM local admin password rotation via Azure Function

Moves VM password rotation off the Automation Account into the existing Function App. Triggered by Key Vault's `SecretNearExpiry` event — no timer or schedule.

**Status:** deployed and verified end to end. Two VMs rotated via Event Grid; login confirmed with a rotated password.

## Flow

Key Vault fires `SecretNearExpiry` at T-30 → `OnVMPasswordNearExpiry` reads the secret's tags to find the VM → generates a password → writes it to Key Vault → applies it to the VM via VMAccess.

Key Vault is written **before** the VM reset. If the reset succeeded and the write failed, the VM would have a password nobody knows. Written first, the worst case is Key Vault being a step ahead, and the reset is idempotent so re-running fixes it. That case is logged as `DRIFT:` and retried.

## Cadence

Key Vault fires at T-30, so `rotation cadence = SECRET_LIFETIME_DAYS - 30`.

Default 90 → rotates every 60 days. Setting it to 60 gives a 30-day rotation, not 60. Terraform rejects values under 31.

## Tagging a secret

Two tags link a secret to its VM:

```bash
az keyvault secret set-attributes --vault-name <vault> --name Team1VMPassword \
  --tags VM-NAME=vm-team1-01 ADMIN-NAME=localadmin
```

That's the whole enrolment — no redeploy. Secrets missing either tag are refused. Tags rather than name-parsing because a rename or typo would otherwise point rotation at the wrong machine.

## Files

- `Modules/VMPasswordRotation/VMPasswordRotation.psm1` — rotation logic
- `OnVMPasswordNearExpiry/` — Event Grid trigger
- `RotateVMPassword/` — HTTP trigger for manual runs

Terraform adds a second Event Grid subscription, the `SECRET_LIFETIME_DAYS` setting, and a commented role assignment. `Az.Compute` vendored into the package (+18 MB, ~62 MB total).

## Manual endpoint

```bash
curl -X POST "https://<app>.azurewebsites.net/api/RotateVMPassword?code=<key>" \
  -H "Content-Type: application/json" -d '{"listOnly":true}'
```

Also takes `{"secretName":"..."}` or `{"all":true}`. Returns 200 / 207 partial / 500. Rotations are isolated — one bad VM doesn't stop the rest.

## Notable behaviour

Preflight checks the VM is running before generating anything. Duplicate VM names across resource groups are refused rather than guessed. Tags are rewritten on every version, since `Set-AzKeyVaultSecret` replaces rather than merges them. Permanent failures (missing tag, stopped VM, denied) are swallowed with a loud error instead of burning 30 Event Grid retries.

Passwords are 32 chars from `RandomNumberGenerator`, all four character classes, no ambiguous or shell-breaking glyphs.

## Verified

Two secrets (`Team1VMPassword`, `Team2VMPassword`) tagged to two Windows VMs in `sam-rg-skynet-test`. Both rotated via Event Grid on their own `SecretNearExpiry` events. Discovery returns both targets; the HTTP trigger rotates one or all. Logged into a rotated VM with the password from Key Vault.

Two bugs found and fixed during testing:

- `Set-AzVMAccessExtension` in Az.Compute 11.9 takes `-Credential` (a `PSCredential`) and `-Location`, not the `-Username`/`-Password` pair in older docs. Surfaced as a `DRIFT:` error — which is the ordering design working: Key Vault held the new password, the VM reset failed, and the system said so rather than losing the credential.
- `Select-Object -First 1` returns null when nothing matches, and `.Value` on null throws under `Set-StrictMode -Version Latest`. Broke `listOnly` on any secret with empty tags.

Every Az cmdlet call in the module is now validated against the vendored module signatures.

A third bug surfaced later, once secret distribution was added: rotation wrote a **fixed** set of tags, and `Set-AzKeyVaultSecret` replaces the tag collection rather than merging into it. Every rotation therefore deleted any tag rotation did not own itself — including the `GITHUB-REPO` / `GITHUB-SECRET-NAME` tags that tell the distributor where to publish. Rotation kept working and distribution silently stopped. Fixed by reading the current tags and carrying them forward, overwriting only the rotation-owned ones.

Worth noting the code already carried a comment warning that tags are replaced rather than merged — written for the VM tags, and then the same mistake was made for a different set.

## Still to confirm

- [ ] `vm_password_secret_prefix` — defaults to `"Team"`, which also catches `Team5SPN`
- [ ] Expiry stamped on two early rotations was 24 days rather than 90; believed to be a stale deployment, not reproduced since. Worth watching — a short expiry puts T-30 in the past, so the secret silently drops out of the cadence.

## Open

**Role is too broad.** `Virtual Machine Contributor` can delete VMs. Needs a custom role with `virtualMachines/read` and `virtualMachines/extensions/read|write`. Worth doing before teams depend on it.

**No backstop — the main gap.** Rotation depends entirely on one event per secret version. Miss it (retries exhausted, function down, a deploy mid-flight, or a secret tagged with no expiry) and nothing rotates and nothing says so. The webhook design has a daily timer for exactly this; VM rotation has no equivalent. A timer sweeping `Get-RotatableVMSecret` for anything inside the window would close it — roughly 40 lines.

**A secret with no expiry never rotates** and looks healthy. Nothing detects it.

**Nothing verifies the reset took.** VMAccess reporting success isn't the same as a usable credential — that was confirmed by hand here, not by the code.

**Consumers unknown.** If anything caches these passwords, rotation breaks it without warning. Needs answering before enabling on VMs something depends on.

**No tests.** Only the password generator is verified; the rotation path hasn't run against a real VM.

## Related

`STORY-SECRET-DISTRIBUTION.md` · `PHASE-1-SUMMARY.md` · `MANUAL-RBAC.md` · `CRITIQUE.md`
