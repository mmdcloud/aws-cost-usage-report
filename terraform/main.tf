# -------------------------------------------------------------------------------
# Data Sources
# -------------------------------------------------------------------------------
data "aws_caller_identity" "current" {}

# -------------------------------------------------------------------------------
# S3 Bucket for Cost Reports
# -------------------------------------------------------------------------------
module "cost_reports" {
  source             = "./modules/s3"
  bucket_name        = "cost-reports-${data.aws_caller_identity.current.account_id}"
  objects            = []
  versioning_enabled = "Enabled"
  cors = [
    {
      allowed_headers = ["*"]
      allowed_methods = ["GET"]
      allowed_origins = ["*"]
      max_age_seconds = 3000
    },
    {
      allowed_headers = ["*"]
      allowed_methods = ["PUT"]
      allowed_origins = ["*"]
      max_age_seconds = 3000
    }
  ]
  bucket_policy = jsonencode({
    "Version" : "2012-10-17",
    "Id" : "PolicyForBillingReports",
    "Statement" : [
      {
        "Sid" : "AllowBillingReportsServiceGetObject",
        "Effect" : "Allow",
        "Principal" : {
          "Service" : "billingreports.amazonaws.com"
        },
        "Action" : [
          "s3:GetBucketAcl",
          "s3:GetBucketPolicy"
        ],
        "Resource" : "${module.cost_reports.arn}"
      },
      {
        "Sid" : "AllowBillingReportsServicePutObject",
        "Effect" : "Allow",
        "Principal" : {
          "Service" : "billingreports.amazonaws.com"
        },
        "Action" : [
          "s3:PutObject"
        ],
        "Resource" : "${module.cost_reports.arn}/*"
      }
    ]
  })
  force_destroy = true
}

resource "aws_s3_bucket_lifecycle_configuration" "cost_reports_lifecycle" {
  bucket = module.cost_reports.bucket
  rule {
    id     = "archive-old-reports"
    status = "Enabled"
    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }
    transition {
      days          = 90
      storage_class = "GLACIER"
    }
    expiration {
      days = 365
    }
  }
}

# -------------------------------------------------------------------------------
# S3 bucket for Athena Query Results
# -------------------------------------------------------------------------------
module "athena_query_results" {
  source        = "./modules/s3"
  bucket_name   = "athena-query-results-${data.aws_caller_identity.current.account_id}"
  objects       = []
  bucket_policy = ""
  cors = [
    {
      allowed_headers = ["*"]
      allowed_methods = ["GET"]
      allowed_origins = ["*"]
      max_age_seconds = 3000
    }
  ]
  versioning_enabled = "Enabled"
  force_destroy      = true
}

resource "aws_s3_bucket_lifecycle_configuration" "athena_results_lifecycle" {
  bucket = module.athena_query_results.bucket
  rule {
    id     = "cleanup-old-query-results"
    status = "Enabled"
    expiration {
      days = 30
    }
  }
}


# -----------------------------------------------------------------------------------------
# Glue Configuration
# -----------------------------------------------------------------------------------------
resource "aws_iam_role" "glue_crawler_role" {
  name = "glue-crawler-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "glue.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "glue_service_policy" {
  role       = aws_iam_role.glue_crawler_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

resource "aws_iam_role_policy" "s3_access_policy" {
  role = aws_iam_role.glue_crawler_role.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ],
        Resource = [
          "${module.cost_reports.arn}",
          "${module.cost_reports.arn}/*"
        ]
      }
    ]
  })
}

resource "aws_glue_catalog_database" "database" {
  name        = var.glue_database_name
  description = var.glue_database_name
}

resource "aws_glue_crawler" "crawler" {
  database_name = aws_glue_catalog_database.database.name
  name          = var.glue_crawler_name
  role          = aws_iam_role.glue_crawler_role.arn
  schedule      = "cron(0 1 * * ? *)"
  schema_change_policy {
    delete_behavior = "LOG"
    update_behavior = "UPDATE_IN_DATABASE"
  }
  s3_target {
    path = "s3://${module.cost_reports.bucket}/reports"
  }
  configuration = jsonencode({
    Version = 1.0
    CrawlerOutput = {
      Partitions = { AddOrUpdateBehavior = "InheritFromTable" }
    }
  })
}

