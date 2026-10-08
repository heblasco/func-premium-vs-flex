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
}

provider "random" {}

provider "http" {}

provider "time" {}
