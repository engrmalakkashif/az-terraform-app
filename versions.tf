###############################################################################
# versions.tf
#
# Purpose : Pins the Terraform core version and all provider versions used
#           across this project. Pinning ensures consistent, reproducible
#           deployments regardless of the workstation or CI/CD runner.
#
# Providers:
#   azurerm  – Primary Azure Resource Manager provider. Manages every Azure
#              resource: VNets, VMs, Key Vault, Storage Accounts, etc.
#   azuread  – Azure Active Directory provider. Used for reading tenant/
#              service-principal data and configuring Key Vault policies.
#   random   – Generates unique alphanumeric suffixes for globally-scoped
#              Azure resources (Key Vault names, Storage Account names).
#   tls      – Generates the RSA-4096 SSH key pair for the portfolio VM.
#              The private key is stored securely in Azure Key Vault.
#
# Azure Well-Architected alignment:
#   Operational Excellence – version pinning guarantees infrastructure
#   deployments behave identically across dev, staging, and prod pipelines.
###############################################################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    # Azure Resource Manager – core provider for all Azure infrastructure
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }

    # Azure Active Directory – tenant/SP lookups and Key Vault access policies
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 2.50"
    }

    # Random – globally unique resource name suffixes (Key Vault, Storage)
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }

    # TLS – RSA-4096 SSH key pair generation for the portfolio VM
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

###############################################################################
# AzureRM Provider – Feature Flags
#
# These flags control the behaviour of the azurerm provider during
# Terraform destroy and lifecycle operations.
#
# key_vault:
#   purge_soft_delete_on_destroy    = false
#     When Terraform destroys a Key Vault, the vault enters a soft-deleted
#     state and remains recoverable for the configured retention period
#     (default 30 days). Setting this to false ensures secrets and keys are
#     not permanently purged immediately on destroy – protecting against
#     accidental data loss.
#   recover_soft_deleted_key_vaults = true
#     If a Key Vault with the same name was previously soft-deleted, Terraform
#     will recover it instead of failing with a name-conflict error.
#
# resource_group:
#   prevent_deletion_if_contains_resources = true
#     Terraform will refuse to delete a Resource Group that still contains
#     Azure resources. This is a safety guard against accidentally destroying
#     an entire environment.
#
# virtual_machine:
#   delete_os_disk_on_deletion = true
#     When the VM is destroyed, its OS disk (Azure Managed Disk) is also
#     deleted automatically, preventing orphaned disks from incurring charges.
###############################################################################
provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy    = false
      recover_soft_deleted_key_vaults = true
    }

    resource_group {
      prevent_deletion_if_contains_resources = true
    }

    virtual_machine {
      delete_os_disk_on_deletion     = true
      graceful_shutdown              = false
      skip_shutdown_and_force_delete = false
    }
  }
}
