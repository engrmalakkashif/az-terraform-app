###############################################################################
# modules/compute/main.tf
#
# Purpose:
#   Deploys the publicly accessible portfolio web server on Azure.
#
# Resources created:
#   1. Static Standard Public IP
#      A zone-pinned static IPv4 address with a DNS label that makes the
#      portfolio accessible at a predictable FQDN:
#        <project>-<env>.eastus.cloudapp.azure.com
#
#   2. Network Interface Card (NIC)
#      Connects the VM to the public subnet inside the VNet.
#      Combines the static public IP with a dynamic private IP in 12.0.1.0/24.
#
#   3. NSG → NIC Association (defence-in-depth)
#      The public NSG is already associated at the subnet level (networking
#      module). Attaching it to the NIC as well creates a second enforcement
#      point: traffic must pass both the subnet NSG and the NIC NSG.
#
#   4. Linux Virtual Machine (Ubuntu 22.04 LTS)
#      The portfolio web server. Key security hardening:
#        - SSH password authentication disabled (key-based only)
#        - UEFI Secure Boot enabled (blocks unsigned bootloaders/kernel modules)
#        - User-Assigned Managed Identity attached (passwordless Azure auth)
#        - OS disk encrypted with Customer-Managed Key (CMK)
#        - Azure Automatic VM Guest Patching (auto OS security patches)
#        - Boot diagnostics enabled (troubleshoot startup failures in Portal)
#        - cloud-init bootstraps Nginx + portfolio page on first boot
#
#   5. Azure Monitor Agent VM Extension
#      Installs the Azure Monitor Agent on the VM. Collects:
#        - VM metrics (CPU, memory, disk, network) → Azure Monitor
#        - Application logs → Log Analytics Workspace (configure separately)
#      Enables alerting, dashboards, and log queries in the Azure Portal.
#
# Traffic flow to the portfolio:
#   Internet → NSG (allow port 80) → Static Public IP → NIC → VM (Nginx:80)
#
# Azure Well-Architected alignment:
#   Security         – SSH key-only auth, UEFI Secure Boot, CMK disk encryption,
#                      NSG at subnet + NIC level, fail2ban, hardened SSH config
#   Reliability      – Zone-pinned resources, Azure Monitor Agent for alerting
#   Cost Optimisation– Standard_B2s (burstable) suits low-traffic portfolio apps
#   Operational Exc. – Azure Monitor Agent, Boot Diagnostics, cloud-init logs
###############################################################################

###############################################################################
# Static Standard Public IP
#
# A Standard SKU Static Public IP provides:
#   - A fixed IPv4 address that does not change across VM stop/start cycles
#   - Zone support (pinned to Availability Zone 1 here)
#   - Required SKU for use with Azure Load Balancer Standard and NAT Gateway
#
# DNS label:
#   Setting domain_name_label creates a free Azure-managed DNS record:
#     <label>.<region>.cloudapp.azure.com
#   Example: portfolio-dev.eastus.cloudapp.azure.com
#   This FQDN resolves to the static public IP address.
#
# Standard vs Basic SKU:
#   Standard – Zone-redundant capable, secure by default (needs NSG to allow
#              traffic), supports Availability Zones.
#   Basic    – No zone support, open by default (legacy, being retired).
#   Always use Standard SKU for new deployments.
###############################################################################
resource "azurerm_public_ip" "portfolio" {
  name                = "pip-${var.project_name}-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"   # Fixed IP – does not change on VM restart
  sku                 = "Standard" # Required for zone support and NAT Gateway
  zones               = ["1"]      # Zone 1 (matches NAT Gateway zone for dev)

  # Free Azure DNS: <label>.<region>.cloudapp.azure.com
  domain_name_label = "${var.project_name}-${var.environment}"

  idle_timeout_in_minutes = 10
  tags                    = var.tags
}

