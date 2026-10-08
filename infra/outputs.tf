###############################################################################
# Outputs
###############################################################################

output "resource_group_name" {
  description = "Resource group containing all demo resources."
  value       = azurerm_resource_group.main.name
}

output "location" {
  value = azurerm_resource_group.main.location
}

output "suffix" {
  description = "Random 4-hex-digit UID appended to resource names."
  value       = local.suffix
}

output "flex_app_name" {
  value = azurerm_function_app_flex_consumption.flex.name
}

output "flex_default_hostname" {
  value = azurerm_function_app_flex_consumption.flex.default_hostname
}

output "premium_app_name" {
  value = azurerm_linux_function_app.premium.name
}

output "premium_default_hostname" {
  value = azurerm_linux_function_app.premium.default_hostname
}

output "flex_stress_url" {
  description = "Stress endpoint for the Flex app (requires a function key)."
  value       = "https://${azurerm_function_app_flex_consumption.flex.default_hostname}/api/stress"
}

output "premium_stress_url" {
  description = "Stress endpoint for the Premium app (requires a function key)."
  value       = "https://${azurerm_linux_function_app.premium.default_hostname}/api/stress"
}

output "application_insights_name" {
  value = azurerm_application_insights.main.name
}

output "application_insights_connection_string" {
  description = "App Insights connection string (already injected into both apps)."
  value       = azurerm_application_insights.main.connection_string
  sensitive   = true
}

output "log_analytics_workspace_name" {
  value = azurerm_log_analytics_workspace.main.name
}

output "load_test_name" {
  value       = var.enable_load_testing ? azurerm_load_test.main[0].name : null
  description = "Azure Load Testing resource name (null if disabled)."
}

output "loadtest_subnet_id" {
  description = "Subnet ID to use for Azure Load Testing VNet injection."
  value       = azurerm_subnet.loadtest.id
}

output "flex_storage_account" {
  value = azurerm_storage_account.flex.name
}

output "premium_storage_account" {
  value = azurerm_storage_account.premium.name
}

output "deployer_ipv4_used" {
  description = "Public IP allow-listed for storage firewall and function SCM."
  value       = local.deployer_ipv4
}
