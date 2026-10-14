mock_provider "azurerm" {}
mock_provider "azapi" {}
mock_provider "http" {}
mock_provider "random" {}
mock_provider "time" {}

variables {
  enable_verification_runner       = false
  enable_elastic_premium           = false
  ep_package_sha256                = null
  verification_ssh_public_key_path = null
  subscription_id                  = "00000000-0000-0000-0000-000000000000"
  auto_discover_deployer_ip        = false
  deployer_ipv4                    = "203.0.113.25"
}

run "private_runner" {
  command = plan
  variables {
    enable_verification_runner       = true
    verification_ssh_public_key_path = "tests\\runner.pub"
  }
  assert {
    condition     = azurerm_network_interface.verification[0].ip_configuration[0].public_ip_address_id == null
    error_message = "The VM must not have a public IP."
  }
  assert {
    condition     = azurerm_subnet.verification[0].address_prefixes == tolist(["10.60.1.64/26"]) && !azurerm_subnet.verification[0].default_outbound_access_enabled
    error_message = "Use the non-overlapping private subnet and explicit outbound access."
  }
  assert {
    condition     = azurerm_linux_virtual_machine.verification[0].secure_boot_enabled && azurerm_linux_virtual_machine.verification[0].vtpm_enabled && azurerm_linux_virtual_machine.verification[0].disable_password_authentication
    error_message = "The runner requires Trusted Launch and no password authentication."
  }
}

run "disabled_by_default" {
  command = plan
  assert {
    condition     = length(azurerm_linux_function_app.ep) == 0 && length(azurerm_service_plan.ep) == 0 && length(azurerm_storage_account.ep) == 0
    error_message = "Default configuration must not create any EP resources."
  }
}

run "bootstrap_without_compute" {
  command = plan
  variables {
    enable_elastic_premium = true
  }
  assert {
    condition     = length(azurerm_storage_account.ep) == 1 && length(azurerm_linux_function_app.ep) == 0 && length(azurerm_service_plan.ep) == 0
    error_message = "Bootstrap must create storage but defer EP compute until a package hash is supplied."
  }
  assert {
    condition     = !azurerm_storage_account.ep[0].shared_access_key_enabled && !azurerm_storage_account.ep[0].public_network_access_enabled
    error_message = "EP storage must remain keyless and private."
  }
  assert {
    condition     = azurerm_subnet.ep_integ[0].address_prefixes[0] == "10.60.3.0/25"
    error_message = "EP subnet must not overlap existing default subnets."
  }
}

run "ep_ready_configuration" {
  command = plan
  variables {
    enable_elastic_premium = true
    ep_package_sha256      = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  }
  assert {
    condition     = azurerm_service_plan.ep[0].sku_name == "EP1" && azurerm_service_plan.ep[0].maximum_elastic_worker_count == 3
    error_message = "Use actual Elastic Premium with a bounded maximum."
  }
  assert {
    condition     = azurerm_linux_function_app.ep[0].content_share_force_disabled && azurerm_linux_function_app.ep[0].storage_uses_managed_identity
    error_message = "EP must not require an Azure Files shared key."
  }
  assert {
    condition     = azurerm_linux_function_app.ep[0].site_config[0].elastic_instance_minimum == 1 && azurerm_linux_function_app.ep[0].site_config[0].pre_warmed_instance_count == 1
    error_message = "Always-ready and prewarmed buffer must remain separate settings."
  }
  assert {
    condition     = azurerm_linux_function_app.ep[0].app_settings["PLAN_LABEL"] == "elastic-premium"
    error_message = "EP telemetry must not collide with legacy Dedicated labels."
  }
}

run "reject_bad_hash" {
  command = plan
  variables {
    ep_package_sha256 = "not-a-package-hash"
  }
  expect_failures = [var.ep_package_sha256]
}
