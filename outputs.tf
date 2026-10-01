###############################################################################
# outputs.tf  –  Root Module Outputs
#
# Purpose:
#   Exposes the most important resource identifiers, addresses, and connection
#   details after a successful terraform apply. Outputs are used by:
#     - Developers (SSH into the VM, open the portfolio URL in a browser)
#     - CI/CD pipelines (downstream steps that consume resource IDs)
#     - Other Terraform workspaces (via terraform_remote_state data source)
#
# Retrieve after deployment:
#     terraform output                          # all outputs
#     terraform output portfolio_public_ip      # single value
#     terraform output -json                    # machine-readable JSON
#
# Sections:
#   1. Azure Resource Group
#   2. Azure Networking (VNet, subnets, NSGs, NAT Gateway)
#   3. Azure Compute (VM, public IP, FQDN)
#   4. Azure Security (Key Vault, Managed Identity)
#   5. Connection summary (quick-reference block)
###############################################################################

# ─────────────────────────────────────────────────────────────────────────────
# 1. Azure Resource Group
# ─────────────────────────────────────────────────────────────────────────────

output "resource_group_name" {
  description = <<-EOT
    Name of the Azure Resource Group that contains all deployed resources.
    Use this in az CLI commands:
      az resource list --resource-group <value> --output table
  EOT
  value       = azurerm_resource_group.main.name
}

output "resource_group_id" {
  description = "Full Azure Resource ID of the Resource Group."
  value       = azurerm_resource_group.main.id
}

output "location" {
  description = "Azure region where all resources are deployed (e.g. eastus)."
  value       = azurerm_resource_group.main.location
}

# ─────────────────────────────────────────────────────────────────────────────
# 2. Azure Networking
# ─────────────────────────────────────────────────────────────────────────────

output "vnet_id" {
  description = <<-EOT
    Azure Resource ID of the Virtual Network (VNet).
    The VNet is the private, isolated network boundary (12.0.0.0/16).
    Used when peering VNets or linking Private DNS Zones.
  EOT
  value       = module.networking.vnet_id
}

output "vnet_name" {
  description = "Name of the Azure Virtual Network."
  value       = module.networking.vnet_name
}

output "public_subnet_id" {
  description = <<-EOT
    Azure Resource ID of the public subnet (12.0.1.0/24).
    Resources placed here have access to a Static Public IP and are protected
    by the public NSG (allows HTTP 80, HTTPS 443, SSH 22).
  EOT
  value       = module.networking.public_subnet_id
}

output "private_subnet_id" {
  description = <<-EOT
    Azure Resource ID of the private subnet (12.0.2.0/24).
    Resources here are not directly reachable from the internet.
    Outbound traffic routes through the NAT Gateway.
  EOT
  value       = module.networking.private_subnet_id
}

output "nat_gateway_public_ip" {
  description = <<-EOT
    Public IP prefix (CIDR range) assigned to the Azure NAT Gateway.
    All outbound traffic from the private subnet originates from this prefix.
    Add this to allowlists on external APIs or services.
  EOT
  value       = module.networking.nat_gateway_public_ip
}

output "public_nsg_id" {
  description = <<-EOT
    Azure Resource ID of the Network Security Group (NSG) attached to the
    public subnet. Allows inbound HTTP (80), HTTPS (443), SSH (22).
    Explicitly denies all other inbound traffic at priority 4000.
  EOT
  value       = module.networking.public_nsg_id
}

