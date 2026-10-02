<#
    Core renewal logic shared by two triggers:
      - RenewWebhook (timer, daily)      -> the reconciliation authority. Runs
                                            the lead-day window check, so it
                                            no-ops cheaply until T-14.
      - OnSecretNearExpiry (Event Grid)  -> early fast-path. Passes
                                            -TriggeredByExpiryEvent, which
                                            bypasses the window check, because
                                            SecretNearExpiry fires once at T-30
                                            and never repeats for that secret
                                            version.

    Renewal has two branches:
      - Webhook still has time left           -> extend expiryTime in place
                                                   via the ARM REST API (the
                                                   Az.Automation module has no
                                                   cmdlet for this). URL is
                                                   unchanged, so only the Key
                                                   Vault secret's `Expires`
                                                   attribute needs updating.
      - Webhook missing or already expired    -> create a brand-new webhook
                                                   (expired ones can't be
                                                   revived), store the new URL
                                                   as the secret VALUE, and
                                                   flag it loudly since any
                                                   caller with the old URL
                                                   hardcoded will now fail.
#>

function Get-AutomationWebhookOrNull {
    <#
        Returns the webhook, or $null ONLY when Azure genuinely reports it does
        not exist. Every other failure -- 401/403, 429, 5xx, no Az context --
        rethrows, because callers treat $null as "create a replacement" and
        that path invalidates the live webhook URL.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ResourceGroupName,
        [Parameter(Mandatory)] [string] $AutomationAccountName,
        [Parameter(Mandatory)] [string] $Name
    )

    try {
        $result = Get-AzAutomationWebhook `
            -ResourceGroupName $ResourceGroupName `
            -AutomationAccountName $AutomationAccountName `
            -Name $Name `
            -ErrorAction Stop
    }
    catch {
        $status = $null
        try { $status = $_.Exception.Response.StatusCode.value__ } catch { }

        $notFound = ($status -eq 404) -or
                    ($_.Exception.Message -match '(?i)\b(not\s*found|does\s*not\s*exist|could\s*not\s*be\s*found)\b')

        if ($notFound) { return $null }

        throw "Cannot determine whether webhook '$Name' exists (status: $(if ($status) { $status } else { 'unknown' })): $($_.Exception.Message)"
    }

    # -Name can still match nothing without erroring, and could in principle
    # return a collection. Normalise both to a single object or $null.
    if (-not $result) { return $null }
    if ($result -is [array]) {
        if ($result.Count -eq 0) { return $null }
        if ($result.Count -gt 1) { throw "Expected one webhook named '$Name' but Azure returned $($result.Count)." }
        return $result[0]
    }
    return $result
}

