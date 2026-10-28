# Everything *inside* the Databricks workspace: secret scope, secret, notebook.
#
# Separate from infra/azure/ on purpose: the Databricks provider has to talk to
# a workspace that already exists, so infra/azure/ is applied first and this
# folder reads its outputs (workspace URL, Event Hubs connection string).
terraform {
  required_version = ">= 1.6"

  required_providers {
    databricks = {
      source  = "databricks/databricks"
      version = "~> 1.130"
    }
  }
}

# Outputs of infra/azure/, read straight from its local state file.
data "terraform_remote_state" "azure" {
  backend = "local"
  config = {
    path = "${path.module}/../azure/terraform.tfstate"
  }
}

# Authenticates with your `az login` session; no Databricks token needed.
provider "databricks" {
  host                        = data.terraform_remote_state.azure.outputs.databricks_workspace_url
  azure_workspace_resource_id = data.terraform_remote_state.azure.outputs.databricks_workspace_resource_id
  auth_type                   = "azure-cli"
}
