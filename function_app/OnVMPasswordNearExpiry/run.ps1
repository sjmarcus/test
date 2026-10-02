<#
    Event Grid handler for VM password rotation.

    Key Vault fires Microsoft.KeyVault.SecretNearExpiry 30 days before a
    secret's expiry date. The event's subject is the secret name.

    CADENCE. This is the whole scheduling mechanism -- there is no timer.
    Rotation writes a new secret version with an expiry 90 days out, Key
    Vault fires near-expiry 30 days before that, and the cycle repeats:

        rotate -> expiry set to now + 90
               -> near-expiry fires at day 60
               -> rotate  ... a 60-day rotation cadence

    Setting SECRET_LIFETIME_DAYS to 60 would give a 30-day cadence, not 60.
    The T-30 offset is easy to get wrong; see the note on -SecretLifetimeDays
    in VMPasswordRotation.psm1.

    SEPARATE FROM THE WEBHOOK PATH ON PURPOSE. OnSecretNearExpiry handles the
    automation webhook secret and does something completely different with it
    (extends a webhook expiry). This handler resets a VM password. They share
    an event type and nothing else, so they are separate subscriptions with
    separate subject filters rather than one handler branching on the secret.

    UNLIKE THE WEBHOOK, THERE IS NO TIMER BACKSTOP. If this event is missed,
    nothing else rotates the password -- it simply expires in Key Vault while
    the VM keeps the old one. That asymmetry is deliberate for now (a VM
    password does not stop working when the Key Vault entry expires, so the
    failure is silent rather than breaking), but it is the reason failures
    here must be loud.
#>
param($eventGridEvent, $TriggerMetadata)

Import-Module "$PSScriptRoot/../Modules/VMPasswordRotation/VMPasswordRotation.psm1" -Force

$eventType  = $eventGridEvent.eventType
$secretName = $eventGridEvent.subject

Write-Host "Event Grid fired: '$eventType' for secret '$secretName'."

if ($eventType -ne 'Microsoft.KeyVault.SecretNearExpiry') {
    # The subscription filters on type, so this should not happen -- but a
    # misconfigured subscription must not silently rotate on the wrong event.
    Write-Warning "Ignoring unexpected event type '$eventType'. This handler only acts on SecretNearExpiry."
    return
}

if ([string]::IsNullOrWhiteSpace($secretName)) {
    Write-Error "Event carried no subject, so there is no secret to rotate. Not retrying."
    return
}

if ([string]::IsNullOrWhiteSpace($env:KEY_VAULT_URI)) {
    # Deterministic: retrying will not conjure an app setting.
    Write-Error "KEY_VAULT_URI is not set. Not retrying."
    return
}

$vaultName = ([Uri]$env:KEY_VAULT_URI).Host.Split('.')[0]

# The subscription's subject filter is the first line of defence, but it is
# name-based and names change. The tags are the real contract: if this secret
# does not carry VM-NAME and ADMIN-NAME, it is not ours to rotate.
#
# This matters more here than in the webhook handler -- acting on the wrong
# secret means resetting the wrong machine's password, which no retry fixes.
try {
    $target = Resolve-VMTargetFromSecret -VaultName $vaultName -SecretName $secretName
}
catch {
    Write-Error "Not rotating '$secretName': $($_.Exception.Message)"
    return
}

Write-Host "Secret '$secretName' -> VM '$($target.VMName)' in '$($target.VMResourceGroup)', account '$($target.AdminUsername)'."

$secretLifetimeDays = 90
if (-not [string]::IsNullOrWhiteSpace($env:SECRET_LIFETIME_DAYS)) {
    $secretLifetimeDays = [int]$env:SECRET_LIFETIME_DAYS
}

try {
    $result = Invoke-VMPasswordRotation `
        -KeyVaultUri $env:KEY_VAULT_URI `
        -SecretName $secretName `
        -SecretLifetimeDays $secretLifetimeDays

    Write-Host "Rotated '$secretName' for VM '$($result.VMName)'. Next near-expiry event due around $($result.ExpiresUtc.AddDays(-30)) UTC."
}
catch {
    $message = $_.Exception.Message

    # DRIFT is the one failure worth retrying: the new password is already in
    # Key Vault and only the VM reset failed, which is often transient (agent
    # busy, VM restarting). Re-running reapplies the stored value, and the
    # reset is idempotent.
    $isDrift = $message -match '^DRIFT:'

    # Everything else is deterministic -- a missing tag, an unresolvable VM, a
    # stopped VM, a denied write. Event Grid would retry up to 30 times over
    # 24h and fail identically each time, so swallow it and rely on the loud
    # error instead.
    $isPermanent = -not $isDrift -and
                   ($message -match '(?i)(denied|forbidden|unauthorized|\b40[134]\b|not found|missing required tag|not running|multiple resource groups)')

    if ($isPermanent) {
        Write-Error ("Rotation FAILED permanently for '$secretName' -- not retrying: $message " +
                     "NOTE: there is no timer backstop for VM passwords. This secret will NOT be rotated until " +
                     "the underlying problem is fixed and it is re-run manually via RotateVMPassword.")
        return
    }

    Write-Error "Rotation failed for '$secretName'; allowing Event Grid to retry: $message"
    throw
}