function Invoke-WebhookRenewalCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $SubscriptionId,
        [Parameter(Mandatory)] [string] $AutomationResourceGroup,
        [Parameter(Mandatory)] [string] $AutomationAccountName,
        [Parameter(Mandatory)] [string] $RunbookName,
        [Parameter(Mandatory)] [string] $WebhookName,
        [Parameter(Mandatory)] [string] $KeyVaultUri,
        [Parameter(Mandatory)] [string] $KeyVaultSecretName,
        [int] $RenewalLeadDays = 14,
        [int] $NewWebhookLifetimeDays = 90,

        # Set by the Event Grid trigger only. SecretNearExpiry fires once, at
        # T-30 days, and never again for that secret version -- so the event
        # itself IS the renewal signal and the lead-day window must not be
        # re-applied to it. Without this, a T-30 event hits the T-14 guard,
        # returns "success", and the webhook silently lapses.
        [switch] $TriggeredByExpiryEvent
    )

    $vaultName = ([Uri]$KeyVaultUri).Host.Split('.')[0]

    # A missing webhook and an UNREADABLE one are completely different states.
    # With -ErrorAction SilentlyContinue, a 403 (RBAC grant missing or not yet
    # propagated), a 429, a transient 503, or a missing Az context all yield
    # $null -- indistinguishable from "not found". The caller then takes the
    # create branch and REPLACES a webhook that was healthy all along,
    # invalidating the URL every existing consumer holds.
    $webhook = Get-AutomationWebhookOrNull `
        -ResourceGroupName $AutomationResourceGroup `
        -AutomationAccountName $AutomationAccountName `
        -Name $WebhookName

    if (-not $webhook) {
        Write-Warning "Webhook '$WebhookName' not found -- creating it for the first time."
        New-RenewedWebhook -SubscriptionId $SubscriptionId `
            -AutomationResourceGroup $AutomationResourceGroup `
            -AutomationAccountName $AutomationAccountName `
            -RunbookName $RunbookName `
            -WebhookName $WebhookName `
            -VaultName $vaultName `
            -SecretName $KeyVaultSecretName `
            -LifetimeDays $NewWebhookLifetimeDays
        return
    }

    if ($null -eq $webhook.ExpiryTime) {
        # A webhook with no expiry cannot be reasoned about. Treat it as
        # needing replacement rather than crashing on a null subtraction.
        Write-Warning "Webhook '$WebhookName' has no ExpiryTime -- treating it as unrenewable and replacing it."
        New-RenewedWebhook -SubscriptionId $SubscriptionId `
            -AutomationResourceGroup $AutomationResourceGroup `
            -AutomationAccountName $AutomationAccountName `
            -RunbookName $RunbookName `
            -WebhookName $WebhookName `
            -VaultName $vaultName `
            -SecretName $KeyVaultSecretName `
            -LifetimeDays $NewWebhookLifetimeDays
        return
    }

    $daysRemaining = ($webhook.ExpiryTime.UtcDateTime - (Get-Date).ToUniversalTime()).TotalDays

    Write-Host "Webhook '$WebhookName' expires $($webhook.ExpiryTime.UtcDateTime) UTC ($([math]::Round($daysRemaining,1)) days remaining)."

    if ($daysRemaining -gt $RenewalLeadDays) {
        if (-not $TriggeredByExpiryEvent) {
            Write-Host "Outside the $RenewalLeadDays-day renewal window -- nothing to do."
            return
        }

        Write-Host "Outside the $RenewalLeadDays-day window ($([math]::Round($daysRemaining,1)) days left), but SecretNearExpiry fired -- renewing anyway. That event does not repeat for this secret version, so deferring here would mean never renewing."
    }

    # Use a small positive floor, not -le 0. $daysRemaining is read once, and
    # an expiry a few seconds out would take the extend path whose ARM PATCH
    # then races the actual expiry -- Azure rejects expiry updates on an
    # already-expired webhook, so that run fails with a deterministic 400
    # instead of falling through to the create path that would have fixed it.
    if ($daysRemaining -lt 0.5) {
        Write-Warning "Webhook expired or within 12h of expiring ($([math]::Round($daysRemaining,3)) days) -- too close to extend safely. Creating a replacement."
        New-RenewedWebhook -SubscriptionId $SubscriptionId `
            -AutomationResourceGroup $AutomationResourceGroup `
            -AutomationAccountName $AutomationAccountName `
            -RunbookName $RunbookName `
            -WebhookName $WebhookName `
            -VaultName $vaultName `
            -SecretName $KeyVaultSecretName `
            -LifetimeDays $NewWebhookLifetimeDays
        return
    }

    Write-Host "Within renewal window -- extending expiry in place (URL is unaffected)."
    $newExpiry = (Get-Date).ToUniversalTime().AddDays($NewWebhookLifetimeDays)

    Set-AutomationWebhookExpiryViaRest `
        -SubscriptionId $SubscriptionId `
        -ResourceGroup $AutomationResourceGroup `
        -AutomationAccountName $AutomationAccountName `
        -WebhookName $WebhookName `
        -NewExpiryUtc $newExpiry

    # URL didn't change -- just push the new expiry onto the existing secret
    # so Key Vault / Event Grid metadata stays accurate.
    #
    # The ARM PATCH above has ALREADY COMMITTED at this point. If this update
    # fails we are half-committed: the webhook is good for another 90 days but
    # Key Vault still carries the old expiry, so SecretNearExpiry fires on a
    # stale date and never fires near the real one -- silently killing the
    # Event Grid path. Must be loud, and must fail the invocation so the
    # timer's next run reconciles it.
    try {
        Update-AzKeyVaultSecret -VaultName $vaultName -Name $KeyVaultSecretName `
            -Expires $newExpiry -ErrorAction Stop | Out-Null
    }
    catch {
        throw ("INCONSISTENT STATE: webhook '$WebhookName' expiry was extended to $newExpiry UTC, but writing " +
               "that expiry to Key Vault secret '$KeyVaultSecretName' failed: $($_.Exception.Message). " +
               "The secret's expiry metadata is now stale, so SecretNearExpiry will fire on the wrong date. " +
               "The next timer run will retry the update.")
    }

    Write-Host "Extended webhook expiry to $newExpiry UTC and updated Key Vault secret metadata."
}

