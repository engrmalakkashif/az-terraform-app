###############################################################################
# modules/security/outputs.tf
#
# Exposes the security resource identifiers and URIs needed by:
#   - The compute module (Managed Identity ID, Disk Encryption Set ID)
#   - The root module (Key Vault ID to store the SSH private key secret)
#   - Operators (Key Vault URI for application configuration)
###############################################################################

output "managed_identity_id" {
  description = <<-EOT
    Azure Resource ID of the User-Assigned Managed Identity.
    Passed to the compute module to attach the identity to the portfolio VM.
    Also used when assigning Azure RBAC roles to the identity:
      az role assignment create --assignee <value> --role "Storage Blob Data Reader" ...
  EOT
  value = azurerm_user_assigned_identity.portfolio.id
}

output "managed_identity_client_id" {
  description = <<-EOT
    Client ID (Application ID) of the User-Assigned Managed Identity.
    Used when explicitly targeting this identity in the Azure SDK:
      ManagedIdentityCredential(client_id="<value>")
    Not required when DefaultAzureCredential is used on a VM with a single UAMI.
  EOT
  value = azurerm_user_assigned_identity.portfolio.client_id
}

output "managed_identity_principal_id" {
  description = <<-EOT
    Principal (Object) ID of the User-Assigned Managed Identity in Azure AD.
    Used when creating Key Vault access policies or Azure RBAC assignments
    that target this Managed Identity by its Azure AD object ID.
  EOT
  value = azurerm_user_assigned_identity.portfolio.principal_id
}

output "key_vault_id" {
  description = <<-EOT
    Azure Resource ID of the Key Vault.
    Used in the root module to write the SSH private key secret:
      azurerm_key_vault_secret.ssh_private_key.key_vault_id = module.security.key_vault_id
  EOT
  value = azurerm_key_vault.main.id
}

output "key_vault_uri" {
  description = <<-EOT
    HTTPS vault URI for the Azure Key Vault.
    Format: https://<vault-name>.vault.azure.net/
    Set this as the AZURE_KEY_VAULT_URI environment variable in the portfolio
    application to enable secret retrieval using the Azure SDK with the VM's
    Managed Identity (no credentials required in the application code).
  EOT
  value = azurerm_key_vault.main.vault_uri
}

output "key_vault_name" {
  description = <<-EOT
    Name of the Azure Key Vault.
    Use in az CLI commands:
      az keyvault secret list --vault-name <value>
      az keyvault secret show --vault-name <value> --name portfolio-vm-ssh-private-key
  EOT
  value = azurerm_key_vault.main.name
}

output "disk_encryption_set_id" {
  description = <<-EOT
    Azure Resource ID of the Disk Encryption Set.
    Passed to the compute module and referenced in the VM's os_disk block:
      disk_encryption_set_id = module.security.disk_encryption_set_id
    This ensures the VM OS disk is encrypted using the Customer-Managed Key
    stored in Key Vault rather than the default platform-managed key.
  EOT
  value = azurerm_disk_encryption_set.main.id
}

output "disk_encryption_key_id" {
  description = <<-EOT
    Full versioned Key Vault Key ID of the disk encryption CMK.
    Format: https://<vault>.vault.azure.net/keys/<name>/<version>
    Useful for auditing which key version is currently in use.
  EOT
  value = azurerm_key_vault_key.disk_encryption.id
}
