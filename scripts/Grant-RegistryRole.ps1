<#
.SYNOPSIS
    Assigns a registry role to a user or group.

.DESCRIPTION
    Adds the person (or group) to one of the registry app's roles. The app
    registration has "Assignment required" on, so someone with no assignment
    cannot sign in at all; someone assigned Reader can only view.

        Reader   view entries and state
        Editor   + create and update
        Admin    + delete

    Run by someone who can manage the enterprise application (Application
    Administrator, or an owner of the app).

    Assigning a GROUP to an app role needs Entra ID P1 or higher. On a free
    tenant, assign individual users.

    Role changes take effect at the person's next sign-in, not instantly: the
    role is carried in their token. To revoke, remove the assignment in the
    portal (Enterprise applications > the app > Users and groups).

    Requires: Azure CLI, signed in (`az login`).

.EXAMPLE
    ./Grant-RegistryRole.ps1 -ClientId <app-id> -Role Admin  -User me@contoso.com
    ./Grant-RegistryRole.ps1 -ClientId <app-id> -Role Reader -Group 'Registry Readers'
#>
[CmdletBinding(DefaultParameterSetName = 'User', SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string] $ClientId,
    [Parameter(Mandatory)] [ValidateSet('Reader', 'Editor', 'Admin')] [string] $Role,
    [Parameter(Mandatory, ParameterSetName = 'User')]  [string] $User,
    [Parameter(Mandatory, ParameterSetName = 'Group')] [string] $Group,
    [string] $GraphHost = 'https://graph.microsoft.com'
)

$ErrorActionPreference = 'Stop'

function Invoke-Az {
    $out = & az @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "az $($args -join ' ') failed:`n$out" }
    $out
}

$spId = (Invoke-Az ad sp show --id $ClientId --query id -o tsv).Trim()
$roleId = (Invoke-Az ad app show --id $ClientId --query "appRoles[?value=='Registry.$Role'].id | [0]" -o tsv).Trim()
if (-not $roleId) { throw "Role 'Registry.$Role' not found on app $ClientId. Was Setup-RegistryAuth.ps1 run?" }

if ($PSCmdlet.ParameterSetName -eq 'User') {
    $principalId = (Invoke-Az ad user show --id $User --query id -o tsv).Trim()
    $label = $User
}
else {
    $principalId = (Invoke-Az ad group show --group $Group --query id -o tsv).Trim()
    $label = "group '$Group'"
}

if (-not $PSCmdlet.ShouldProcess($label, "Assign Registry.$Role")) { return }

$body = @{ principalId = $principalId; resourceId = $spId; appRoleId = $roleId } | ConvertTo-Json
$file = New-TemporaryFile
try {
    Set-Content -Path $file -Value $body -Encoding utf8
    & az rest --method POST --uri "$GraphHost/v1.0/servicePrincipals/$spId/appRoleAssignedTo" `
        --headers 'Content-Type=application/json' --body "@$file" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        # Re-run to surface the real message, and treat "already assigned" as success.
        $err = & az rest --method POST --uri "$GraphHost/v1.0/servicePrincipals/$spId/appRoleAssignedTo" `
            --headers 'Content-Type=application/json' --body "@$file" 2>&1 | Out-String
        if ($err -match 'already exists') { Write-Host "$label already has Registry.$Role."; return }
        throw "Assignment failed:`n$err"
    }
    Write-Host "Assigned Registry.$Role to $label. It applies at their next sign-in."
}
finally { Remove-Item $file -ErrorAction SilentlyContinue }
