###############################################################################
# modules/networking/outputs.tf
#
# Exposes the key Azure resource identifiers from the networking module.
# These outputs are consumed by the compute and security modules, and are
# also surfaced in the root module outputs.tf for operator reference.
###############################################################################

output "vnet_id" {
  description = <<-EOT
    Azure Resource ID of the Virtual Network.
    Format: /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<name>
    Used when:
      - Peering this VNet with another VNet (azurerm_virtual_network_peering)
      - Linking a Private DNS Zone to this VNet
      - Granting Key Vault network access via service endpoints
  EOT
  value       = azurerm_virtual_network.main.id
}

output "vnet_name" {
  description = "Name of the Azure Virtual Network (e.g. vnet-portfolio-dev)."
  value       = azurerm_virtual_network.main.name
}

output "public_subnet_id" {
  description = <<-EOT
    Azure Resource ID of the public subnet (12.0.1.0/24).
    Required when placing a Network Interface (NIC) or Azure resource into
    the public subnet.
  EOT
  value       = azurerm_subnet.public.id
}

output "private_subnet_id" {
  description = <<-EOT
    Azure Resource ID of the private subnet (12.0.2.0/24).
    Required when placing a backend resource (database, internal service) into
    the private subnet, or when configuring Private Endpoints.
  EOT
  value       = azurerm_subnet.private.id
}

output "public_nsg_id" {
  description = <<-EOT
    Azure Resource ID of the Network Security Group attached to the public subnet.
    Used in the compute module to also associate the NSG at the NIC level
    (defence-in-depth: NSG enforced at both subnet and NIC).
  EOT
  value       = azurerm_network_security_group.public.id
}

output "private_nsg_id" {
  description = "Azure Resource ID of the Network Security Group attached to the private subnet."
  value       = azurerm_network_security_group.private.id
}

output "nat_gateway_id" {
  description = <<-EOT
    Azure Resource ID of the NAT Gateway.
    Returns null when enable_nat_gateway is false.
  EOT
  value       = var.enable_nat_gateway ? azurerm_nat_gateway.main[0].id : null
}

output "nat_gateway_public_ip" {
  description = <<-EOT
    Public IP prefix range (CIDR) assigned to the NAT Gateway.
    All outbound connections from the private subnet originate from IPs
    within this prefix. Add this to allowlists on external APIs and services.
    Returns null when enable_nat_gateway is false.
  EOT
  value       = var.enable_nat_gateway ? azurerm_public_ip_prefix.nat[0].ip_prefix : null
}

output "public_route_table_id" {
  description = "Azure Resource ID of the User-Defined Route Table (UDR) for the public subnet."
  value       = azurerm_route_table.public.id
}

output "private_route_table_id" {
  description = "Azure Resource ID of the User-Defined Route Table (UDR) for the private subnet."
  value       = azurerm_route_table.private.id
}
