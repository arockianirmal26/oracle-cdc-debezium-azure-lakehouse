output "resource_group" {
  value = azurerm_resource_group.this.name
}

output "eventhub_namespace" {
  value = azurerm_eventhub_namespace.this.name
}

output "eventhub_name" {
  value = azurerm_eventhub.changes.name
}

# Kafka bootstrap server for Databricks (Event Hubs' Kafka endpoint listens on 9093)
output "kafka_bootstrap_server" {
  value = "${azurerm_eventhub_namespace.this.name}.servicebus.windows.net:9093"
}

# Read by infra/databricks/ to configure the Databricks provider.
output "databricks_workspace_url" {
  value = "https://${azurerm_databricks_workspace.this.workspace_url}"
}

output "databricks_workspace_resource_id" {
  value = azurerm_databricks_workspace.this.id
}

# Connection strings are secrets: Terraform hides them in plan/apply output.
# Read one deliberately with:  terraform output -raw debezium_connection_string

# Debezium Server takes the hub name as a separate setting, so this string is
# built without the EntityPath=... part that the hub-level rule would add.
output "debezium_connection_string" {
  sensitive = true
  value = join(";", [
    "Endpoint=sb://${azurerm_eventhub_namespace.this.name}.servicebus.windows.net/",
    "SharedAccessKeyName=${azurerm_eventhub_authorization_rule.debezium.name}",
    "SharedAccessKey=${azurerm_eventhub_authorization_rule.debezium.primary_key}",
  ])
}

# For Databricks' Kafka source the full hub-level string (with EntityPath) is
# used as the SASL password.
output "databricks_connection_string" {
  sensitive = true
  value     = azurerm_eventhub_authorization_rule.databricks.primary_connection_string
}
