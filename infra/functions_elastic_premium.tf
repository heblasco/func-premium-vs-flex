# Optional third arm. Bootstrap storage first, upload <sha256>.zip from a
# private executor, then set ep_package_sha256 to create the EP plan and app.
locals {
  ep_app_enabled = var.enable_elastic_premium && var.ep_package_sha256 != null
  ep_app_name    = "${var.name_prefix}-ep-${local.suffix}"
  ep_roles = var.enable_elastic_premium ? toset([
    "Storage Blob Data Owner", "Storage Queue Data Contributor", "Storage Table Data Contributor"
  ]) : toset([])
}

resource "azurerm_storage_account" "ep" {
  count                           = var.enable_elastic_premium ? 1 : 0
  name                            = "${var.name_prefix}ep${local.suffix}sa"
  resource_group_name             = azurerm_resource_group.main.name
  location                        = azurerm_resource_group.main.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  shared_access_key_enabled       = false
  public_network_access_enabled   = false
  default_to_oauth_authentication = true
  allow_nested_items_to_be_public = false
  https_traffic_only_enabled      = true
  tags                            = local.tags
}

resource "azapi_resource" "ep_package_container" {
  count     = var.enable_elastic_premium ? 1 : 0
  type      = "Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01"
  name      = "deploymentpackage"
  parent_id = "${azurerm_storage_account.ep[0].id}/blobServices/default"
  body      = { properties = { publicAccess = "None" } }
}

resource "azurerm_user_assigned_identity" "ep" {
  count               = var.enable_elastic_premium ? 1 : 0
  name                = "id-ep-${local.suffix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = local.tags
}

resource "azurerm_role_assignment" "ep_storage" {
  for_each             = local.ep_roles
  scope                = azurerm_storage_account.ep[0].id
  role_definition_name = each.key
  principal_id         = azurerm_user_assigned_identity.ep[0].principal_id
}

resource "azurerm_role_assignment" "ep_publisher" {
  count                = var.enable_elastic_premium && var.ep_publisher_principal_id != null ? 1 : 0
  scope                = azapi_resource.ep_package_container[0].id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = var.ep_publisher_principal_id
}

resource "time_sleep" "ep_rbac" {
  count           = var.enable_elastic_premium ? 1 : 0
  create_duration = "60s"
  depends_on      = [azurerm_role_assignment.ep_storage, azurerm_role_assignment.ep_publisher]
}

