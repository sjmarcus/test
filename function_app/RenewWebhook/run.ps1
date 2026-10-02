param($Timer)

# Reconciliation authority: this daily run is what actually guarantees
# renewal. The Event Grid handler is only a fast path.
#
# Timer triggers are NOT retried by the platform, so an unhandled throw here
# is a silently missed renewal -- there is no second attempt until tomorrow.
# Catch, log loudly, and rethrow so the invocation is still marked failed
# (that is the only thing an alert rule can bind to).

Import-Module "$PSScriptRoot/../Modules/WebhookRenewal/WebhookRenewal.psm1" -Force

$required = @(
    'SUBSCRIPTION_ID', 'AUTOMATION_ACCOUNT_RESOURCE_GROUP', 'AUTOMATION_ACCOUNT_NAME',
    'RUNBOOK_NAME', 'WEBHOOK_NAME', 'KEY_VAULT_URI', 'KEY_VAULT_SECRET_NAME', 'RENEWAL_LEAD_DAYS'
)
$missing = $required | Where-Object { [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($_)) }
if ($missing) {
    # Without this, [int]$null silently becomes 0 lead-days -- every webhook
    # then looks "outside the window" and the timer no-ops forever while
    # appearing healthy. The Mandatory params would also block on a prompt.
    throw "Missing required app settings: $($missing -join ', '). Refusing to run with defaulted values."
}

if ($Timer.IsPastDue) {
    Write-Warning "Timer invocation is past due -- the schedule was missed and this is a catch-up run."
}

try {
    Invoke-WebhookRenewalCheck `
        -SubscriptionId $env:SUBSCRIPTION_ID `
        -AutomationResourceGroup $env:AUTOMATION_ACCOUNT_RESOURCE_GROUP `
        -AutomationAccountName $env:AUTOMATION_ACCOUNT_NAME `
        -RunbookName $env:RUNBOOK_NAME `
        -WebhookName $env:WEBHOOK_NAME `
        -KeyVaultUri $env:KEY_VAULT_URI `
        -KeyVaultSecretName $env:KEY_VAULT_SECRET_NAME `
        -RenewalLeadDays ([int]$env:RENEWAL_LEAD_DAYS)

    Write-Host "Scheduled renewal check completed successfully."
}
catch {
    Write-Error "SCHEDULED RENEWAL CHECK FAILED: $($_.Exception.Message)"
    Write-Error "No retry will occur until the next scheduled run. If this repeats, the webhook will lapse."
    throw
}
