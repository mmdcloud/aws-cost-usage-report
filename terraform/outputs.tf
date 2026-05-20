# -------------------------------------------------------------------------------
# S3
# -------------------------------------------------------------------------------
output "cost_reports_bucket_name" {
  description = "Name of the S3 bucket storing CUR Parquet files."
  value       = module.cost_reports.bucket
}

output "cost_reports_bucket_arn" {
  description = "ARN of the CUR S3 bucket (used for IAM / bucket policy references)."
  value       = module.cost_reports.arn
}

output "athena_results_bucket_name" {
  description = "Name of the S3 bucket where Athena query results are written."
  value       = module.athena_query_results.bucket
}

# -------------------------------------------------------------------------------
# Athena
# -------------------------------------------------------------------------------
output "athena_workgroup_name" {
  description = "Name of the Athena workgroup for CUR queries."
  value       = aws_athena_workgroup.cost_analysis.name
}

output "athena_workgroup_arn" {
  description = "ARN of the Athena workgroup."
  value       = aws_athena_workgroup.cost_analysis.arn
}

# -------------------------------------------------------------------------------
# Glue
# -------------------------------------------------------------------------------
output "glue_database_name" {
  description = "Name of the Glue Catalog database containing the CUR schema."
  value       = aws_glue_catalog_database.database.name
}

output "glue_crawler_name" {
  description = "Name of the Glue crawler that populates the CUR table."
  value       = aws_glue_crawler.crawler.name
}

# -------------------------------------------------------------------------------
# SNS
# -------------------------------------------------------------------------------
output "cost_alerts_topic_arn" {
  description = "ARN of the SNS topic that receives cost anomaly and budget breach alerts."
  value       = aws_sns_topic.cost_alerts.arn
}

# -------------------------------------------------------------------------------
# DynamoDB
# -------------------------------------------------------------------------------
output "cost_recommendations_table_name" {
  description = "DynamoDB table name for storing cost optimisation recommendations."
  value       = aws_dynamodb_table.cost_recommendations.name
}

output "cost_anomalies_table_name" {
  description = "DynamoDB table name for storing detected cost anomalies."
  value       = aws_dynamodb_table.cost_anomalies.name
}

# -------------------------------------------------------------------------------
# KMS Key ARNs (useful for cross-stack / cross-account references)
# -------------------------------------------------------------------------------
output "kms_s3_key_arn" {
  description = "ARN of the KMS key used to encrypt S3 buckets."
  value       = aws_kms_key.s3_encryption.arn
}

output "kms_sns_key_arn" {
  description = "ARN of the KMS key used to encrypt the SNS topic."
  value       = aws_kms_key.sns_encryption.arn
}

output "kms_dynamodb_key_arn" {
  description = "ARN of the KMS key used to encrypt DynamoDB tables."
  value       = aws_kms_key.dynamodb_encryption.arn
}

# -------------------------------------------------------------------------------
# Lambda ARNs
# -------------------------------------------------------------------------------
output "cost_analyzer_lambda_arn" {
  description = "ARN of the daily cost analyzer Lambda function."
  value       = aws_lambda_function.cost_analyzer.arn
}

output "tag_compliance_lambda_arn" {
  description = "ARN of the weekly tag compliance checker Lambda function."
  value       = aws_lambda_function.tag_compliance_checker.arn
}

output "slack_notifier_lambda_arn" {
  description = "ARN of the Slack notification Lambda function."
  value       = aws_lambda_function.slack_notifier.arn
}

# -------------------------------------------------------------------------------
# IAM Role ARNs
# -------------------------------------------------------------------------------
output "glue_crawler_role_arn" {
  description = "ARN of the Glue crawler IAM role."
  value       = aws_iam_role.glue_crawler_role.arn
}

output "athena_role_arn" {
  description = "ARN of the Athena execution IAM role."
  value       = aws_iam_role.athena_role.arn
}

output "lambda_exec_role_arn" {
  description = "ARN of the shared Lambda execution IAM role."
  value       = aws_iam_role.lambda_exec.arn
}