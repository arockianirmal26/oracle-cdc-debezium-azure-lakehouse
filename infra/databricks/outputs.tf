output "workspace_url" {
  value = data.terraform_remote_state.azure.outputs.databricks_workspace_url
}

output "secret_scope" {
  value = databricks_secret_scope.this.name
}

output "notebook_url" {
  value = databricks_notebook.products_cdc.url
}
