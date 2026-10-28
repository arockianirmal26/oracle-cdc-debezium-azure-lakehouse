# All variables have defaults, so `terraform apply` works without a .tfvars file.
# Override on the command line if needed, e.g.  terraform apply -var location=westeurope

variable "location" {
  description = "Azure region for all resources"
  type        = string
  default     = "germanywestcentral"
}

# Separate region for the Databricks workspace: in germanywestcentral every
# 4-vCPU VM size is restricted for this subscription type
# (NotAvailableForSubscription), so classic cluster VMs can't start there.
# The notebook now runs on serverless compute, but changing the region would
# recreate the workspace. Event Hubs stays in var.location; the cross-region
# traffic is a handful of events.
variable "databricks_location" {
  description = "Azure region for the Databricks workspace and its cluster VMs"
  type        = string
  default     = "swedencentral"
}

variable "name" {
  description = "Base name used in all resource names"
  type        = string
  default     = "oracle-cdc"
}

variable "partition_count" {
  description = <<-EOT
    Partitions of the change-event hub. Events with the same key (= same table
    row) always land in the same partition, so per-row order is kept.
    Can't be changed later on the Standard tier, only by recreating the hub.
  EOT
  type        = number
  default     = 4
}

variable "message_retention_days" {
  description = "How long Event Hubs keeps events (Standard tier: max 7). Gives the Databricks consumer time to catch up after downtime."
  type        = number
  default     = 7
}
