###############################################################################
# Premium (Elastic Premium) function app
#
# Platform note: Elastic Premium requires an Azure Files content share, which
# only supports a shared-key connection string (identity-based content shares
# are not supported on this plan). Host storage therefore uses the access key,
# while the app-level UAMI is still attached. Flex Consumption, by contrast, is
# fully keyless - this asymmetry is itself a finding in the comparison.
# Content-share traffic is forced over the VNet (WEBSITE_CONTENTOVERVNET=1 +
# vnet_route_all_enabled) to the private "file" endpoint.
###############################################################################

resource "azurerm_service_plan" "premium" {
  name                         = "asp-prem-${local.suffix}"
  location                     = azurerm_resource_group.main.location
  resource_group_name          = azurerm_resource_group.main.name
  os_type                      = "Linux"
  sku_name                     = var.premium_sku_name
  maximum_elastic_worker_count = var.premium_maximum_elastic_worker_count
  tags                         = local.tags
}

resource "azurerm_linux_function_app" "premium" {
  name                = local.premium_app_name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  service_plan_id     = azurerm_service_plan.premium.id

  storage_account_name       = azurerm_storage_account.premium.name
  storage_account_access_key = azurerm_storage_account.premium.primary_access_key

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
    # Route the Azure Files content share over the VNet to the private endpoint.
    WEBSITE_CONTENTOVERVNET = "1"
    WEBSITE_CONTENTSHARE    = azurerm_storage_share.premium_content.name
  }

  site_config {
    application_stack {
      node_version = var.premium_node_version
    }

    application_insights_connection_string = azurerm_application_insights.main.connection_string

    vnet_route_all_enabled    = true
    pre_warmed_instance_count = var.premium_prewarmed_instance_count
    minimum_tls_version       = "1.2"

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
    azurerm_private_endpoint.premium_blob,
    azurerm_private_endpoint.premium_file,
    azurerm_private_endpoint.premium_queue,
    azurerm_private_dns_zone_virtual_network_link.links,
  ]

  tags = local.tags

  lifecycle {
    ignore_changes = [
      # The platform manages the content-share connection string app setting.
      app_settings["WEBSITE_CONTENTAZUREFILECONNECTIONSTRING"],
    ]
  }
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
