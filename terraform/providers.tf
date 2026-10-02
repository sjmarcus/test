terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.110"
    }
  }
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy    = true
      recover_soft_deleted_key_vaults = true
    }
  }

  # Service principal auth -- required when `az login` isn't available (CI,
  # headless boxes, etc). Leave all four null to fall back to Azure CLI /
  # environment-variable auth (ARM_CLIENT_ID, ARM_CLIENT_SECRET, ARM_TENANT_ID,
  # ARM_SUBSCRIPTION_ID) instead.
  #
  # Set client_secret via TF_VAR_client_secret or -var on the command line --
  # never in terraform.tfvars or any other committed file.
  # "public" or "usgovernment". Without this the provider signs in against
  # commercial Entra and every call fails for a Gov tenant.
  environment = var.azure_environment

  client_id       = var.client_id
  client_secret   = var.client_secret
  tenant_id       = var.tenant_id
  subscription_id = var.subscription_id

  # The service principal used for this spike isn't subscription
  # Owner/Contributor, so it can't register Resource Providers itself.
  # The providers this stack needs (Microsoft.Storage, Microsoft.Web,
  # Microsoft.KeyVault, Microsoft.Automation, Microsoft.EventGrid,
  # Microsoft.Insights) are already registered on most subscriptions that
  # have deployed resources before -- if apply fails on a provider that
  # genuinely isn't registered, an Owner/Contributor needs to register it
  # (`az provider register --namespace Microsoft.Foo`) before this will work.
  #
  # NOTE: this is `skip_provider_registration` (bool) on azurerm ~> 3.x,
  # renamed to `resource_provider_registrations` (string) in azurerm 4.x.
  skip_provider_registration = true
}
