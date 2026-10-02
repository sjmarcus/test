# Runs once per PowerShell worker at startup, BEFORE any function is indexed.
#
# Everything here is wrapped in try/catch on purpose: an unhandled throw in
# this file takes down worker startup, and a host that cannot start indexes
# NO functions at all. That failure mode is badly misleading -- the portal
# still lists the functions (it reads deployed metadata), but the runtime
# serves nothing, so Event Grid endpoint validation fails with a bare 404 /
# NotFound and the app looks deployed-but-empty.
#
# Connect-AzAccount depends on Az.Accounts being restored from the gallery
# via requirements.psd1. On a cold consumption plan that restore can be slow
# or fail outright, so it must never be load-bearing for startup.
if ($env:MSI_SECRET -or $env:IDENTITY_ENDPOINT) {
    try {
        Disable-AzContextAutosave -Scope Process | Out-Null
        # AZURE_ENVIRONMENT is AzureCloud or AzureUSGovernment (set by Terraform).
        # Unset keeps the module default, which is commercial Azure.
        $connectArgs = @{ Identity = $true; Subscription = $env:SUBSCRIPTION_ID }
        if ($env:AZURE_ENVIRONMENT) { $connectArgs.Environment = $env:AZURE_ENVIRONMENT }
        Connect-AzAccount @connectArgs | Out-Null
        Write-Host "profile.ps1: connected to Azure with the managed identity."
    }
    catch {
        # Deliberately non-fatal. Individual invocations will fail with a
        # clearer error than a silent host that never starts.
        Write-Warning "profile.ps1: Connect-AzAccount failed at startup: $($_.Exception.Message)"
        Write-Warning "profile.ps1: continuing so functions still index; invocations needing Azure will fail until this resolves."
    }
}
else {
    Write-Host "profile.ps1: no managed identity endpoint (MSI_SECRET/IDENTITY_ENDPOINT unset) -- skipping sign-in (expected when running locally)."
}
