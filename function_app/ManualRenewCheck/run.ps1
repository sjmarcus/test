<#
    TEST-ONLY convenience trigger. Event Grid's SecretNearExpiry check isn't
    instant after deploy, so this lets you POST to the function directly and
    exercise the exact same renewal logic without waiting on it. Protected
    by function-key auth (see function.json). Not meant to stick around
    once Event Grid is confirmed working end to end -- delete this folder
    when you're done validating.
#>
param($Request, $TriggerMetadata)

Import-Module "$PSScriptRoot/../Modules/WebhookRenewal/WebhookRenewal.psm1" -Force

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

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = 200
        Body       = "Renewal check completed. Check the Application Insights traces for which branch ran -- a 200 here only means no error was thrown, NOT that anything was renewed."
    })
}
catch {
    # Log the full exception, but do not echo it to the caller: Az exception
    # messages routinely embed subscription IDs, resource paths and principal
    # object IDs.
    Write-Error "ManualRenewCheck failed: $($_.Exception.ToString())"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = 500
        Body       = "Renewal check failed. See the function's Application Insights traces for details."
    })
}
