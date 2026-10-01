###############################################################################
# variables.tf  –  Root Module Input Variables
#
# Purpose:
#   Defines all configurable parameters for the Azure portfolio infrastructure.
#   Every variable includes a description, type constraint, default value, and
#   where appropriate a validation block to catch invalid inputs early.
#
# Usage:
#   Override defaults by setting values in terraform.tfvars, or pass them
#   directly on the command line:
#     terraform apply -var="environment=prod" -var="vm_size=Standard_D2s_v3"
#
# Sections:
#   1. General / project identity
#   2. Azure networking (VNet, subnets, NAT Gateway)
#   3. Compute (VM size, admin user, SSH, disk)
#   4. Security (Azure Key Vault)
#   5. Remote state backend (informational only)
###############################################################################

# ─────────────────────────────────────────────────────────────────────────────
# 1. General / Project Identity
# ─────────────────────────────────────────────────────────────────────────────

variable "project_name" {
  description = <<-EOT
    Short identifier for this project. Used as a prefix in all Azure resource
    names to ensure consistent naming and easy discovery in the Azure Portal.
    Must be 1–8 lowercase alphanumeric characters.
    Example resource name: rg-portfolio-dev, vnet-portfolio-dev.
  EOT
  type        = string
  default     = "portfolio"

  validation {
    condition     = can(regex("^[a-z0-9]{1,8}$", var.project_name))
    error_message = "project_name must be 1-8 lowercase alphanumeric characters."
  }
}

