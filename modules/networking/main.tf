###############################################################################
# modules/networking/main.tf
#
# Purpose:
#   Deploys the complete Azure network topology for the portfolio application.
#
# Resources created:
#   ┌─────────────────────────────────────────────────────────────────────┐
#   │  Azure Virtual Network (VNet)  12.0.0.0/16                         │
#   │                                                                     │
#   │  ┌──────────────── Public Subnet  12.0.1.0/24 ──────────────────┐  │
#   │  │  NSG: Allow SSH (22), HTTP (80), HTTPS (443) inbound         │  │
#   │  │  NSG: Deny all other inbound (priority 4000)                 │  │
#   │  │  Route Table: 0.0.0.0/0 → Internet                          │  │
#   │  │  NAT Gateway (outbound for private subnet)                   │  │
#   │  └──────────────────────────────────────────────────────────────┘  │
#   │                                                                     │
#   │  ┌──────────────── Private Subnet  12.0.2.0/24 ─────────────────┐  │
#   │  │  NSG: Allow VNet-internal inbound only                       │  │
#   │  │  NSG: Deny all internet inbound (priority 4000)              │  │
#   │  │  Route Table: 0.0.0.0/0 → Internet (intercepted by NAT GW)  │  │
#   │  └──────────────────────────────────────────────────────────────┘  │
#   └─────────────────────────────────────────────────────────────────────┘
#
# Azure networking concepts used:
#   Virtual Network (VNet):
#     The foundational isolated network for Azure resources. All resources in
#     the same VNet can communicate privately by default. Traffic leaving the
#     VNet is governed by NSGs and route tables.
#
#   Network Security Group (NSG):
#     A stateful layer-4 firewall attached at the subnet level (and optionally
#     at the NIC level). Rules are evaluated by priority (lower = higher
#     precedence). Azure adds implicit deny-all rules at the end; we also add
#     an explicit deny at priority 4000 for auditability.
#
#   Azure NAT Gateway:
#     Provides outbound-only internet connectivity for private subnet resources.
#     NAT Gateway uses a Public IP Prefix (a range of static public IPs) as
#     the source address for all outbound connections from the private subnet.
#     Inbound connections from the internet to private subnet resources are
#     not allowed through the NAT Gateway.
#
#   User-Defined Route Table (UDR):
#     Overrides Azure's default system routes for fine-grained traffic control.
#     The public subnet UDR explicitly routes 0.0.0.0/0 to the Internet next
#     hop. The private subnet UDR routes 0.0.0.0/0 via Internet (NAT Gateway
#     intercepts before packets leave Azure).
#
# Azure Well-Architected alignment:
#   Security          – NSGs at subnet level, explicit deny-all rules
#   Reliability       – Zone-1 NAT Gateway (expand to zone-redundant in prod)
#   Cost Optimisation – /31 Public IP Prefix (2 IPs) keeps NAT Gateway cost minimal
###############################################################################

###############################################################################
# Azure Virtual Network (VNet)
#
# The VNet is the private, isolated network for all portfolio resources.
# Address space: 12.0.0.0/16 (65,536 IP addresses across all subnets).
#
# Production guidance:
#   Enable Azure DDoS Network Protection by adding a ddos_protection_plan
#   block. This adds ~$2,944/month but provides SLA-backed DDoS mitigation.
#   For low-traffic portfolios the built-in Azure DDoS Basic (free) is adequate.
###############################################################################
resource "azurerm_virtual_network" "main" {
  name                = "vnet-${var.project_name}-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group_name
  address_space       = var.vnet_address_space

  # Uncomment in production for paid DDoS Network Protection:
  # ddos_protection_plan {
  #   id     = azurerm_network_ddos_protection_plan.main.id
  #   enable = true
  # }

  tags = var.tags
}

