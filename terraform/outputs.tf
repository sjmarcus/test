output "function_app_name" {
  value = azurerm_linux_function_app.renew.name
}

output "function_app_identity_principal_id" {
  value = azurerm_linux_function_app.renew.identity[0].principal_id
}

output "key_vault_name" {
  value = local.key_vault_name
}

output "key_vault_uri" {
  value = local.key_vault_uri
}

output "automation_account_name" {
  value = azurerm_automation_account.this.name
}

output "runbook_name" {
  value = azurerm_automation_runbook.target.name
}

output "resource_group_name" {
  value = local.resource_group_name
}

# --- Secret distribution (.NET function, when enabled) ----------------------

output "distributor_function_app_name" {
  description = "Name of the .NET distribution Function App, or null when disabled."
  value       = var.enable_secret_distribution ? azurerm_linux_function_app.dist[0].name : null
}

output "cosmos_endpoint" {
  description = "Secret registry Cosmos endpoint, or null when disabled."
  value       = var.enable_secret_distribution ? azurerm_cosmosdb_account.registry[0].endpoint : null
}

output "distributor_identity_principal_id" {
  description = "Principal ID to grant Key Vault read access to. Needed for the manual RBAC step."
  value       = var.enable_secret_distribution ? azurerm_linux_function_app.dist[0].identity[0].principal_id : null
}
