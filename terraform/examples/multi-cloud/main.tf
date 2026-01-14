# Qualys VM Scanner - Multi-Cloud Example
# Deploy hub and spoke resources across AWS, Azure, and GCP

terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 3.0"
    }
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0"
    }
  }
}

# =============================================================================
# VARIABLES
# =============================================================================

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

# AWS Variables
variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "aws_organization_id" {
  description = "AWS Organization ID"
  type        = string
  default     = ""
}

variable "deploy_aws" {
  description = "Deploy to AWS"
  type        = bool
  default     = false
}

# Azure Variables
variable "azure_resource_group_name" {
  description = "Azure resource group name"
  type        = string
  default     = "qualys-scanner-rg"
}

variable "azure_location" {
  description = "Azure region"
  type        = string
  default     = "eastus"
}

variable "deploy_azure" {
  description = "Deploy to Azure"
  type        = bool
  default     = false
}

# GCP Variables
variable "gcp_project_id" {
  description = "GCP project ID"
  type        = string
  default     = ""
}

variable "gcp_region" {
  description = "GCP region"
  type        = string
  default     = "us-central1"
}

variable "deploy_gcp" {
  description = "Deploy to GCP"
  type        = bool
  default     = false
}

# =============================================================================
# PROVIDERS
# =============================================================================

provider "aws" {
  region = var.aws_region
}

provider "azurerm" {
  features {}
}

provider "google" {
  project = var.gcp_project_id
  region  = var.gcp_region
}

# =============================================================================
# AWS DEPLOYMENT
# =============================================================================

module "aws" {
  count  = var.deploy_aws ? 1 : 0
  source = "../../modules/aws"

  deploy_hub          = true
  deploy_spoke        = true
  organization_id     = var.aws_organization_id
  qualys_pod          = var.qualys_pod
  qualys_access_token = var.qualys_access_token
}

# =============================================================================
# AZURE DEPLOYMENT
# =============================================================================

resource "azurerm_resource_group" "qualys" {
  count    = var.deploy_azure ? 1 : 0
  name     = var.azure_resource_group_name
  location = var.azure_location
}

module "azure" {
  count  = var.deploy_azure ? 1 : 0
  source = "../../modules/azure"

  resource_group_name = azurerm_resource_group.qualys[0].name
  location            = var.azure_location
  deploy_hub          = true
  deploy_spoke        = true
  qualys_pod          = var.qualys_pod
  qualys_access_token = var.qualys_access_token
}

# =============================================================================
# GCP DEPLOYMENT
# =============================================================================

module "gcp" {
  count  = var.deploy_gcp ? 1 : 0
  source = "../../modules/gcp"

  project_id          = var.gcp_project_id
  region              = var.gcp_region
  deploy_hub          = true
  deploy_spoke        = true
  qualys_pod          = var.qualys_pod
  qualys_access_token = var.qualys_access_token
}

# =============================================================================
# OUTPUTS
# =============================================================================

output "aws" {
  description = "AWS deployment outputs"
  value       = var.deploy_aws ? module.aws[0] : null
}

output "azure" {
  description = "Azure deployment outputs"
  value       = var.deploy_azure ? module.azure[0] : null
}

output "gcp" {
  description = "GCP deployment outputs"
  value       = var.deploy_gcp ? module.gcp[0] : null
}
