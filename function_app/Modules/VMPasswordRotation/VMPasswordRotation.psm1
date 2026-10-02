<#
    VM local administrator password rotation.

    ORDERING IS THE WHOLE DESIGN. Unlike the webhook renewal in
    WebhookRenewal.psm1, which creates a resource and then stores its
    credential, this writes to Key Vault FIRST and only then applies the
    password to the VM.

    The reason: a VM password reset has no overlap window and no rollback.
    If the reset succeeded and the Key Vault write then failed, the VM would
    be live with a password nobody knows -- unrecoverable without a support
    path. Writing first means the worst case is a Key Vault version that is
    one step ahead of the VM, which the next run reconciles by simply
    applying it again (the reset is idempotent).

    So: generate -> store -> apply. A failure after storing is recoverable.
    A failure after applying, had we stored second, would not be.
#>

Set-StrictMode -Version Latest

function New-RotatedPassword {
    <#
        Generates a password that satisfies the Azure VM complexity rules:
        12-123 chars, and at least 3 of {lowercase, uppercase, digit,
        special}. We always include all four.

        Uses RNGCryptoServiceProvider rather than Get-Random -- the latter is
        seeded pseudo-randomness and is not appropriate for a credential.
    #>
    [CmdletBinding()]
    param(
        [ValidateRange(12, 123)]
        [int] $Length = 32
    )

    # Deliberately excludes characters Azure rejects or that commonly break
    # shells, connection strings and CSV exports: " ' ` \ / < > & | ; $ %
    $lower   = 'abcdefghijkmnopqrstuvwxyz'      # no 'l'
    $upper   = 'ABCDEFGHJKLMNPQRSTUVWXYZ'       # no 'I', no 'O'
    $digit   = '23456789'                       # no '0', no '1'
    $special = '!#*+-=?@_~'
    $all     = $lower + $upper + $digit + $special

    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        # Guarantee one of each class, then fill the remainder.
        $chars = @(
            Get-RandomChar -Pool $lower   -Rng $rng
            Get-RandomChar -Pool $upper   -Rng $rng
            Get-RandomChar -Pool $digit   -Rng $rng
            Get-RandomChar -Pool $special -Rng $rng
        )
        for ($i = $chars.Count; $i -lt $Length; $i++) {
            $chars += Get-RandomChar -Pool $all -Rng $rng
        }

        # Shuffle so the guaranteed characters are not always in positions
        # 0-3, which would make the first four characters predictable in class.
        $shuffled = $chars | Sort-Object { Get-RandomInt -MaxExclusive 65536 -Rng $rng }
        return -join $shuffled
    }
    finally {
        $rng.Dispose()
    }
}

function Get-RandomInt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [int] $MaxExclusive,
        [Parameter(Mandatory)] [System.Security.Cryptography.RandomNumberGenerator] $Rng
    )
    # Rejection sampling: taking a raw value modulo $MaxExclusive biases the
    # low end whenever the range does not divide evenly into 2^32.
    $bytes = [byte[]]::new(4)
    $limit = [uint32]::MaxValue - ([uint32]::MaxValue % $MaxExclusive) - 1
    do {
        $Rng.GetBytes($bytes)
        $value = [BitConverter]::ToUInt32($bytes, 0)
    } while ($value -gt $limit)
    return [int]($value % $MaxExclusive)
}

function Get-RandomChar {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Pool,
        [Parameter(Mandatory)] [System.Security.Cryptography.RandomNumberGenerator] $Rng
    )
    return $Pool[(Get-RandomInt -MaxExclusive $Pool.Length -Rng $Rng)]
}

function Get-VMOrNull {
    <#
        Returns the VM, or $null ONLY when Azure genuinely reports it does not
        exist. Every other failure -- 401/403, 429, 5xx, no Az context --
        rethrows.

        Same reasoning as Get-AutomationWebhookOrNull in WebhookRenewal.psm1:
        a masked permission error that looks like "not found" leads callers
        into a destructive branch.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ResourceGroupName,
        [Parameter(Mandatory)] [string] $Name
    )

    try {
        return Get-AzVM -ResourceGroupName $ResourceGroupName -Name $Name -ErrorAction Stop
    }
    catch {
        $status = $null
        try { $status = $_.Exception.Response.StatusCode.value__ } catch { }

        $notFound = ($status -eq 404) -or
                    ($_.Exception.Message -match '(?i)\b(not\s*found|does\s*not\s*exist|could\s*not\s*be\s*found)\b')

        if ($notFound) { return $null }

        throw "Cannot determine whether VM '$Name' exists (status: $(if ($status) { $status } else { 'unknown' })): $($_.Exception.Message)"
    }
}

