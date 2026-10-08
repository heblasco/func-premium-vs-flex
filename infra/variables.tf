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
  description = "Flex always-ready instances for the stress function (0 = scale to zero / cold starts)."
  default     = 0
}

variable "flex_runtime_version" {
  type        = string
  description = "Node runtime version for Flex Consumption."
  default     = "20"
}

###############################################################################
# Premium (Elastic Premium) plan
###############################################################################

variable "premium_sku_name" {
  type        = string
  description = "Elastic Premium SKU. EP1 is the cheapest (~1 vCPU / 3.5 GB) and closest to Flex 2048."
  default     = "EP1"

  validation {
    condition     = contains(["EP1", "EP2", "EP3"], var.premium_sku_name)
    error_message = "premium_sku_name must be EP1, EP2 or EP3."
  }
}

variable "premium_maximum_elastic_worker_count" {
  type        = number
  description = "Premium maximum elastic (burst) worker count."
  default     = 40
}

variable "premium_prewarmed_instance_count" {
  type        = number
  description = "Premium pre-warmed instances (buffer). 1 is the product default; raising it reduces cold-start at extra cost."
  default     = 1
}

variable "premium_node_version" {
  type        = string
  description = "Node runtime version for the Premium Linux function app."
  default     = "20"
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
