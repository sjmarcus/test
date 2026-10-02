<#
.SYNOPSIS
    Runs terraform init/plan/apply using service principal auth, for boxes
    without `az login` available.

.DESCRIPTION
    Loads the service principal's client ID, secret, tenant ID, and
    subscription ID from .env.ps1 in this folder if it exists (copy
    .env.ps1.example to .env.ps1 and fill in real values -- it's gitignored
    and never committed). Falls back to an interactive masked prompt if
    .env.ps1 isn't present. Either way, the values are exported as ARM_*
    environment variables for this process only and cleared when the script
    exits.

    Re-run with -Apply to actually apply after reviewing the plan.

.PARAMETER Apply
    Run `terraform apply` (with approval prompt) instead of just `plan`.

.PARAMETER Destroy
    Run `terraform destroy` instead of plan/apply.

.PARAMETER Workspace
    Terraform workspace to select (created if missing). Use a separate one per
    cloud, e.g. `-Workspace gov`, so the Gov deployment gets its own state
    instead of trying to reconcile the commercial one.

.PARAMETER VarFile
    Extra variable file, e.g. gov.tfvars. Applied after terraform.tfvars, so it
    overrides any value both set.

.EXAMPLE
    ./deploy.ps1
    Runs init + plan only.

.EXAMPLE
    ./deploy.ps1 -Apply
    Runs init + plan + apply.
#>
param(
    [switch]$Apply,
    [switch]$Destroy,
    [string]$Workspace = "",
    [string]$VarFile = ""
)

$ErrorActionPreference = "Stop"

Push-Location $PSScriptRoot
try {
    $envFile = Join-Path $PSScriptRoot ".env.ps1"

    if (Test-Path $envFile) {
        Write-Host "Loading service principal credentials from .env.ps1." -ForegroundColor Cyan
        . $envFile

        $clientId       = $script:SpClientId
        $plainSecret    = $script:SpClientSecret
        $tenantId       = $script:SpTenantId
        $subscriptionId = $script:SpSubscriptionId
    }
    else {
        Write-Host "Service principal authentication for Terraform (azurerm provider)." -ForegroundColor Cyan
        Write-Host "No .env.ps1 found -- prompting instead. Copy .env.ps1.example to .env.ps1 to skip this next time." -ForegroundColor DarkGray

        $clientId       = Read-Host "Client ID (app/client ID)"
        $clientSecretSecure = Read-Host "Client secret" -AsSecureString
        $tenantId       = Read-Host "Tenant ID"
        $subscriptionId = Read-Host "Subscription ID"

        $plainSecret = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($clientSecretSecure)
        )
    }

    if ([string]::IsNullOrWhiteSpace($clientId) -or [string]::IsNullOrWhiteSpace($tenantId) -or [string]::IsNullOrWhiteSpace($subscriptionId)) {
        throw "Client ID, tenant ID, and subscription ID are all required."
    }
    if ([string]::IsNullOrWhiteSpace($plainSecret)) {
        throw "Client secret is required."
    }

    $env:ARM_CLIENT_ID       = $clientId
    $env:ARM_CLIENT_SECRET   = $plainSecret
    $env:ARM_TENANT_ID       = $tenantId
    $env:ARM_SUBSCRIPTION_ID = $subscriptionId
    $plainSecret = $null

    terraform init
    if ($LASTEXITCODE -ne 0) { throw "terraform init failed." }

    if ($Workspace) {
        terraform workspace select -or-create $Workspace
        if ($LASTEXITCODE -ne 0) { throw "terraform workspace select failed." }
    }

    $varArgs = @()
    if ($VarFile) {
        if (-not (Test-Path $VarFile)) { throw "Var file '$VarFile' not found." }
        $varArgs += "-var-file=$VarFile"
    }

    if ($Destroy) {
        terraform destroy @varArgs
    }
    elseif ($Apply) {
        terraform apply @varArgs
    }
    else {
        terraform plan @varArgs
        Write-Host "`nPlan-only run. Re-run with -Apply to apply, or -Destroy to tear down." -ForegroundColor Yellow
    }
    if ($LASTEXITCODE -ne 0) { throw "terraform command failed." }
}
finally {
    Remove-Item Env:\ARM_CLIENT_ID, Env:\ARM_CLIENT_SECRET, Env:\ARM_TENANT_ID, Env:\ARM_SUBSCRIPTION_ID -ErrorAction SilentlyContinue
    Pop-Location
}
