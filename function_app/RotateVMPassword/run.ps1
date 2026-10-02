<#
    On-demand VM password rotation.

    POST body (JSON), one of:
        { "secretName": "Team1VMPassword" }   rotate that one secret
        { "all": true }                        rotate every tagged secret
        { "listOnly": true }                   report targets, change nothing

    The VM and admin account come from the secret's VM-NAME and ADMIN-NAME
    tags -- this function does not need to be told which machine to touch.

    Function-key protected. This resets a live credential with no overlap
    window, so it is deliberately explicit: there is no "rotate everything"
    default, and listOnly exists so operators can see the blast radius first.
#>
param($Request, $TriggerMetadata)

Import-Module "$PSScriptRoot/../Modules/VMPasswordRotation/VMPasswordRotation.psm1" -Force

function Send-Response {
    param([int] $StatusCode, $Body)
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode  = $StatusCode
        ContentType = 'application/json'
        Body        = ($Body | ConvertTo-Json -Depth 6)
    })
}

$required = @('KEY_VAULT_URI')
$missing = $required | Where-Object { [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($_)) }
if ($missing) {
    Write-Error "Missing required app settings: $($missing -join ', ')."
    Send-Response -StatusCode 500 -Body @{ error = 'Function is misconfigured. See the function logs.' }
    return
}

$vaultUri  = $env:KEY_VAULT_URI
$vaultName = ([Uri]$vaultUri).Host.Split('.')[0]

$body       = $Request.Body
$secretName = $body.secretName
$rotateAll  = [bool]$body.all
$listOnly   = [bool]$body.listOnly

if (-not $secretName -and -not $rotateAll -and -not $listOnly) {
    Send-Response -StatusCode 400 -Body @{
        error = "Specify one of: secretName (rotate one), all=true (rotate every tagged secret), or listOnly=true (report targets without changing anything)."
    }
    return
}

try {
    # --- List mode: show what WOULD be rotated ---------------------------
    if ($listOnly) {
        $targets = @(Get-RotatableVMSecret -VaultName $vaultName)
        Write-Host "Found $($targets.Count) rotatable secret(s)."
        Send-Response -StatusCode 200 -Body @{
            count   = $targets.Count
            targets = $targets
        }
        return
    }

    # --- Determine scope -------------------------------------------------
    $scope = if ($secretName) {
        @([pscustomobject]@{ SecretName = $secretName })
    } else {
        @(Get-RotatableVMSecret -VaultName $vaultName)
    }

    if ($scope.Count -eq 0) {
        Send-Response -StatusCode 404 -Body @{ error = "No secrets tagged with VM-NAME and ADMIN-NAME were found in vault '$vaultName'." }
        return
    }

    Write-Host "Rotating $($scope.Count) secret(s)."

    # --- Rotate ----------------------------------------------------------
    # Each rotation is isolated: one VM being unreachable must not abandon
    # the rest. Collect per-secret outcomes and report them all.
    # Ternaries are PowerShell 7+ only; keep this explicit.
    $secretLifetimeDays = 90
    if (-not [string]::IsNullOrWhiteSpace($env:SECRET_LIFETIME_DAYS)) {
        $secretLifetimeDays = [int]$env:SECRET_LIFETIME_DAYS
    }

    $results = @()
    foreach ($item in $scope) {
        try {
            $r = Invoke-VMPasswordRotation `
                -KeyVaultUri $vaultUri `
                -SecretName $item.SecretName `
                -SecretLifetimeDays $secretLifetimeDays

            $results += [pscustomobject]@{
                secretName = $item.SecretName
                vmName     = $r.VMName
                username   = $r.Username
                rotated    = $true
                expiresUtc = $r.ExpiresUtc
            }
            Write-Host "Rotated '$($item.SecretName)' -> VM '$($r.VMName)'."
        }
        catch {
            # Do not leak the exception text to the caller -- Az messages
            # routinely carry subscription and principal identifiers.
            Write-Error "Rotation FAILED for '$($item.SecretName)': $($_.Exception.ToString())"
            $results += [pscustomobject]@{
                secretName = $item.SecretName
                rotated    = $false
                error      = 'Rotation failed. See the function logs for detail.'
            }
        }
    }

    $failed = @($results | Where-Object { -not $_.rotated }).Count
    $code   = if ($failed -eq 0) { 200 } elseif ($failed -eq $results.Count) { 500 } else { 207 }

    Send-Response -StatusCode $code -Body @{
        requested = $results.Count
        rotated   = $results.Count - $failed
        failed    = $failed
        results   = $results
    }
}
catch {
    Write-Error "RotateVMPassword failed: $($_.Exception.ToString())"
    Send-Response -StatusCode 500 -Body @{ error = 'Rotation request failed. See the function logs for detail.' }
}
