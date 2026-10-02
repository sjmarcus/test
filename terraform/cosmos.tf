# ---------------------------------------------------------------------------
# SECRET REGISTRY -- Cosmos DB (NoSQL API).
#
# Holds METADATA about secrets: which Key Vault secret is distributed where,
# who owns it, and what was last pushed. It never holds a secret value -- those
# stay in Key Vault, referenced by name.
#
# Two containers, split by WRITER so a human edit and a function write-back
# never clobber each other's fields:
#   registry  edited by people through the registry API (targets, owner, ...)
#   state     written by the distributor (last pushed version / time / key id)
#
# Both use /id as the partition key. The registry document id IS the Key Vault
# secret name, so the SecretNewVersionCreated event subject is a point read.
#
# Serverless: the load is a handful of reads a day, and provisioned RU/s would
# be a standing cost for nothing. Gated on enable_secret_distribution because
# the registry API lives in that .NET app and nothing else touches Cosmos.
# ---------------------------------------------------------------------------
locals {
  # Cosmos capacity is per region and East US has been out of it for new
  # accounts, so this can be pointed elsewhere without moving anything else.
  cosmos_location = var.cosmos_location != "" ? var.cosmos_location : local.resource_group_location
}

resource "azurerm_cosmosdb_account" "registry" {
  count               = var.enable_secret_distribution ? 1 : 0
  name                = "cosmos-${var.prefix}-${random_string.suffix.result}"
  resource_group_name = local.resource_group_name
  location            = local.cosmos_location
  offer_type          = "Standard"
  kind                = "GlobalDocumentDB"

  capabilities {
    name = "EnableServerless"
  }

  consistency_policy {
    # Session is enough: the API reads its own writes, and the distributor
    # reads a registry entry that was written long before the event fired.
    consistency_level = "Session"
  }

  geo_location {
    location          = local.cosmos_location
    failover_priority = 0
  }

  # Entra-only. With local auth disabled there are no account keys to leak or
  # rotate; the only way in is a data-plane role assignment (below).
  local_authentication_disabled = true

  # Public for the spike, matching Key Vault and the Function Apps. Private
  # endpoint goes in with the rest of the networking work.
  public_network_access_enabled = true

  tags = var.tags
}

resource "azurerm_cosmosdb_sql_database" "registry" {
  count               = var.enable_secret_distribution ? 1 : 0
  name                = "secret-registry"
  resource_group_name = local.resource_group_name
  account_name        = azurerm_cosmosdb_account.registry[0].name
}

resource "azurerm_cosmosdb_sql_container" "registry" {
  count                 = var.enable_secret_distribution ? 1 : 0
  name                  = "registry"
  resource_group_name   = local.resource_group_name
  account_name          = azurerm_cosmosdb_account.registry[0].name
  database_name         = azurerm_cosmosdb_sql_database.registry[0].name
  partition_key_path    = "/id"
  partition_key_version = 2
}

resource "azurerm_cosmosdb_sql_container" "state" {
  count                 = var.enable_secret_distribution ? 1 : 0
  name                  = "state"
  resource_group_name   = local.resource_group_name
  account_name          = azurerm_cosmosdb_account.registry[0].name
  database_name         = azurerm_cosmosdb_sql_database.registry[0].name
  partition_key_path    = "/id"
  partition_key_version = 2
}

# ---------------------------------------------------------------------------
# Data-plane access. Cosmos SQL roles are their own resource type
# (Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments), NOT
# Microsoft.Authorization/roleAssignments, so unlike the Key Vault grants this
# is not blocked by the deploying SP's missing roleAssignments/write. If the
# apply 403s here anyway, the SP lacks Contributor on the account -- see
# MANUAL-RBAC.md for the equivalent `az cosmosdb sql role assignment create`.
#
# Built-in "Cosmos DB Built-in Data Contributor" (…0002): read/write documents.
# It is scoped to this database only, so the identity cannot reach any other
# database on the account or change the account itself.
# ---------------------------------------------------------------------------
resource "random_uuid" "cosmos_dist_role" {
  count = var.enable_secret_distribution ? 1 : 0
}

resource "azurerm_cosmosdb_sql_role_assignment" "dist" {
  count               = var.enable_secret_distribution ? 1 : 0
  name                = random_uuid.cosmos_dist_role[0].result
  resource_group_name = local.resource_group_name
  account_name        = azurerm_cosmosdb_account.registry[0].name
  role_definition_id  = "${azurerm_cosmosdb_account.registry[0].id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002"
  principal_id        = azurerm_linux_function_app.dist[0].identity[0].principal_id
  scope               = "${azurerm_cosmosdb_account.registry[0].id}/dbs/${azurerm_cosmosdb_sql_database.registry[0].name}"
}
