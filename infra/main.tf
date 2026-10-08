###############################################################################
# Context, uniqueness suffix and resource group
###############################################################################

data "azurerm_client_config" "current" {}

# Auto-discover the operator public IPv4 when not provided explicitly. Used to
# allow the deployer through the storage firewall and the function SCM endpoint.
data "http" "deployer_ip" {
  count = var.deployer_ipv4 == null && var.auto_discover_deployer_ip ? 1 : 0
  url   = "https://api.ipify.org"
}

# Random 4-hex-digit UID appended to every resource name to avoid collisions.
resource "random_id" "suffix" {
  byte_length = 2
}

locals {
  suffix = random_id.suffix.hex

  deployer_ipv4 = var.deployer_ipv4 != null ? var.deployer_ipv4 : (
    var.auto_discover_deployer_ip ? trimspace(data.http.deployer_ip[0].response_body) : null
  )

  # Storage account names: 3-24 chars, lowercase/digits only, globally unique.
  flex_storage_name    = substr("${var.name_prefix}flex${local.suffix}sa", 0, 24)
  premium_storage_name = substr("${var.name_prefix}prem${local.suffix}sa", 0, 24)

  flex_app_name    = "${var.name_prefix}-flex-${local.suffix}"
  premium_app_name = "${var.name_prefix}-prem-${local.suffix}"

  tags = merge(var.tags, { suffix = local.suffix })
}

resource "azurerm_resource_group" "main" {
  name     = "rg-${var.name_prefix}-${local.suffix}"
  location = var.location
  tags     = local.tags
}
