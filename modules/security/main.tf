###############################################################################
# modules/security/main.tf
#
# Purpose:
#   Deploys the Azure security services layer for the portfolio infrastructure.
#
# Resources created:
#   1. User-Assigned Managed Identity (UAMI)
#      Provides the portfolio VM with a passwordless Azure identity.
#      The VM uses this identity to authenticate to Azure Key Vault and other
#      Azure services without any credentials stored in code or config files.
#
#   2. Azure Key Vault
#      Centralised secret, key, and certificate management service.
#      Stores the VM SSH private key. Hosts the Customer-Managed Key (CMK)
#      for disk encryption. Protects all secrets with soft-delete and
#      purge protection.
#
#   3. Key Vault Access Policies
#      deployer    – The CI/CD Service Principal or local Azure CLI identity.
#                   Granted full permissions to write secrets and manage keys
#                   during terraform apply.
#      vm_identity – The portfolio VM's Managed Identity.
#                   Granted read-only (Get/List) access only.
#                   Principle of least privilege: the VM can read secrets
#                   it needs at runtime, but cannot create or delete them.
#      disk_enc    – The Disk Encryption Set's system-assigned identity.
#                   Granted WrapKey/UnwrapKey to perform disk encryption.
#
#   4. Key Vault Key (RSA-4096)
#      A Customer-Managed Key (CMK) used to encrypt the portfolio VM's OS disk.
#      Includes an automatic rotation policy: the key rotates every year,
#      with a 30-day advance notification before expiry.
#
#   5. Disk Encryption Set (DES)
#      Links the Key Vault CMK to Azure Managed Disk encryption.
#      The OS disk in the compute module references this DES to ensure
#      the disk is encrypted with the customer-controlled key rather than
#      the default platform-managed key.
#
# Azure Well-Architected alignment:
#   Security:
#     - Managed Identity eliminates the need for stored credentials
#     - CMK disk encryption gives the customer control over data-at-rest keys
#     - Key auto-rotation reduces the blast radius of key compromise
#     - Soft-delete + purge protection prevents accidental permanent data loss
#   Operational Excellence:
#     - Key Vault audit logs track every access and management operation
#     - Access policies enforce separation of concerns (deployer vs. VM)
###############################################################################

