<#
.SYNOPSIS
    Creates the Entra app registration that signs users in to the registry UI.

.DESCRIPTION
    Run ONCE, by someone who can create app registrations (Application
    Administrator or higher) and can write secrets to the Key Vault. The
    Terraform service principal usually cannot, which is why this is a script.

    It:
      1. Creates the app registration with three app roles:
             Registry.Reader   view entries and state
             Registry.Editor   + create and update
             Registry.Admin    + delete
      2. Sets the sign-in redirect URI for Easy Auth.
      3. Creates the enterprise application (service principal) and turns on
         "Assignment required", so only people you assign a role can sign in.
      4. Creates a client secret and stores it STRAIGHT into Key Vault. It is
         never printed or written anywhere else.
      5. Optionally (-AllowAzCli) exposes an API scope and pre-authorises the
         Azure CLI, so scripts can get a token with `az account get-access-token`.

    It prints the client id to put in terraform.tfvars. It does not assign any
    roles -- use Grant-RegistryRole.ps1 for that.

    Requires: Azure CLI, signed in (`az login`) to the right tenant.

    NOT TESTED against a live tenant. Read it once before running, and expect to
    adjust if your tenant restricts app registration or Graph calls.

.PARAMETER AppHostname
    Hostname of the distributor Function App, e.g. func-wbhkrnw-dist-mb4x3.azurewebsites.net.
    Used for the sign-in redirect URI.

.PARAMETER VaultName
    Key Vault that will hold the client secret.

.PARAMETER GraphHost
    Microsoft Graph endpoint. Use https://graph.microsoft.us for Azure Government.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string] $AppHostname,
    [Parameter(Mandatory)] [string] $VaultName,
    [string] $DisplayName = 'Secret Registry',
    [string] $SecretName = 'registry-ui-client-secret',
    [string] $GraphHost = 'https://graph.microsoft.com',
    [switch] $AllowAzCli
)

$ErrorActionPreference = 'Stop'

function Invoke-Az {
    # Stops on failure with the CLI's own message, instead of carrying on with $null.
    $out = & az @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "az $($args -join ' ') failed:`n$out" }
    $out
}

# Fixed ids so the roles are identical if this is ever recreated.
$roles = @(
    @{ v = 'Registry.Reader'; n = 'Registry Reader'; d = 'View registry entries and what was last distributed.';        id = 'b8f3c1a0-5c1e-4d64-9a35-2f0e1c6a7d11' }
    @{ v = 'Registry.Editor'; n = 'Registry Editor'; d = 'View, create and update registry entries.';                    id = 'c2a4d9e1-7b3f-4f85-8e46-3a1f2d7b8e22' }
    @{ v = 'Registry.Admin';  n = 'Registry Admin';  d = 'View, create, update and delete registry entries.';           id = 'd5b6e0f2-8c4a-4a96-b057-4b2a3e8c9f33' }
) | ForEach-Object {
    [ordered]@{
        allowedMemberTypes = @('User')
        description        = $_.d
        displayName        = $_.n
        id                 = $_.id
        isEnabled          = $true
        value              = $_.v
    }
}

$tmp = New-Item -ItemType Directory -Path (Join-Path ([IO.Path]::GetTempPath()) "registry-auth-$([guid]::NewGuid())")
try {
    if (-not $PSCmdlet.ShouldProcess("tenant of the signed-in az account", "Create app registration '$DisplayName' with 3 roles, store its secret in $VaultName")) { return }

    $rolesFile = Join-Path $tmp 'roles.json'
    ConvertTo-Json -InputObject @($roles) -Depth 5 | Set-Content -Path $rolesFile -Encoding utf8

    Write-Host "Creating app registration '$DisplayName'..."
    $app = Invoke-Az ad app create --display-name $DisplayName --sign-in-audience AzureADMyOrg `
        --web-redirect-uris "https://$AppHostname/.auth/login/aad/callback" `
        --enable-id-token-issuance true --app-roles "@$rolesFile" -o json | ConvertFrom-Json
    $appId = $app.appId

    Invoke-Az ad app update --id $appId --identifier-uris "api://$appId" | Out-Null

    Write-Host 'Creating the enterprise application and requiring assignment...'
    $sp = Invoke-Az ad sp create --id $appId -o json | ConvertFrom-Json
    Invoke-Az ad sp update --id $sp.id --set appRoleAssignmentRequired=true | Out-Null

    Write-Host "Storing a client secret in Key Vault '$VaultName' as '$SecretName' (never displayed)..."
    $secretValue = Invoke-Az ad app credential reset --id $appId --display-name easyauth --years 1 --query password -o tsv
    $secretFile = Join-Path $tmp 'secret.txt'
    # A file rather than --value, so the secret is not visible in the process list.
    [IO.File]::WriteAllText($secretFile, ($secretValue | Out-String).Trim())
    Invoke-Az keyvault secret set --vault-name $VaultName --name $SecretName --file $secretFile `
        --expires (Get-Date).AddYears(1).AddDays(-7).ToString('yyyy-MM-ddTHH:mm:ssZ') | Out-Null
    Remove-Variable secretValue

    if ($AllowAzCli) {
        Write-Host 'Exposing an API scope and pre-authorising the Azure CLI...'
        $scopeId = 'e7c8f1a3-9d5b-4ba7-a168-5c3b4f9dae44'
        $graphApp = "$GraphHost/v1.0/applications(appId='$appId')"

        # Scope first, THEN pre-authorise it: Graph rejects a pre-authorisation
        # that points at a scope that does not exist yet.
        $scopeBody = @{ api = @{
            requestedAccessTokenVersion = 2
            oauth2PermissionScopes = @(@{
                id = $scopeId; value = 'access_as_user'; type = 'User'; isEnabled = $true
                adminConsentDisplayName = 'Use the secret registry'; adminConsentDescription = 'Call the secret registry API as the signed-in user.'
                userConsentDisplayName  = 'Use the secret registry'; userConsentDescription  = 'Call the secret registry API as you.'
            })
        } } | ConvertTo-Json -Depth 6
        $f1 = Join-Path $tmp 'scope.json'; Set-Content -Path $f1 -Value $scopeBody -Encoding utf8
        Invoke-Az rest --method PATCH --uri $graphApp --headers 'Content-Type=application/json' --body "@$f1" | Out-Null

        $preauth = @{ api = @{ preAuthorizedApplications = @(@{
            appId = '04b07795-8ddb-461a-bbee-02f9e1bf7b46'   # Azure CLI
            delegatedPermissionIds = @($scopeId)
        }) } } | ConvertTo-Json -Depth 6
        $f2 = Join-Path $tmp 'preauth.json'; Set-Content -Path $f2 -Value $preauth -Encoding utf8
        Invoke-Az rest --method PATCH --uri $graphApp --headers 'Content-Type=application/json' --body "@$f2" | Out-Null
    }
    else {
        Invoke-Az ad app update --id $appId --set api.requestedAccessTokenVersion=2 | Out-Null
    }

    Write-Host ''
    Write-Host 'Done. Next:' -ForegroundColor Green
    Write-Host "  1. Add to terraform.tfvars:   entra_client_id = `"$appId`""
    Write-Host "     (client secret name in Key Vault: $SecretName -- matches the default)"
    Write-Host '  2. Give the distributor app identity "Key Vault Secrets User" on the vault, if it does not already have it.'
    Write-Host '  3. terraform apply'
    Write-Host "  4. Assign roles:   ./Grant-RegistryRole.ps1 -ClientId $appId -Role Admin -User you@yourdomain.com"
    Write-Host "  The client secret expires in about a year; recreate it before then."
}
finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
