variable "region" {
  description = "The AWS region to deploy resources in."
  type        = string
  default     = "us-east-1"
}

variable "glue_database_name" {
  type    = string
  default = "cur-glue-database"
}

variable "glue_table_name" {
  type    = string
  default = "cur-glue-table"
}

variable "glue_crawler_name" {
  type    = string
  default = "cur-glue-crawler"
}