# -------------------------------------------------------------------------------
# Cost and Usage Report Definition
# -------------------------------------------------------------------------------
resource "aws_cur_report_definition" "cost_usage_report" {
  report_name                = "daily-cost-usage-report"
  time_unit                  = "DAILY"
  format                     = "Parquet"
  compression                = "Parquet"
  additional_schema_elements = ["RESOURCES"]
  s3_bucket                  = module.cost_reports.bucket
  s3_prefix                  = "reports"
  s3_region                  = var.region
  additional_artifacts       = ["ATHENA"]
  refresh_closed_reports     = true
  report_versioning          = "OVERWRITE_REPORT"

  depends_on = [module.cost_reports]
}

# -------------------------------------------------------------------------------
# Athena Workgroup for Querying Reports
# -------------------------------------------------------------------------------
resource "aws_athena_workgroup" "cost_analysis" {
  name = "cost-analysis"
  configuration {
    execution_role                     = aws_iam_role.athena_role.arn
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true
    result_configuration {
      output_location = "s3://${module.athena_query_results.bucket}/"
      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }
  }
}

# -------------------------------------------------------------------------------
# IAM Policy for Athena Access
# -------------------------------------------------------------------------------
resource "aws_iam_policy" "athena_cost_query" {
  name        = "AthenaCostQueryAccess"
  description = "Allows querying cost and usage reports"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "athena:StartQueryExecution",
          "athena:GetQueryExecution",
          "athena:GetQueryResults",
          "athena:StopQueryExecution",
          "athena:GetWorkGroup"
        ],
        Resource = [
          "arn:aws:athena:${var.region}:${data.aws_caller_identity.current.account_id}:workgroup/${aws_athena_workgroup.cost_analysis.name}"
        ]
      },
      {
        Effect = "Allow",
        Action = [
          "glue:GetDatabase",
          "glue:GetTable",
          "glue:GetTables",
          "glue:GetPartition",
          "glue:GetPartitions"
        ],
        Resource = [
          "arn:aws:glue:${var.region}:${data.aws_caller_identity.current.account_id}:catalog",
          "arn:aws:glue:${var.region}:${data.aws_caller_identity.current.account_id}:database/${aws_glue_catalog_database.database.name}",
          "arn:aws:glue:${var.region}:${data.aws_caller_identity.current.account_id}:table/${aws_glue_catalog_database.database.name}/*"
        ]
      },
      {
        Effect = "Allow",
        Action = [
          "s3:GetBucketLocation",
          "s3:GetObject",
          "s3:ListBucket"
        ],
        Resource = [
          module.cost_reports.arn,
          "${module.cost_reports.arn}/*"
        ]
      },
      {
        Effect = "Allow",
        Action = [
          "s3:GetBucketLocation",
          "s3:GetObject",
          "s3:ListBucket",
          "s3:ListBucketMultipartUploads",
          "s3:ListMultipartUploadParts",
          "s3:AbortMultipartUpload",
          "s3:PutObject",
          "s3:DeleteObject"
        ],
        Resource = [
          module.athena_query_results.arn,
          "${module.athena_query_results.arn}/*"
        ]
      }
    ]
  })
}

resource "aws_iam_role" "athena_role" {
  name = "athena-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "athena.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "athena_role_policy" {
  role       = aws_iam_role.athena_role.name
  policy_arn = aws_iam_policy.athena_cost_query.arn
}

# -------------------------------------------------------------------------------
# Budgets and Alerts
# -------------------------------------------------------------------------------
resource "aws_budgets_budget" "monthly_budget" {
  name              = "monthly-total-budget"
  budget_type       = "COST"
  limit_amount      = var.monthly_budget_limit
  limit_unit        = "USD"
  time_unit         = "MONTHLY"
  time_period_start = "2024-01-01_00:00"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
    subscriber_sns_topic_arns  = [aws_sns_topic.cost_alerts.arn]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
    subscriber_sns_topic_arns  = [aws_sns_topic.cost_alerts.arn]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 90
    threshold_type            = "PERCENTAGE"
    notification_type         = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }
}

# Per-service budgets
resource "aws_budgets_budget" "ec2_budget" {
  name         = "ec2-monthly-budget"
  budget_type  = "COST"
  limit_amount = "5000"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "Service"
    values = ["Amazon Elastic Compute Cloud - Compute"]
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 80
    threshold_type           = "PERCENTAGE"
    notification_type        = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.cost_alerts.arn]
  }
}