function Set-AutomationWebhookExpiryViaRest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $SubscriptionId,
        [Parameter(Mandatory)] [string] $ResourceGroup,
        [Parameter(Mandatory)] [string] $AutomationAccountName,
        [Parameter(Mandatory)] [string] $WebhookName,
        [Parameter(Mandatory)] [datetime] $NewExpiryUtc
    )

    # Az.Automation has no cmdlet that can extend expiry without regenerating
    # the URL, so this goes straight at the ARM REST API -- the same call the
    # Portal's "Extend" button makes under the hood.
    $path = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup" +
            "/providers/Microsoft.Automation/automationAccounts/$AutomationAccountName" +
            "/webhooks/$WebhookName`?api-version=2015-10-31"

    $body = @{
        name       = $WebhookName
        properties = @{
            expiryTime = $NewExpiryUtc.ToString("o")
        }
    } | ConvertTo-Json -Depth 5

    $response = Invoke-AzRestMethod -Path $path -Method PATCH -Payload $body

    if ($response.StatusCode -notin 200, 201) {
        # Do NOT dump $response.Content: the webhook PATCH response body
        # echoes the webhook's own properties. Surface the status and a
        # bounded excerpt of the error code only.
        $detail = ''
        try {
            $parsed = $response.Content | ConvertFrom-Json
            if ($parsed.error.code) { $detail = " [$($parsed.error.code)]" }
        } catch { }
        throw "Failed to extend webhook expiry via REST for '$WebhookName' (HTTP $($response.StatusCode))$detail."
    }
}

