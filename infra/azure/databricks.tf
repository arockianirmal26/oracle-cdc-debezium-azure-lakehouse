# Azure Databricks workspace (the Azure-level resource only).
#
# What runs *inside* the workspace (secret, notebook) is defined in
# infra/databricks/, because the Databricks provider needs this workspace to
# exist before it can plan anything.
#
# SKU "premium": needed for Unity Catalog tables and serverless compute. (The
# free "trial" SKU is rejected on Azure Free Trial subscriptions.) The
# workspace itself costs nothing; serverless compute is billed only while
# notebook cells run.
# Azure also creates a second, managed resource group for the workspace's own
# storage, network and cluster VMs; `terraform destroy` removes it as well.
#
# Both names carry the random suffix: after a workspace is deleted, Azure keeps
# its name bound to the old region for a while (409 InvalidResourceLocation),
# and its managed resource group is deleted in the background.
resource "azurerm_databricks_workspace" "this" {
  name                        = "dbw-${var.name}-${random_string.suffix.result}"
  resource_group_name         = azurerm_resource_group.this.name
  location                    = var.databricks_location
  sku                         = "premium"
  managed_resource_group_name = "rg-${var.name}-dbw-${random_string.suffix.result}-managed"
  tags                        = local.tags
}
