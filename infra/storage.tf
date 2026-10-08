###############################################################################
# Storage accounts
#
# Both accounts are network-restricted (default-deny firewall + private
# endpoints) and only reachable from the VNet or the allow-listed deployer IP.
#
# Runtime access to AzureWebJobsStorage is via each app's user-assigned managed
# identity (keyless). Shared key access is left enabled because:
#   * Terraform creates the deployment container / content share via data plane;
#   * Premium (Elastic Premium) requires a shared-key Azure Files content share
#     (WEBSITE_CONTENTAZUREFILECONNECTIONSTRING) - identity-based content shares
#     are not supported on that plan. This asymmetry is documented in the README.
###############################################################################

locals {
  deployer_ip_rules = local.deployer_ipv4 != null ? [local.deployer_ipv4] : []
}

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
  shared_access_key_enabled       = true
  public_network_access_enabled   = true
  allow_nested_items_to_be_public = false
  tags                            = local.tags

  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices"]
    ip_rules       = local.deployer_ip_rules
  }
}

resource "azurerm_storage_container" "flex_deployment" {
  name                  = "deploymentpackage"
  storage_account_id    = azurerm_storage_account.flex.id
  container_access_type = "private"
}

# --- Premium storage ----------------------------------------------------------
resource "azurerm_storage_account" "premium" {
  name                            = local.premium_storage_name
  resource_group_name             = azurerm_resource_group.main.name
  location                        = azurerm_resource_group.main.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  shared_access_key_enabled       = true
  public_network_access_enabled   = true
  allow_nested_items_to_be_public = false
  tags                            = local.tags

  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices"]
    ip_rules       = local.deployer_ip_rules
  }
}

# Azure Files content share for the Premium plan (required by the platform).
resource "azurerm_storage_share" "premium_content" {
  name               = "content-${local.suffix}"
  storage_account_id = azurerm_storage_account.premium.id
  quota              = 5
}

###############################################################################
# Private endpoints + DNS zone groups
###############################################################################

# Flex: blob endpoint (deployment container + AzureWebJobsStorage blob access).
resource "azurerm_private_endpoint" "flex_blob" {
  name                = "pe-${local.flex_storage_name}-blob"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.pe.id
  tags                = local.tags

  private_service_connection {
    name                           = "psc-blob"
    private_connection_resource_id = azurerm_storage_account.flex.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "blob"
    private_dns_zone_ids = [azurerm_private_dns_zone.zones["blob"].id]
  }
}

resource "azurerm_private_endpoint" "flex_queue" {
  name                = "pe-${local.flex_storage_name}-queue"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.pe.id
  tags                = local.tags

  private_service_connection {
    name                           = "psc-queue"
    private_connection_resource_id = azurerm_storage_account.flex.id
    subresource_names              = ["queue"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "queue"
    private_dns_zone_ids = [azurerm_private_dns_zone.zones["queue"].id]
  }
}

# Premium: blob, file (content share) and queue endpoints.
resource "azurerm_private_endpoint" "premium_blob" {
  name                = "pe-${local.premium_storage_name}-blob"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.pe.id
  tags                = local.tags

  private_service_connection {
    name                           = "psc-blob"
    private_connection_resource_id = azurerm_storage_account.premium.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "blob"
    private_dns_zone_ids = [azurerm_private_dns_zone.zones["blob"].id]
  }
}

resource "azurerm_private_endpoint" "premium_file" {
  name                = "pe-${local.premium_storage_name}-file"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.pe.id
  tags                = local.tags

  private_service_connection {
    name                           = "psc-file"
    private_connection_resource_id = azurerm_storage_account.premium.id
    subresource_names              = ["file"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "file"
    private_dns_zone_ids = [azurerm_private_dns_zone.zones["file"].id]
  }
}

resource "azurerm_private_endpoint" "premium_queue" {
  name                = "pe-${local.premium_storage_name}-queue"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.pe.id
  tags                = local.tags

  private_service_connection {
    name                           = "psc-queue"
    private_connection_resource_id = azurerm_storage_account.premium.id
    subresource_names              = ["queue"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "queue"
    private_dns_zone_ids = [azurerm_private_dns_zone.zones["queue"].id]
  }
}