function New-RenewedWebhook {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $SubscriptionId,
        [Parameter(Mandatory)] [string] $AutomationResourceGroup,
        [Parameter(Mandatory)] [string] $AutomationAccountName,
        [Parameter(Mandatory)] [string] $RunbookName,
        [Parameter(Mandatory)] [string] $WebhookName,
        [Parameter(Mandatory)] [string] $VaultName,
        [Parameter(Mandatory)] [string] $SecretName,
        [Parameter(Mandatory)] [int] $LifetimeDays
    )

    # If a same-named expired webhook still exists, remove it first -- you
    # cannot re-create over an existing name.
    # Same reasoning as the caller: a masked failure here would skip the
    # delete, and New- would then collide with a name that is still occupied.
    $existing = Get-AutomationWebhookOrNull `
        -ResourceGroupName $AutomationResourceGroup `
        -AutomationAccountName $AutomationAccountName `
        -Name $WebhookName

    if ($existing) {
        # NB: Remove-AzAutomationWebhook has NO -Force parameter (unlike
        # New-AzAutomationWebhook, which does). Passing it throws
        # "A parameter cannot be found that matches parameter name 'Force'".
        # It supports ShouldProcess, so -Confirm:$false is what suppresses
        # the prompt in a non-interactive Functions host.
        Remove-AzAutomationWebhook `
            -ResourceGroupName $AutomationResourceGroup `
            -AutomationAccountName $AutomationAccountName `
            -Name $WebhookName `
            -Confirm:$false
    }

    $expiry = (Get-Date).ToUniversalTime().AddDays($LifetimeDays)

    $newWebhook = New-AzAutomationWebhook `
        -ResourceGroupName $AutomationResourceGroup `
        -AutomationAccountName $AutomationAccountName `
        -RunbookName $RunbookName `
        -Name $WebhookName `
        -IsEnabled $true `
        -ExpiryTime $expiry `
        -Force

    # ---------------------------------------------------------------------
    # CRITICAL SECTION. New-AzAutomationWebhook returns the URI exactly once
    # -- it is not stored by Azure and cannot be read back by any API. From
    # here until Set-AzKeyVaultSecret commits, the only copy of that URL is
    # the in-memory $newWebhook.WebhookURI.
    #
    # If the Key Vault write fails and we simply throw, we leave behind an
    # enabled webhook whose URL nobody can ever learn: not usable, not
    # renewable (a later run would see it as "healthy" and extend it
    # forever), and not distinguishable from a good one. That orphan also
    # squats the name, so the next attempt has to delete it first.
    #
    # So a failed write must roll the webhook back. Deleting it returns the
    # system to the "no webhook" state, which the next run handles cleanly
    # by creating a fresh one.
    # ---------------------------------------------------------------------
    if ([string]::IsNullOrWhiteSpace($newWebhook.WebhookURI)) {
        # Do NOT roll back here. Get-AzAutomationWebhook deliberately returns
        # WebhookURI as an empty string for security; if New- ever adopted the
        # same redaction, an unconditional rollback would delete every webhook
        # this function creates. Fail loudly and leave the webhook in place --
        # a human can inspect it; a deleted one tells us nothing.
        throw ("New-AzAutomationWebhook returned no WebhookURI for '$WebhookName'. " +
               "The webhook WAS created and is left in place for inspection; its URL is not recoverable, " +
               "so delete it manually once diagnosed.")
    }

    $secureValue = ConvertTo-SecureString -String $newWebhook.WebhookURI -AsPlainText -Force

    try {
        Set-AzKeyVaultSecret -VaultName $VaultName -Name $SecretName `
            -SecretValue $secureValue -Expires $expiry -ErrorAction Stop | Out-Null
    }
    catch {
        $writeError = $_.Exception.Message
        $status = $null
        try { $status = $_.Exception.Response.StatusCode.value__ } catch { }

        # Rollback is ONLY correct for a transient write failure. On a
        # permission/not-found error the next run will fail identically, so
        # deleting the webhook converts a recoverable problem into a daily
        # create-then-destroy loop that never stores a usable URL. In that
        # case the orphan is the lesser evil: it still works for anyone
        # already holding the URL.
        $isPermanent = $status -in 401, 403, 404

        if ($isPermanent) {
            # NOTE: log AFTER deciding, and never before a rollback -- if the
            # host runs with $ErrorActionPreference = 'Stop', Write-Error
            # throws and would skip everything below it.
            Write-Error ("Key Vault write DENIED ($status) for secret '$SecretName' in vault '$VaultName'. " +
                         "NOT rolling back: webhook '$WebhookName' is left in place, but its URL was never stored " +
                         "and cannot be recovered. Fix the vault RBAC grant, then delete the webhook so the next run recreates it.")
            throw "Key Vault write denied ($status) persisting new webhook URL: $writeError"
        }

        # Transient failure: roll back, but only if the webhook at this name
        # is still the one WE created. A concurrent run may have already
        # replaced it, and deleting that would destroy a healthy webhook
        # whose URL is live in Key Vault.
        $rolledBack = $false
        try {
            $current = Get-AzAutomationWebhook -ResourceGroupName $AutomationResourceGroup `
                -AutomationAccountName $AutomationAccountName -Name $WebhookName -ErrorAction Stop

            if ($current -and $current.CreationTime -eq $newWebhook.CreationTime) {
                Remove-AzAutomationWebhook -ResourceGroupName $AutomationResourceGroup `
                    -AutomationAccountName $AutomationAccountName -Name $WebhookName -Confirm:$false
                $rolledBack = $true
            }
            else {
                Write-Warning ("Skipping rollback: webhook '$WebhookName' was replaced by a concurrent run " +
                               "(creation time differs). Leaving it alone -- deleting it would destroy a webhook " +
                               "whose URL another run already stored.")
            }
        }
        catch {
            Write-Error ("ORPHANED WEBHOOK: '$WebhookName' exists in automation account '$AutomationAccountName' " +
                         "but its URL was never stored and rollback failed ($($_.Exception.Message)). " +
                         "Delete it manually before the next run.")
        }

        if ($rolledBack) {
            Write-Warning "Rolled back: deleted webhook '$WebhookName' because its URL could not be persisted. The next run will create a replacement."
        }

        throw "Failed to persist new webhook URL to Key Vault: $writeError"
    }

    # NB: string concatenation must happen inside the parentheses. Written as
    # `Write-Warning "a" + "b"` PowerShell passes only "a" as -Message and then
    # tries to evaluate `+ "b"` separately, so half the warning is lost.
    Write-Warning ("REPLACED webhook '$WebhookName' -- new URL written to Key Vault secret '$SecretName'. " +
                   "Any consumer with the old URL hardcoded must pull the new one.")
}

Export-ModuleMember -Function Invoke-WebhookRenewalCheck
