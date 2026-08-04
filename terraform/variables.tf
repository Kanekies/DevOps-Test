variable "aws_region" {
  type    = string
  default = "eu-central-1"
}

variable "environment" {
  type    = string
  default = "cell-01"
}

variable "db_username" {
  type    = string
  default = "billing_admin"
}

variable "project" {
  type        = string
  description = "Project slug used as a name prefix"
  default     = "acme"
}

variable "tier" {
  type        = string
  description = "Commercial tier of the cell"
  default     = "enterprise"

  validation {
    condition     = contains(["standard", "enterprise", "regulated"], var.tier)
    error_message = "Choose the right tier!"
  }
}

variable "allowed_account_ids" {
  type        = list(string)
  description = "Refuse to run against any other account"
}

variable "owner" {
  type    = string
  default = "platform-team"
}

variable "data_classification" {
  type    = string
  default = "confidential"
}

variable "vpc_cidr" {
  type        = string
  description = "Address range for the cell VPC"
  default     = "10.100.0.0/16"
}

variable "az_count" {
  type        = number
  description = "How many availability zones this cell spans"
  default     = 3

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "az_count must be 2 or 3."
  }
}

variable "single_nat_gateway" {
  type        = bool
  description = "One shared NAT gateway"
  default     = false
}

variable "enable_interface_endpoints" {
  type        = bool
  description = "Cost/isolation trade-off"
  default     = true
}

variable "log_retention_days" {
  type        = number
  description = "How long VPC flow logs live in CloudWatch"
  default     = 365
}

variable "byok_key_arn" {
  type        = string
  description = "Customer-supplied KMS key. Empty - key is used."
  default     = ""
}

variable "github_repository" {
  type        = string
  description = "GitHub repository allowed to assume the deploy role, in owner/name form"
  default     = "Kanekies/DevOps-Test"
}