output "private_nsg_id" {
  description = <<-EOT
    Azure Resource ID of the Network Security Group (NSG) attached to the
    private subnet. Allows only VNet-internal inbound traffic.
    Blocks all direct inbound internet traffic.
  EOT
  value       = module.networking.private_nsg_id
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. Azure Compute – Portfolio VM
# ─────────────────────────────────────────────────────────────────────────────

output "portfolio_vm_id" {
  description = <<-EOT
    Azure Resource ID of the portfolio Linux Virtual Machine.
    Use in az CLI:
      az vm show --ids <value>
  EOT
  value       = module.compute.vm_id
}

output "portfolio_vm_name" {
  description = "Name of the portfolio Azure Virtual Machine."
  value       = module.compute.vm_name
}

output "portfolio_public_ip" {
  description = <<-EOT
    Static public IPv4 address of the portfolio web server.
    Open in a browser to view the portfolio: http://<value>
    Available ~2 minutes after terraform apply completes (cloud-init runtime).
  EOT
  value       = module.compute.public_ip_address
}

output "portfolio_public_fqdn" {
  description = <<-EOT
    Fully Qualified Domain Name (FQDN) of the portfolio Static Public IP.
    Format: <project>-<env>.<region>.cloudapp.azure.com
    Example: portfolio-dev.eastus.cloudapp.azure.com
    Open in a browser: http://<value>
  EOT
  value       = module.compute.public_ip_fqdn
}

output "portfolio_ssh_command" {
  description = <<-EOT
    Ready-to-use SSH command to connect to the portfolio VM.
    Replace <private_key_path> with the path to the key retrieved from Key Vault.
    Retrieve the key:
      az keyvault secret show \
        --vault-name <key_vault_name> \
        --name portfolio-vm-ssh-private-key \
        --query value --output tsv > ~/.ssh/portfolio.pem
      chmod 600 ~/.ssh/portfolio.pem
  EOT
  value       = "ssh -i <private_key_path> ${var.admin_username}@${module.compute.public_ip_address}"
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. Azure Security
# ─────────────────────────────────────────────────────────────────────────────

output "key_vault_id" {
  description = <<-EOT
    Azure Resource ID of the Key Vault.
    Used to configure access policies, link Disk Encryption Sets, or reference
    the vault in other Terraform workspaces.
  EOT
  value       = module.security.key_vault_id
}

output "key_vault_name" {
  description = <<-EOT
    Name of the Azure Key Vault.
    Use in az CLI commands:
      az keyvault secret list --vault-name <value>
  EOT
  value       = module.security.key_vault_name
}

output "key_vault_uri" {
  description = <<-EOT
    HTTPS URI of the Azure Key Vault.
    Format: https://<vault-name>.vault.azure.net/
    Set this as the AZURE_KEY_VAULT_URI environment variable in your
    application to enable Key Vault-backed secret retrieval using the
    Azure SDK DefaultAzureCredential (works automatically with the VM's
    Managed Identity).
  EOT
  value       = module.security.key_vault_uri
}

output "managed_identity_id" {
  description = <<-EOT
    Azure Resource ID of the User-Assigned Managed Identity attached to the VM.
    Use this ID when assigning Azure RBAC roles to the identity, for example
    granting it access to an Azure Storage Account or Service Bus.
  EOT
  value       = module.security.managed_identity_id
}

output "managed_identity_client_id" {
  description = <<-EOT
    Client ID of the User-Assigned Managed Identity.
    Pass this as the AZURE_CLIENT_ID environment variable when using the
    Azure SDK with a specific Managed Identity (ManagedIdentityCredential).
    Not required when using DefaultAzureCredential on a VM with a single UAMI.
  EOT
  value       = module.security.managed_identity_client_id
}

output "ssh_private_key_secret_name" {
  description = <<-EOT
    Name of the Azure Key Vault secret that stores the SSH private key for the VM.
    Retrieve with:
      az keyvault secret show \
        --vault-name $(terraform output -raw key_vault_name) \
        --name <value> \
        --query value --output tsv > ~/.ssh/portfolio.pem
  EOT
  value       = azurerm_key_vault_secret.ssh_private_key.name
}

# ─────────────────────────────────────────────────────────────────────────────
# 5. Connection Summary
# ─────────────────────────────────────────────────────────────────────────────

output "connection_summary" {
  description = <<-EOT
    Quick-reference block containing all connection details for the portfolio
    deployment. Print with: terraform output connection_summary
  EOT
  value = {
    portfolio_url      = "http://${module.compute.public_ip_address}"
    portfolio_fqdn_url = "http://${module.compute.public_ip_fqdn}"
    ssh_access         = "ssh -i <key> ${var.admin_username}@${module.compute.public_ip_address}"
    key_vault_uri      = module.security.key_vault_uri
    azure_region       = var.location
    environment        = var.environment
    resource_group     = azurerm_resource_group.main.name
  }
}
