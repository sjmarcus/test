<#
.SYNOPSIS
    Imports the original team/repo JSON into the secret registry.

.DESCRIPTION
    Converts the original structure:

        { "<KEY>": { "Repos": [ { "Name", "EnvironmentName" } ],
                     "SubscriptionID": "...", "ClientID": "..." } }

    into one registry entry per top-level key, through the registry API so the
    same validation applies. Each repo becomes a github-environment target.

    ASSUMPTIONS -- check these before running without -WhatIf:
      * The top-level KEY is the Key Vault secret NAME. The registry id must be
        the secret name (that is how an Event Grid event finds its entry). If
        your secrets are named differently, pass -IdMap.
      * Every target writes the same GitHub secret name (-SecretName).
      * SubscriptionID / ClientID are optional; entries without them are fine.

    Safe to re-run: an entry that already exists is skipped, not overwritten.

    AUTH: the API signs users in through Entra, so this needs an access token
    for the registry app, and the account it belongs to needs the Editor (or
    Admin) role. Get one with:

        az account get-access-token --scope api://<client-id>/access_as_user --query accessToken -o tsv

    (that scope exists only if Setup-RegistryAuth.ps1 was run with -AllowAzCli.)

.PARAMETER IdMap
    Hashtable of JSON key -> Key Vault secret name, for keys that are not
    themselves the secret name. Keys not listed use the key as-is.

.EXAMPLE
    $token = az account get-access-token --scope api://<client-id>/access_as_user --query accessToken -o tsv
    ./Import-LegacyJsonToRegistry.ps1 -Path ./teams.json -SecretName AZURE_CLIENT_SECRET `
        -ApiBase https://func-x-dist-abc12.azurewebsites.net/api -AccessToken $token -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string] $Path,
    [Parameter(Mandatory)] [string] $ApiBase,
    [Parameter(Mandatory)] [string] $AccessToken,
    [string] $SecretName = 'AZURE_CLIENT_SECRET',
    [hashtable] $IdMap = @{}
)

$ErrorActionPreference = 'Stop'
$headers = @{ Authorization = "Bearer $AccessToken" }
$ApiBase = $ApiBase.TrimEnd('/')

$source = Get-Content -Raw -Path $Path | ConvertFrom-Json

$created = 0; $skipped = 0; $failed = 0

foreach ($prop in $source.PSObject.Properties) {
    $key   = $prop.Name
    $group = $prop.Value
    $id    = if ($IdMap.ContainsKey($key)) { $IdMap[$key] } else { $key }

    $targets = @(foreach ($r in $group.Repos) {
        [ordered]@{
            type        = 'github-environment'
            repo        = $r.Name
            environment = $r.EnvironmentName
            secretName  = $SecretName
        }
    })

    $entry = [ordered]@{ id = $id; displayName = $key; enabled = $true }
    # Some entries have no identity fields; leave them out rather than send nulls.
    if ($group.SubscriptionID) { $entry.subscriptionId = $group.SubscriptionID }
    if ($group.ClientID)       { $entry.clientId       = $group.ClientID }
    $entry.targets = $targets

    $body = $entry | ConvertTo-Json -Depth 6

    if (-not $PSCmdlet.ShouldProcess($id, "Create registry entry with $($targets.Count) target(s)")) { continue }

    try {
        # No If-Match means create-only: a 412 means the entry is already there.
        Invoke-RestMethod -Method Put -Uri "$ApiBase/registry/$id" -Headers $headers `
            -ContentType 'application/json' -Body $body | Out-Null
        Write-Host "created  $id ($($targets.Count) targets)"
        $created++
    }
    catch {
        $status = $_.Exception.Response.StatusCode.value__
        if ($status -eq 412) { Write-Host "skipped  $id (already in registry)"; $skipped++ }
        else { Write-Warning "failed   ${id}: HTTP $status $($_.ErrorDetails.Message)"; $failed++ }
    }
}

Write-Host "`nCreated $created, skipped $skipped, failed $failed."
if ($failed) { exit 1 }
