data "azurerm_client_config" "current" {}

resource "random_string" "suffix" {
  length  = 5
  special = false
  upper   = false
}

# With var.create_resource_group = false the group must already exist and is
# only read, never created or destroyed. Use that when the deploying SP is
# scoped to one resource group and cannot create groups itself.
resource "azurerm_resource_group" "this" {
  count    = var.create_resource_group ? 1 : 0
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

data "azurerm_resource_group" "existing" {
  count = var.create_resource_group ? 0 : 1
  name  = var.resource_group_name
}

locals {
  resource_group_name     = var.create_resource_group ? azurerm_resource_group.this[0].name : data.azurerm_resource_group.existing[0].name
  resource_group_location = var.create_resource_group ? azurerm_resource_group.this[0].location : data.azurerm_resource_group.existing[0].location
}

# ---------------------------------------------------------------------------
# Storage account required by the Function App runtime
# ---------------------------------------------------------------------------
resource "azurerm_storage_account" "func" {
  name                     = "st${var.prefix}${random_string.suffix.result}"
  resource_group_name      = local.resource_group_name
  location                 = local.resource_group_location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  tags                     = var.tags
}

# ---------------------------------------------------------------------------
# Consumption plan + PowerShell Function App
# ---------------------------------------------------------------------------
resource "azurerm_service_plan" "func" {
  name                = "asp-${var.prefix}-${random_string.suffix.result}"
  resource_group_name = local.resource_group_name
  location            = local.resource_group_location
  os_type             = "Linux"
  sku_name            = "Y1" # Consumption. Swap to EP1 later if VNet integration is added.
  tags                = var.tags
}

# ---------------------------------------------------------------------------
# Application Insights — REMOVED FROM THE SPIKE.
#
# Classic App Insights was retired in Feb 2024, so Azure auto-provisions a
# Log Analytics workspace and links it server-side. azurerm 3.117.1 recorded
# `workspace_id = ""` in state instead of that workspace, and then refused to
# apply with "`workspace_id` can not be removed after set".
#
# The component Azure created is backed by:
#   /subscriptions/.../resourceGroups/ai_appi-wbhkrnw-mb4x3_<guid>_managed
#     /providers/Microsoft.OperationalInsights/workspaces/managed-appi-wbhkrnw-mb4x3-ws
#
# It is telemetry only — nothing in the renewal path depends on it — so it is
# dropped to keep the spike deployable. Function logs are still available via
# the Function App's own log stream (`func azure functionapp logstream`, or
# Log stream in the portal).
#
# To restore it properly: declare an azurerm_log_analytics_workspace, set
# `workspace_id` on the component explicitly, and import the existing one
# rather than letting Azure auto-create a managed workspace.
# ---------------------------------------------------------------------------

resource "azurerm_linux_function_app" "renew" {
  name                = "func-${var.prefix}-${random_string.suffix.result}"
  resource_group_name = local.resource_group_name
  location            = local.resource_group_location

  storage_account_name       = azurerm_storage_account.func.name
  storage_account_access_key = azurerm_storage_account.func.primary_access_key
  service_plan_id            = azurerm_service_plan.func.id

  identity {
    type = "SystemAssigned"
  }

  site_config {
    # application_insights_key removed along with the App Insights resource
    # above. Use the Function App's log stream for diagnostics.
    application_stack {
      powershell_core_version = "7.4"
    }
  }

  app_settings = {
    "FUNCTIONS_WORKER_RUNTIME"          = "powershell"
    "KEY_VAULT_URI"                     = local.key_vault_uri
    "AZURE_ENVIRONMENT"                 = local.az_environment_name # read by profile.ps1 for Connect-AzAccount
    "KEY_VAULT_SECRET_NAME"             = var.key_vault_secret_name
    "AUTOMATION_ACCOUNT_RESOURCE_GROUP" = local.resource_group_name
    "AUTOMATION_ACCOUNT_NAME"           = var.automation_account_name
    "RUNBOOK_NAME"                      = var.runbook_name
    "WEBHOOK_NAME"                      = var.webhook_name
    "RENEWAL_LEAD_DAYS"                 = tostring(var.renewal_lead_days)
    "SUBSCRIPTION_ID"                   = data.azurerm_client_config.current.subscription_id

    # VM password rotation. SECRET_LIFETIME_DAYS is the secret's expiry, not
    # the rotation cadence -- see the variable description.
    "SECRET_LIFETIME_DAYS" = tostring(var.vm_password_secret_lifetime_days)
  }

  # Zip deploy on Linux Consumption works by adding this setting. Terraform
  # treats app_settings as the complete list, so without this it removes the
  # setting on the next apply and the app silently stops serving its code.
  lifecycle {
    ignore_changes = [app_settings["WEBSITE_RUN_FROM_PACKAGE"]]
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Key Vault (RBAC authorization model) + placeholder secret
# ---------------------------------------------------------------------------
#
# When var.existing_key_vault_name is set, this stack uses that vault and does
# NOT own it: `terraform destroy` leaves it alone. Otherwise it creates one.
# Everything else refers to the vault through local.key_vault_* below, never to
# either object directly.
resource "azurerm_key_vault" "this" {
  count                      = var.existing_key_vault_name == "" ? 1 : 0
  name                       = "kv-${var.prefix}-${random_string.suffix.result}"
  resource_group_name        = local.resource_group_name
  location                   = local.resource_group_location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  enable_rbac_authorization  = true
  soft_delete_retention_days = 7
  tags                       = var.tags
}

data "azurerm_key_vault" "existing" {
  count               = var.existing_key_vault_name == "" ? 0 : 1
  name                = var.existing_key_vault_name
  resource_group_name = var.existing_key_vault_resource_group_name == "" ? local.resource_group_name : var.existing_key_vault_resource_group_name
}

locals {
  key_vault_id       = var.existing_key_vault_name == "" ? azurerm_key_vault.this[0].id : data.azurerm_key_vault.existing[0].id
  key_vault_name     = var.existing_key_vault_name == "" ? azurerm_key_vault.this[0].name : data.azurerm_key_vault.existing[0].name
  key_vault_uri      = var.existing_key_vault_name == "" ? azurerm_key_vault.this[0].vault_uri : data.azurerm_key_vault.existing[0].vault_uri
  key_vault_location = var.existing_key_vault_name == "" ? azurerm_key_vault.this[0].location : data.azurerm_key_vault.existing[0].location

  # The role grants in MANUAL-RBAC.md assume the RBAC permission model. An
  # existing vault on access policies would 403 every call with no hint why.
  key_vault_uses_rbac = var.existing_key_vault_name == "" ? true : data.azurerm_key_vault.existing[0].enable_rbac_authorization

  # Name the Az PowerShell module and the Azure CLI use for the same cloud.
  az_environment_name = var.azure_environment == "usgovernment" ? "AzureUSGovernment" : "AzureCloud"
}

# Placeholder value — the function overwrites this with the real webhook URL
# and a matching `expires` attribute on first run.
resource "azurerm_key_vault_secret" "webhook_url" {
  name            = var.key_vault_secret_name
  value           = "PLACEHOLDER-SET-BY-FUNCTION-ON-FIRST-RUN"
  key_vault_id    = local.key_vault_id
  expiration_date = timeadd(timestamp(), "24h") # forces a near-expiry state so the first run renews immediately

  lifecycle {
    ignore_changes = [value, expiration_date] # the function owns these after creation

    precondition {
      condition     = local.key_vault_uses_rbac
      error_message = "Key Vault '${local.key_vault_name}' uses access policies, not Azure RBAC. Enable 'Azure role-based access control' on it, or the role assignments in MANUAL-RBAC.md will not apply."
    }
  }

  # NOTE: the `depends_on` for deployer_kv_officer was removed when that role
  # assignment moved to manual creation (see below). The grant MUST already
  # exist before this resource applies, or creation fails with 403. Key Vault
  # RBAC is also eventually consistent, so a freshly created grant can take a
  # minute or two to take effect -- re-run the apply if it 403s.
}

# ---------------------------------------------------------------------------
# MANUAL RBAC — the deploying service principal does not hold
# Microsoft.Authorization/roleAssignments/write, so it cannot create role
# assignments. The blocks below are kept, commented, as the record of what
# must exist; create them out-of-band with the `az` commands in each note.
#
# Trade-off: Terraform does not own these. `terraform destroy` + re-apply
# generates a new random_string suffix, hence new resource names and a new
# Function App principal ID, so every scope below must be recreated by hand.
# If this stack gets torn down more than once or twice, granting the SP
# "User Access Administrator" on the resource group and restoring these
# blocks is the cheaper path.
# ---------------------------------------------------------------------------

# Deployer needs rights to create the placeholder secret above.
#
#   az role assignment create \
#     --assignee <deployer-sp-object-id> \
#     --role "Key Vault Secrets Officer" \
#     --scope <key-vault-resource-id>
#
# resource "azurerm_role_assignment" "deployer_kv_officer" {
#   scope                = local.key_vault_id
#   role_definition_name = "Key Vault Secrets Officer"
#   principal_id         = data.azurerm_client_config.current.object_id
# }

# Function App's managed identity needs the same on the Key Vault. Without it
# the function cannot read or write the webhook URL secret.
#
#   az role assignment create \
#     --assignee <function-app-principal-id> \
#     --role "Key Vault Secrets Officer" \
#     --scope <key-vault-resource-id>
#
# The principal ID is the `function_app_identity_principal_id` output.
#
# resource "azurerm_role_assignment" "func_kv_officer" {
#   scope                = local.key_vault_id
#   role_definition_name = "Key Vault Secrets Officer"
#   principal_id         = azurerm_linux_function_app.renew.identity[0].principal_id
# }

# ---------------------------------------------------------------------------
# Automation Account + target Runbook — created here for a fully greenfield
# deploy. The runbook body is a placeholder; swap `content` for your real
# logic (or import it separately) once this is more than a spike.
# ---------------------------------------------------------------------------
resource "azurerm_automation_account" "this" {
  name                = var.automation_account_name
  resource_group_name = local.resource_group_name
  location            = local.resource_group_location
  sku_name            = "Basic"
  tags                = var.tags
}

resource "azurerm_automation_runbook" "target" {
  name                    = var.runbook_name
  resource_group_name     = local.resource_group_name
  location                = local.resource_group_location
  automation_account_name = azurerm_automation_account.this.name
  runbook_type            = "PowerShell"
  log_verbose             = true
  log_progress            = true

  content = <<-EOT
    param(
        [object] $WebhookData
    )
    Write-Output "Runbook triggered at $(Get-Date -AsUTC)."
    if ($WebhookData) {
        Write-Output "Received webhook payload: $($WebhookData.RequestBody)"
    }
  EOT

  tags = var.tags
}

# RBAC on the Automation Account this stack itself created — same caveat as
# before: "Automation Contributor" is coarse, tighten to a custom role
# scoped to Microsoft.Automation/automationAccounts/webhooks/* before this
# leaves spike.
#
# MANUAL — without this the function cannot create or renew the webhook.
#
#   az role assignment create \
#     --assignee <function-app-principal-id> \
#     --role "Automation Contributor" \
#     --scope <automation-account-resource-id>
#
# resource "azurerm_role_assignment" "func_automation_contributor" {
#   scope                = azurerm_automation_account.this.id
#   role_definition_name = "Automation Contributor"
#   principal_id         = azurerm_linux_function_app.renew.identity[0].principal_id
# }

# ---------------------------------------------------------------------------
# Event Grid System Topic on the Key Vault -> EARLY FAST-PATH for renewal.
# The renewal authority is the daily timer in function_app/RenewWebhook;
# this subscription just gets us renewed ~16 days sooner when it works.
#
# SecretNearExpiry fires once, at a fixed T-30-days mark tied to the
# secret's current `Expires` value -- it will NOT refire if the function
# runs, returns success, but fails to actually renew. Because of that,
# OnSecretNearExpiry passes -TriggeredByExpiryEvent and skips the
# RenewalLeadDays window entirely; applying a T-14 window to a T-30
# event would silently discard the only notification we ever get.
#
# Failed *deliveries* are retried by Event Grid itself (retry_policy
# below), and anything that still fails after that lands in the
# dead-letter container. Logic failures inside a successful run are not
# covered here -- that is what the timer is for.
# ---------------------------------------------------------------------------
resource "azurerm_storage_container" "dead_letter" {
  name                  = "eventgrid-deadletter"
  storage_account_name  = azurerm_storage_account.func.name
  container_access_type = "private"
}

# MANUAL — and unlike the others, this one CANNOT be created up front: it
# targets the system topic's managed identity, which does not exist until
# azurerm_eventgrid_system_topic.kv has been created by an apply. Hence the
# two-pass sequence in README.md — apply first, then grant, using:
#
#   terraform state show azurerm_eventgrid_system_topic.kv \
#     | grep principal_id
#
#   az role assignment create \
#     --assignee <system-topic-principal-id> \
#     --role "Storage Blob Data Contributor" \
#     --scope <storage-account-resource-id>
#
# Until it exists, Event Grid cannot write to the dead-letter container:
# deliveries that exhaust retry_policy below are dropped silently rather
# than dead-lettered. The subscription itself still works.
#
# resource "azurerm_role_assignment" "eventgrid_deadletter_blob_contributor" {
#   scope                = azurerm_storage_account.func.id
#   role_definition_name = "Storage Blob Data Contributor"
#   principal_id         = azurerm_eventgrid_system_topic.kv.identity[0].principal_id
# }

resource "azurerm_eventgrid_system_topic" "kv" {
  name                = "egst-${var.prefix}-${random_string.suffix.result}"
  resource_group_name = local.resource_group_name

  # Must match the source resource's region, NOT "global". Only system topics
  # whose source is itself a global resource (Subscriptions, Resource Groups,
  # Azure Maps) use "global"; a Key Vault is regional, so the topic is too.
  location = local.key_vault_location

  source_arm_resource_id = local.key_vault_id
  topic_type             = "Microsoft.KeyVault.vaults"
  tags                   = var.tags

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_eventgrid_system_topic_event_subscription" "kv_near_expiry" {
  name                = "sub-secret-near-expiry"
  system_topic        = azurerm_eventgrid_system_topic.kv.name
  resource_group_name = local.resource_group_name

  included_event_types = ["Microsoft.KeyVault.SecretNearExpiry"]

  # Without this, EVERY secret in the vault that nears expiry invokes the
  # handler, which would rotate the webhook for an unrelated secret's sake.
  # The handler re-checks the subject too -- this just avoids the invocation.
  subject_filter {
    subject_begins_with = var.key_vault_secret_name
  }

  azure_function_endpoint {
    function_id                       = "${azurerm_linux_function_app.renew.id}/functions/OnSecretNearExpiry"
    max_events_per_batch              = 1
    preferred_batch_size_in_kilobytes = 64
  }

  retry_policy {
    max_delivery_attempts = 30
    event_time_to_live    = 1440 # minutes = 24h, the max Event Grid allows
  }

  storage_blob_dead_letter_destination {
    storage_account_id          = azurerm_storage_account.func.id
    storage_blob_container_name = azurerm_storage_container.dead_letter.name
  }

  # NOTE: `depends_on` for eventgrid_deadletter_blob_contributor removed --
  # that grant is created manually after this resource exists (see above), so
  # on a first apply the dead-letter destination below is configured but not
  # yet writable. Grant it, and dead-lettering starts working; no re-apply of
  # this resource is needed.
}

# ---------------------------------------------------------------------------
# VM password rotation -> a SECOND subscription on the same system topic.
#
# Deliberately separate from kv_near_expiry above rather than one subscription
# fanning out. The two handlers share an event type and nothing else: one
# extends an Automation webhook's expiry, the other resets a VM local
# administrator password. Separate subscriptions mean each gets its own
# subject filter, its own retry accounting, and a failure in one cannot
# affect delivery to the other.
#
# CADENCE: rotation is driven entirely by this event -- there is no timer
# backstop for VM passwords (unlike the webhook, which has RenewWebhook).
# Key Vault fires at T-30, the handler writes a new version expiring
# vm_password_secret_lifetime_days out, and the cycle repeats. With the
# default of 90 that is a 60-day rotation.
# ---------------------------------------------------------------------------
resource "azurerm_eventgrid_system_topic_event_subscription" "kv_vm_password_near_expiry" {
  name                = "sub-vm-password-near-expiry"
  system_topic        = azurerm_eventgrid_system_topic.kv.name
  resource_group_name = local.resource_group_name

  included_event_types = ["Microsoft.KeyVault.SecretNearExpiry"]

  # Narrows delivery to VM password secrets. The handler independently
  # verifies the VM-NAME / ADMIN-NAME tags before touching anything, so this
  # is an optimisation rather than the security boundary -- a secret that
  # slips through the filter without those tags is refused by the code.
  #
  # A "" prefix delivers every near-expiry event in the vault, including the
  # webhook's, and lets the tag check do all the filtering. That is valid but
  # noisier; it also means both handlers fire for the webhook secret.
  dynamic "subject_filter" {
    for_each = var.vm_password_secret_prefix == "" ? [] : [1]
    content {
      subject_begins_with = var.vm_password_secret_prefix
    }
  }

  azure_function_endpoint {
    function_id                       = "${azurerm_linux_function_app.renew.id}/functions/OnVMPasswordNearExpiry"
    max_events_per_batch              = 1
    preferred_batch_size_in_kilobytes = 64
  }

  retry_policy {
    max_delivery_attempts = 30
    event_time_to_live    = 1440
  }

  storage_blob_dead_letter_destination {
    storage_account_id          = azurerm_storage_account.func.id
    storage_blob_container_name = azurerm_storage_container.dead_letter.name
  }
}

# ---------------------------------------------------------------------------
# MANUAL RBAC -- Virtual Machine Contributor, one grant per VM resource group.
#
# Scoped per resource group rather than at the subscription, so the identity
# can only touch VMs it is meant to.
#
# CAVEAT WORTH RAISING BEFORE PRODUCTION: "Virtual Machine Contributor" is
# coarse for this job. It permits deleting VMs, changing their size, and
# detaching disks -- none of which this function needs. All it requires is
# Microsoft.Compute/virtualMachines/read plus the ability to write the
# VMAccess extension (Microsoft.Compute/virtualMachines/extensions/write).
# A custom role with exactly those two actions should replace this before the
# function rotates anything real. The blast radius of the managed identity is
# otherwise much larger than the task justifies.
#
# Left commented for the same reason as the other role assignments: the
# deploying service principal lacks Microsoft.Authorization/roleAssignments/write.
# Populate var.vm_resource_group_names and uncomment once that is resolved.
#
#   az role assignment create \
#     --assignee <function-app-principal-id> \
#     --role "Virtual Machine Contributor" \
#     --scope /subscriptions/<sub>/resourceGroups/<vm-resource-group>
#
# resource "azurerm_role_assignment" "func_vm_contributor" {
#   for_each             = toset(var.vm_resource_group_names)
#   scope                = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/resourceGroups/${each.value}"
#   role_definition_name = "Virtual Machine Contributor"
#   principal_id         = azurerm_linux_function_app.renew.identity[0].principal_id
# }

# ---------------------------------------------------------------------------
# SECRET DISTRIBUTION -- a SECOND Function App, running .NET.
#
# Why a separate app rather than another function in the PowerShell one:
# FUNCTIONS_WORKER_RUNTIME is per-app, so runtimes cannot be mixed. This code
# is .NET for one specific reason -- GitHub Actions secrets must be encrypted
# with libsodium crypto_box_seal before upload, and there is no libsodium
# binding for PowerShell and no X25519 in the .NET BCL. Sodium.Core does it in
# one call; the PowerShell alternative was hand-rolling X25519, XSalsa20,
# Poly1305 and Blake2b, which failed its RFC 7748 test vector and was
# abandoned. This runtime boundary is deliberate, not incidental.
#
# The app shares the storage account and resource group with the PowerShell
# app but has its own plan and its own managed identity -- it only needs to
# READ secrets, where the rotation app needs to write them.
# ---------------------------------------------------------------------------
resource "azurerm_service_plan" "dist" {
  count               = var.enable_secret_distribution ? 1 : 0
  name                = "asp-${var.prefix}-dist-${random_string.suffix.result}"
  resource_group_name = local.resource_group_name
  location            = local.resource_group_location
  os_type             = "Linux"
  sku_name            = "Y1"
  tags                = var.tags
}

resource "azurerm_linux_function_app" "dist" {
  count               = var.enable_secret_distribution ? 1 : 0
  name                = "func-${var.prefix}-dist-${random_string.suffix.result}"
  resource_group_name = local.resource_group_name
  location            = local.resource_group_location

  storage_account_name       = azurerm_storage_account.func.name
  storage_account_access_key = azurerm_storage_account.func.primary_access_key
  service_plan_id            = azurerm_service_plan.dist[0].id

  identity {
    type = "SystemAssigned"
  }

  site_config {
    application_stack {
      dotnet_version              = "8.0"
      use_dotnet_isolated_runtime = true
    }
  }

  # ---- Easy Auth: sign-in for the registry UI/API --------------------------
  # Every request must be signed in to Entra, EXCEPT the Event Grid webhook.
  # Event Grid delivers events to /runtime/webhooks/EventGrid with its own
  # system key and cannot sign in as a user; if that path were covered by
  # authentication, SecretNewVersionCreated deliveries would be rejected and
  # distribution would silently stop (the Event Grid subscription's endpoint
  # validation would fail too). It is still protected by the host's system key.
  #
  # The registry API then checks the signed-in user's app role in code.
  dynamic "auth_settings_v2" {
    for_each = var.entra_client_id == "" ? [] : [1]
    content {
      auth_enabled           = true
      require_authentication = true
      require_https          = true
      default_provider       = "azureactivedirectory"
      unauthenticated_action = "RedirectToLoginPage"
      excluded_paths         = ["/runtime/webhooks/EventGrid"]

      active_directory_v2 {
        client_id                  = var.entra_client_id
        tenant_auth_endpoint       = "${var.entra_authority_host}/${data.azurerm_client_config.current.tenant_id}/v2.0"
        client_secret_setting_name = "MICROSOFT_PROVIDER_AUTHENTICATION_SECRET"
        # A v2 token's audience is the client id; a v1 token's is the api:// URI.
        allowed_audiences = ["api://${var.entra_client_id}", var.entra_client_id]
      }

      login {
        token_store_enabled = false
      }
    }
  }

  app_settings = merge({
    "FUNCTIONS_WORKER_RUNTIME" = "dotnet-isolated"
    "KEY_VAULT_URI"            = local.key_vault_uri
    "GITHUB_TOKEN_SECRET_NAME" = var.github_token_secret_name
    "GITHUB_DEFAULT_ORG"       = var.github_default_org

    # See var.registry_open_access: UI/API open to anyone with the URL.
    "REGISTRY_OPEN_ACCESS" = var.registry_open_access ? "true" : "false"

    # Secret registry (see cosmos.tf). Endpoint only -- auth is the managed
    # identity, so there is no key or connection string to configure.
    "COSMOS_ENDPOINT" = azurerm_cosmosdb_account.registry[0].endpoint
    "COSMOS_DATABASE" = azurerm_cosmosdb_sql_database.registry[0].name
    },
    # Easy Auth's client secret, by Key Vault reference so the value never
    # touches Terraform state. Resolved with the app's managed identity.
    var.entra_client_id == "" ? {} : {
      "MICROSOFT_PROVIDER_AUTHENTICATION_SECRET" = "@Microsoft.KeyVault(SecretUri=${local.key_vault_uri}secrets/${var.entra_client_secret_name})"
    }
  )

  # See the same block on the renew app: deploys add this setting, and
  # Terraform must not strip it.
  lifecycle {
    ignore_changes = [app_settings["WEBSITE_RUN_FROM_PACKAGE"]]
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# SecretNewVersionCreated -> distribution.
#
# A DIFFERENT event from the two SecretNearExpiry subscriptions above. Those
# fire when something is about to expire and needs rotating; this fires when a
# new version already exists and needs propagating.
#
# Deliberately unfiltered by subject: the point of this design is that it
# reacts to ANY new secret version -- one the VM rotation wrote, one a person
# created, one another process rotated. The handler reads the secret
# GITHUB-REPO / GITHUB-SECRET-NAME tags and ignores anything without them, so
# the tag check is the filter. A subject filter here would silently exclude
# secrets whose names do not match a guessed prefix, which is exactly the
# fragility the tag-based design exists to avoid.
# ---------------------------------------------------------------------------
resource "azurerm_eventgrid_system_topic_event_subscription" "kv_new_version" {
  count               = var.enable_secret_distribution ? 1 : 0
  name                = "sub-secret-new-version"
  system_topic        = azurerm_eventgrid_system_topic.kv.name
  resource_group_name = local.resource_group_name

  included_event_types = ["Microsoft.KeyVault.SecretNewVersionCreated"]

  azure_function_endpoint {
    function_id                       = "${azurerm_linux_function_app.dist[0].id}/functions/DistributeSecret"
    max_events_per_batch              = 1
    preferred_batch_size_in_kilobytes = 64
  }

  retry_policy {
    max_delivery_attempts = 30
    event_time_to_live    = 1440
  }

  storage_blob_dead_letter_destination {
    storage_account_id          = azurerm_storage_account.func.id
    storage_blob_container_name = azurerm_storage_container.dead_letter.name
  }
}

# ---------------------------------------------------------------------------
# MANUAL RBAC -- the distribution app identity needs to READ secrets.
#
# "Key Vault Secrets User" (read-only), NOT "Secrets Officer". This app never
# writes secret values; it only reads the rotated value and the GitHub token.
# It does write TAGS back (LAST-PUSHED-VERSION and friends), which requires
# write on properties -- if tag writes 403, the push still succeeds and only
# the bookkeeping is skipped, which the handler logs and tolerates. Grant
# "Key Vault Secrets Officer" instead if you want the tags recorded.
#
#   az role assignment create \
#     --assignee <dist-function-principal-id> \
#     --role "Key Vault Secrets User" \
#     --scope <key-vault-resource-id>
#
# resource "azurerm_role_assignment" "dist_kv_reader" {
#   count                = var.enable_secret_distribution ? 1 : 0
#   scope                = local.key_vault_id
#   role_definition_name = "Key Vault Secrets User"
#   principal_id         = azurerm_linux_function_app.dist[0].identity[0].principal_id
# }
