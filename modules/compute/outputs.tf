###############################################################################
# modules/compute/outputs.tf
#
# Exposes the compute resource identifiers and connection addresses.
# Consumed by the root module outputs.tf for surfacing to operators.
###############################################################################

output "vm_id" {
  description = <<-EOT
    Azure Resource ID of the portfolio Linux Virtual Machine.
    Use in az CLI commands:
      az vm show --ids <value> --output table
      az vm start --ids <value>
      az vm deallocate --ids <value>
  EOT
  value       = azurerm_linux_virtual_machine.portfolio.id
}

output "vm_name" {
  description = <<-EOT
    Name of the Azure Virtual Machine (e.g. vm-portfolio-dev).
    Use in az CLI commands:
      az vm show -g rg-portfolio-dev -n <value>
      az vm run-command invoke -g rg-portfolio-dev -n <value> \
        --command-id RunShellScript --scripts "systemctl status nginx"
  EOT
  value       = azurerm_linux_virtual_machine.portfolio.name
}

output "private_ip_address" {
  description = <<-EOT
    Private IPv4 address of the VM's NIC within the public subnet (12.0.1.0/24).
    Used for VNet-internal communication from the private subnet to the VM.
    Dynamically assigned from the subnet address range by Azure DHCP.
  EOT
  value       = azurerm_network_interface.portfolio.private_ip_address
}

output "public_ip_address" {
  description = <<-EOT
    Static public IPv4 address of the portfolio web server.
    This address is fixed and does not change across VM stop/start cycles.
    Open the portfolio in a browser: http://<value>
    Available ~2 minutes after terraform apply (cloud-init bootstrap time).
  EOT
  value       = azurerm_public_ip.portfolio.ip_address
}

output "public_ip_fqdn" {
  description = <<-EOT
    Fully Qualified Domain Name of the portfolio Static Public IP.
    Azure-managed DNS record: <project>-<env>.<region>.cloudapp.azure.com
    Example: portfolio-dev.eastus.cloudapp.azure.com
    Open the portfolio in a browser: http://<value>
    Resolves to the same static IP as public_ip_address.
  EOT
  value       = azurerm_public_ip.portfolio.fqdn
}

output "public_ip_id" {
  description = <<-EOT
    Azure Resource ID of the Static Standard Public IP resource.
    Used when associating the Public IP with an Azure Load Balancer frontend,
    or when configuring Azure DDoS Protection plan exclusions.
  EOT
  value       = azurerm_public_ip.portfolio.id
}

output "nic_id" {
  description = <<-EOT
    Azure Resource ID of the VM's Network Interface Card.
    Used when adding additional IP configurations, enabling Azure Accelerated
    Networking, or troubleshooting network flow issues in Network Watcher.
  EOT
  value       = azurerm_network_interface.portfolio.id
}