###############################################################################
# Public Subnet  –  12.0.1.0/24
#
# Hosts resources that require direct internet connectivity. In this project,
# the portfolio VM's Network Interface (NIC) is placed here, paired with a
# Static Standard Public IP address.
#
# Azure subnet behaviour:
#   - Azure reserves 5 IP addresses per subnet (first 4 + last 1).
#     12.0.1.0  – Network address
#     12.0.1.1  – Default Azure gateway
#     12.0.1.2  – Azure DNS
#     12.0.1.3  – Reserved
#     12.0.1.255 – Broadcast
#   - Usable addresses: 12.0.1.4 – 12.0.1.254 (251 addresses)
#
# Unlike some cloud platforms, Azure does not auto-assign public IPs to
# resources in a subnet. Public IP assignment is explicit per NIC/resource.
###############################################################################
resource "azurerm_subnet" "public" {
  name                 = "snet-public-${var.project_name}-${var.environment}"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.public_subnet_prefix]
  # NAT Gateway association is handled via azurerm_subnet_nat_gateway_association
}

###############################################################################
# Private Subnet  –  12.0.2.0/24
#
# Hosts resources that must not be directly reachable from the internet.
# Examples: Azure SQL Managed Instance, internal APIs, Redis Cache.
# Outbound internet access (e.g. for OS updates) is routed through the
# NAT Gateway in the public subnet.
###############################################################################
resource "azurerm_subnet" "private" {
  name                 = "snet-private-${var.project_name}-${var.environment}"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.private_subnet_prefix]
}

###############################################################################
# Network Security Group – Public Subnet
#
# Controls inbound and outbound traffic for the public subnet.
# Rules are evaluated in ascending priority order (100 is evaluated first).
#
# Inbound rules:
#   100 – Allow SSH   (port 22)  from var.allowed_ssh_cidr
#   110 – Allow HTTP  (port 80)  from Internet service tag
#   120 – Allow HTTPS (port 443) from Internet service tag
#  4000 – Deny All   (explicit catch-all, defence-in-depth)
#
# Outbound rules:
#   100 – Allow All outbound to Internet
#
# Azure service tags used:
#   "Internet" – all public IP addresses outside Azure's address space
#   Avoids the need to enumerate individual IP ranges for internet traffic.
###############################################################################
resource "azurerm_network_security_group" "public" {
  name                = "nsg-public-${var.project_name}-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  # ── Inbound: SSH ─────────────────────────────────────────────────────────
  # Allows SSH access from the CIDR defined in var.allowed_ssh_cidr.
  # Production: restrict to a known IP (e.g. "203.0.113.10/32") or VPN CIDR.
  security_rule {
    name                       = "Allow-SSH-Inbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.allowed_ssh_cidr
    destination_address_prefix = "*"
    description                = "SSH access to the portfolio VM. Restrict source CIDR in production."
  }

  # ── Inbound: HTTP ────────────────────────────────────────────────────────
  # Allows public HTTP traffic for the portfolio web application.
  # The "Internet" service tag covers all public IP addresses.
  security_rule {
    name                       = "Allow-HTTP-Inbound"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
    description                = "HTTP inbound for the publicly accessible portfolio application."
  }

  # ── Inbound: HTTPS ───────────────────────────────────────────────────────
  # Allows public HTTPS traffic. Requires a TLS certificate on Nginx.
  # Add an Azure-issued certificate via App Gateway or a Let's Encrypt cert.
  security_rule {
    name                       = "Allow-HTTPS-Inbound"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
    description                = "HTTPS inbound for the portfolio application (TLS termination on VM)."
  }

  # ── Inbound: Deny All (explicit) ─────────────────────────────────────────
  # Azure adds an implicit DenyAllInBound rule at priority 65500. This
  # explicit deny at 4000 makes the security posture visible and auditable
  # without relying on hidden platform behaviour.
  security_rule {
    name                       = "Deny-All-Inbound"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
    description                = "Explicit deny-all inbound. Defence-in-depth catch-all rule."
  }

  # ── Outbound: Allow All ──────────────────────────────────────────────────
  # The portfolio VM needs outbound internet access for OS updates and
  # package installs during cloud-init bootstrap.
  security_rule {
    name                       = "Allow-All-Outbound"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "Internet"
    description                = "Allow all outbound internet traffic from the public subnet."
  }
}

