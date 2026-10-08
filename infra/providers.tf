provider "azurerm" {
  subscription_id = var.subscription_id

  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }

  # Register any resource providers that are missing. Set to false if the
  # deploying principal lacks permission to register providers at subscription
  # scope (then register them once manually, see docs/STEP-BY-STEP.md).
  resource_provider_registrations = "none"

  # Use Azure AD (Entra) for any storage data-plane operations instead of
  # shared keys. Shared-key access is disabled by subscription policy.
  storage_use_azuread = true
}

provider "azapi" {}

provider "random" {}

provider "http" {}

provider "time" {}
