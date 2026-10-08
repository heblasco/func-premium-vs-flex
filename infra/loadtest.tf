###############################################################################
# Azure Load Testing resource
#
# The resource only provisions the Load Testing service. The JMeter test plan,
# VNet (subnet) test configuration and the test run itself are data-plane
# operations performed by scripts/run-loadtest.ps1 (az load test ...).
###############################################################################

resource "azurerm_load_test" "main" {
  count               = var.enable_load_testing ? 1 : 0
  name                = "lt-${var.name_prefix}-${local.suffix}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags

  identity {
    type = "SystemAssigned"
  }
}