###############################################################################
# Network Interface Card (NIC)
#
# The NIC connects the VM to the Azure VNet. Each NIC has one or more IP
# configurations. The primary configuration here:
#   - private_ip_address_allocation = "Dynamic"
#       Azure assigns a private IP from 12.0.1.0/24 automatically.
#       For production web servers, consider "Static" private IP allocation
#       to ensure consistent internal DNS resolution.
#   - public_ip_address_id = azurerm_public_ip.portfolio.id
#       Associates the Static Public IP with this NIC, making the VM
#       internet-reachable on its assigned public IP address.
###############################################################################
resource "azurerm_network_interface" "portfolio" {
  name                = "nic-${var.project_name}-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  ip_configuration {
    name                          = "ipconfig-primary"
    subnet_id                     = var.public_subnet_id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.portfolio.id
  }
}

###############################################################################
# NSG → NIC Association (Defence-in-Depth)
#
# Azure allows NSGs to be applied at two levels:
#   1. Subnet level – applied in the networking module (all traffic to/from subnet)
#   2. NIC level    – applied here (all traffic to/from this specific NIC)
#
# When both are present, Azure evaluates the subnet NSG first, then the NIC NSG
# for inbound traffic (reverse for outbound). Traffic must pass both.
# This dual association ensures that even if the subnet NSG is misconfigured,
# the NIC-level NSG still blocks unauthorised traffic to this VM.
###############################################################################
resource "azurerm_network_interface_security_group_association" "portfolio" {
  network_interface_id      = azurerm_network_interface.portfolio.id
  network_security_group_id = var.public_nsg_id
}

###############################################################################
# cloud-init Bootstrap Script
#
# cloud-init is the industry-standard multi-distribution package for
# cross-platform cloud instance initialisation. Azure Linux VMs run cloud-init
# automatically on first boot.
#
# The cloud-init.yaml file (in this module directory) performs:
#   - System package update and upgrade (apt-get update && upgrade)
#   - Installs: nginx, curl, git, ufw (firewall), fail2ban (SSH protection)
#   - Configures ufw: deny all inbound, allow 22/80/443
#   - Hardens SSH: disables root login, password auth, X11 forwarding
#   - Deploys a static portfolio HTML page to /var/www/portfolio/
#   - Configures Nginx with security headers (CSP, X-Frame-Options, etc.)
#   - Enables and starts nginx and fail2ban services
#
# templatefile() substitutes ${project_name} and ${environment} variables
# into the YAML at plan time. The result is base64-encoded and passed to
# the VM as custom_data – Azure delivers it to cloud-init on first boot.
#
# Verify bootstrap completed:
#   ssh -i <key> azureuser@<public_ip>
#   sudo cat /var/log/cloud-init-output.log
#   sudo cat /var/log/cloud-init-portfolio.log
###############################################################################
locals {
  cloud_init = base64encode(templatefile("${path.module}/cloud-init.yaml", {
    project_name = var.project_name
    environment  = var.environment
  }))
}

