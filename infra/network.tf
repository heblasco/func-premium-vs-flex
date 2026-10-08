###############################################################################
# Virtual network, subnets and NSGs
###############################################################################

resource "azurerm_virtual_network" "main" {
  name                = "vnet-${var.name_prefix}-${local.suffix}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  address_space       = [var.vnet_address_space]
  tags                = local.tags
}

# --- Flex Consumption VNet integration subnet (delegated to Microsoft.App) ----
resource "azurerm_subnet" "flex_integ" {
  name                 = "snet-flex-integ"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [cidrsubnet(var.vnet_address_space, 3, 0)] # /25 -> 10.60.0.0/25

  delegation {
    name = "flex-delegation"
    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

# --- Premium VNet integration subnet (delegated to Microsoft.Web/serverFarms) -
resource "azurerm_subnet" "premium_integ" {
  name                 = "snet-premium-integ"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [cidrsubnet(var.vnet_address_space, 3, 1)] # /25 -> 10.60.0.128/25

  delegation {
    name = "premium-delegation"
    service_delegation {
      name    = "Microsoft.Web/serverFarms"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

# --- Private endpoints subnet (no delegation) --------------------------------
resource "azurerm_subnet" "pe" {
  name                              = "snet-pe"
  resource_group_name               = azurerm_resource_group.main.name
  virtual_network_name              = azurerm_virtual_network.main.name
  address_prefixes                  = [cidrsubnet(var.vnet_address_space, 4, 4)] # /26 -> 10.60.1.0/26
  private_endpoint_network_policies = "Enabled"
}

# --- Azure Load Testing injection subnet (no delegation, generous size) -------
resource "azurerm_subnet" "loadtest" {
  name                 = "snet-loadtest"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [cidrsubnet(var.vnet_address_space, 2, 2)] # /24 -> 10.60.2.0/24, large block for test engines
}

###############################################################################
# NSGs (associated; default rules already allow intra-VNet + outbound internet)
###############################################################################

resource "azurerm_network_security_group" "flex_integ" {
  name                = "nsg-flex-integ-${local.suffix}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags
}

resource "azurerm_network_security_group" "premium_integ" {
  name                = "nsg-premium-integ-${local.suffix}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags
}

resource "azurerm_network_security_group" "pe" {
  name                = "nsg-pe-${local.suffix}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags
}

resource "azurerm_network_security_group" "loadtest" {
  name                = "nsg-loadtest-${local.suffix}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags
}

resource "azurerm_subnet_network_security_group_association" "flex_integ" {
  subnet_id                 = azurerm_subnet.flex_integ.id
  network_security_group_id = azurerm_network_security_group.flex_integ.id
}

resource "azurerm_subnet_network_security_group_association" "premium_integ" {
  subnet_id                 = azurerm_subnet.premium_integ.id
  network_security_group_id = azurerm_network_security_group.premium_integ.id
}

resource "azurerm_subnet_network_security_group_association" "pe" {
  subnet_id                 = azurerm_subnet.pe.id
  network_security_group_id = azurerm_network_security_group.pe.id
}

resource "azurerm_subnet_network_security_group_association" "loadtest" {
  subnet_id                 = azurerm_subnet.loadtest.id
  network_security_group_id = azurerm_network_security_group.loadtest.id
}

###############################################################################
# Private DNS zones + VNet links
###############################################################################

locals {
  private_dns_zones = {
    blob  = "privatelink.blob.core.windows.net"
    file  = "privatelink.file.core.windows.net"
    queue = "privatelink.queue.core.windows.net"
    table = "privatelink.table.core.windows.net"
    sites = "privatelink.azurewebsites.net"
  }
}

resource "azurerm_private_dns_zone" "zones" {
  for_each            = local.private_dns_zones
  name                = each.value
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "links" {
  for_each              = local.private_dns_zones
  name                  = "link-${each.key}-${local.suffix}"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.zones[each.key].name
  virtual_network_id    = azurerm_virtual_network.main.id
  registration_enabled  = false
  tags                  = local.tags
}