###############################################################################
# Network Security Group – Private Subnet
#
# Controls traffic for the private subnet. No inbound traffic from the
# internet is permitted. Resources here communicate only within the VNet.
#
# Inbound rules:
#   100 – Allow VNet-internal (VirtualNetwork → VirtualNetwork)
#   110 – Allow Azure Load Balancer health probes (required by Azure platform)
#  4000 – Deny All internet inbound
#
# Outbound rules:
#   100 – Allow VNet-internal outbound
#   110 – Allow outbound to Internet (routed via NAT Gateway)
###############################################################################
resource "azurerm_network_security_group" "private" {
  name                = "nsg-private-${var.project_name}-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  # ── Inbound: VNet-internal ───────────────────────────────────────────────
  # The "VirtualNetwork" service tag covers all subnets within this VNet
  # and any peered VNets. Allows the portfolio VM (public subnet) to call
  # services in the private subnet.
  security_rule {
    name                       = "Allow-VNet-Inbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "VirtualNetwork"
    description                = "Allow all VNet-internal inbound traffic between subnets."
  }

  # ── Inbound: Azure Load Balancer ─────────────────────────────────────────
  # Azure requires this rule when an Azure Load Balancer performs health probes
  # against resources in this subnet. Omitting it causes health probe failures.
  security_rule {
    name                       = "Allow-AzureLoadBalancer-Inbound"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "*"
    description                = "Required Azure platform rule for Load Balancer health probes."
  }

  # ── Inbound: Deny Internet ───────────────────────────────────────────────
  # Blocks all inbound traffic originating from the internet to the private
  # subnet. Combined with no Public IP assignment, this makes resources here
  # unreachable from the internet.
  security_rule {
    name                       = "Deny-Internet-Inbound"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
    description                = "Block all direct internet inbound to the private subnet."
  }

  # ── Outbound: VNet-internal ──────────────────────────────────────────────
  security_rule {
    name                       = "Allow-VNet-Outbound"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "VirtualNetwork"
    description                = "Allow all VNet-internal outbound traffic."
  }

  # ── Outbound: Internet via NAT Gateway ──────────────────────────────────
  # Private subnet resources can reach the internet outbound (e.g. for OS
  # patches via apt). The NAT Gateway intercepts this traffic before it
  # reaches the internet, replacing the source IP with the NAT Gateway's
  # Public IP Prefix. No inbound connection can be initiated from the internet.
  security_rule {
    name                       = "Allow-Internet-Outbound-via-NAT"
    priority                   = 110
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "Internet"
    description                = "Outbound internet via NAT Gateway. Inbound from internet is not permitted."
  }
}

###############################################################################
# NSG → Subnet Associations
#
# Attaches each NSG to its respective subnet. Once associated, the NSG's rules
# are enforced on all traffic entering and leaving the subnet.
# An NSG can be associated with multiple subnets, but each subnet can only
# have one NSG at the subnet level.
###############################################################################
resource "azurerm_subnet_network_security_group_association" "public" {
  subnet_id                 = azurerm_subnet.public.id
  network_security_group_id = azurerm_network_security_group.public.id
}

resource "azurerm_subnet_network_security_group_association" "private" {
  subnet_id                 = azurerm_subnet.private.id
  network_security_group_id = azurerm_network_security_group.private.id
}

###############################################################################
# Azure NAT Gateway
#
# Provides outbound-only internet connectivity for the private subnet.
# Key characteristics:
#   - Outbound connections originate from the NAT Gateway's Public IP Prefix
#   - Supports up to 64,000 concurrent outbound TCP/UDP connections per IP
#   - Stateful: return traffic for outbound connections is allowed back in
#   - Zone-scoped: pinned to Availability Zone 1 in this dev configuration
#
# Components:
#   Public IP Prefix  – A range of contiguous static public IPs (/31 = 2 IPs).
#                       Adding more IPs increases connection capacity.
#   NAT Gateway       – The gateway resource itself (sku: Standard).
#   IP-to-GW assoc    – Links the Public IP Prefix to the NAT Gateway.
#   GW-to-Subnet assoc– Associates the NAT Gateway with specific subnets.
#
# Cost notes:
#   Billed: ~$32/month base + $0.045/GB processed.
#   The /31 prefix (2 IPs) is the smallest available, minimising cost.
#   Set enable_nat_gateway = false in dev to eliminate this cost entirely
#   if private subnet outbound access is not required.
###############################################################################
resource "azurerm_public_ip_prefix" "nat" {
  count = var.enable_nat_gateway ? 1 : 0

  name                = "ippre-nat-${var.project_name}-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group_name
  prefix_length       = 31    # /31 = 2 public IPs (smallest available prefix)
  sku                 = "Standard"
  zones               = ["1"] # Single zone for dev. Use zone-redundant in prod.
  tags                = var.tags
}

