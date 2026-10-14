###############################################################################
# Core / subscription
###############################################################################

variable "subscription_id" {
  type        = string
  description = "Azure subscription ID where resources are deployed. Required by the azurerm 4.x provider."
}

variable "location" {
  type        = string
  description = "Azure region. Must support Flex Consumption, Azure Load Testing and EP1. Good defaults: westeurope, eastus, swedencentral."
  default     = "westeurope"
}

variable "name_prefix" {
  type        = string
  description = "Short prefix (3-8 chars, lowercase/digits) used to build resource names. A random 4-hex suffix is appended automatically."
  default     = "fnvs"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{2,7}$", var.name_prefix))
    error_message = "name_prefix must be 3-8 chars, start with a letter, lowercase letters and digits only."
  }
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to every resource."
  default = {
    project   = "func-premium-vs-flex"
    managedBy = "terraform"
    purpose   = "cost-perf-demo"
  }
}

###############################################################################
# Networking
###############################################################################

variable "vnet_address_space" {
  type        = string
  description = "VNet CIDR. Carved into /26 subnets for flex-integ, premium-integ, private endpoints and load-test injection."
  default     = "10.60.0.0/22"
}

variable "enable_function_private_endpoints" {
  type        = bool
  description = "Create private endpoints (subresource 'sites') for both function apps so Azure Load Testing (VNet-injected) reaches them privately. Recommended for the WAF-aligned demo."
  default     = true
}

###############################################################################
# Deployer access (bootstrap)
###############################################################################

variable "deployer_ipv4" {
  type        = string
  description = "Public IPv4 /32 of the machine running terraform/func publish. Allowed through storage firewall and function SCM. Leave null to auto-discover via https://api.ipify.org."
  default     = null

  validation {
    condition     = var.deployer_ipv4 == null || can(regex("^\\d{1,3}(\\.\\d{1,3}){3}$", var.deployer_ipv4))
    error_message = "deployer_ipv4 must be a bare IPv4 address (no CIDR), or null to auto-discover."
  }
}

variable "auto_discover_deployer_ip" {
  type        = bool
  description = "If deployer_ipv4 is null, discover the public IP via api.ipify.org. Disable behind corporate proxies/IPv6 and set deployer_ipv4 explicitly."
  default     = true
}

variable "deployer_allow_cidr" {
  type        = string
  description = "Optional CIDR to allow through the function SCM/site IP restriction instead of the single auto-discovered /32. Useful when the deployer egress IP rotates within a corporate range (e.g. 167.220.0.0/16). Leave null to use the discovered /32."
  default     = null

  validation {
    condition     = var.deployer_allow_cidr == null || can(cidrhost(var.deployer_allow_cidr, 0))
    error_message = "deployer_allow_cidr must be a valid CIDR (e.g. 167.220.0.0/16) or null."
  }
}

###############################################################################
# Flex Consumption plan
###############################################################################

variable "flex_instance_memory_mb" {
  type        = number
  description = "Flex Consumption per-instance memory (MB). Supported: 512, 2048, 4096."
  default     = 2048

  validation {
    condition     = contains([512, 2048, 4096], var.flex_instance_memory_mb)
    error_message = "flex_instance_memory_mb must be one of 512, 2048, 4096."
  }
}

variable "flex_maximum_instance_count" {
  type        = number
  description = "Flex Consumption maximum scale-out instances."
  default     = 40
}

variable "flex_always_ready_count" {
  type        = number
  description = "Flex always-ready instances for the HTTP scale group (0 permits scale-to-zero)."
  default     = 0

  validation {
    condition     = var.flex_always_ready_count >= 0 && var.flex_always_ready_count <= 20 && floor(var.flex_always_ready_count) == var.flex_always_ready_count
    error_message = "flex_always_ready_count must be an integer from 0 to 20."
  }
}

variable "flex_runtime_version" {
  type        = string
  description = "Node runtime version for Flex Consumption."
  default     = "22"
}

###############################################################################
# "Premium" side: Dedicated App Service plan
#
# This legacy arm remains Dedicated. The optional EP arm uses a private Blob
# package without Azure Files; see functions_elastic_premium.tf.
###############################################################################

variable "premium_sku_name" {
  type        = string
  description = "Dedicated App Service plan SKU for the 'premium' side. P0v3 (~1 vCPU / 4 GB) is the closest always-on match to Flex 2048. B-series is cheaper/burstable."
  default     = "P0v3"

  validation {
    condition     = contains(["P0v3", "P1v3", "P2v3", "B1", "B2", "B3"], var.premium_sku_name)
    error_message = "premium_sku_name must be one of P0v3, P1v3, P2v3, B1, B2, B3."
  }
}

variable "premium_worker_count" {
  type        = number
  description = "Number of workers (instances) for the Dedicated plan. 1 keeps the demo cheap; raise to compare scale-out behaviour."
  default     = 1
}

variable "premium_node_version" {
  type        = string
  description = "Node runtime version for the Premium Linux function app."
  default     = "22"
}

###############################################################################
# Runtime / fairness controls (applied identically to both apps)
###############################################################################

variable "functions_worker_process_count" {
  type        = number
  description = "FUNCTIONS_WORKER_PROCESS_COUNT applied to both apps so per-instance concurrency is identical."
  default     = 1
}

###############################################################################
# Azure Load Testing
###############################################################################

variable "enable_load_testing" {
  type        = bool
  description = "Create the Azure Load Testing resource. The JMeter test itself is created via scripts/run-loadtest.ps1 (data-plane)."
  default     = true
}

variable "enable_elastic_premium" {
  type        = bool
  default     = false
  description = "Opt in to separate keyless EP infrastructure. With no package hash, create bootstrap resources only."
}

variable "ep_package_sha256" {
  type        = string
  default     = null
  description = "SHA256 of an already-uploaded immutable deploymentpackage/<hash>.zip. Null defers EP plan/app creation."
  validation {
    condition     = var.ep_package_sha256 == null ? true : can(regex("^[a-f0-9]{64}$", var.ep_package_sha256))
    error_message = "ep_package_sha256 must be null or a lowercase SHA256 hash."
  }
}

variable "ep_publisher_principal_id" {
  type        = string
  default     = null
  description = "Optional external publisher object ID for container-scoped Blob Data Contributor. The built-in verification runner receives its own assignment."
}

variable "ep_minimum_instances" {
  type        = number
  default     = 1
  description = "Always-ready EP instances; billed baseline."
  validation {
    condition     = var.ep_minimum_instances >= 1 && var.ep_minimum_instances <= var.ep_maximum_instances && floor(var.ep_minimum_instances) == var.ep_minimum_instances
    error_message = "EP minimum must be an integer from 1 to ep_maximum_instances."
  }
}

variable "ep_prewarmed_instances" {
  type        = number
  default     = 1
  description = "EP HTTP scale-out buffer, billed when allocated; not an idle minimum."
  validation {
    condition     = var.ep_prewarmed_instances >= 1 && var.ep_prewarmed_instances <= var.ep_maximum_instances && floor(var.ep_prewarmed_instances) == var.ep_prewarmed_instances
    error_message = "EP prewarmed count must be an integer from 1 to ep_maximum_instances."
  }
}

variable "ep_maximum_instances" {
  type        = number
  default     = 3
  description = "Bounded EP app scale-out and plan maximum elastic workers (1-20)."
  validation {
    condition     = var.ep_maximum_instances >= 1 && var.ep_maximum_instances <= 20 && floor(var.ep_maximum_instances) == var.ep_maximum_instances
    error_message = "EP maximum must be an integer from 1 to 20."
  }
}