###############################################################################
# Azure Linux Virtual Machine
#
# Deploys Ubuntu 22.04 LTS (Jammy Jellyfish) as the portfolio web server.
#
# OS Image:
#   publisher = "Canonical"
#   offer     = "0001-com-ubuntu-server-jammy"
#   sku       = "22_04-lts-gen2"  (Gen2 UEFI – required for Secure Boot)
#   version   = "latest"           (always gets the latest patched image)
#
# SSH authentication:
#   disable_password_authentication = true
#     Azure disables password login at the OS level. The only way to SSH
#     into this VM is with the RSA-4096 private key stored in Key Vault.
#   admin_ssh_key: the public key is injected into ~/.ssh/authorized_keys
#     for the admin_username during VM provisioning.
#
# Managed Identity:
#   type = "UserAssigned"
#   identity_ids: attaches the UAMI from the security module. The VM's Azure
#   Instance Metadata Service (IMDS) provides tokens for this identity,
#   enabling the application to call Key Vault without any credentials.
#
# OS Disk (Premium SSD):
#   storage_account_type = "Premium_LRS"
#     Premium Locally Redundant Storage SSD – low latency, high throughput.
#     Suitable for web server OS disks.
#   disk_encryption_set_id:
#     References the Disk Encryption Set (DES) from the security module.
#     The OS disk is encrypted at rest using the Customer-Managed Key (CMK)
#     in Azure Key Vault (envelope encryption).
#   The disk is automatically deleted when the VM is destroyed
#   (configured in versions.tf: delete_os_disk_on_deletion = true).
#
# UEFI Secure Boot:
#   secure_boot_enabled = true
#     Requires the VM to boot only with firmware/bootloader/OS signed by
#     trusted certificates. Blocks unsigned bootkit and rootkit attacks.
#     Requires a Gen2 VM image (22_04-lts-gen2).
#
# Azure Automatic VM Guest Patching:
#   patch_mode = "AutomaticByPlatform"
#     Azure automatically assesses and installs critical and security OS
#     patches on a regular schedule without requiring a maintenance window.
#     Assessment runs within 24 hours of creation, then continuously.
#
# Boot Diagnostics:
#   storage_account_uri = null (Azure-managed storage – no cost)
#     Captures the VM's serial console output. Invaluable for diagnosing
#     boot failures. Accessible in the Azure Portal:
#       VM → Support + troubleshooting → Boot diagnostics
###############################################################################
resource "azurerm_linux_virtual_machine" "portfolio" {
  name                = "vm-${var.project_name}-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group_name
  size                = var.vm_size
  admin_username      = var.admin_username

  # NIC created above – connects the VM to the public subnet + public IP
  network_interface_ids = [azurerm_network_interface.portfolio.id]

  # Key-based authentication only – password login disabled at the OS level
  disable_password_authentication = true

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  # Attach the User-Assigned Managed Identity (passwordless Azure auth)
  identity {
    type         = "UserAssigned"
    identity_ids = [var.managed_identity_id]
  }

  # OS disk – Premium SSD, CMK encrypted, auto-deleted with VM
  os_disk {
    name                   = "osdisk-${var.project_name}-${var.environment}"
    caching                = "ReadWrite"
    storage_account_type   = "Premium_LRS"
    disk_size_gb           = var.os_disk_size_gb
    disk_encryption_set_id = var.disk_encryption_set_id
  }

  # Ubuntu 22.04 LTS Gen2 – UEFI-capable, Secure Boot compatible
  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  # cloud-init: install Nginx + deploy portfolio page on first boot
  custom_data = local.cloud_init

  # Boot diagnostics – Azure-managed storage (free), helps debug boot issues
  boot_diagnostics {
    storage_account_uri = null
  }

  # Automatic OS security patching via Azure Automatic VM Guest Patching
  patch_mode = "AutomaticByPlatform"

  # UEFI Secure Boot – blocks unsigned bootloader/kernel (Gen2 VMs only)
  vtpm_enabled        = false
  secure_boot_enabled = true

  tags = var.tags

  # NIC must have the NSG associated before the VM is created
  depends_on = [azurerm_network_interface_security_group_association.portfolio]
}

###############################################################################
# Azure Monitor Agent – VM Extension
#
# The Azure Monitor Agent (AMA) is Microsoft's unified agent for collecting
# telemetry from Azure VMs. It replaces the legacy Log Analytics Agent (MMA)
# and Diagnostics Extension (LAD).
#
# What it collects (configured separately via Data Collection Rules – DCR):
#   - VM metrics: CPU, memory, disk IOPS, network bytes/s → Azure Monitor
#   - Syslog and custom log files → Log Analytics Workspace
#   - Windows Event Logs (Linux equivalent: syslog) → Log Analytics
#
# Benefits over direct SSH for troubleshooting:
#   - No need to open inbound port 22 for observability
#   - Centralised dashboards in Azure Monitor Workbooks
#   - Alerting rules based on metric thresholds (e.g. CPU > 80%)
#   - Log queries using Kusto Query Language (KQL) in Log Analytics
#
# automatic_upgrade_enabled = true ensures Azure automatically updates the
# agent to the latest version, applying bug fixes and new features.
#
# To complete monitoring setup, create a Data Collection Rule (DCR) in
# Azure Monitor and associate it with this VM.
###############################################################################
resource "azurerm_virtual_machine_extension" "monitor" {
  name                       = "AzureMonitorLinuxAgent"
  virtual_machine_id         = azurerm_linux_virtual_machine.portfolio.id
  publisher                  = "Microsoft.Azure.Monitor"
  type                       = "AzureMonitorLinuxAgent"
  type_handler_version       = "1.0"
  auto_upgrade_minor_version = true
  automatic_upgrade_enabled  = true

  tags = var.tags
}