resource "azurerm_nat_gateway" "main" {
  count = var.enable_nat_gateway ? 1 : 0

  name                    = "natgw-${var.project_name}-${var.environment}"
  location                = var.location
  resource_group_name     = var.resource_group_name
  sku_name                = "Standard"
  idle_timeout_in_minutes = 10  # TCP idle connection timeout (4–120 minutes)
  zones                   = ["1"]
  tags                    = var.tags
}

# Associate the Public IP Prefix with the NAT Gateway
resource "azurerm_nat_gateway_public_ip_prefix_association" "main" {
  count = var.enable_nat_gateway ? 1 : 0

  nat_gateway_id      = azurerm_nat_gateway.main[0].id
  public_ip_prefix_id = azurerm_public_ip_prefix.nat[0].id
}

# Attach NAT Gateway to the public subnet
# The NAT Gateway is hosted in the public subnet and manages the outbound
# SNAT (Source Network Address Translation) for associated subnets.
resource "azurerm_subnet_nat_gateway_association" "public" {
  count = var.enable_nat_gateway ? 1 : 0

  subnet_id      = azurerm_subnet.public.id
  nat_gateway_id = azurerm_nat_gateway.main[0].id
}

# Attach NAT Gateway to the private subnet
# All outbound traffic from private subnet resources is translated to the
# NAT Gateway's Public IP Prefix before reaching the internet.
resource "azurerm_subnet_nat_gateway_association" "private" {
  count = var.enable_nat_gateway ? 1 : 0

  subnet_id      = azurerm_subnet.private.id
  nat_gateway_id = azurerm_nat_gateway.main[0].id
}

###############################################################################
# User-Defined Route Table (UDR) – Public Subnet
#
# Azure creates system default routes for every subnet automatically.
# This explicit Route Table documents and enforces the public subnet routing:
#   0.0.0.0/0 → Internet  (all non-VNet traffic goes directly to the internet)
#
# Why define it explicitly?
#   - Makes routing intent visible in the Azure Portal and Terraform plan output
#   - Allows future customisation (e.g. redirect traffic through Azure Firewall)
#   - Prevents accidental routing changes from Azure system route updates
#
# disable_bgp_route_propagation = false means Azure ExpressRoute/VPN gateway
# routes are still propagated into this route table (correct for most setups).
###############################################################################
resource "azurerm_route_table" "public" {
  name                          = "rt-public-${var.project_name}-${var.environment}"
  location                      = var.location
  resource_group_name           = var.resource_group_name
  disable_bgp_route_propagation = false
  tags                          = var.tags

  route {
    name           = "default-internet"
    address_prefix = "0.0.0.0/0"
    next_hop_type  = "Internet"
  }
}

resource "azurerm_subnet_route_table_association" "public" {
  subnet_id      = azurerm_subnet.public.id
  route_table_id = azurerm_route_table.public.id
}

###############################################################################
# User-Defined Route Table (UDR) – Private Subnet
#
# Routes outbound traffic from the private subnet to the internet via the
# NAT Gateway. The next_hop_type is "Internet" here because Azure automatically
# intercepts this traffic at the NAT Gateway association level before it
# reaches the public internet.
#
# Traffic flow for private subnet outbound:
#   Private VM → Route Table (0.0.0.0/0 → Internet) →
#   NAT Gateway (SNAT to Public IP Prefix) → Azure backbone → Internet
###############################################################################
resource "azurerm_route_table" "private" {
  name                          = "rt-private-${var.project_name}-${var.environment}"
  location                      = var.location
  resource_group_name           = var.resource_group_name
  disable_bgp_route_propagation = false
  tags                          = var.tags

  route {
    name           = "default-via-nat"
    address_prefix = "0.0.0.0/0"
    next_hop_type  = "Internet"
    # The NAT Gateway subnet association intercepts this traffic
    # and performs SNAT before it leaves Azure.
  }
}

resource "azurerm_subnet_route_table_association" "private" {
  subnet_id      = azurerm_subnet.private.id
  route_table_id = azurerm_route_table.private.id
}
