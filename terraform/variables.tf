variable "client_id" {
  description = "Service principal app (client) ID for azurerm provider auth. Leave null to use az login / ARM_* env vars instead."
  type        = string
  default     = null
}

variable "client_secret" {
  description = "Service principal client secret for azurerm provider auth. Pass via TF_VAR_client_secret or -var, never in a committed .tfvars file."
  type        = string
  default     = null
  sensitive   = true
}

variable "tenant_id" {
  description = "Azure AD tenant ID for azurerm provider auth. Leave null to use az login / ARM_* env vars instead."
  type        = string
  default     = null
}

variable "subscription_id" {
  description = "Azure subscription ID to deploy into. Leave null to use az login / ARM_* env vars instead."
  type        = string
  default     = null
}

variable "azure_environment" {
  description = <<-EOT
    Which Azure cloud to deploy into: "public" or "usgovernment". Drives the
    azurerm provider's endpoints and the Az PowerShell environment the
    PowerShell Function App signs in to. Pair it with a Gov region in
    `location` and entra_authority_host = https://login.microsoftonline.us.
  EOT
  type        = string
  default     = "public"

  validation {
    condition     = contains(["public", "usgovernment"], var.azure_environment)
    error_message = "azure_environment must be \"public\" or \"usgovernment\"."
  }
}

variable "existing_key_vault_name" {
  description = <<-EOT
    Name of an existing Key Vault to use instead of creating one. When set,
    Terraform reads the vault and does not own it (destroy leaves it alone).
    The vault must use the Azure RBAC permission model. Empty creates
    kv-<prefix>-<suffix>.
  EOT
  type        = string
  default     = ""
}

variable "existing_key_vault_resource_group_name" {
  description = "Resource group of existing_key_vault_name. Empty means this stack's resource group."
  type        = string
  default     = ""
}

variable "prefix" {
  description = "Short prefix used for naming all resources in this spike."
  type        = string
  default     = "wbhkrnw"
}

variable "location" {
  description = "Azure region for all resources. Azure Government uses usgovvirginia, usgovarizona or usgovtexas."
  type        = string
  default     = "eastus"
}

variable "create_resource_group" {
  description = <<-EOT
    true creates resource_group_name. false uses an existing group of that name
    and never creates or destroys it; `location` is then ignored in favour of
    the group's own region. Set false when the deploying SP only has rights on
    one resource group.
  EOT
  type        = bool
  default     = true
}

variable "resource_group_name" {
  description = "Name of the resource group to create (or, with create_resource_group = false, to use)."
  type        = string
  default     = "rg-webhook-renewal-spike"
}

# --- Automation Account / Runbook (created by this stack for greenfield testing) ---

variable "automation_account_name" {
  description = "Name of the Automation Account this stack creates."
  type        = string
  default     = "aa-webhook-renewal-spike"
}

variable "runbook_name" {
  description = "Name of the runbook this stack creates and triggers via webhook."
  type        = string
  default     = "Spike-Target-Runbook"
}

variable "webhook_name" {
  description = "Name of the webhook the function creates/renews on the runbook."
  type        = string
  default     = "spike-renewable-webhook"
}

variable "initial_webhook_expiry_days" {
  description = "How far out to set expiry when the webhook is first created by this stack (mock/demo only)."
  type        = number
  default     = 90
}

variable "renewal_lead_days" {
  description = "Renew when the webhook has fewer than this many days left before expiry."
  type        = number
  default     = 14
}

variable "key_vault_secret_name" {
  description = "Name of the Key Vault secret that stores the current webhook URL."
  type        = string
  default     = "automation-webhook-url"
}

# --- VM password rotation ---------------------------------------------------

variable "vm_password_secret_prefix" {
  description = <<-EOT
    Prefix that identifies VM password secrets, used as the Event Grid
    subject filter. Secrets are expected to be named like "Team1VMPassword",
    so a per-team prefix does not work -- this filters on a common leading
    string instead. Set to "" to receive near-expiry events for EVERY secret
    in the vault and let the handler's tag check do all the filtering.

    Note the handler always re-checks the VM-NAME / ADMIN-NAME tags before
    acting, so this filter is an optimisation, not the security boundary.
  EOT
  type        = string
  default     = "Team"
}

