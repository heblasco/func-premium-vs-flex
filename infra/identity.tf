###############################################################################
# User-assigned managed identities (one per app).
#
# Using UAMIs (instead of system-assigned) lets us assign storage data-plane
# roles BEFORE the function apps are created, avoiding the first-apply RBAC
# bootstrap race where an app starts before its principal has permissions.
###############################################################################

resource "azurerm_user_assigned_identity" "flex" {
  name                = "id-${local.flex_app_name}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags
}

resource "azurerm_user_assigned_identity" "premium" {
  name                = "id-${local.premium_app_name}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags
}
