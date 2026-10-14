###############################################################################
# Storage accounts
#
# Subscription policy forces every storage account to be keyless
# (allowSharedKeyAccess = false) and private (publicNetworkAccess = Disabled).
# The Terraform configuration matches that policy to avoid perpetual drift:
#
#   * shared_access_key_enabled     = false  -> only Entra ID (AAD) data plane
#   * public_network_access_enabled = false  -> only reachable via private
#                                               endpoints from inside the VNet
#
# Consequences:
#   * Runtime access to AzureWebJobsStorage is via each app's user-assigned
#     managed identity (Blob + Queue + Table data roles, see rbac.tf).
#   * The Flex deployment container is created through the Azure Resource
#     Manager control plane (azapi) because the data plane is unreachable from
#     the deployer machine.
#   * No Azure Files content share is used. The legacy Premium-named side is
#     Dedicated. Optional Elastic Premium uses an external private Blob package
#     with managed identity; see functions_elastic_premium.tf.
###############################################################################

# --- Flex Consumption storage -------------------------------------------------
resource "azurerm_storage_account" "flex" {
  name                            = local.flex_storage_name
  resource_group_name             = azurerm_resource_group.main.name
  location                        = azurerm_resource_group.main.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  shared_access_key_enabled       = false
  public_network_access_enabled   = false
  default_to_oauth_authentication = true
  allow_nested_items_to_be_public = false
  tags                            = local.tags
}

# Deployment container for the Flex Consumption app. Created via the control
# plane (azapi) because the data plane is private + keyless.
resource "azapi_resource" "flex_deployment_container" {
  type      = "Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01"
  name      = "deploymentpackage"
  parent_id = "${azurerm_storage_account.flex.id}/blobServices/default"

  body = {
    properties = {
      publicAccess = "None"
    }
  }
}

# --- Premium (Dedicated plan) storage -----------------------------------------
resource "azurerm_storage_account" "premium" {
  name                            = local.premium_storage_name
  resource_group_name             = azurerm_resource_group.main.name
  location                        = azurerm_resource_group.main.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  shared_access_key_enabled       = false
  public_network_access_enabled   = false
  default_to_oauth_authentication = true
  allow_nested_items_to_be_public = false
  tags                            = local.tags
}

###############################################################################
# Private endpoints + DNS zone groups
#
# Identity-based AzureWebJobsStorage needs Blob, Queue and Table data access, so
# each account gets a private endpoint for all three sub-resources.
###############################################################################

locals {
  storage_accounts = {
    flex    = azurerm_storage_account.flex.id
    premium = azurerm_storage_account.premium.id
  }
  # One private endpoint per (account, sub-resource) pair.
  storage_private_endpoints = merge([
    for acc_key, acc_id in local.storage_accounts : {
      for sub in ["blob", "queue", "table"] :
      "${acc_key}-${sub}" => {
        account_id  = acc_id
        account     = acc_key
        subresource = sub
      }
    }
  ]...)
}

resource "azurerm_private_endpoint" "storage" {
  for_each = local.storage_private_endpoints

  name                = "pe-${var.name_prefix}-${each.value.account}-${each.value.subresource}-${local.suffix}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.pe.id
  tags                = local.tags

  private_service_connection {
    name                           = "psc-${each.value.subresource}"
    private_connection_resource_id = each.value.account_id
    subresource_names              = [each.value.subresource]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = each.value.subresource
    private_dns_zone_ids = [azurerm_private_dns_zone.zones[each.value.subresource].id]
  }
}