function Resolve-VMTargetFromSecret {
    <#
        The Key Vault secret is the source of truth for which VM it belongs
        to. Two tags carry that link:

            VM-NAME     the VM the password is for
            ADMIN-NAME  the local account the password belongs to

        Resolving from tags rather than the secret NAME is deliberate. Parsing
        "Team1VMPassword" to infer a VM is fragile -- a rename or a typo
        silently points the rotation at the wrong machine, or at none. Tags
        are explicit, queryable, and can be corrected without recreating the
        secret.

        The VM's resource group is resolved by lookup rather than stored, so
        a VM that moves does not strand its secret with a stale value.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $VaultName,
        [Parameter(Mandatory)] [string] $SecretName
    )

    $secret = Get-AzKeyVaultSecret -VaultName $VaultName -Name $SecretName -ErrorAction Stop
    if (-not $secret) {
        throw "Secret '$SecretName' not found in vault '$VaultName'."
    }

    $tags = $secret.Tags
    if (-not $tags) {
        throw "Secret '$SecretName' has no tags. It must carry VM-NAME and ADMIN-NAME to be rotated."
    }

    # Key Vault tag keys are case-sensitive on read, but operators are not.
    # Accept any casing rather than failing on 'vm-name' vs 'VM-NAME'.
    # Pull the entries out before dereferencing: under Set-StrictMode, .Value
    # on a null (no match) throws instead of returning $null.
    $vmEntry    = $tags.GetEnumerator() | Where-Object { $_.Key -ieq 'VM-NAME' }    | Select-Object -First 1
    $adminEntry = $tags.GetEnumerator() | Where-Object { $_.Key -ieq 'ADMIN-NAME' } | Select-Object -First 1

    $vmName    = if ($vmEntry)    { $vmEntry.Value }    else { $null }
    $adminName = if ($adminEntry) { $adminEntry.Value } else { $null }

    $missing = @()
    if ([string]::IsNullOrWhiteSpace($vmName))    { $missing += 'VM-NAME' }
    if ([string]::IsNullOrWhiteSpace($adminName)) { $missing += 'ADMIN-NAME' }
    if ($missing) {
        throw "Secret '$SecretName' is missing required tag(s): $($missing -join ', '). Cannot determine the rotation target."
    }

    # Locate the VM by name across the subscription. Get-AzVM without a
    # resource group returns all VMs; match on name.
    $matches = @(Get-AzVM -ErrorAction Stop | Where-Object { $_.Name -ieq $vmName })

    if ($matches.Count -eq 0) {
        throw "Secret '$SecretName' targets VM '$vmName' (tag VM-NAME) but no such VM is visible to this identity."
    }
    if ($matches.Count -gt 1) {
        # Ambiguous: the same VM name in two resource groups. Refuse rather
        # than guess -- resetting the wrong machine's password is not
        # recoverable by re-running.
        $groups = ($matches | ForEach-Object { $_.ResourceGroupName }) -join ', '
        throw "Secret '$SecretName' targets VM '$vmName', but that name exists in multiple resource groups ($groups). Cannot resolve unambiguously."
    }

    return [pscustomobject]@{
        VMName          = $matches[0].Name
        VMResourceGroup = $matches[0].ResourceGroupName
        AdminUsername   = $adminName
        SecretName      = $SecretName
    }
}

