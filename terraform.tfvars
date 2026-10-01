###############################################################################
# terraform.tfvars  –  Development Environment Variable Values
#
# Purpose:
#   Supplies concrete values for the input variables defined in variables.tf.
#   This file targets the development (dev) environment.
#
# How Terraform loads this file:
#   Terraform automatically loads any file named terraform.tfvars or
#   *.auto.tfvars in the working directory during plan and apply.
#   For other environments, pass the file explicitly:
#     terraform apply -var-file=environments/staging.tfvars
#
# Security rules:
#   - DO NOT store secrets, passwords, or service principal credentials here.
#   - Secrets belong in Azure Key Vault, injected at runtime.
#   - CI/CD credentials use ARM_* environment variables, not this file.
#   - This file IS safe to commit to version control (no sensitive values).
#
# Azure Well-Architected (Cost Optimisation):
#   The dev values below choose the smallest viable SKUs (Standard_B2s VM,
#   standard Key Vault, single NAT Gateway zone) to minimise cost while
#   keeping the architecture production-representative.
###############################################################################

# ─────────────────────────────────────────────────────────────────────────────
# Project Identity
# ─────────────────────────────────────────────────────────────────────────────

project_name = "portfolio" # prefix used in all Azure resource names
environment  = "dev"       # used in resource names and tags
location     = "eastus"    # Azure East US region

# ─────────────────────────────────────────────────────────────────────────────
# Azure Resource Tags
# Applied to every resource for cost management and governance.
# Tags are visible in Azure Portal > Cost Management + Billing.
# ─────────────────────────────────────────────────────────────────────────────
tags = {
  Project     = "portfolio"
  Environment = "dev"
  ManagedBy   = "Terraform"
  Owner       = "DevOps"
  CostCenter  = "engineering"
  Repo        = "Azure-Terraform-Application"
}

# ─────────────────────────────────────────────────────────────────────────────
# Azure Virtual Network
# VNet address space: 12.0.0.0/16 (65,536 IPs)
#   Public  subnet:   12.0.1.0/24 – internet-facing resources
#   Private subnet:   12.0.2.0/24 – backend / internal resources
# ─────────────────────────────────────────────────────────────────────────────
vnet_address_space    = ["12.0.0.0/16"]
public_subnet_prefix  = "12.0.1.0/24"
private_subnet_prefix = "12.0.2.0/24"

# Azure NAT Gateway – provides controlled outbound internet for the private subnet.
# Billed per hour + per GB processed. Set false to reduce dev cost if not needed.
enable_nat_gateway = true

# ─────────────────────────────────────────────────────────────────────────────
# Azure Virtual Machine – Portfolio Web Server
# Standard_B2s: 2 vCPU, 4 GB RAM – burstable series, cost-optimised for dev.
# OS: Ubuntu 22.04 LTS (configured in modules/compute/main.tf).
# ─────────────────────────────────────────────────────────────────────────────
vm_size         = "Standard_B2s"
admin_username  = "azureuser"
os_disk_size_gb = 30 # Azure Managed Disk (Premium SSD, CMK encrypted)

# ─────────────────────────────────────────────────────────────────────────────
# Azure Network Security Group – SSH Access Rule
#
# IMPORTANT: 0.0.0.0/0 allows SSH from any IP address.
# This is acceptable for dev, but MUST be restricted before deploying to
# staging or production. Replace with your specific IP or VPN CIDR:
#   allowed_ssh_cidr = "203.0.113.10/32"   # single IP
#   allowed_ssh_cidr = "10.0.0.0/8"        # VPN range
# ─────────────────────────────────────────────────────────────────────────────
allowed_ssh_cidr = "0.0.0.0/0"

# ─────────────────────────────────────────────────────────────────────────────
# Azure Key Vault
# standard SKU: software-protected keys, sufficient for dev and most prod use.
# premium  SKU: HSM-backed keys, required for compliance/regulated workloads.
# Soft-delete: deleted vault remains recoverable for 30 days.
# ─────────────────────────────────────────────────────────────────────────────
key_vault_sku              = "standard"
key_vault_soft_delete_days = 30

# ─────────────────────────────────────────────────────────────────────────────
# Remote State Backend – Azure Blob Storage (informational only)
# These values mirror what is in backend.conf. The backend block reads
# backend.conf directly at `terraform init -backend-config=backend.conf`.
# ─────────────────────────────────────────────────────────────────────────────
backend_resource_group  = "rg-tfstate"
backend_storage_account = "stportfoliotfstate"
backend_container       = "tfstate"
