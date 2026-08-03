locals {
  name_prefix = "${var.project}-${var.environment}"

  common_tags = {
    Project   = var.project
    Cell      = var.environment
    Tier      = var.tier
    Owner     = var.owner
    ManagedBy = "terraform"
    DataClass = var.data_classification
  }
}