###############################################################################
# User-Assigned Managed Identity (UAMI)
#
# A Managed Identity is an Azure AD identity managed by the Azure platform.
# Unlike a Service Principal, it has no credentials (no client secret or
# certificate) to rotate, expire, or accidentally expose.
#
# User-Assigned vs System-Assigned:
#   User-Assigned (chosen here): Created as a standalone Azure resource.
#     - Can be shared across multiple VMs or services
#     - Its lifecycle is independent of the VM (identity persists if VM is rebuilt)
#     - Enables pre-assigning Key Vault access policies before VM creation
#   System-Assigned: Created and managed per-resource, deleted with the resource.
#
# How the VM uses this identity:
#   The Azure SDK's DefaultAzureCredential or ManagedIdentityCredential
#   automatically uses the UAMI to obtain short-lived Azure AD tokens for
#   calling Azure services (Key Vault, Blob Storage, Service Bus, etc.).
#   No ARM_CLIENT_SECRET or connection strings required in the application.
###############################################################################
resource "azurerm_user_assigned_identity" "portfolio" {
  name                = "id-${var.project_name}-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

###############################################################################
# Azure Key Vault
#
# Key Vault provides three services:
#   Secrets  – Store and retrieve sensitive strings (connection strings, SSH keys)
#   Keys     – Manage cryptographic keys (used for disk encryption, data signing)
#   Certificates – Manage TLS/SSL certificates with auto-renewal
#
# Naming: Key Vault names are globally unique across all Azure tenants.
# A random suffix is appended to prevent naming conflicts.
# Format: kv-<project>-<suffix>  (max 24 characters, alphanumeric + hyphens)
#
# Security configuration:
#   soft_delete_retention_days:
#     Deleted vaults, secrets, and keys are retained for this many days in a
#     soft-deleted state. They can be recovered with:
#       az keyvault recover --name <vault-name>
#
#   purge_protection_enabled = true:
#     Even an administrator cannot permanently delete the vault or its
#     contents during the soft-delete retention period. This prevents
#     both accidental and malicious permanent data loss.
#
#   public_network_access_enabled = true (dev only):
#     In production, set this to false and use an Azure Private Endpoint
#     to restrict Key Vault access to the VNet only.
#
#   network_acls default_action = "Allow" (dev only):
#     In production, set to "Deny" and explicitly allow only:
#       - The deployment agent's IP range (for Terraform access)
#       - The VNet subnet service endpoints (for VM access)
###############################################################################
resource "azurerm_key_vault" "main" {
  name                = "kv-${var.project_name}-${var.random_suffix}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tenant_id           = var.tenant_id
  sku_name            = var.key_vault_sku

  # Soft-delete: vault and contents remain recoverable for N days after deletion
  soft_delete_retention_days = var.key_vault_soft_delete_days

  # Purge protection: prevents permanent deletion during the retention period
  # This cannot be disabled once enabled (by design – it's a safety lock)
  purge_protection_enabled = true

  # Dev: allow public access for simpler deployment
  # Production: set false and configure a Private Endpoint
  public_network_access_enabled = true

  network_acls {
    default_action = "Allow" # Production: change to "Deny"
    bypass         = "AzureServices"

    # Production additions:
    # virtual_network_subnet_ids = [
    #   var.public_subnet_id,
    #   var.private_subnet_id,
    # ]
    # ip_rules = ["<deployer-ip>/32"]
  }

  tags = var.tags
}

###############################################################################
# Key Vault Access Policy – Terraform Deployer
#
# Grants full administrative permissions to the identity running Terraform
# (either the local user logged in via `az login`, or the CI/CD Service
# Principal identified by var.deployer_object_id).
#
# These permissions are required during terraform apply to:
#   - Create and manage the disk encryption key (keys: Create, Update, etc.)
#   - Write the SSH private key secret (secrets: Set)
#   - Read back values for output references (Get, List)
#   - Configure key rotation policies (GetRotationPolicy, SetRotationPolicy)
#
# In production: restrict this to a dedicated pipeline Service Principal
# and remove permissions that are not required after initial deployment.
###############################################################################
resource "azurerm_key_vault_access_policy" "deployer" {
  key_vault_id = azurerm_key_vault.main.id
  tenant_id    = var.tenant_id
  object_id    = var.deployer_object_id

  key_permissions = [
    "Get", "List", "Create", "Delete", "Update",
    "Recover", "Purge", "GetRotationPolicy", "SetRotationPolicy",
  ]

  secret_permissions = [
    "Get", "List", "Set", "Delete", "Recover", "Purge", "Backup", "Restore",
  ]

  certificate_permissions = [
    "Get", "List", "Create", "Delete", "Update", "Import", "Recover", "Purge",
  ]
}

###############################################################################
# Key Vault Access Policy – Portfolio VM (Managed Identity)
#
# Grants the portfolio VM's Managed Identity read-only access to Key Vault
# secrets and keys. This follows the principle of least privilege:
#   - The VM can read the secrets it needs at runtime (Get, List)
#   - The VM cannot create, update, delete, or purge secrets or keys
#
# How the VM uses this at runtime:
#   The application running on the VM calls Key Vault using the Azure SDK
#   (e.g. SecretClient from @azure/keyvault-secrets in Node.js, or
#   azure-keyvault in Python). The SDK automatically obtains a token from
#   the Azure Instance Metadata Service (IMDS) using the Managed Identity
#   and presents it to Key Vault for authentication. No credentials needed.
###############################################################################
resource "azurerm_key_vault_access_policy" "vm_identity" {
  key_vault_id = azurerm_key_vault.main.id
  tenant_id    = var.tenant_id
  object_id    = azurerm_user_assigned_identity.portfolio.principal_id

  # Read-only access: the VM retrieves secrets it needs, cannot modify them
  secret_permissions = ["Get", "List"]
  key_permissions    = ["Get", "List"]
}

###############################################################################
# Key Vault Key – Disk Encryption CMK (RSA-4096)
#
# A Customer-Managed Key (CMK) used to encrypt the portfolio VM's OS disk.
# Using a CMK instead of the default Platform-Managed Key (PMK) gives the
# customer full control over the encryption key:
#   - Key is stored and protected in Azure Key Vault
#   - Key can be revoked instantly, rendering encrypted disks unreadable
#   - Key rotation is automated by the rotation policy below
#   - Every key operation is logged in Azure Monitor
#
# Key type RSA-4096:
#   4096-bit RSA provides strong asymmetric encryption suitable for
#   key-wrapping operations used in disk encryption (envelope encryption).
#
# Rotation policy:
#   expire_after         = "P1Y"   – Key expires after 1 year
#   time_before_expiry   = "P30D"  – Auto-rotate 30 days before expiry
#   notify_before_expiry = "P30D"  – Send notification 30 days before expiry
#   Azure automatically creates a new key version and updates the Disk
#   Encryption Set to use the new version without VM downtime.
###############################################################################
resource "azurerm_key_vault_key" "disk_encryption" {
  name         = "key-disk-${var.project_name}-${var.environment}"
  key_vault_id = azurerm_key_vault.main.id
  key_type     = "RSA"
  key_size     = 4096

  key_opts = [
    "decrypt",   # Decrypt data encrypted with this key
    "encrypt",   # Encrypt data with this key
    "sign",      # Create digital signatures
    "unwrapKey", # Unwrap (decrypt) a symmetric key
    "verify",    # Verify digital signatures
    "wrapKey",   # Wrap (encrypt) a symmetric key – used in disk encryption
  ]

  # Automatic key rotation policy
  rotation_policy {
    automatic {
      time_before_expiry = "P30D" # ISO 8601 duration: 30 days before expiry
    }
    expire_after         = "P1Y" # ISO 8601 duration: 1 year
    notify_before_expiry = "P30D"
  }

  tags = var.tags

  # Key creation requires the deployer access policy to be in place first
  depends_on = [azurerm_key_vault_access_policy.deployer]
}

###############################################################################
# Azure Disk Encryption Set (DES)
#
# A Disk Encryption Set is the Azure resource that links a Key Vault key to
# Azure Managed Disk encryption. When a VM's OS disk references a DES, Azure
# encrypts and decrypts the disk using the CMK in Key Vault.
#
# How it works (envelope encryption):
#   1. Azure generates a Data Encryption Key (DEK) per disk
#   2. The DEK is encrypted (wrapped) using the Key Vault CMK
#   3. The wrapped DEK is stored with the disk metadata
#   4. On disk access, Azure calls Key Vault to unwrap the DEK
#   5. The DEK decrypts the disk data in memory – the CMK never leaves Key Vault
#
# The Disk Encryption Set uses a System-Assigned Managed Identity to call
# Key Vault for WrapKey/UnwrapKey operations. This identity is automatically
# created by Azure when the DES is provisioned.
###############################################################################
resource "azurerm_disk_encryption_set" "main" {
  name                = "des-${var.project_name}-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group_name
  key_vault_key_id    = azurerm_key_vault_key.disk_encryption.id

  # System-assigned identity: Azure creates and manages this identity
  # specifically for the DES to call Key Vault. It has no permissions
  # until the access policy below grants them.
  identity {
    type = "SystemAssigned"
  }

  tags = var.tags
}

###############################################################################
# Key Vault Access Policy – Disk Encryption Set
#
# Grants the Disk Encryption Set's system-assigned identity the minimum
# permissions required to perform disk encryption operations:
#   Get       – Read the key metadata
#   WrapKey   – Encrypt (wrap) the disk's Data Encryption Key using the CMK
#   UnwrapKey – Decrypt (unwrap) the disk's Data Encryption Key for disk access
#
# This policy is created after the DES so that its system-assigned
# identity's principal_id is available.
###############################################################################
resource "azurerm_key_vault_access_policy" "disk_encryption_set" {
  key_vault_id = azurerm_key_vault.main.id
  tenant_id    = var.tenant_id
  object_id    = azurerm_disk_encryption_set.main.identity[0].principal_id

  key_permissions = ["Get", "WrapKey", "UnwrapKey"]

  depends_on = [azurerm_disk_encryption_set.main]
}