# -------------------------------------------------------------------------------
# Cost Allocation Tags
# -------------------------------------------------------------------------------
resource "aws_ce_cost_allocation_tag" "environment" {
  tag_key = "Environment"
  status  = "Active"
}

resource "aws_ce_cost_allocation_tag" "team" {
  tag_key = "Team"
  status  = "Active"
}

resource "aws_ce_cost_allocation_tag" "project" {
  tag_key = "Project"
  status  = "Active"
}

# Tag policy (if using AWS Organizations)
resource "aws_organizations_policy" "tag_policy" {
  name        = "required-tags-policy"
  description = "Enforce required tags"
  type        = "TAG_POLICY"

  content = jsonencode({
    tags = {
      Environment = {
        tag_key = {
          @@assign = "Environment"
        }
        enforced_for = {
          @@assign = ["ec2:instance", "rds:db", "s3:bucket"]
        }
      }
      Team = {
        tag_key = {
          @@assign = "Team"
        }
      }
    }
  })
}

# Lambda to check tag compliance
resource "aws_lambda_function" "tag_compliance_checker" {
  filename      = "lambda/tag_compliance.zip"
  function_name = "tag-compliance-checker"
  role          = aws_iam_role.lambda_exec.arn
  handler       = "index.handler"
  runtime       = "python3.11"
}

# -------------------------------------------------------------------------------
# DynamoDB Tables for Storing Cost Recommendations and Anomalies
# -------------------------------------------------------------------------------
resource "aws_dynamodb_table" "cost_recommendations" {
  name           = "cost-recommendations"
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = "resource_id"
  range_key      = "timestamp"

  attribute {
    name = "resource_id"
    type = "S"
  }

  attribute {
    name = "timestamp"
    type = "N"
  }

  attribute {
    name = "status"
    type = "S"
  }

  global_secondary_index {
    name            = "StatusIndex"
    hash_key        = "status"
    range_key       = "timestamp"
    projection_type = "ALL"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = {
    Name        = "cost-recommendations"
    Environment = var.environment
  }
}

resource "aws_dynamodb_table" "cost_anomalies" {
  name           = "cost-anomalies"
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = "date"
  range_key      = "service"

  attribute {
    name = "date"
    type = "S"
  }

  attribute {
    name = "service"
    type = "S"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }
}

# -------------------------------------------------------------------------------
# EventBridge Rules for Automated Tasks
# -------------------------------------------------------------------------------
# Daily cost analysis
resource "aws_cloudwatch_event_rule" "daily_cost_analysis" {
  name                = "daily-cost-analysis"
  description         = "Trigger cost analysis daily"
  schedule_expression = "cron(0 8 * * ? *)"  # 8 AM UTC daily
}

resource "aws_cloudwatch_event_target" "cost_analysis_lambda" {
  rule      = aws_cloudwatch_event_rule.daily_cost_analysis.name
  target_id = "CostAnalysisLambda"
  arn       = aws_lambda_function.cost_analyzer.arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cost_analyzer.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.daily_cost_analysis.arn
}

# Weekly unused resources scan
resource "aws_cloudwatch_event_rule" "weekly_unused_scan" {
  name                = "weekly-unused-resources-scan"
  description         = "Scan for unused resources weekly"
  schedule_expression = "cron(0 9 ? * MON *)"  # Every Monday 9 AM
}


# -------------------------------------------------------------------------------
# SNS Notifications for Cost Anomalies
# -------------------------------------------------------------------------------
resource "aws_sns_topic" "cost_alerts" {
  name              = "cost-alerts"
  display_name      = "Cost Anomaly Alerts"
  kms_master_key_id = aws_kms_key.sns_encryption.id
}

resource "aws_sns_topic_subscription" "cost_alerts_email" {
  topic_arn = aws_sns_topic.cost_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_sns_topic_subscription" "cost_alerts_slack" {
  topic_arn = aws_sns_topic.cost_alerts.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.slack_notifier.arn
}

# KMS key for SNS encryption
resource "aws_kms_key" "sns_encryption" {
  description             = "KMS key for SNS topic encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}