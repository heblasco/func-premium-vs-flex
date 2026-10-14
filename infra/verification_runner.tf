# Private verification executor. No public NIC address or inbound management.
variable "enable_verification_runner" {
  type        = bool
  default     = false
  description = "Create the private managed-identity verification VM and explicit outbound NAT."
}

variable "verification_ssh_public_key_path" {
  type        = string
  default     = null
  description = "Local public key file for the VM OS account. SSH ingress remains denied."
  validation {
    condition     = !var.enable_verification_runner || var.verification_ssh_public_key_path != null
    error_message = "The verification runner requires a local public key path."
  }
}

resource "azurerm_user_assigned_identity" "verification" {
  count               = var.enable_verification_runner ? 1 : 0
  name                = "id-verify-${local.suffix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = local.tags
}

resource "azurerm_subnet" "verification" {
  count                           = var.enable_verification_runner ? 1 : 0
  name                            = "snet-verification"
  resource_group_name             = azurerm_resource_group.main.name
  virtual_network_name            = azurerm_virtual_network.main.name
  address_prefixes                = [cidrsubnet(var.vnet_address_space, 4, 5)]
  default_outbound_access_enabled = false
}

resource "azurerm_network_security_group" "verification" {
  count               = var.enable_verification_runner ? 1 : 0
  name                = "nsg-verify-${local.suffix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = local.tags
  security_rule {
    name                       = "deny-inbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
  security_rule {
    name                       = "allow-https"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
  security_rule {
    name                       = "allow-platform"
    priority                   = 110
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_ranges    = ["53", "80", "32526"]
    source_address_prefix      = "*"
    destination_address_prefix = "168.63.129.16"
  }
  security_rule {
    name                       = "allow-managed-identity"
    priority                   = 120
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"
    destination_address_prefix = "169.254.169.254"
  }
  security_rule {
    name                       = "deny-other-outbound"
    priority                   = 4000
    direction                  = "Outbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "verification" {
  count                     = var.enable_verification_runner ? 1 : 0
  subnet_id                 = azurerm_subnet.verification[0].id
  network_security_group_id = azurerm_network_security_group.verification[0].id
}

resource "azurerm_public_ip" "verification_egress" {
  lifecycle {
    ignore_changes = [ip_tags["FirstPartyUsage"]]
  }
  count               = var.enable_verification_runner ? 1 : 0
  name                = "pip-verify-egress-${local.suffix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_nat_gateway" "verification" {
  count               = var.enable_verification_runner ? 1 : 0
  name                = "nat-verify-${local.suffix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku_name            = "Standard"
  tags                = local.tags
}

resource "azurerm_nat_gateway_public_ip_association" "verification" {
  count                = var.enable_verification_runner ? 1 : 0
  nat_gateway_id       = azurerm_nat_gateway.verification[0].id
  public_ip_address_id = azurerm_public_ip.verification_egress[0].id
}

resource "azurerm_subnet_nat_gateway_association" "verification" {
  count          = var.enable_verification_runner ? 1 : 0
  subnet_id      = azurerm_subnet.verification[0].id
  nat_gateway_id = azurerm_nat_gateway.verification[0].id
}

resource "azurerm_network_interface" "verification" {
  count               = var.enable_verification_runner ? 1 : 0
  name                = "nic-verify-${local.suffix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = local.tags
  ip_configuration {
    name                          = "private"
    subnet_id                     = azurerm_subnet.verification[0].id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_linux_virtual_machine" "verification" {
  count                           = var.enable_verification_runner ? 1 : 0
  name                            = "vm-verify-${local.suffix}"
  resource_group_name             = azurerm_resource_group.main.name
  location                        = azurerm_resource_group.main.location
  size                            = "Standard_D2s_v5"
  admin_username                  = "verifier"
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.verification[0].id]
  secure_boot_enabled             = true
  vtpm_enabled                    = true
  patch_mode                      = "AutomaticByPlatform"
  patch_assessment_mode           = "AutomaticByPlatform"
  tags                            = merge(local.tags, { purpose = "private-verification" })
  admin_ssh_key {
    username   = "verifier"
    public_key = var.verification_ssh_public_key_path == null ? "" : file(var.verification_ssh_public_key_path)
  }
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.verification[0].id]
  }
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = 32
  }
  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }
  boot_diagnostics {}
  depends_on = [
    azurerm_subnet_network_security_group_association.verification,
    azurerm_nat_gateway_public_ip_association.verification,
    azurerm_subnet_nat_gateway_association.verification,
  ]
}

resource "azurerm_dev_test_global_vm_shutdown_schedule" "verification" {
  count                 = var.enable_verification_runner ? 1 : 0
  virtual_machine_id    = azurerm_linux_virtual_machine.verification[0].id
  location              = azurerm_resource_group.main.location
  enabled               = true
  daily_recurrence_time = "2200"
  timezone              = "UTC"
  notification_settings {
    enabled = false
  }
  tags = local.tags
}

resource "azapi_resource" "verification_results" {
  count     = var.enable_verification_runner ? 1 : 0
  type      = "Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01"
  name      = "startupresults"
  parent_id = "${azurerm_storage_account.flex.id}/blobServices/default"
  body      = { properties = { publicAccess = "None" } }
}

resource "azurerm_role_assignment" "verification_results" {
  count                = var.enable_verification_runner ? 1 : 0
  scope                = azapi_resource.verification_results[0].id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.verification[0].principal_id
}

resource "azurerm_role_assignment" "verification_ep_package" {
  count                = var.enable_verification_runner && var.enable_elastic_premium ? 1 : 0
  scope                = azapi_resource.ep_package_container[0].id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.verification[0].principal_id
}

resource "azurerm_role_definition" "verification_publish" {
  count       = var.enable_verification_runner ? 1 : 0
  name        = "Function verification publisher ${local.suffix}"
  scope       = azurerm_resource_group.main.id
  description = "App-scoped read, key discovery and package publication; no infrastructure administration."
  permissions {
    actions = [
      "Microsoft.Web/sites/read",
      "Microsoft.Web/sites/config/read",
      "Microsoft.Web/sites/config/list/action",
      "Microsoft.Web/sites/host/listkeys/action",
      "Microsoft.Web/sites/publish/action",
      "Microsoft.Web/sites/syncfunctiontriggers/action",
      "Microsoft.Web/sites/extensions/read",
      "Microsoft.Web/sites/extensions/write",
    ]
  }
  assignable_scopes = [azurerm_resource_group.main.id]
}

locals {
  verification_sites = var.enable_verification_runner ? merge({
    flex      = azurerm_function_app_flex_consumption.flex.id
    dedicated = azurerm_linux_function_app.premium.id
  }, local.ep_app_enabled ? { ep = azurerm_linux_function_app.ep[0].id } : {}) : {}
}

resource "azurerm_role_assignment" "verification_publish" {
  for_each           = local.verification_sites
  scope              = each.value
  role_definition_id = azurerm_role_definition.verification_publish[0].role_definition_resource_id
  principal_id       = azurerm_user_assigned_identity.verification[0].principal_id
}

output "verification_runner" {
  value = var.enable_verification_runner ? {
    vm_name           = azurerm_linux_virtual_machine.verification[0].name
    vm_id             = azurerm_linux_virtual_machine.verification[0].id
    client_id         = azurerm_user_assigned_identity.verification[0].client_id
    results_account   = azurerm_storage_account.flex.name
    results_container = azapi_resource.verification_results[0].name
  } : null
}
