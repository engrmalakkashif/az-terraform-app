###############################################################################
# main.tf  –  Root Module
#
# Purpose:
#   Orchestrates the three child modules that together form the complete
#   Azure infrastructure for the publicly accessible portfolio application.
#
# Architecture overview:
#
#   ┌─────────────────────────── Azure Resource Group ──────────────────────┐
#   │                                                                        │
#   │  ┌──────────── Module: networking ──────────────────────────────────┐ │
#   │  │  Virtual Network (VNet)  12.0.0.0/16                             │ │
#   │  │  ├── Public Subnet  12.0.1.0/24  (NSG: allow 22, 80, 443)       │ │
#   │  │  │       └── NAT Gateway  (outbound internet for private subnet)  │ │
#   │  │  │       └── Route Table  (0.0.0.0/0 → Internet)                 │ │
#   │  │  └── Private Subnet  12.0.2.0/24  (NSG: VNet-internal only)     │ │
#   │  │            └── Route Table  (0.0.0.0/0 → via NAT Gateway)        │ │
#   │  └──────────────────────────────────────────────────────────────────┘ │
#   │                                                                        │
#   │  ┌──────────── Module: security ────────────────────────────────────┐ │
#   │  │  Azure Key Vault                (secrets, keys, certificates)    │ │
#   │  │  User-Assigned Managed Identity (passwordless auth for VM)       │ │
#   │  │  Disk Encryption Set            (CMK encryption for OS disk)     │ │
#   │  └──────────────────────────────────────────────────────────────────┘ │
#   │                                                                        │
#   │  ┌──────────── Module: compute ─────────────────────────────────────┐ │
#   │  │  Static Public IP               (internet-facing, Standard SKU)  │ │
#   │  │  Network Interface              (placed in public subnet)        │ │
#   │  │  Linux Virtual Machine          (Ubuntu 22.04 LTS)              │ │
#   │  │    ├── cloud-init               (Nginx + portfolio page)         │ │
#   │  │    ├── Managed Identity         (Key Vault access, no passwords) │ │
#   │  │    ├── CMK-encrypted OS disk    (via Disk Encryption Set)        │ │
#   │  │    └── Azure Monitor Agent      (metrics + log collection)       │ │
#   │  └──────────────────────────────────────────────────────────────────┘ │
#   │                                                                        │
#   │  SSH Private Key  →  stored as Azure Key Vault Secret                 │
#   └────────────────────────────────────────────────────────────────────────┘
#
# Remote state:
#   Stored in Azure Blob Storage (backend.conf). The blob container uses
#   built-in Azure Blob Lease for state locking – no additional lock
#   resource is required.
#
# Authentication:
#   Uses the current Azure CLI session locally, or ARM_* environment
#   variables in CI/CD pipelines (GitHub Actions / Azure DevOps).
###############################################################################

###############################################################################
# Terraform Backend – Azure Blob Storage
#
# The Terraform state file is stored in an Azure Storage Account blob
# container. This enables:
#   - Remote and shared state across team members and CI/CD pipelines
#   - State locking via Azure Blob Lease (prevents concurrent modifications)
#   - Encryption at rest using Azure Storage Service Encryption (SSE)
#   - Versioning for state history and rollback capability
#
# Configuration values are injected at init time:
#   terraform init -backend-config=backend.conf
#
# The backend block must remain empty here; values cannot use Terraform
# variables inside a backend block.
###############################################################################
terraform {
  backend "azurerm" {}
}

###############################################################################
# Data Source – Azure Client Configuration
#
# Reads the authenticated identity's tenant ID and object ID at plan time.
# Used to:
#   - Set the Key Vault tenant_id (identifies the Azure AD tenant)
#   - Set the deployer_object_id for Key Vault access policies (grants the
#     CI/CD pipeline or local user full Key Vault management permissions)
###############################################################################
data "azurerm_client_config" "current" {}

###############################################################################
# Random Suffix
#
# Azure Key Vault names must be globally unique across all Azure tenants.
# A 6-character random lowercase alphanumeric suffix appended to the resource
# name guarantees uniqueness and prevents naming conflicts on re-deployment.
###############################################################################
resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

###############################################################################
# Azure Resource Group
#
# A Resource Group is a logical container that holds all related Azure
# resources for this project. It defines:
#   - The Azure region where metadata is stored
#   - The billing boundary for cost management and tagging
#   - The scope for Azure RBAC role assignments
#   - The unit of lifecycle management (create/destroy all resources together)
#
# Naming convention: rg-<project>-<environment>
#   Example: rg-portfolio-dev
###############################################################################
resource "azurerm_resource_group" "main" {
  name     = "rg-${var.project_name}-${var.environment}"
  location = var.location
  tags     = var.tags
}

###############################################################################
# SSH Key Pair – RSA 4096-bit
#
# Generates a secure RSA key pair for SSH access to the portfolio VM.
# Azure Linux VMs require key-based authentication; password authentication
# is disabled in this configuration as a security best practice.
#
# Key handling:
#   - Public key  → pushed to the VM via the admin_ssh_key block
#   - Private key → stored as a secret in Azure Key Vault (never on disk
#                   long-term; retrieve with: az keyvault secret show)
#
# Azure Well-Architected (Security):
#   Centralising the private key in Key Vault means it is protected by
#   Key Vault's access policies, soft-delete, and audit logging. No developer
#   or pipeline needs to store a .pem file locally.
###############################################################################
resource "tls_private_key" "portfolio" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