function Invoke-VMPasswordRotation {
    <#
        Rotates one VM's local administrator password.

        The VM and admin account are resolved from the secret's VM-NAME and
        ADMIN-NAME tags unless passed explicitly.

        Writes the new password to Key Vault as a new secret version, then
        applies it to the VM via the VMAccess extension. See the file header
        for why that order is not negotiable.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $KeyVaultUri,
        [Parameter(Mandatory)] [string] $SecretName,

        # Optional overrides. When omitted, both are read from the secret's
        # tags -- which is the normal path.
        [string] $VMName,
        [string] $VMResourceGroup,
        [string] $AdminUsername,

        [int] $PasswordLength = 32,

        # Expiry stamped on the new secret version -- NOT the rotation
        # cadence. Key Vault fires SecretNearExpiry 30 days before expiry, and
        # that event is what triggers the next rotation, so:
        #
        #     rotation cadence = SecretLifetimeDays - 30
        #
        # 90 here gives a 60-day rotation. Setting this to 60 would give a
        # 30-day rotation, not 60 -- the offset is easy to get wrong, which is
        # why this is named for what it sets rather than what it produces.
        [int] $SecretLifetimeDays = 90
    )

    $vaultName = ([Uri]$KeyVaultUri).Host.Split('.')[0]

    if (-not $VMName -or -not $AdminUsername -or -not $VMResourceGroup) {
        $target = Resolve-VMTargetFromSecret -VaultName $vaultName -SecretName $SecretName
        if (-not $VMName)          { $VMName          = $target.VMName }
        if (-not $VMResourceGroup) { $VMResourceGroup = $target.VMResourceGroup }
        if (-not $AdminUsername)   { $AdminUsername   = $target.AdminUsername }
        Write-Host "Resolved from tags: VM '$VMName' in '$VMResourceGroup', account '$AdminUsername'."
    }

    # --- Preflight -------------------------------------------------------
    # Check the VM is reachable and healthy BEFORE generating or storing
    # anything. A reset against a stopped VM or a dead guest agent fails, and
    # we would rather not have written a password we cannot apply.
    $vm = Get-VMOrNull -ResourceGroupName $VMResourceGroup -Name $VMName
    if (-not $vm) {
        throw "VM '$VMName' not found in resource group '$VMResourceGroup'. Nothing was generated or stored."
    }

    $status = Get-AzVM -ResourceGroupName $VMResourceGroup -Name $VMName -Status -ErrorAction Stop
    $powerState = ($status.Statuses | Where-Object { $_.Code -like 'PowerState/*' } | Select-Object -First 1).Code

    if ($powerState -ne 'PowerState/running') {
        throw "VM '$VMName' is '$powerState', not running. The VMAccess extension requires a running VM with a healthy guest agent. Nothing was generated or stored."
    }

    $agentStatus = $status.VMAgent.Statuses | Where-Object { $_.Code -like 'ProvisioningState/*' } | Select-Object -First 1
    if ($agentStatus -and $agentStatus.Code -notlike '*succeeded*') {
        Write-Warning "VM '$VMName' guest agent reports '$($agentStatus.Code)'. The reset may fail."
    }

    $osType = $vm.StorageProfile.OsDisk.OsType
    Write-Host "VM '$VMName' is running ($osType). Rotating password for account '$AdminUsername'."

    if (-not $PSCmdlet.ShouldProcess("$VMName/$AdminUsername", "Rotate local administrator password")) {
        return [pscustomobject]@{ VMName = $VMName; Action = 'WhatIf'; Rotated = $false }
    }

    # Read the current tags so they can be carried onto the new version. Tags
    # are per-version and Set-AzKeyVaultSecret replaces rather than merges, so
    # without this every rotation drops any tag rotation does not own itself.
    $existingTags = $null
    try {
        $currentSecret = Get-AzKeyVaultSecret -VaultName $vaultName -Name $SecretName -ErrorAction Stop
        if ($currentSecret) { $existingTags = $currentSecret.Tags }
    }
    catch {
        # Non-fatal: a first rotation has no prior version to read. Losing
        # tags that were never there costs nothing.
        Write-Warning "Could not read existing tags on '$SecretName' to preserve them: $($_.Exception.Message)"
    }

    # --- Generate --------------------------------------------------------
    $newPassword = New-RotatedPassword -Length $PasswordLength
    $expiry      = (Get-Date).ToUniversalTime().AddDays($SecretLifetimeDays)

    try {
        $secureValue = ConvertTo-SecureString -String $newPassword -AsPlainText -Force

        # --- Store FIRST -------------------------------------------------
        # If this fails, nothing has changed on the VM. The old password is
        # still valid and still the one in Key Vault. Safe to abort.
        try {
            # CRITICAL: Set-AzKeyVaultSecret REPLACES the tag collection on the
            # new version rather than merging into it. Anything not passed here
            # is silently lost.
            #
            # That means rotation must NOT write a fixed set of tags. Other
            # systems attach their own -- GITHUB-REPO / GITHUB-SECRET-NAME for
            # distribution, LAST-PUSHED-* written back by the distributor --
            # and a rotation that only knew about its own tags would wipe them
            # every cycle. The symptom is subtle: rotation keeps working, and
            # distribution silently stops, because the secret no longer
            # declares where it should be published.
            #
            # So: carry every existing tag forward, then overwrite only the
            # ones rotation owns.
            $tagsToWrite = @{}
            if ($existingTags) {
                foreach ($kvp in $existingTags.GetEnumerator()) { $tagsToWrite[$kvp.Key] = $kvp.Value }
            }
            $tagsToWrite['VM-NAME']       = $VMName
            $tagsToWrite['ADMIN-NAME']    = $AdminUsername
            $tagsToWrite['resourceGroup'] = $VMResourceGroup
            $tagsToWrite['osType']        = [string]$osType
            $tagsToWrite['rotatedUtc']    = (Get-Date).ToUniversalTime().ToString('o')

            Set-AzKeyVaultSecret -VaultName $vaultName -Name $SecretName `
                -SecretValue $secureValue -Expires $expiry `
                -ContentType 'vm-local-admin-password' `
                -Tag $tagsToWrite `
                -ErrorAction Stop | Out-Null
        }
        catch {
            throw ("Key Vault write failed for '$SecretName' -- the VM password was NOT changed and the existing " +
                   "credential remains valid: $($_.Exception.Message)")
        }

        Write-Host "New password stored as a new version of secret '$SecretName' (expires $expiry UTC)."

        # --- Then apply --------------------------------------------------
        # From here a failure leaves Key Vault one step ahead of the VM. That
        # is the recoverable direction: the stored password is either already
        # live or will be applied by the next run, and the reset is
        # idempotent. Say so explicitly rather than failing quietly.
        try {
            # NB: Az.Compute 11.x takes -Credential (a PSCredential), NOT the
            # -Username/-Password pair older docs and examples show. Passing
            # those throws "A parameter cannot be found that matches parameter
            # name 'Username'". -Location is also required.
            $credential = New-Object System.Management.Automation.PSCredential(
                $AdminUsername,
                (ConvertTo-SecureString -String $newPassword -AsPlainText -Force)
            )

            Set-AzVMAccessExtension `
                -ResourceGroupName $VMResourceGroup `
                -VMName $VMName `
                -Name 'enablevmaccess' `
                -Location $vm.Location `
                -Credential $credential `
                -TypeHandlerVersion $(if ($osType -eq 'Windows') { '2.4' } else { '1.5' }) `
                -ForceRerun ([guid]::NewGuid().ToString()) `
                -ErrorAction Stop | Out-Null
        }
        catch {
            throw ("DRIFT: the new password is stored in Key Vault secret '$SecretName' but applying it to VM " +
                   "'$VMName' failed: $($_.Exception.Message). The VM may still be on the PREVIOUS password. " +
                   "Re-run to reapply -- the reset is idempotent and the stored value is authoritative.")
        }

        Write-Host "Password applied to '$VMName' via the VMAccess extension."

        return [pscustomobject]@{
            VMName     = $VMName
            SecretName = $SecretName
            Username   = $AdminUsername
            Rotated    = $true
            ExpiresUtc = $expiry
        }
    }
    finally {
        # Reduce the window the plaintext sits in memory. The worker process
        # is reused across invocations on a consumption plan.
        if (Get-Variable -Name newPassword -Scope 0 -ErrorAction SilentlyContinue) {
            Set-Variable -Name newPassword -Value $null -Scope 0
        }
        [System.GC]::Collect()
    }
}

