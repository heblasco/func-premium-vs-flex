###############################################################################
# "Premium" side: Dedicated App Service plan function app
#
# Design note / deviation: the subscription enforces keyless + private storage
# (allowSharedKeyAccess = false). Elastic Premium (EPx) requires an Azure Files
# content share that only supports a shared-key connection string, so it is not
# viable here. Instead the always-on / reserved-capacity side runs on a
# Dedicated App Service plan (default P0v3), which supports:
#   * identity-based AzureWebJobsStorage (storage_uses_managed_identity = true)
#   * running without the Azure Files mount (WEBSITES_ENABLE_APP_SERVICE_STORAGE
#     = false) + always_on
# The comparison is therefore "serverless Flex Consumption" vs "reserved,
# always-warm Dedicated plan". Documented in the README.
###############################################################################

resource "azurerm_service_plan" "premium" {
  name                = "asp-ded-${local.suffix}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  os_type             = "Linux"
  sku_name            = var.premium_sku_name
  worker_count        = var.premium_worker_count
  tags                = local.tags
}

resource "azurerm_linux_function_app" "premium" {
  name                = local.premium_app_name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  service_plan_id     = azurerm_service_plan.premium.id

  # Keyless host storage via the user-assigned managed identity.
  storage_account_name          = azurerm_storage_account.premium.name
  storage_uses_managed_identity = true

  functions_extension_version = "~4"
  https_only                  = true

  public_network_access_enabled = true
  virtual_network_subnet_id     = azurerm_subnet.premium_integ.id

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.premium.id]
  }

  app_settings = {
    PLAN_LABEL                     = "premium"
    FUNCTIONS_WORKER_PROCESS_COUNT = tostring(var.functions_worker_process_count)
    # Select the user-assigned identity for the AzureWebJobsStorage connection.
    AzureWebJobsStorage__clientId = azurerm_user_assigned_identity.premium.client_id
    # No Azure Files content mount: run from the local worker filesystem.
    WEBSITES_ENABLE_APP_SERVICE_STORAGE = "false"
  }

  site_config {
    application_stack {
      node_version = var.premium_node_version
    }

    application_insights_connection_string = azurerm_application_insights.main.connection_string

    always_on              = true
    vnet_route_all_enabled = true
    minimum_tls_version    = "1.2"

    ip_restriction_default_action = local.restrict_public ? "Deny" : "Allow"
    scm_use_main_ip_restriction   = true

    dynamic "ip_restriction" {
      for_each = local.restrict_public ? [1] : []
      content {
        name       = "allow-deployer"
        ip_address = local.deployer_cidr
        action     = "Allow"
        priority   = 100
      }
    }
  }

  depends_on = [
    time_sleep.rbac_propagation,
    azurerm_private_endpoint.storage,
    azurerm_private_dns_zone_virtual_network_link.links,
  ]

  tags = local.tags
}

resource "azurerm_private_endpoint" "premium_sites" {
  count               = var.enable_function_private_endpoints ? 1 : 0
  name                = "pe-${local.premium_app_name}-sites"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.pe.id
  tags                = local.tags

  private_service_connection {
    name                           = "psc-sites"
    private_connection_resource_id = azurerm_linux_function_app.premium.id
    subresource_names              = ["sites"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "sites"
    private_dns_zone_ids = [azurerm_private_dns_zone.zones["sites"].id]
  }
}