resource "azurerm_subnet" "ep_integ" {
  count                = var.enable_elastic_premium ? 1 : 0
  name                 = "snet-ep-integ"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [cidrsubnet(var.vnet_address_space, 3, 6)] # 10.60.3.0/25 for the default /22
  delegation {
    name = "ep-delegation"
    service_delegation {
      name    = "Microsoft.Web/serverFarms"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_network_security_group" "ep_integ" {
  count               = var.enable_elastic_premium ? 1 : 0
  name                = "nsg-ep-integ-${local.suffix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = local.tags
}

resource "azurerm_subnet_network_security_group_association" "ep_integ" {
  count                     = var.enable_elastic_premium ? 1 : 0
  subnet_id                 = azurerm_subnet.ep_integ[0].id
  network_security_group_id = azurerm_network_security_group.ep_integ[0].id
}

resource "azurerm_private_endpoint" "ep_storage" {
  for_each            = var.enable_elastic_premium ? toset(["blob", "queue", "table"]) : toset([])
  name                = "pe-ep-${each.key}-${local.suffix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  subnet_id           = azurerm_subnet.pe.id
  tags                = local.tags
  private_service_connection {
    name                           = "psc-${each.key}"
    private_connection_resource_id = azurerm_storage_account.ep[0].id
    subresource_names              = [each.key]
    is_manual_connection           = false
  }
  private_dns_zone_group {
    name                 = each.key
    private_dns_zone_ids = [azurerm_private_dns_zone.zones[each.key].id]
  }
}

resource "azurerm_service_plan" "ep" {
  count                        = local.ep_app_enabled ? 1 : 0
  name                         = "asp-ep-${local.suffix}"
  resource_group_name          = azurerm_resource_group.main.name
  location                     = azurerm_resource_group.main.location
  os_type                      = "Linux"
  sku_name                     = "EP1"
  worker_count                 = var.ep_minimum_instances
  maximum_elastic_worker_count = var.ep_maximum_instances
  tags                         = local.tags
}

resource "azurerm_linux_function_app" "ep" {
  lifecycle {
    ignore_changes = [tags["hidden-link: /app-insights-resource-id"]]
  }
  count                                          = local.ep_app_enabled ? 1 : 0
  name                                           = local.ep_app_name
  resource_group_name                            = azurerm_resource_group.main.name
  location                                       = azurerm_resource_group.main.location
  service_plan_id                                = azurerm_service_plan.ep[0].id
  storage_account_name                           = azurerm_storage_account.ep[0].name
  storage_uses_managed_identity                  = true
  content_share_force_disabled                   = true
  ftp_publish_basic_authentication_enabled       = false
  webdeploy_publish_basic_authentication_enabled = false
  functions_extension_version                    = "~4"
  https_only                                     = true
  public_network_access_enabled                  = true
  virtual_network_subnet_id                      = azurerm_subnet.ep_integ[0].id
  tags                                           = local.tags
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.ep[0].id]
  }
  app_settings = {
    PLAN_LABEL                                   = "elastic-premium"
    FUNCTIONS_WORKER_PROCESS_COUNT               = tostring(var.functions_worker_process_count)
    AzureWebJobsStorage__credential              = "managedidentity"
    AzureWebJobsStorage__clientId                = azurerm_user_assigned_identity.ep[0].client_id
    WEBSITE_RUN_FROM_PACKAGE                     = "${azurerm_storage_account.ep[0].primary_blob_endpoint}deploymentpackage/${var.ep_package_sha256}.zip"
    WEBSITE_RUN_FROM_PACKAGE_BLOB_MI_RESOURCE_ID = azurerm_user_assigned_identity.ep[0].id
  }
  site_config {
    always_on = false # EP readiness is controlled by elastic_instance_minimum.
    application_stack {
      node_version = var.premium_node_version
    }
    application_insights_connection_string = azurerm_application_insights.main.connection_string
    elastic_instance_minimum               = var.ep_minimum_instances
    pre_warmed_instance_count              = var.ep_prewarmed_instances
    app_scale_limit                        = var.ep_maximum_instances
    vnet_route_all_enabled                 = true
    minimum_tls_version                    = "1.2"
    scm_minimum_tls_version                = "1.2"
    ftps_state                             = "Disabled"
    ip_restriction_default_action          = local.restrict_public ? "Deny" : "Allow"
    scm_use_main_ip_restriction            = true
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
    time_sleep.ep_rbac, azurerm_private_endpoint.ep_storage,
    azurerm_private_dns_zone_virtual_network_link.links,
  ]
}

resource "azurerm_private_endpoint" "ep_sites" {
  count               = local.ep_app_enabled && var.enable_function_private_endpoints ? 1 : 0
  name                = "pe-${local.ep_app_name}-sites"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  subnet_id           = azurerm_subnet.pe.id
  tags                = local.tags
  private_service_connection {
    name                           = "psc-sites"
    private_connection_resource_id = azurerm_linux_function_app.ep[0].id
    subresource_names              = ["sites"]
    is_manual_connection           = false
  }
  private_dns_zone_group {
    name                 = "sites"
    private_dns_zone_ids = [azurerm_private_dns_zone.zones["sites"].id]
  }
}

output "elastic_premium" {
  description = "Optional EP bootstrap/deployment metadata; null when disabled."
  value = var.enable_elastic_premium ? {
    storage_account = azurerm_storage_account.ep[0].name
    container       = azapi_resource.ep_package_container[0].name
    app_name        = local.ep_app_enabled ? azurerm_linux_function_app.ep[0].name : null
    app_id          = local.ep_app_enabled ? azurerm_linux_function_app.ep[0].id : null
    hostname        = local.ep_app_enabled ? azurerm_linux_function_app.ep[0].default_hostname : null
    package_sha256  = var.ep_package_sha256
  } : null
}
