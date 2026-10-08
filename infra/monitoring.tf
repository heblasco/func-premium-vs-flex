###############################################################################
# Monitoring: Log Analytics workspace + shared workspace-based Application
# Insights. Both function apps send telemetry to the same component and are
# distinguished by cloud_RoleName (= app name) and the custom "plan" dimension.
###############################################################################

resource "azurerm_log_analytics_workspace" "main" {
  name                = "log-${var.name_prefix}-${local.suffix}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.tags
}

resource "azurerm_application_insights" "main" {
  name                = "appi-${var.name_prefix}-${local.suffix}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  workspace_id        = azurerm_log_analytics_workspace.main.id
  application_type    = "Node.JS"
  # Disable adaptive sampling at the component level so request/metric counts are
  # not skewed between the two plans during a benchmark run.
  sampling_percentage = 100
  tags                = local.tags
}