variable "environment" {
  description = <<-EOT
    Deployment environment stage. Controls resource naming, tagging, and
    can be used to toggle environment-specific settings (e.g. VM size,
    NAT Gateway, SSH CIDR restrictions).
    Allowed values: dev | staging | prod
  EOT
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "location" {
  description = <<-EOT
    Azure region where all resources are deployed.
    Use 'az account list-locations --output table' to see all valid values.
    Default: eastus (East US – one of the lowest-latency Azure regions).
  EOT
  type        = string
  default     = "eastus"
}

variable "tags" {
  description = <<-EOT
    Map of Azure resource tags applied to every resource in this deployment.
    Tags enable cost management, resource filtering, and governance in the
    Azure Portal and Azure Cost Management + Billing.
    Recommended keys: Project, Environment, ManagedBy, Owner, CostCenter.
  EOT
  type        = map(string)
  default = {
    Project     = "portfolio"
    Environment = "dev"
    ManagedBy   = "Terraform"
    Owner       = "DevOps"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# 2. Azure Networking
# ─────────────────────────────────────────────────────────────────────────────

variable "vnet_address_space" {
  description = <<-EOT
    CIDR address space for the Azure Virtual Network (VNet).
    The VNet is the private, isolated network boundary for all Azure resources
    in this deployment. All subnets are carved from this address space.
    Default: 12.0.0.0/16  (65,536 available IP addresses)
  EOT
  type        = list(string)
  default     = ["12.0.0.0/16"]
}

variable "public_subnet_prefix" {
  description = <<-EOT
    CIDR prefix for the public subnet within the VNet.
    The public subnet hosts resources that require direct internet connectivity,
    such as the portfolio VM's Network Interface (with a Static Public IP).
    The subnet is protected by the public Network Security Group (NSG) which
    allows inbound HTTP (80), HTTPS (443), and SSH (22).
    Default: 12.0.1.0/24  (256 addresses)
  EOT
  type        = string
  default     = "12.0.1.0/24"
}

variable "private_subnet_prefix" {
  description = <<-EOT
    CIDR prefix for the private subnet within the VNet.
    The private subnet hosts backend resources (databases, internal services)
    that must not be directly reachable from the internet. Its NSG blocks all
    inbound internet traffic. Outbound internet access is routed through the
    Azure NAT Gateway in the public subnet.
    Default: 12.0.2.0/24  (256 addresses)
  EOT
  type        = string
  default     = "12.0.2.0/24"
}

variable "enable_nat_gateway" {
  description = <<-EOT
    Controls whether an Azure NAT Gateway is deployed on the public subnet.
    When true, the NAT Gateway provides controlled outbound internet access
    for resources in the private subnet (e.g. package downloads, OS updates)
    without exposing them to inbound traffic from the internet.
    The NAT Gateway is billed per hour plus per GB of processed data.
    Set to false in dev environments to reduce cost if private subnet
    outbound access is not required.
  EOT
  type        = bool
  default     = true
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. Compute
# ─────────────────────────────────────────────────────────────────────────────

variable "vm_size" {
  description = <<-EOT
    Azure Virtual Machine size for the portfolio web server.
    The size determines vCPU count, memory, and available disk throughput.
    Standard_B2s = 2 vCPU, 4 GB RAM – suitable for low-traffic web workloads.
    For higher traffic, consider Standard_B2ms (2 vCPU, 8 GB) or
    Standard_D2s_v3 (2 vCPU, 8 GB, better network throughput).
    Full list: az vm list-sizes --location eastus --output table
  EOT
  type        = string
  default     = "Standard_B2s"
}

variable "admin_username" {
  description = <<-EOT
    Linux administrator username for the Azure Virtual Machine.
    This user is created during VM provisioning and is the account used for
    SSH access. Password authentication is disabled; access requires the SSH
    private key stored in Azure Key Vault.
    Azure restrictions: must not be root, admin, or administrator.
  EOT
  type        = string
  default     = "azureuser"

  validation {
    condition     = !contains(["root", "admin", "administrator"], lower(var.admin_username))
    error_message = "admin_username must not be root, admin, or administrator (Azure restriction)."
  }
}

variable "allowed_ssh_cidr" {
  description = <<-EOT
    Source IP CIDR range allowed for inbound SSH (port 22) on the public NSG.
    In production, restrict this to your office or VPN IP address to reduce
    attack surface:  e.g. "203.0.113.10/32"
    The default 0.0.0.0/0 is acceptable for dev but must be tightened before
    deploying to staging or production.
  EOT
  type        = string
  default     = "0.0.0.0/0"

  validation {
    condition     = can(cidrhost(var.allowed_ssh_cidr, 0))
    error_message = "allowed_ssh_cidr must be a valid CIDR block (e.g. 0.0.0.0/0 or 1.2.3.4/32)."
  }
}

variable "os_disk_size_gb" {
  description = <<-EOT
    Size of the Azure Managed Disk used as the VM OS disk, in gigabytes.
    The disk is provisioned as Premium_LRS (SSD-backed) and encrypted with a
    Customer-Managed Key (CMK) via the Disk Encryption Set in the security module.
    30 GB is sufficient for the portfolio Nginx workload.
  EOT
  type        = number
  default     = 30
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. Security – Azure Key Vault
# ─────────────────────────────────────────────────────────────────────────────

variable "key_vault_sku" {
  description = <<-EOT
    Azure Key Vault pricing tier.
    standard – software-protected keys; suitable for dev and most production use.
    premium  – HSM-backed keys (FIPS 140-2 Level 2); required for compliance
               workloads that mandate hardware key protection.
  EOT
  type        = string
  default     = "standard"

  validation {
    condition     = contains(["standard", "premium"], var.key_vault_sku)
    error_message = "key_vault_sku must be standard or premium."
  }
}

variable "key_vault_soft_delete_days" {
  description = <<-EOT
    Number of days a deleted Azure Key Vault and its contents remain in a
    soft-deleted (recoverable) state before permanent deletion.
    Valid range: 7–90 days. Azure default is 90 days.
    After this period, the vault and all secrets/keys/certs are permanently deleted.
    Purge protection (enabled in the security module) prevents permanent deletion
    even by administrators during this retention window.
  EOT
  type        = number
  default     = 30
}

# ─────────────────────────────────────────────────────────────────────────────
# 5. Remote State Backend (informational – actual values are in backend.conf)
# ─────────────────────────────────────────────────────────────────────────────

variable "backend_resource_group" {
  description = <<-EOT
    Name of the Azure Resource Group that contains the Terraform remote state
    Storage Account. This resource group is created manually before running
    terraform init (see the bootstrap steps in INFRASTRUCTURE_GUIDE.md).
    This variable is informational only; the backend block reads from backend.conf.
  EOT
  type        = string
  default     = "rg-tfstate"
}

variable "backend_storage_account" {
  description = <<-EOT
    Name of the Azure Storage Account used for storing the Terraform state file.
    Storage Account names must be globally unique across all Azure tenants,
    3–24 lowercase alphanumeric characters, no hyphens.
    This variable is informational only; the backend block reads from backend.conf.
  EOT
  type        = string
  default     = "stportfoliotfstate"
}

variable "backend_container" {
  description = <<-EOT
    Name of the Azure Blob Storage container inside the state Storage Account.
    The Terraform state file is stored as a blob inside this container.
    Azure Blob Lease provides automatic state locking; no separate lock
    resource is required.
    This variable is informational only; the backend block reads from backend.conf.
  EOT
  type        = string
  default     = "tfstate"
}