###############################################################################
# Key Vault Secret – SSH Private Key
#
# Stores the generated SSH private key as a versioned secret in Azure Key
# Vault. The secret is protected by:
#   - Key Vault access policies (only authorised identities can read it)
#   - Soft-delete and purge protection (accidental deletion is recoverable)
#   - Azure Monitor audit logs (every access is logged)
#
# Retrieve the key for SSH:
#   az keyvault secret show \
#     --vault-name <kv-name> \
#     --name portfolio-vm-ssh-private-key \
#     --query value --output tsv > ~/.ssh/portfolio.pem
#   chmod 600 ~/.ssh/portfolio.pem
###############################################################################
resource "azurerm_key_vault_secret" "ssh_private_key" {
  name         = "portfolio-vm-ssh-private-key"
  value        = tls_private_key.portfolio.private_key_pem
  key_vault_id = module.security.key_vault_id

  content_type    = "text/plain"
  expiration_date = timeadd(timestamp(), "8760h") # expires after 1 year

  tags = var.tags

  lifecycle {
    # Prevent re-deployment on every plan due to timestamp() being dynamic
    ignore_changes = [expiration_date]
  }
}

###############################################################################
# Module: Networking
#
# Deploys the full Azure network topology:
#   - Virtual Network (VNet) with address space 12.0.0.0/16
#   - Public Subnet  (12.0.1.0/24) with NSG allowing HTTP/HTTPS/SSH
#   - Private Subnet (12.0.2.0/24) with NSG restricting to VNet-internal only
#   - Azure NAT Gateway on the public subnet (controlled outbound for private)
#   - User-Defined Route Tables (UDR) for both subnets
#   - NSG → Subnet associations for both subnets
#
# The public subnet hosts internet-facing resources (portfolio VM public IP).
# The private subnet is reserved for backend or database resources that must
# not be directly reachable from the internet.
###############################################################################
module "networking" {
  source = "./modules/networking"

  project_name          = var.project_name
  environment           = var.environment
  location              = var.location
  resource_group_name   = azurerm_resource_group.main.name
  vnet_address_space    = var.vnet_address_space
  public_subnet_prefix  = var.public_subnet_prefix
  private_subnet_prefix = var.private_subnet_prefix
  enable_nat_gateway    = var.enable_nat_gateway
  allowed_ssh_cidr      = var.allowed_ssh_cidr
  tags                  = var.tags
}

###############################################################################
# Module: Security
#
# Deploys the Azure security services layer:
#   - Azure Key Vault: centralised secret, key, and certificate management
#       • SSH private key storage
#       • Customer-Managed Key (CMK) for disk encryption
#       • Soft-delete + purge protection enabled
#   - User-Assigned Managed Identity (UAMI):
#       • Attached to the portfolio VM
#       • Grants the VM read-only access to Key Vault secrets
#       • No passwords or credentials stored anywhere on the VM
#   - Disk Encryption Set (DES):
#       • Links the Key Vault CMK to Azure Managed Disk encryption
#       • Ensures the VM OS disk is encrypted with a customer-controlled key
#
# Key Vault access policies:
#   deployer    → full permissions (CI/CD pipeline writes secrets during deploy)
#   vm_identity → read-only Get/List (least-privilege for the running VM)
###############################################################################
module "security" {
  source = "./modules/security"

  project_name               = var.project_name
  environment                = var.environment
  location                   = var.location
  resource_group_name        = azurerm_resource_group.main.name
  key_vault_sku              = var.key_vault_sku
  key_vault_soft_delete_days = var.key_vault_soft_delete_days
  random_suffix              = random_string.suffix.result
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  deployer_object_id         = data.azurerm_client_config.current.object_id
  tags                       = var.tags
}

###############################################################################
# Module: Compute
#
# Deploys the portfolio web server on Azure:
#   - Static Public IP (Standard SKU, zone-pinned) with a DNS label:
#       <project>-<env>.eastus.cloudapp.azure.com
#   - Network Interface Card (NIC) placed in the public subnet
#   - Azure Linux Virtual Machine (Ubuntu 22.04 LTS, Standard_B2s)
#       • SSH key authentication only (passwords disabled)
#       • User-Assigned Managed Identity attached
#       • OS disk encrypted with CMK via Disk Encryption Set
#       • cloud-init bootstraps Nginx + deploys the portfolio static page
#       • UEFI Secure Boot enabled
#       • Auto OS patching via Azure Automatic VM Guest Patching
#   - Azure Monitor Agent extension:
#       • Ships VM metrics and logs to Azure Monitor
#       • Enables alerting, dashboards, and log queries via Log Analytics
#
# The VM is publicly accessible on port 80 (HTTP) after ~2 minutes.
# URL: http://<portfolio_public_ip>  or  http://<portfolio_public_fqdn>
###############################################################################
module "compute" {
  source = "./modules/compute"

  project_name           = var.project_name
  environment            = var.environment
  location               = var.location
  resource_group_name    = azurerm_resource_group.main.name
  vm_size                = var.vm_size
  admin_username         = var.admin_username
  ssh_public_key         = tls_private_key.portfolio.public_key_openssh
  public_subnet_id       = module.networking.public_subnet_id
  public_nsg_id          = module.networking.public_nsg_id
  managed_identity_id    = module.security.managed_identity_id
  disk_encryption_set_id = module.security.disk_encryption_set_id
  os_disk_size_gb        = var.os_disk_size_gb
  tags                   = var.tags

  # Networking and security resources must exist before compute is created
  depends_on = [module.networking, module.security]
}
