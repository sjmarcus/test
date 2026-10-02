<#
.SYNOPSIS
    Copies the legacy GITHUB-* Key Vault tags into the secret registry.

.DESCRIPTION
    Before the registry, distribution targets lived in tags on each secret:
        GITHUB-REPO, GITHUB-SECRET-NAME, GITHUB-TOKEN-SECRET (optional)
    This creates one registry entry per tagged secret, through the registry
    API -- never straight to Cosmos, so the same validation applies.

    Safe to re-run: an entry that already exists is skipped, not overwritten.
    The tags are left in place. DistributeSecret prefers the registry and only
    falls back to tags when there is no entry, so once an entry exists the tags
    are dead weight you can remove at leisure.

    Needs Az.KeyVault and a signed-in session (Connect-AzAccount) with
    permission to list secrets in the vault. It reads tags only, never values.

    AUTH: the API signs users in through Entra, so this needs an access token
    for the registry app, and the account it belongs to needs the Editor (or
    Admin) role. Get one with:

        az account get-access-token --scope api://<client-id>/access_as_user --query accessToken -o tsv

    (that scope exists only if Setup-RegistryAuth.ps1 was run with -AllowAzCli.)

.EXAMPLE
    $token = az account get-access-token --scope api://<client-id>/access_as_user --query accessToken -o tsv
    ./Import-TagsToRegistry.ps1 -VaultName kv-wbhkrnw-mb4x3 `
        -ApiBase https://func-wbhkrnw-dist-abc12.azurewebsites.net/api `
        -AccessToken $token -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string] $VaultName,
    [Parameter(Mandatory)] [string] $ApiBase,
    [Parameter(Mandatory)] [string] $AccessToken
)

$ErrorActionPreference = 'Stop'
$headers = @{ Authorization = "Bearer $AccessToken" }
$ApiBase = $ApiBase.TrimEnd('/')

$created = 0; $skipped = 0; $failed = 0

foreach ($secret in Get-AzKeyVaultSecret -VaultName $VaultName) {
    $tags = @{}
    foreach ($k in $secret.Tags.Keys) { $tags[$k.ToUpperInvariant()] = $secret.Tags[$k] }

    if (-not $tags['GITHUB-REPO'] -or -not $tags['GITHUB-SECRET-NAME']) { continue }

    $target = [ordered]@{
        type       = 'github-actions'
        repo       = $tags['GITHUB-REPO']
        secretName = $tags['GITHUB-SECRET-NAME']
    }
    if ($tags['GITHUB-TOKEN-SECRET']) { $target.tokenSecret = $tags['GITHUB-TOKEN-SECRET'] }

    $body = [ordered]@{ id = $secret.Name; enabled = $true; targets = @($target) } | ConvertTo-Json -Depth 5

    if (-not $PSCmdlet.ShouldProcess($secret.Name, "Create registry entry -> $($target.repo) / $($target.secretName)")) { continue }

    try {
        # No If-Match means create-only: a 412 means the entry is already there.
        Invoke-RestMethod -Method Put -Uri "$ApiBase/registry/$($secret.Name)" -Headers $headers `
            -ContentType 'application/json' -Body $body | Out-Null
        Write-Host "created  $($secret.Name)"
        $created++
    }
    catch {
        $status = $_.Exception.Response.StatusCode.value__
        if ($status -eq 412) { Write-Host "skipped  $($secret.Name) (already in registry)"; $skipped++ }
        else { Write-Warning "failed   $($secret.Name): HTTP $status $($_.ErrorDetails.Message)"; $failed++ }
    }
}

Write-Host "`nCreated $created, skipped $skipped, failed $failed."
if ($failed) { exit 1 }
