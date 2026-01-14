terraform {
  required_version = ">= 1.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 3.0"
    }
  }
}

variable "resource_group_name" {
  description = "Name of the resource group"
  type        = string
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "eastus"
}

variable "deploy_hub" {
  description = "Whether to deploy hub resources"
  type        = bool
  default     = true
}

variable "deploy_spoke" {
  description = "Whether to deploy spoke resources"
  type        = bool
  default     = true
}

variable "qualys_pod" {
  description = "Qualys POD identifier"
  type        = string
  default     = "US2"
}

variable "qualys_access_token" {
  description = "Qualys API access token"
  type        = string
  sensitive   = true
}

variable "hub_subscription_id" {
  description = "Hub subscription ID (required for spoke-only deployment)"
  type        = string
  default     = ""
}

variable "hub_resource_group" {
  description = "Hub resource group name (required for spoke-only deployment)"
  type        = string
  default     = ""
}

variable "hub_storage_account_name" {
  description = "Hub storage account name (required for spoke-only deployment)"
  type        = string
  default     = ""
}

variable "hub_key_vault_name" {
  description = "Hub Key Vault name (required for spoke-only deployment)"
  type        = string
  default     = ""
}

variable "scan_types" {
  description = "Scan types to run"
  type        = string
  default     = "os,sca,fileinsight"
}

variable "enable_new_vm_trigger" {
  description = "Enable scanning on new VM creation"
  type        = bool
  default     = true
}

variable "enable_scheduled_scan" {
  description = "Enable scheduled scanning"
  type        = bool
  default     = true
}

variable "result_retention_days" {
  description = "Number of days to retain scan results"
  type        = number
  default     = 90
}

data "azurerm_client_config" "current" {}
data "azurerm_subscription" "current" {}

locals {
  unique_suffix        = substr(md5(var.resource_group_name), 0, 8)
  storage_account_name = "qualysscan${local.unique_suffix}"
  key_vault_name       = "qualys-hub-${local.unique_suffix}"
}

resource "azurerm_storage_account" "results" {
  count                           = var.deploy_hub ? 1 : 0
  name                            = local.storage_account_name
  resource_group_name             = var.resource_group_name
  location                        = var.location
  account_tier                    = "Standard"
  account_replication_type        = "GRS"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
  public_network_access_enabled   = false
  shared_access_key_enabled       = false

  blob_properties {
    delete_retention_policy {
      days = 7
    }
    versioning_enabled = true
  }

  queue_properties {
    logging {
      delete                = true
      read                  = true
      write                 = true
      version               = "1.0"
      retention_policy_days = 7
    }
  }

  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices"]
  }
}

resource "azurerm_storage_container" "scans" {
  count                 = var.deploy_hub ? 1 : 0
  name                  = "scans"
  storage_account_name  = azurerm_storage_account.results[0].name
  container_access_type = "private"
}

resource "azurerm_storage_management_policy" "lifecycle" {
  count              = var.deploy_hub ? 1 : 0
  storage_account_id = azurerm_storage_account.results[0].id

  rule {
    name    = "expire-results"
    enabled = true
    filters {
      prefix_match = ["scans/"]
      blob_types   = ["blockBlob"]
    }
    actions {
      base_blob {
        delete_after_days_since_modification_greater_than = var.result_retention_days
      }
    }
  }
}

resource "azurerm_key_vault" "qualys" {
  count                          = var.deploy_hub ? 1 : 0
  name                           = local.key_vault_name
  resource_group_name            = var.resource_group_name
  location                       = var.location
  tenant_id                      = data.azurerm_client_config.current.tenant_id
  sku_name                       = "standard"
  soft_delete_retention_days     = 90
  purge_protection_enabled       = true
  enable_rbac_authorization      = true
  public_network_access_enabled  = false

  network_acls {
    default_action = "Deny"
    bypass         = "AzureServices"
  }
}

resource "azurerm_key_vault_secret" "qualys_pod" {
  count        = var.deploy_hub ? 1 : 0
  name         = "qualys-pod"
  value        = var.qualys_pod
  key_vault_id = azurerm_key_vault.qualys[0].id
  content_type = "text/plain"

  expiration_date = timeadd(timestamp(), "8760h")
}

resource "azurerm_key_vault_secret" "qualys_token" {
  count        = var.deploy_hub ? 1 : 0
  name         = "qualys-access-token"
  value        = var.qualys_access_token
  key_vault_id = azurerm_key_vault.qualys[0].id
  content_type = "text/plain"

  expiration_date = timeadd(timestamp(), "8760h")
}

output "hub_storage_account_name" {
  description = "Name of the hub storage account"
  value       = var.deploy_hub ? azurerm_storage_account.results[0].name : var.hub_storage_account_name
}

output "hub_storage_account_id" {
  description = "ID of the hub storage account"
  value       = var.deploy_hub ? azurerm_storage_account.results[0].id : null
}

output "hub_key_vault_name" {
  description = "Name of the hub Key Vault"
  value       = var.deploy_hub ? azurerm_key_vault.qualys[0].name : var.hub_key_vault_name
}

output "hub_key_vault_uri" {
  description = "URI of the hub Key Vault"
  value       = var.deploy_hub ? azurerm_key_vault.qualys[0].vault_uri : null
}

output "hub_subscription_id" {
  description = "Hub subscription ID"
  value       = data.azurerm_subscription.current.subscription_id
}

output "hub_resource_group" {
  description = "Hub resource group name"
  value       = var.resource_group_name
}
