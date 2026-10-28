# Azure side of the CDC pipeline:
#
#   resource group
#   └── Event Hubs namespace (Standard, 1 throughput unit)
#       └── event hub "oracle-changes"  ← all captured tables, partitioned by primary key
#           ├── auth rule "debezium-send"     (send only)   → used by Debezium Server
#           ├── auth rule "databricks-listen" (listen only) → used by Databricks
#           └── consumer group "databricks"
#   └── Databricks workspace (see databricks.tf)
#
# One hub for all tables instead of one per table: a Standard namespace allows
# only 10 event hubs, and each event carries its schema/table in the payload anyway.

locals {
  tags = {
    project = var.name
    purpose = "oracle-cdc"
  }
}

resource "azurerm_resource_group" "this" {
  name     = "rg-${var.name}"
  location = var.location
  tags     = local.tags
}

# Namespace names are global DNS names (<name>.servicebus.windows.net),
# so a random suffix avoids collisions.
resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

# Standard, not Basic: Basic has no Kafka endpoint, so Databricks couldn't use
# its built-in Kafka source. 1 throughput unit = 1 MB/s in, 2 MB/s out, far more
# than this setup needs.
resource "azurerm_eventhub_namespace" "this" {
  name                = "evhns-${var.name}-${random_string.suffix.result}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "Standard"
  capacity            = 1
  minimum_tls_version = "1.2"
  tags                = local.tags
}

resource "azurerm_eventhub" "changes" {
  name              = "oracle-changes"
  namespace_id      = azurerm_eventhub_namespace.this.id
  partition_count   = var.partition_count
  message_retention = var.message_retention_days
}

# Separate least-privilege keys per side: if the Debezium key leaks, it can't
# read data; if the Databricks key leaks, it can't inject fake changes.
resource "azurerm_eventhub_authorization_rule" "debezium" {
  name                = "debezium-send"
  namespace_name      = azurerm_eventhub_namespace.this.name
  eventhub_name       = azurerm_eventhub.changes.name
  resource_group_name = azurerm_resource_group.this.name
  send                = true
  listen              = false
  manage              = false
}

resource "azurerm_eventhub_authorization_rule" "databricks" {
  name                = "databricks-listen"
  namespace_name      = azurerm_eventhub_namespace.this.name
  eventhub_name       = azurerm_eventhub.changes.name
  resource_group_name = azurerm_resource_group.this.name
  send                = false
  listen              = true
  manage              = false
}

# Own consumer group, so the Databricks stream tracks its position independently
# of anyone else reading the hub (e.g. ad-hoc inspection with $Default).
resource "azurerm_eventhub_consumer_group" "databricks" {
  name                = "databricks"
  namespace_name      = azurerm_eventhub_namespace.this.name
  eventhub_name       = azurerm_eventhub.changes.name
  resource_group_name = azurerm_resource_group.this.name
}
