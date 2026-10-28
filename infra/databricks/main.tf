# Inside the workspace:
#
#   secret scope "oracle-cdc"
#   └── secret "eventhubs-connection-string"   listen-only key for the event hub
#   notebook ~/oracle-cdc/products_cdc         Bronze + Silver for SALES.PRODUCTS
#
# No cluster: the notebook runs on serverless compute. It starts in seconds,
# bills only while cells run, and doesn't use the subscription's VM quota.

# The user running Terraform (from `az login`); the notebook goes into their home folder.
data "databricks_current_user" "me" {}

# The notebook reads the Event Hubs key with dbutils.secrets.get(), so it never
# appears in code or in notebook output (Databricks redacts secret values).
resource "databricks_secret_scope" "this" {
  name = "oracle-cdc"
}

resource "databricks_secret" "eventhubs" {
  scope        = databricks_secret_scope.this.name
  key          = "eventhubs-connection-string"
  string_value = data.terraform_remote_state.azure.outputs.databricks_connection_string
}

# The notebook lives in the repo (databricks/) and is uploaded on every apply,
# so the workspace copy never drifts from Git. Edit it here, not in the UI.
resource "databricks_notebook" "products_cdc" {
  path     = "${data.databricks_current_user.me.home}/oracle-cdc/products_cdc"
  source   = "${path.module}/../../databricks/products_cdc.py"
  language = "PYTHON"
}
