# Azure Terraform Infrastructure – Complete Operations Guide

> **Project:** Portfolio Application on Azure  
> **Stack:** Terraform v1.5+ · Azure Provider v3.x · Ubuntu Linux  
> **Author:** Kashif Khan  
> **Last Updated:** 2026

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Install Azure CLI](#2-install-azure-cli)
3. [Configure Azure CLI – Login & Authentication](#3-configure-azure-cli--login--authentication)
4. [Install Terraform](#4-install-terraform)
5. [Project Structure Overview](#5-project-structure-overview)
6. [Bootstrap Remote State Storage](#6-bootstrap-remote-state-storage)
7. [Configure the Backend](#7-configure-the-backend)
8. [Terraform Workflow – Step by Step](#8-terraform-workflow--step-by-step)
9. [Verify the Deployment](#9-verify-the-deployment)
10. [Access the Portfolio Application](#10-access-the-portfolio-application)
11. [SSH into the VM](#11-ssh-into-the-vm)
12. [Retrieve the SSH Private Key from Key Vault](#12-retrieve-the-ssh-private-key-from-key-vault)
13. [Environment Management (dev / staging / prod)](#13-environment-management-dev--staging--prod)
14. [CI/CD Pipeline Setup (GitHub Actions)](#14-cicd-pipeline-setup-github-actions)
15. [Destroy Infrastructure](#15-destroy-infrastructure)
16. [Troubleshooting](#16-troubleshooting)
17. [Security Checklist](#17-security-checklist)
18. [Cost Estimation](#18-cost-estimation)
19. [AWS → Azure Quick Reference](#19-aws--azure-quick-reference)

---

## 1. Prerequisites

Before starting, make sure your Linux workstation has the following:

| Tool | Minimum Version | Check Command |
|---|---|---|
| Azure CLI | 2.55+ | `az --version` |
| Terraform | 1.5+ | `terraform -version` |
| Git | 2.x | `git --version` |
| curl | any | `curl --version` |
| unzip | any | `unzip -v` |

**Required Azure permissions:**  
Your account (or Service Principal) needs at minimum:
- `Contributor` on the target subscription
- `User Access Administrator` on the subscription (to assign roles to the Managed Identity)

---

## 2. Install Azure CLI

### Ubuntu / Debian (recommended – Microsoft repo)

```bash
# Step 1: Install dependencies
sudo apt-get update
sudo apt-get install -y ca-certificates curl apt-transport-https lsb-release gnupg

# Step 2: Add Microsoft signing key
sudo mkdir -p /etc/apt/keyrings
curl -sLS https://packages.microsoft.com/keys/microsoft.asc | \
  gpg --dearmor | \
  sudo tee /etc/apt/keyrings/microsoft.gpg > /dev/null
sudo chmod go+r /etc/apt/keyrings/microsoft.gpg

# Step 3: Add the Azure CLI repository
AZ_DIST=$(lsb_release -cs)
echo "Types: deb
URIs: https://packages.microsoft.com/repos/azure-cli/
Suites: ${AZ_DIST}
Components: main
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/microsoft.gpg" | \
sudo tee /etc/apt/sources.list.d/azure-cli.sources

# Step 4: Install
sudo apt-get update
sudo apt-get install -y azure-cli

# Step 5: Verify
az --version
```

Expected output:
```
azure-cli                         2.60.0
...
```

### Update Azure CLI (if already installed)

```bash
sudo apt-get update && sudo apt-get upgrade -y azure-cli
```

---

## 3. Configure Azure CLI – Login & Authentication

There are three authentication methods. Choose based on your situation.

---

### Method A: Interactive Login (local development)

Best for: developers working on their own machine.

```bash
# Opens browser for Microsoft login
az login

# If you have multiple subscriptions, list them
az account list --output table

# Set the subscription you want to deploy to
az account set --subscription "<SUBSCRIPTION_ID_OR_NAME>"

# Confirm the active subscription
az account show --output table
```

Expected output after `az login`:
```
[
  {
    "cloudName": "AzureCloud",
    "id": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
    "isDefault": true,
    "name": "My Azure Subscription",
    "state": "Enabled",
    "tenantId": "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy",
    "user": {
      "name": "you@example.com",
      "type": "user"
    }
  }
]
```

---

### Method B: Service Principal Login (CI/CD / automation)

Best for: GitHub Actions, Azure DevOps, Jenkins, or any headless environment.

#### Step 1 – Create a Service Principal

```bash
# Replace <SUBSCRIPTION_ID> with your actual subscription ID
az ad sp create-for-rbac \
  --name "sp-terraform-portfolio" \
  --role "Contributor" \
  --scopes "/subscriptions/<SUBSCRIPTION_ID>" \
  --sdk-auth
```

Save the JSON output – you will not see the password again:
```json
{
  "clientId":       "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "clientSecret":   "your-secret-value",
  "subscriptionId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "tenantId":       "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy"
}
```

#### Step 2 – Also grant User Access Administrator (needed for Managed Identity role assignments)

```bash
az role assignment create \
  --assignee "<clientId>" \
  --role "User Access Administrator" \
  --scope "/subscriptions/<SUBSCRIPTION_ID>"
```

#### Step 3 – Login with the Service Principal

```bash
az login \
  --service-principal \
  --username  "<clientId>" \
  --password  "<clientSecret>" \
  --tenant    "<tenantId>"
```

#### Step 4 – Export as environment variables (Terraform reads these automatically)

```bash
export ARM_CLIENT_ID="<clientId>"
export ARM_CLIENT_SECRET="<clientSecret>"
export ARM_SUBSCRIPTION_ID="<subscriptionId>"
export ARM_TENANT_ID="<tenantId>"
```

Add these to your `~/.bashrc` or `~/.zshrc` for persistence (never commit to git):

```bash
echo 'export ARM_CLIENT_ID="..."'       >> ~/.bashrc
echo 'export ARM_CLIENT_SECRET="..."'   >> ~/.bashrc
echo 'export ARM_SUBSCRIPTION_ID="..."' >> ~/.bashrc
echo 'export ARM_TENANT_ID="..."'       >> ~/.bashrc
source ~/.bashrc
```

---

### Method C: Device Code Login (no browser / SSH session)

Best for: remote servers without a browser.

```bash
az login --use-device-code
```

Follow the on-screen instructions:
```
To sign in, use a web browser to open https://microsoft.com/devicelogin
and enter the code XXXXXXXX to authenticate.
```

---

### Verify Your Login Is Working

```bash
# Show current account
az account show

# List resource groups (should return without error)
az group list --output table

# Get your current user's object ID (needed for Key Vault access policy)
az ad signed-in-user show --query id --output tsv
```

---

## 4. Install Terraform

### Ubuntu / Debian (HashiCorp repo – recommended)

```bash
# Step 1: Add HashiCorp GPG key and repository
wget -O- https://apt.releases.hashicorp.com/gpg | \
  gpg --dearmor | \
  sudo tee /usr/share/keyrings/hashicorp-archive-keyring.gpg > /dev/null

echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
  https://apt.releases.hashicorp.com $(lsb_release -cs) main" | \
  sudo tee /etc/apt/sources.list.d/hashicorp.list

# Step 2: Install
sudo apt-get update
sudo apt-get install -y terraform

# Step 3: Verify
terraform -version
```

Expected output:
```
Terraform v1.8.5
on linux_amd64
```

### Optional: Install tfenv (manage multiple Terraform versions)

```bash
git clone --depth=1 https://github.com/tfutils/tfenv.git ~/.tfenv
echo 'export PATH="$HOME/.tfenv/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc

# Install the exact version this project requires
tfenv install 1.8.5
tfenv use 1.8.5
terraform -version
```

---

## 5. Project Structure Overview

```
Azure-Terraform-Application/
│
├── main.tf               # Root module: resource group, SSH key, module calls
├── variables.tf          # All input variables with types, defaults, validation
├── outputs.tf            # All infrastructure outputs (IPs, IDs, URLs)
├── versions.tf           # Pinned provider versions + provider feature flags
├── terraform.tfvars      # Dev environment variable values
├── backend.conf          # Remote state backend config (NOT committed to git)
├── .gitignore            # Excludes state files, .terraform/, secrets
│
├── modules/
│   ├── networking/       # VNet, subnets, NSGs, NAT Gateway, route tables
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   │
│   ├── security/         # Key Vault, Managed Identity, Disk Encryption Set
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   │
│   └── compute/          # Public IP, NIC, Linux VM, Azure Monitor agent
│       ├── main.tf
│       ├── variables.tf
│       ├── outputs.tf
│       └── cloud-init.yaml   # Nginx install + portfolio page deployment
│
└── .github/
    └── workflows/
        └── terraform.yml     # GitHub Actions CI/CD pipeline
```

---

## 6. Bootstrap Remote State Storage

This step is done **once** before the first `terraform init`. It creates the Azure Storage Account that will hold your `.tfstate` file (equivalent to creating an S3 bucket for AWS backend).

```bash
# Variables – edit these to match your backend.conf
RG_NAME="rg-tfstate"
SA_NAME="stportfoliotfstate"   # must be globally unique, 3-24 chars, lowercase
CONTAINER="tfstate"
LOCATION="eastus"

# Step 1: Create the resource group for state
az group create \
  --name     "$RG_NAME" \
  --location "$LOCATION"

# Step 2: Create the storage account
az storage account create \
  --name                    "$SA_NAME" \
  --resource-group          "$RG_NAME" \
  --location                "$LOCATION" \
  --sku                     Standard_LRS \
  --kind                    StorageV2 \
  --https-only              true \
  --min-tls-version         TLS1_2 \
  --allow-blob-public-access false

# Step 3: Enable versioning (equivalent to S3 versioning for state history)
az storage account blob-service-properties update \
  --account-name  "$SA_NAME" \
  --resource-group "$RG_NAME" \
  --enable-versioning true

# Step 4: Create the blob container
az storage container create \
  --name           "$CONTAINER" \
  --account-name   "$SA_NAME" \
  --auth-mode      login

# Step 5: Verify
az storage container list \
  --account-name "$SA_NAME" \
  --auth-mode    login \
  --output       table
```

Expected output:
```
Name      Lease Status    Last Modified
--------  --------------  -------------------------
tfstate   unlocked        2026-01-01T00:00:00+00:00
```

---

## 7. Configure the Backend

The `backend.conf` file (already created, excluded from git) tells Terraform where to store state:

```hcl
# backend.conf
resource_group_name  = "rg-tfstate"
storage_account_name = "stportfoliotfstate"
container_name       = "tfstate"
key                  = "portfolio/dev/terraform.tfstate"
```

If you need a different key per environment:
- Dev:     `portfolio/dev/terraform.tfstate`
- Staging: `portfolio/staging/terraform.tfstate`
- Prod:    `portfolio/prod/terraform.tfstate`

---

## 8. Terraform Workflow – Step by Step

Navigate to the project root before running any commands:

```bash
cd ~/Documents/Learning/Azure-Terraform-Application
```

---

### Step 1: terraform init

Downloads providers, sets up the backend, initialises modules.

```bash
terraform init -backend-config=backend.conf
```

Expected output:
```
Initializing the backend...
Successfully configured the backend "azurerm"!

Initializing modules...
- networking in modules/networking
- security in modules/security
- compute in modules/compute

Initializing provider plugins...
- Finding hashicorp/azurerm versions matching "~> 3.100"...
- Installing hashicorp/azurerm v3.105.0...

Terraform has been successfully initialized!
```

Re-run init whenever you:
- Add or remove a module
- Change provider versions
- Change backend configuration

---

### Step 2: terraform fmt

Formats all `.tf` files to the canonical style. Always run before committing.

```bash
# Format everything recursively
terraform fmt -recursive

# Check only (used in CI – exits non-zero if formatting needed)
terraform fmt -check -recursive
```

---

### Step 3: terraform validate

Checks syntax and internal consistency without calling Azure APIs.

```bash
terraform validate
```

Expected output:
```
Success! The configuration is valid.
```

---

### Step 4: terraform plan

Shows exactly what will be created, changed, or destroyed. No real changes are made.

```bash
terraform plan -var-file=terraform.tfvars
```

To save the plan for use in apply (recommended for CI/CD):

```bash
terraform plan \
  -var-file=terraform.tfvars \
  -out=tfplan
```

Read the plan output carefully:
- `+` green = resource will be **created**
- `~` yellow = resource will be **updated in place**
- `-/+` red = resource will be **destroyed and recreated** (watch for this)
- `-` red = resource will be **destroyed**

---

### Step 5: terraform apply

Applies the planned changes and creates the infrastructure.

```bash
# Apply with a saved plan (recommended)
terraform apply tfplan

# Or apply interactively (will show plan + prompt for yes/no)
terraform apply -var-file=terraform.tfvars
```

Type `yes` when prompted:
```
Do you want to perform these actions?
  Terraform will perform the actions described above.
  Only 'yes' will be accepted to approve.

  Enter a value: yes
```

Typical apply time: **4–8 minutes** for this infrastructure.

Expected final output:
```
Apply complete! Resources: 28 added, 0 changed, 0 destroyed.

Outputs:

connection_summary = {
  "environment"        = "dev"
  "key_vault_uri"      = "https://kv-portfolio-abc123.vault.azure.net/"
  "portfolio_fqdn_url" = "http://portfolio-dev.eastus.cloudapp.azure.com"
  "portfolio_url"      = "http://20.x.x.x"
  "region"             = "eastus"
  "ssh_access"         = "ssh -i <key> azureuser@20.x.x.x"
}
portfolio_public_ip   = "20.x.x.x"
portfolio_public_fqdn = "portfolio-dev.eastus.cloudapp.azure.com"
```

---

### Step 6: terraform output

Print outputs at any time after a successful apply:

```bash
# All outputs
terraform output

# Single output
terraform output portfolio_public_ip

# Output as JSON (useful for scripting)
terraform output -json
```

---

### Step 7: terraform show

Inspect the current state in a human-readable format:

```bash
terraform show
```

---

### Step 8: terraform state

Inspect individual resources in state:

```bash
# List all resources managed by Terraform
terraform state list

# Show a specific resource
terraform state show module.networking.azurerm_virtual_network.main

# Show the VM
terraform state show module.compute.azurerm_linux_virtual_machine.portfolio
```

---

## 9. Verify the Deployment

After apply completes, verify each layer:

### Verify Resource Group

```bash
az group show --name rg-portfolio-dev --output table
```

### Verify VNet and Subnets

```bash
az network vnet list \
  --resource-group rg-portfolio-dev \
  --output table

az network vnet subnet list \
  --resource-group rg-portfolio-dev \
  --vnet-name vnet-portfolio-dev \
  --output table
```

### Verify NSG Rules

```bash
az network nsg rule list \
  --resource-group rg-portfolio-dev \
  --nsg-name nsg-public-portfolio-dev \
  --output table
```

### Verify NAT Gateway

```bash
az network nat gateway show \
  --resource-group rg-portfolio-dev \
  --name natgw-portfolio-dev \
  --output table
```

### Verify VM Is Running

```bash
az vm show \
  --resource-group rg-portfolio-dev \
  --name vm-portfolio-dev \
  --show-details \
  --output table
```

### Verify Key Vault

```bash
az keyvault show \
  --name kv-portfolio-<suffix> \
  --resource-group rg-portfolio-dev \
  --output table
```

---

## 10. Access the Portfolio Application

Once the VM has fully booted (~2 minutes after apply), open a browser:

```
http://<portfolio_public_ip>
```

Or using the FQDN:
```
http://portfolio-dev.eastus.cloudapp.azure.com
```

Get the URL directly from Terraform:

```bash
echo "http://$(terraform output -raw portfolio_public_ip)"
echo "http://$(terraform output -raw portfolio_public_fqdn)"
```

You should see the portfolio landing page with Azure/Terraform deployment info.

### Test with curl

```bash
PUBLIC_IP=$(terraform output -raw portfolio_public_ip)
curl -I http://$PUBLIC_IP
```

Expected response:
```
HTTP/1.1 200 OK
Server: nginx
Content-Type: text/html
X-Frame-Options: SAMEORIGIN
X-Content-Type-Options: nosniff
```

---

## 11. SSH into the VM

The SSH private key is stored in Azure Key Vault. Here is how to retrieve it and connect.

### Quick SSH (if you still have the Terraform state locally)

```bash
# Export the private key from Terraform state
terraform output -raw ssh_private_key 2>/dev/null || echo "Key is in Key Vault"

# Get the public IP
PUBLIC_IP=$(terraform output -raw portfolio_public_ip)
echo "VM Public IP: $PUBLIC_IP"
```

### SSH with the key retrieved from Key Vault (see Section 12)

```bash
# After saving the key to a file:
chmod 600 ~/.ssh/portfolio-dev.pem
ssh -i ~/.ssh/portfolio-dev.pem azureuser@$PUBLIC_IP
```

### Check VM boot log (cloud-init)

```bash
# After SSH-ing in:
sudo cat /var/log/cloud-init-output.log
sudo cat /var/log/cloud-init-portfolio.log

# Check Nginx status
sudo systemctl status nginx

# View Nginx access log
sudo tail -f /var/log/nginx/access.log
```

---

## 12. Retrieve the SSH Private Key from Key Vault

The private key was generated by Terraform and stored as a Key Vault secret.

```bash
# Step 1: Get the Key Vault name
KV_NAME=$(terraform output -raw key_vault_name 2>/dev/null)
# or look it up:
az keyvault list --resource-group rg-portfolio-dev --query "[].name" --output tsv

# Step 2: Retrieve the secret
az keyvault secret show \
  --vault-name "$KV_NAME" \
  --name "portfolio-vm-ssh-private-key" \
  --query "value" \
  --output tsv > ~/.ssh/portfolio-dev.pem

# Step 3: Set correct permissions
chmod 600 ~/.ssh/portfolio-dev.pem

# Step 4: Connect
PUBLIC_IP=$(terraform output -raw portfolio_public_ip)
ssh -i ~/.ssh/portfolio-dev.pem azureuser@$PUBLIC_IP
```

---

## 13. Environment Management (dev / staging / prod)

The project is designed for multiple environments using separate `.tfvars` files and separate state keys.

### Create a staging environment

```bash
# Step 1: Copy and edit tfvars
cp terraform.tfvars environments/staging.tfvars
# Edit environments/staging.tfvars:
#   environment = "staging"
#   vm_size     = "Standard_B2ms"
#   allowed_ssh_cidr = "YOUR_OFFICE_IP/32"

# Step 2: Create a separate backend config for staging
cat > environments/backend-staging.conf << 'EOF'
resource_group_name  = "rg-tfstate"
storage_account_name = "stportfoliotfstate"
container_name       = "tfstate"
key                  = "portfolio/staging/terraform.tfstate"
EOF

# Step 3: Init with staging backend
terraform init \
  -reconfigure \
  -backend-config=environments/backend-staging.conf

# Step 4: Plan for staging
terraform plan -var-file=environments/staging.tfvars

# Step 5: Apply
terraform apply -var-file=environments/staging.tfvars
```

### Switch back to dev

```bash
terraform init \
  -reconfigure \
  -backend-config=backend.conf
```

---

## 14. CI/CD Pipeline Setup (GitHub Actions)

The pipeline at `.github/workflows/terraform.yml` runs automatically.

### Step 1: Add GitHub Secrets

Go to your repository → **Settings** → **Secrets and variables** → **Actions** → **New repository secret**

Add these four secrets:

| Secret Name | Value |
|---|---|
| `ARM_CLIENT_ID` | Service Principal client ID |
| `ARM_CLIENT_SECRET` | Service Principal client secret |
| `ARM_SUBSCRIPTION_ID` | Your Azure subscription ID |
| `ARM_TENANT_ID` | Your Azure tenant ID |

### Step 2: Set up GitHub Environment (for apply approval gate)

Go to **Settings** → **Environments** → **New environment** → name it `production`

Add a **Required reviewer** – this creates a manual approval step before `apply` runs.

### Step 3: Add backend.conf as a secret (optional)

Since `backend.conf` is gitignored, you can either:

**Option A:** Hardcode backend values directly in the workflow file (safe since they're not secrets):

```yaml
- name: Terraform Init
  run: |
    terraform init \
      -backend-config="resource_group_name=rg-tfstate" \
      -backend-config="storage_account_name=stportfoliotfstate" \
      -backend-config="container_name=tfstate" \
      -backend-config="key=portfolio/dev/terraform.tfstate"
```

**Option B:** Store `backend.conf` content as a GitHub secret and write it to a file in the pipeline.

### Pipeline Behaviour

| Trigger | Jobs That Run |
|---|---|
| Pull Request opened/updated | `validate` → `plan` (plan posted as PR comment) |
| Merge to `main` | `validate` → `apply` (with approval gate) |

---

## 15. Destroy Infrastructure

**WARNING:** This permanently deletes all resources. There is no undo. Take a `terraform plan -destroy` first.

```bash
# Step 1: Preview what will be destroyed
terraform plan \
  -destroy \
  -var-file=terraform.tfvars

# Step 2: Destroy (prompts for confirmation)
terraform destroy -var-file=terraform.tfvars

# Step 3: Confirm by typing 'yes'
```

To destroy without the interactive prompt (CI/CD only):

```bash
terraform destroy -var-file=terraform.tfvars -auto-approve
```

### Destroy a specific resource only

```bash
# Example: destroy only the VM (keeps networking intact)
terraform destroy \
  -target=module.compute.azurerm_linux_virtual_machine.portfolio \
  -var-file=terraform.tfvars
```

---

## 16. Troubleshooting

### Error: "Provider produced inconsistent result"

```bash
# Re-initialize and upgrade providers
terraform init -upgrade
```

### Error: "Error acquiring the state lock"

Another process holds the lock (or a previous run crashed).

```bash
# Check who holds the lock
terraform force-unlock <LOCK_ID>
# The LOCK_ID is shown in the error message.
```

### Error: "InvalidTemplateDeployment – Key Vault name already exists"

Key Vault names are globally unique and soft-deleted vaults hold the name for 30 days.

```bash
# List soft-deleted Key Vaults
az keyvault list-deleted --output table

# Purge it to release the name
az keyvault purge --name kv-portfolio-<suffix> --location eastus
```

### Error: "AuthorizationFailed"

Your account lacks the required role.

```bash
# Check your current role assignments
az role assignment list --assignee $(az ad signed-in-user show --query id -o tsv) \
  --output table

# Add Contributor role if missing
az role assignment create \
  --assignee $(az ad signed-in-user show --query id -o tsv) \
  --role "Contributor" \
  --scope "/subscriptions/<SUBSCRIPTION_ID>"
```

### Error: "The subscription is not registered to use namespace Microsoft.KeyVault"

```bash
az provider register --namespace Microsoft.KeyVault
az provider register --namespace Microsoft.Compute
az provider register --namespace Microsoft.Network

# Wait for registration (check status)
az provider show --namespace Microsoft.KeyVault --query registrationState
```

### VM is not showing portfolio page

```bash
# 1. Check if Nginx is running
ssh -i ~/.ssh/portfolio-dev.pem azureuser@<PUBLIC_IP> "sudo systemctl status nginx"

# 2. Check cloud-init completed successfully
ssh -i ~/.ssh/portfolio-dev.pem azureuser@<PUBLIC_IP> "sudo cat /var/log/cloud-init-output.log | tail -30"

# 3. Check NSG allows port 80
az network nsg rule list \
  --resource-group rg-portfolio-dev \
  --nsg-name nsg-public-portfolio-dev \
  --output table

# 4. Check public IP assignment
az network public-ip show \
  --resource-group rg-portfolio-dev \
  --name pip-portfolio-dev \
  --query ipAddress \
  --output tsv
```

### Terraform state drift (Azure resource changed outside Terraform)

```bash
# Refresh state to match real Azure resources
terraform refresh -var-file=terraform.tfvars

# Then plan to see what Terraform wants to reconcile
terraform plan -var-file=terraform.tfvars
```

### Enable Terraform debug logging

```bash
export TF_LOG=DEBUG
export TF_LOG_PATH=./terraform-debug.log
terraform apply -var-file=terraform.tfvars
# Review ./terraform-debug.log
unset TF_LOG
```

---

## 17. Security Checklist

Run through this before deploying to staging or production.

- [ ] `allowed_ssh_cidr` is set to your specific IP, not `0.0.0.0/0`
- [ ] `backend.conf` is in `.gitignore` and not committed
- [ ] `terraform.tfstate` is not committed (managed by remote backend)
- [ ] SSH private key file has `chmod 600` permissions
- [ ] Service Principal secret is stored in GitHub Secrets, not in code
- [ ] Key Vault purge protection is `true` (already set in code)
- [ ] VM password authentication is disabled (already set in code)
- [ ] OS disk is encrypted with CMK (already set in code)
- [ ] NSG has explicit `Deny-All` rule at priority 4000 (already set)
- [ ] Azure Monitor agent installed on VM (already set in code)
- [ ] `fail2ban` is running on the VM (installed via cloud-init)
- [ ] Terraform provider versions are pinned with `~>` constraints
- [ ] No secrets in `terraform.tfvars` (secrets go in Key Vault)

---

## 18. Cost Estimation

Approximate monthly cost for the **dev** environment in East US:

| Resource | SKU | Est. Monthly Cost (USD) |
|---|---|---|
| Linux VM | Standard_B2s (2 vCPU, 4 GB) | ~$30 |
| OS Disk | Premium_LRS 30 GB | ~$5 |
| Public IP | Static Standard | ~$4 |
| NAT Gateway | Standard + data processed | ~$35 + $0.045/GB |
| Key Vault | Standard – operations | ~$0–2 |
| Storage (state) | Standard_LRS | ~$0.02 |
| **Total (est.)** | | **~$75–80/month** |

**Cost optimisation tips:**
- Stop the VM when not in use: `az vm deallocate -g rg-portfolio-dev -n vm-portfolio-dev`
- Start it again: `az vm start -g rg-portfolio-dev -n vm-portfolio-dev`
- NAT Gateway is the biggest cost – consider removing it in dev if private subnet egress is not needed (`enable_nat_gateway = false`)

---

## 19. AWS → Azure Quick Reference

| AWS Concept | Azure Equivalent | This Project |
|---|---|---|
| VPC | Virtual Network (VNet) | `vnet-portfolio-dev` |
| Internet Gateway | System route (automatic) | Built-in |
| Public Subnet | Subnet (public) | `snet-public-portfolio-dev` |
| Private Subnet | Subnet (private) | `snet-private-portfolio-dev` |
| Security Group | Network Security Group (NSG) | `nsg-public/private-portfolio-dev` |
| NAT Gateway | Azure NAT Gateway | `natgw-portfolio-dev` |
| Elastic IP | Static Public IP | `pip-portfolio-dev` |
| Route Table | User-Defined Route (UDR) | `rt-public/private-portfolio-dev` |
| EC2 | Linux Virtual Machine | `vm-portfolio-dev` |
| EC2 Key Pair | SSH key in Key Vault | `portfolio-vm-ssh-private-key` |
| EC2 User Data | cloud-init (`custom_data`) | `cloud-init.yaml` |
| IAM Role | Managed Identity (UAMI) | `id-portfolio-dev` |
| IAM Instance Profile | `identity {}` block on VM | Attached to VM |
| Secrets Manager + KMS | Azure Key Vault | `kv-portfolio-<suffix>` |
| EBS Encryption (CMK) | Disk Encryption Set | `des-portfolio-dev` |
| S3 Backend | Azure Blob Storage | `stportfoliotfstate/tfstate` |
| DynamoDB Lock | Blob lease (built-in) | Automatic |
| CloudWatch Agent | Azure Monitor Agent (extension) | Installed on VM |
| SSM Session Manager | Azure Bastion / Az Serial Console | (optional, not deployed) |
| us-east-1 | East US | `eastus` |
| Availability Zone | Availability Zone 1 | `zones = ["1"]` |

---

*End of Guide*
