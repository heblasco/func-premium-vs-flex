###############################################################################
# RBAC: grant each app's UAMI data-plane access to its storage account BEFORE
# the function app is created, then wait for Entra/RBAC propagation.
###############################################################################

# --- Flex UAMI -> Flex storage -----------------------------------------------
resource "azurerm_role_assignment" "flex_blob_owner" {
  scope                = azurerm_storage_account.flex.id
  role_definition_name = "Storage Blob Data Owner"
  principal_id         = azurerm_user_assigned_identity.flex.principal_id
}

resource "azurerm_role_assignment" "flex_queue" {
  scope                = azurerm_storage_account.flex.id
  role_definition_name = "Storage Queue Data Contributor"
  principal_id         = azurerm_user_assigned_identity.flex.principal_id
}

# --- Premium UAMI -> Premium storage -----------------------------------------
resource "azurerm_role_assignment" "premium_blob_owner" {
  scope                = azurerm_storage_account.premium.id
  role_definition_name = "Storage Blob Data Owner"
  principal_id         = azurerm_user_assigned_identity.premium.principal_id
}

resource "azurerm_role_assignment" "premium_queue" {
  scope                = azurerm_storage_account.premium.id
  role_definition_name = "Storage Queue Data Contributor"
  principal_id         = azurerm_user_assigned_identity.premium.principal_id
}

# Allow time for role assignments to propagate before the apps use the identity.
resource "time_sleep" "rbac_propagation" {
  create_duration = "60s"

  depends_on = [
    azurerm_role_assignment.flex_blob_owner,
    azurerm_role_assignment.flex_queue,
    azurerm_role_assignment.premium_blob_owner,
    azurerm_role_assignment.premium_queue,
  ]
}
