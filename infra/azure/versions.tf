# Terraform and provider versions, pinned so `terraform init` gives the same
# result on every machine. The exact provider builds are recorded in
# .terraform.lock.hcl, which is committed on purpose.
terraform {
  required_version = ">= 1.6"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.50"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

# The subscription comes from the environment, not from code:
#   export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
# Authentication uses your `az login` session.
provider "azurerm" {
  features {}

  # Register only what this project needs instead of the provider's large
  # default set. A fresh subscription has none of these registered.
  # Databricks creates VMs, storage, a VNet and a managed identity in its own
  # managed resource group, so those providers are needed too.
  resource_provider_registrations = "none"
  resource_providers_to_register = [
    "Microsoft.EventHub",
    "Microsoft.Databricks",
    "Microsoft.Compute",
    "Microsoft.Storage",
    "Microsoft.Network",
    "Microsoft.ManagedIdentity",
  ]
}
