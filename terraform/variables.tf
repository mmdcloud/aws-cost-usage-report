# -------------------------------------------------------------------------------
# Core
# -------------------------------------------------------------------------------
variable "region" {
  description = "AWS region to deploy all resources into."
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Deployment environment (dev / staging / prod)."
  type        = string
  default     = "prod"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "team_name" {
  description = "Owning team name — stamped onto every resource via default_tags."
  type        = string
  default     = "platform-engineering"
}

# -------------------------------------------------------------------------------
# Glue
# -------------------------------------------------------------------------------
variable "glue_database_name" {
  description = "Name of the Glue Catalog database that holds the CUR schema."
  type        = string
  default     = "cur-glue-database"

  validation {
    condition     = can(regex("^[a-z0-9_-]{1,255}$", var.glue_database_name))
    error_message = "glue_database_name must be lowercase alphanumeric, hyphens, or underscores (max 255 chars)."
  }
}

variable "glue_table_name" {
  description = "Name of the Glue table inside the CUR database."
  type        = string
  default     = "cur-glue-table"
}

variable "glue_crawler_name" {
  description = "Name of the Glue crawler that populates the CUR table."
  type        = string
  default     = "cur-glue-crawler"
}

# -------------------------------------------------------------------------------
# Budgets & Alerting
# -------------------------------------------------------------------------------
variable "monthly_budget_limit" {
  description = "Hard monthly budget ceiling in USD (used for overall account budget)."
  type        = string
  default     = "10000"

  validation {
    condition     = can(tonumber(var.monthly_budget_limit)) && tonumber(var.monthly_budget_limit) > 0
    error_message = "monthly_budget_limit must be a positive numeric string, e.g. \"10000\"."
  }
}

variable "ec2_monthly_budget_limit" {
  description = "Per-service monthly budget ceiling for EC2 in USD."
  type        = string
  default     = "5000"

  validation {
    condition     = can(tonumber(var.ec2_monthly_budget_limit)) && tonumber(var.ec2_monthly_budget_limit) > 0
    error_message = "ec2_monthly_budget_limit must be a positive numeric string."
  }
}

variable "alert_email" {
  description = "Email address that receives budget breach and cost anomaly notifications."
  type        = string

  validation {
    condition     = can(regex("^[^@]+@[^@]+\\.[^@]+$", var.alert_email))
    error_message = "alert_email must be a valid email address."
  }
}

variable "budget_time_period_start" {
  description = "ISO 8601 start date for the budget period (format: YYYY-MM-DD_HH:MM)."
  type        = string
  default     = "2025-01-01_00:00"
}

# -------------------------------------------------------------------------------
# KMS
# -------------------------------------------------------------------------------
variable "kms_deletion_window_days" {
  description = "Waiting period (days) before a scheduled KMS key deletion takes effect. Minimum 7, maximum 30."
  type        = number
  default     = 30

  validation {
    condition     = var.kms_deletion_window_days >= 7 && var.kms_deletion_window_days <= 30
    error_message = "kms_deletion_window_days must be between 7 and 30."
  }
}

# -------------------------------------------------------------------------------
# Athena
# -------------------------------------------------------------------------------
variable "athena_workgroup_name" {
  description = "Name of the Athena workgroup used for CUR queries."
  type        = string
  default     = "cost-analysis"
}

# -------------------------------------------------------------------------------
# CORS — allowed origins for the S3 cost-reports bucket
# -------------------------------------------------------------------------------
variable "cost_reports_cors_origins" {
  description = "List of allowed origins for the cost-reports S3 bucket CORS policy. Must be explicit origins, not wildcards."
  type        = list(string)

  validation {
    condition     = !contains(var.cost_reports_cors_origins, "*")
    error_message = "Wildcard '*' is not allowed in cost_reports_cors_origins. Specify explicit HTTPS origins."
  }
}