function Get-RotatableVMSecret {
    <#
        Lists every secret in the vault carrying both VM-NAME and ADMIN-NAME,
        i.e. everything this rotation is responsible for.

        This is what makes the design scale across teams without a config
        file: adding Team7VMPassword with the two tags is enough to enrol it.
        Nothing needs redeploying.

        Note Get-AzKeyVaultSecret's list form returns tags, so this does not
        need a per-secret round trip.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $VaultName,

        # Optional: restrict to one team's secrets by tag value.
        [string] $VMNameFilter
    )

    $all = Get-AzKeyVaultSecret -VaultName $VaultName -ErrorAction Stop

    foreach ($s in $all) {
        # Secrets with no tags at all, or with an empty tag collection (the
        # webhook secret has {}), are simply not ours.
        if (-not $s.PSObject.Properties['Tags'] -or -not $s.Tags -or $s.Tags.Count -eq 0) { continue }

        # Select-Object -First 1 returns $null when nothing matches, and under
        # Set-StrictMode -Version Latest dereferencing .Value on $null throws
        # rather than yielding $null. Pull the match out first.
        $vmEntry    = $s.Tags.GetEnumerator() | Where-Object { $_.Key -ieq 'VM-NAME' }    | Select-Object -First 1
        $adminEntry = $s.Tags.GetEnumerator() | Where-Object { $_.Key -ieq 'ADMIN-NAME' } | Select-Object -First 1

        if (-not $vmEntry -or -not $adminEntry) { continue }

        $vmName    = $vmEntry.Value
        $adminName = $adminEntry.Value

        if ([string]::IsNullOrWhiteSpace($vmName) -or [string]::IsNullOrWhiteSpace($adminName)) { continue }
        if ($VMNameFilter -and $vmName -ine $VMNameFilter) { continue }

        [pscustomobject]@{
            SecretName    = $s.Name
            VMName        = $vmName
            AdminUsername = $adminName
            Enabled       = $s.Enabled
            ExpiresUtc    = $s.Expires
            UpdatedUtc    = $s.Updated
        }
    }
}

Export-ModuleMember -Function Invoke-VMPasswordRotation, New-RotatedPassword, Get-RotatableVMSecret, Resolve-VMTargetFromSecret
