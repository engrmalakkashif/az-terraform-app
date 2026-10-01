###############################################################################
# modules/networking/variables.tf
#
# Input variables for the Azure networking module.
# All variables are passed from the root module (main.tf module block).
###############################################################################

variable "project_name" {
  description = <<-EOT
    Short project identifier used as a prefix in all Azure resource names.
    Example: "portfolio" produces "vnet-portfolio-dev", "nsg-public-portfolio-dev".
  EOT
  type        = string
}

variable "environment" {
  description = <<-EOT
    Deployment stage (dev | staging | prod).
    Appended to resource names to distinguish environments in the Azure Portal.
  EOT
  type        = string
}

variable "location" {
  description = "Azure region where all networking resources are deployed (e.g. eastus)."
  type        = string
}

variable "resource_group_name" {
  description = <<-EOT
    Name of the Azure Resource Group in which all networking resources are created.
    The Resource Group must already exist (created in the root module).
  EOT
  type        = string
}

variable "vnet_address_space" {
  description = <<-EOT
    Address space for the Azure Virtual Network expressed as a list of CIDR blocks.
    All subnets must fall within this address space.
    Example: ["12.0.0.0/16"] provides 65,536 IP addresses.
  EOT
  type        = list(string)
}

variable "public_subnet_prefix" {
  description = <<-EOT
    CIDR prefix for the public subnet.
    Must be a subset of vnet_address_space.
    Example: "12.0.1.0/24"  (256 addresses, 251 usable after Azure reservations)
  EOT
  type        = string
}

variable "private_subnet_prefix" {
  description = <<-EOT
    CIDR prefix for the private subnet.
    Must be a subset of vnet_address_space and must not overlap with public_subnet_prefix.
    Example: "12.0.2.0/24"  (256 addresses, 251 usable after Azure reservations)
  EOT
  type        = string
}

variable "enable_nat_gateway" {
  description = <<-EOT
    When true, deploys an Azure NAT Gateway on the public subnet and associates
    it with both the public and private subnets. The NAT Gateway provides
    controlled outbound internet access for private subnet resources.
    When false, no NAT Gateway is created and the private subnet has no
    outbound internet connectivity.
    Set to false in dev environments to reduce the ~$32/month NAT Gateway cost.
  EOT
  type        = bool
  default     = true
}

variable "allowed_ssh_cidr" {
  description = <<-EOT
    Source CIDR range permitted for inbound SSH (TCP port 22) in the public NSG.
    Applied to the "Allow-SSH-Inbound" rule at priority 100.
    Production recommendation: restrict to your office/VPN IP, e.g. "203.0.113.10/32".
    Default "0.0.0.0/0" allows SSH from any IP (acceptable for dev only).
  EOT
  type        = string
  default     = "0.0.0.0/0"
}

variable "tags" {
  description = <<-EOT
    Map of Azure tags applied to all networking resources (VNet, subnets, NSGs,
    NAT Gateway, Route Tables). Tags appear in Azure Cost Management and Portal.
  EOT
  type        = map(string)
  default     = {}
}
