param($eventGridEvent, $TriggerMetadata)

Import-Module "$PSScriptRoot/../Modules/WebhookRenewal/WebhookRenewal.psm1" -Force

Write-Host "Event Grid fired: $($eventGridEvent.eventType) for subject '$($eventGridEvent.subject)'."

# The subscription filters on event TYPE only (see main.tf), so any secret in
# this vault nearing expiry lands here. Renewing the webhook because some
# unrelated secret is expiring would rotate a credential for no reason.
$expectedSecret = $env:KEY_VAULT_SECRET_NAME
if ($eventGridEvent.subject -and $expectedSecret -and $eventGridEvent.subject -ne $expectedSecret) {
    Write-Host "Ignoring event for '$($eventGridEvent.subject)' -- this handler only manages '$expectedSecret'."
    return
}

$required = @(
    'SUBSCRIPTION_ID', 'AUTOMATION_ACCOUNT_RESOURCE_GROUP', 'AUTOMATION_ACCOUNT_NAME',
    'RUNBOOK_NAME', 'WEBHOOK_NAME', 'KEY_VAULT_URI', 'KEY_VAULT_SECRET_NAME', 'RENEWAL_LEAD_DAYS'
)
$missing = $required | Where-Object { [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($_)) }
if ($missing) {
    # Deterministic: retrying 30 times will not conjure app settings. Fail
    # without throwing so the retry budget is not burned.
    Write-Error "Missing required app settings: $($missing -join ', '). Not retrying."
    return
}

# Same check-and-branch logic as the timer, with one deliberate difference:
# -TriggeredByExpiryEvent bypasses the lead-day window. SecretNearExpiry fires
# once at T-30 and never repeats for this secret version, so treating it as
# "too early" would mean the webhook is never renewed on this path at all.
try {
    Invoke-WebhookRenewalCheck `
        -TriggeredByExpiryEvent `
        -SubscriptionId $env:SUBSCRIPTION_ID `
        -AutomationResourceGroup $env:AUTOMATION_ACCOUNT_RESOURCE_GROUP `
        -AutomationAccountName $env:AUTOMATION_ACCOUNT_NAME `
        -RunbookName $env:RUNBOOK_NAME `
        -WebhookName $env:WEBHOOK_NAME `
        -KeyVaultUri $env:KEY_VAULT_URI `
        -KeyVaultSecretName $env:KEY_VAULT_SECRET_NAME `
        -RenewalLeadDays ([int]$env:RENEWAL_LEAD_DAYS)

    Write-Host "Event-driven renewal check completed successfully."
}
catch {
    # Event Grid retries a FAILED invocation up to 30 times over 24h. That is
    # right for a transient fault and actively harmful for a deterministic one
    # -- each retry can create and roll back a webhook, and those retries race
    # the daily timer. So: rethrow only what is worth retrying.
    $message = $_.Exception.Message
    $isPermanent = $message -match '(?i)(denied|forbidden|unauthorized|\b40[134]\b|not\s*registered|Missing required)'

    if ($isPermanent) {
        Write-Error ("Event-driven renewal FAILED permanently -- not retrying (Event Grid would repeat this " +
                     "up to 30 times): $message. The daily timer remains the backstop.")
        return
    }

    Write-Error "Event-driven renewal failed with a possibly transient error; allowing Event Grid to retry: $message"
    throw
}