variable "vm_password_secret_lifetime_days" {
  description = <<-EOT
    Expiry stamped on each new VM password secret version. This is NOT the
    rotation cadence: Key Vault fires SecretNearExpiry 30 days before expiry,
    and that event triggers the next rotation, so

        rotation cadence = this value - 30

    The default of 90 produces a 60-day rotation. Setting this to 60 would
    produce a 30-day rotation, not 60.
  EOT
  type        = number
  default     = 90

  validation {
    condition     = var.vm_password_secret_lifetime_days > 31
    error_message = "Must exceed 31 days: Key Vault fires near-expiry at T-30, so a shorter lifetime would fire immediately or never, leaving no usable rotation window."
  }
}

variable "vm_resource_group_names" {
  description = <<-EOT
    Resource groups containing VMs whose passwords this function rotates.
    The function's managed identity is granted Virtual Machine Contributor on
    each, rather than at subscription scope.

    Empty list means no VM grants are created -- use that when the role
    assignments are made manually (see MANUAL-RBAC.md), which is the current
    situation for this deployment.
  EOT
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Common tags applied to all resources."
  type        = map(string)
  default = {
    project = "webhook-renewal-spike"
    owner   = "samuel"
  }
}

# --- Secret distribution (.NET function) ------------------------------------

variable "github_token_secret_name" {
  description = <<-EOT
    Name of the Key Vault secret holding the GitHub PAT used to write Actions
    secrets. Kept in its own secret rather than an app setting so it can be
    rotated without redeploying, and so it is never visible in tags or
    configuration.

    The token needs fine-grained "Secrets: Read and write" on each target
    repository -- read is required because sealing a value needs the repo's
    public key.
  EOT
  type        = string
  default     = "github-pat"
}

variable "github_default_org" {
  description = <<-EOT
    GitHub organisation used to qualify registry targets whose repo is a bare
    name (e.g. "arcyber" -> "<org>/arcyber"). Leave empty to require every
    target to spell out "owner/repo".
  EOT
  type        = string
  default     = ""
}

# --- Registry sign-in (Easy Auth / Entra) -----------------------------------

variable "entra_client_id" {
  description = <<-EOT
    Client (application) ID of the Entra app registration the registry UI/API
    signs users in against. Create it with scripts/Setup-RegistryAuth.ps1.

    Empty leaves Easy Auth OFF -- and with it off, the registry API refuses
    every request (it will not trust identity headers it cannot verify), so the
    UI will not work. Set this before using the registry.
  EOT
  type        = string
  default     = ""
}

variable "registry_open_access" {
  description = <<-EOT
    TEMPORARY. When true AND entra_client_id is empty (Easy Auth off), the
    registry UI and API are open: anyone who can reach the app's URL is treated
    as an Admin and can add, change or delete registry entries. Use only to test
    the distribution logic before sign-in is set up, then set false.

    With Easy Auth on (entra_client_id set) this has no effect. Left false, an
    app with Easy Auth off refuses every registry request.
  EOT
  type        = bool
  default     = false
}

variable "entra_authority_host" {
  description = "Entra sign-in host. Use https://login.microsoftonline.us for Azure Government."
  type        = string
  default     = "https://login.microsoftonline.com"
}

variable "entra_client_secret_name" {
  description = <<-EOT
    Name of the Key Vault secret holding the app registration's client secret.
    The Function App reads it through a Key Vault reference, so the value never
    appears in Terraform state or app settings. Setup-RegistryAuth.ps1 creates
    it. The distributor's identity needs Key Vault Secrets User on the vault.
  EOT
  type        = string
  default     = "registry-ui-client-secret"
}

variable "cosmos_location" {
  description = <<-EOT
    Region for the Cosmos DB account. Empty means the resource group's region.

    Set this when a region is out of Cosmos capacity for new accounts (the
    create fails with "high demand in <region>" -- ServiceUnavailable). Only the
    account moves; the registry is a few small documents read a handful of times
    a day, so cross-region latency to the Function App is irrelevant.

    Changing this on an existing account forces replacement.
  EOT
  type        = string
  default     = ""
}

variable "enable_secret_distribution" {
  description = <<-EOT
    Whether to deploy the .NET distribution function and its Event Grid
    subscription. Off by default: it is a separate Function App, and the
    SecretNewVersionCreated subscription will fail to create until that app
    has code deployed (Event Grid validates the endpoint live).

    Deploy order when enabling: apply with this false, publish the .NET code,
    then apply with it true.
  EOT
  type        = bool
  default     = false
}
