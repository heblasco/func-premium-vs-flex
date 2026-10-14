###############################################################################
# Flex Consumption function app
###############################################################################

locals {
  restrict_public = local.deployer_ipv4 != null || var.deployer_allow_cidr != null
  deployer_cidr = var.deployer_allow_cidr != null ? var.deployer_allow_cidr : (
    local.deployer_ipv4 != null ? "${local.deployer_ipv4}/32" : null
  )
}

resource "azurerm_service_plan" "flex" {
  name                = "asp-flex-${local.suffix}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  os_type             = "Linux"
  sku_name            = "FC1"
  tags                = local.tags
}

resource "azurerm_function_app_flex_consumption" "flex" {
  name                = local.flex_app_name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  service_plan_id     = azurerm_service_plan.flex.id

  # Deployment storage via user-assigned managed identity (keyless).
  storage_container_type            = "blobContainer"
  storage_container_endpoint        = "${azurerm_storage_account.flex.primary_blob_endpoint}${azapi_resource.flex_deployment_container.name}"
  storage_authentication_type       = "UserAssignedIdentity"
  storage_user_assigned_identity_id = azurerm_user_assigned_identity.flex.id

  runtime_name           = "node"
  runtime_version        = var.flex_runtime_version
  instance_memory_in_mb  = var.flex_instance_memory_mb
  maximum_instance_count = var.flex_maximum_instance_count

  https_only                    = true
  public_network_access_enabled = true

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.flex.id]
  }

  virtual_network_subnet_id = azurerm_subnet.flex_integ.id

  dynamic "always_ready" {
    for_each = var.flex_always_ready_count > 0 ? [1] : []
    content {
      name           = "http"
      instance_count = var.flex_always_ready_count
    }
  }

  app_settings = {
    PLAN_LABEL = "flex"
    # Identity-based AzureWebJobsStorage for the host secret/key store. The Flex
    # resource otherwise injects a shared-key connection string with an empty
    # AccountKey (shared keys are disabled by policy), which breaks key
    # management. The plain AzureWebJobsStorage setting is removed afterwards by
    # terraform_data.flex_fix_host_storage so the identity triplet takes effect.
    AzureWebJobsStorage__accountName = azurerm_storage_account.flex.name
    AzureWebJobsStorage__credential  = "managedidentity"
    AzureWebJobsStorage__clientId    = azurerm_user_assigned_identity.flex.client_id
  }

  site_config {
    application_insights_connection_string = azurerm_application_insights.main.connection_string
    minimum_tls_version                    = "1.2"
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
    time_sleep.rbac_propagation,
    azapi_resource.flex_deployment_container,
    azurerm_private_endpoint.storage,
    azurerm_private_dns_zone_virtual_network_link.links,
  ]

  tags = local.tags
  lifecycle {
    ignore_changes = [tags["hidden-link: /app-insights-resource-id"]]
  }
}

# The Flex Consumption resource injects a plain AzureWebJobsStorage connection
# string with an empty AccountKey (shared keys disabled by policy), which breaks
# the host secret store. Remove it so the AzureWebJobsStorage__* identity
# settings take effect. Re-run after the experiment's runtime/readiness changes.
resource "terraform_data" "flex_fix_host_storage" {
  triggers_replace = [
    azurerm_function_app_flex_consumption.flex.id,
    var.flex_runtime_version,
    var.flex_always_ready_count,
    azurerm_function_app_flex_consumption.flex.app_settings,
  ]

  provisioner "local-exec" {
    interpreter = ["cmd", "/c"]
    command     = "az functionapp config appsettings delete -g ${azurerm_resource_group.main.name} -n ${azurerm_function_app_flex_consumption.flex.name} --setting-names AzureWebJobsStorage -o none"
  }
}

resource "azurerm_private_endpoint" "flex_sites" {
  count               = var.enable_function_private_endpoints ? 1 : 0
  name                = "pe-${local.flex_app_name}-sites"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.pe.id
  tags                = local.tags

  private_service_connection {
    name                           = "psc-sites"
    private_connection_resource_id = azurerm_function_app_flex_consumption.flex.id
    subresource_names              = ["sites"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "sites"
    private_dns_zone_ids = [azurerm_private_dns_zone.zones["sites"].id]
  }
}
