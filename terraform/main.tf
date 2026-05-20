# -------------------------------------------------------------------------------
# Data Sources
# -------------------------------------------------------------------------------
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
}

# -------------------------------------------------------------------------------
# KMS Keys — one key per service boundary
# -------------------------------------------------------------------------------

# Key for S3 (cost reports + Athena results)
resource "aws_kms_key" "s3_encryption" {
  description             = "KMS CMK for cost-intelligence S3 buckets"
  deletion_window_in_days = var.kms_deletion_window_days
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "RootFullAccess"
        Effect = "Allow"
        Principal = {
          AWS = "arn:${local.partition}:iam::${local.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowGlueDecrypt"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.glue_crawler_role.arn
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey"
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowAthenaDecrypt"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.athena_role.arn
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_kms_alias" "s3_encryption" {
  name          = "alias/cost-intelligence-s3"
  target_key_id = aws_kms_key.s3_encryption.key_id
}

# Key for SNS topic encryption
resource "aws_kms_key" "sns_encryption" {
  description             = "KMS CMK for cost-alerts SNS topic"
  deletion_window_in_days = var.kms_deletion_window_days
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "RootFullAccess"
        Effect = "Allow"
        Principal = {
          AWS = "arn:${local.partition}:iam::${local.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowBudgetsEncrypt"
        Effect = "Allow"
        Principal = {
          Service = "budgets.amazonaws.com"
        }
        Action = [
          "kms:GenerateDataKey",
          "kms:Decrypt"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_kms_alias" "sns_encryption" {
  name          = "alias/cost-intelligence-sns"
  target_key_id = aws_kms_key.sns_encryption.key_id
}

# Key for DynamoDB table encryption
resource "aws_kms_key" "dynamodb_encryption" {
  description             = "KMS CMK for cost-intelligence DynamoDB tables"
  deletion_window_in_days = var.kms_deletion_window_days
  enable_key_rotation     = true
}

resource "aws_kms_alias" "dynamodb_encryption" {
  name          = "alias/cost-intelligence-dynamodb"
  target_key_id = aws_kms_key.dynamodb_encryption.key_id
}

# Key for Lambda environment variable encryption
resource "aws_kms_key" "lambda_encryption" {
  description             = "KMS CMK for Lambda environment variable encryption"
  deletion_window_in_days = var.kms_deletion_window_days
  enable_key_rotation     = true
}

resource "aws_kms_alias" "lambda_encryption" {
  name          = "alias/cost-intelligence-lambda"
  target_key_id = aws_kms_key.lambda_encryption.key_id
}

# -------------------------------------------------------------------------------
# S3 Bucket for Cost Reports
# -------------------------------------------------------------------------------
module "cost_reports" {
  source             = "./modules/s3"
  bucket_name        = "cost-reports-${local.account_id}"
  objects            = []
  versioning_enabled = "Enabled"

  # Explicit origins only — no wildcard allowed in production
  cors = [
    {
      allowed_headers = ["Authorization", "Content-Type"]
      allowed_methods = ["GET"]
      allowed_origins = var.cost_reports_cors_origins
      max_age_seconds = 3000
    },
    {
      allowed_headers = ["Authorization", "Content-Type", "x-amz-*"]
      allowed_methods = ["PUT"]
      allowed_origins = var.cost_reports_cors_origins
      max_age_seconds = 3000
    }
  ]

  bucket_policy = jsonencode({
    Version = "2012-10-17"
    Id      = "PolicyForBillingReports"
    Statement = [
      # Allow AWS Billing service to inspect bucket ACL/policy
      {
        Sid    = "AllowBillingReportsServiceGetBucketMeta"
        Effect = "Allow"
        Principal = {
          Service = "billingreports.amazonaws.com"
        }
        Action   = ["s3:GetBucketAcl", "s3:GetBucketPolicy"]
        Resource = module.cost_reports.arn
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = local.account_id
          }
        }
      },
      # Allow AWS Billing to write CUR objects
      {
        Sid    = "AllowBillingReportsServicePutObject"
        Effect = "Allow"
        Principal = {
          Service = "billingreports.amazonaws.com"
        }
        Action   = ["s3:PutObject"]
        Resource = "${module.cost_reports.arn}/*"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = local.account_id
          }
        }
      },
      # Deny any upload not encrypted with SSE-KMS
      {
        Sid    = "DenyUnencryptedObjectUploads"
        Effect = "Deny"
        Principal = {
          AWS = "*"
        }
        Action   = "s3:PutObject"
        Resource = "${module.cost_reports.arn}/*"
        Condition = {
          StringNotEquals = {
            "s3:x-amz-server-side-encryption" = "aws:kms"
          }
        }
      },
      # Deny non-HTTPS access
      {
        Sid    = "DenyHTTP"
        Effect = "Deny"
        Principal = {
          AWS = "*"
        }
        Action   = "s3:*"
        Resource = [module.cost_reports.arn, "${module.cost_reports.arn}/*"]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })

  # Production: never destroy data unless explicitly planned
  force_destroy = false
}

resource "aws_s3_bucket_lifecycle_configuration" "cost_reports_lifecycle" {
  bucket = module.cost_reports.bucket
  rule {
    id     = "archive-old-reports"
    status = "Enabled"

    filter {
      prefix = "reports/"
    }

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

    # Clean up incomplete multipart uploads
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# -------------------------------------------------------------------------------
# S3 Bucket for Athena Query Results
# -------------------------------------------------------------------------------
module "athena_query_results" {
  source             = "./modules/s3"
  bucket_name        = "athena-query-results-${local.account_id}"
  objects            = []
  versioning_enabled = "Enabled"
  force_destroy      = false

  cors = [
    {
      allowed_headers = ["Authorization", "Content-Type"]
      allowed_methods = ["GET"]
      allowed_origins = var.cost_reports_cors_origins
      max_age_seconds = 3000
    }
  ]

  bucket_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DenyHTTP"
        Effect = "Deny"
        Principal = {
          AWS = "*"
        }
        Action   = "s3:*"
        Resource = ["__PLACEHOLDER_ARN__", "__PLACEHOLDER_ARN__/*"]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })
  # Note: Replace __PLACEHOLDER_ARN__ with module.athena_query_results.arn after initial plan.
  # This circular reference limitation requires a two-step apply or moving the policy outside the module.
}

resource "aws_s3_bucket_lifecycle_configuration" "athena_results_lifecycle" {
  bucket = module.athena_query_results.bucket
  rule {
    id     = "cleanup-old-query-results"
    status = "Enabled"

    filter {
      prefix = ""
    }

    expiration {
      days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 3
    }
  }
}

# -------------------------------------------------------------------------------
# Glue — IAM Role
# -------------------------------------------------------------------------------
resource "aws_iam_role" "glue_crawler_role" {
  name                 = "cost-intelligence-glue-crawler-${var.environment}"
  description          = "Allows Glue to crawl the CUR S3 bucket"
  max_session_duration = 3600

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "glue.amazonaws.com"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = local.account_id
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "glue_service_policy" {
  role       = aws_iam_role.glue_crawler_role.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSGlueServiceRole"
}

resource "aws_iam_role_policy" "glue_s3_kms_access" {
  name = "cost-intelligence-glue-s3-kms-access"
  role = aws_iam_role.glue_crawler_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3CURAccess"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          module.cost_reports.arn,
          "${module.cost_reports.arn}/*"
        ]
      },
      {
        Sid    = "KMSDecryptForS3"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey"
        ]
        Resource = [aws_kms_key.s3_encryption.arn]
      }
    ]
  })
}

# -------------------------------------------------------------------------------
# Glue — Catalog + Crawler
# -------------------------------------------------------------------------------
resource "aws_glue_catalog_database" "database" {
  name        = var.glue_database_name
  description = "AWS Cost and Usage Report catalog for ${var.environment}"
}

resource "aws_glue_crawler" "crawler" {
  database_name = aws_glue_catalog_database.database.name
  name          = var.glue_crawler_name
  role          = aws_iam_role.glue_crawler_role.arn
  description   = "Crawls CUR Parquet files in S3 and updates the Glue catalog"
  schedule      = "cron(0 1 * * ? *)"

  schema_change_policy {
    delete_behavior = "LOG"
    update_behavior = "UPDATE_IN_DATABASE"
  }

  recrawl_policy {
    recrawl_behavior = "CRAWL_NEW_FOLDERS_ONLY"
  }

  s3_target {
    path = "s3://${module.cost_reports.bucket}/reports"
  }

  configuration = jsonencode({
    Version = 1.0
    CrawlerOutput = {
      Partitions = { AddOrUpdateBehavior = "InheritFromTable" }
    }
    Grouping = {
      TableGroupingPolicy = "CombineCompatibleSchemas"
    }
  })

  tags = {
    Environment = var.environment
  }
}

# -------------------------------------------------------------------------------
# Cost and Usage Report Definition
# -------------------------------------------------------------------------------
resource "aws_cur_report_definition" "cost_usage_report" {
  report_name                = "daily-cost-usage-report-${var.environment}"
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
# Athena — IAM Role & Policy
# -------------------------------------------------------------------------------
resource "aws_iam_role" "athena_role" {
  name                 = "cost-intelligence-athena-${var.environment}"
  description          = "Allows Athena to query CUR data in S3 via the Glue catalog"
  max_session_duration = 3600

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "athena.amazonaws.com"
      }
      Action = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = local.account_id
        }
      }
    }]
  })
}

resource "aws_iam_policy" "athena_cost_query" {
  name        = "cost-intelligence-AthenaCostQueryAccess-${var.environment}"
  description = "Allows Athena role to query CUR data, write results, and read Glue catalog"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AthenaWorkgroupAccess"
        Effect = "Allow"
        Action = [
          "athena:StartQueryExecution",
          "athena:GetQueryExecution",
          "athena:GetQueryResults",
          "athena:StopQueryExecution",
          "athena:GetWorkGroup"
        ]
        Resource = [
          "arn:${local.partition}:athena:${var.region}:${local.account_id}:workgroup/${var.athena_workgroup_name}"
        ]
      },
      {
        Sid    = "GlueCatalogReadAccess"
        Effect = "Allow"
        Action = [
          "glue:GetDatabase",
          "glue:GetTable",
          "glue:GetTables",
          "glue:GetPartition",
          "glue:GetPartitions"
        ]
        Resource = [
          "arn:${local.partition}:glue:${var.region}:${local.account_id}:catalog",
          "arn:${local.partition}:glue:${var.region}:${local.account_id}:database/${aws_glue_catalog_database.database.name}",
          "arn:${local.partition}:glue:${var.region}:${local.account_id}:table/${aws_glue_catalog_database.database.name}/*"
        ]
      },
      {
        Sid    = "S3CURReadAccess"
        Effect = "Allow"
        Action = [
          "s3:GetBucketLocation",
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          module.cost_reports.arn,
          "${module.cost_reports.arn}/*"
        ]
      },
      {
        Sid    = "S3AthenaResultsAccess"
        Effect = "Allow"
        Action = [
          "s3:GetBucketLocation",
          "s3:GetObject",
          "s3:ListBucket",
          "s3:ListBucketMultipartUploads",
          "s3:ListMultipartUploadParts",
          "s3:AbortMultipartUpload",
          "s3:PutObject",
          "s3:DeleteObject"
        ]
        Resource = [
          module.athena_query_results.arn,
          "${module.athena_query_results.arn}/*"
        ]
      },
      {
        Sid    = "KMSDecryptForBothBuckets"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey"
        ]
        Resource = [aws_kms_key.s3_encryption.arn]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "athena_role_policy" {
  role       = aws_iam_role.athena_role.name
  policy_arn = aws_iam_policy.athena_cost_query.arn
}

# -------------------------------------------------------------------------------
# Athena Workgroup
# -------------------------------------------------------------------------------
resource "aws_athena_workgroup" "cost_analysis" {
  name        = var.athena_workgroup_name
  description = "Workgroup for querying AWS Cost and Usage Reports"

  configuration {
    execution_role                     = aws_iam_role.athena_role.arn
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true

    # Prevent runaway query costs — 1 GB scan limit per query
    bytes_scanned_cutoff_per_query = 1073741824

    result_configuration {
      output_location = "s3://${module.athena_query_results.bucket}/"
      encryption_configuration {
        encryption_option = "SSE_KMS"
        kms_key           = aws_kms_key.s3_encryption.arn
      }
    }
  }
}

# -------------------------------------------------------------------------------
# SNS Topic & Subscriptions
# -------------------------------------------------------------------------------
resource "aws_sns_topic" "cost_alerts" {
  name              = "cost-alerts-${var.environment}"
  display_name      = "Cost Anomaly Alerts"
  kms_master_key_id = aws_kms_key.sns_encryption.id
}

# Restrict SNS publish to trusted services only
resource "aws_sns_topic_policy" "cost_alerts" {
  arn = aws_sns_topic.cost_alerts.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowBudgetsPublish"
        Effect = "Allow"
        Principal = {
          Service = "budgets.amazonaws.com"
        }
        Action   = "SNS:Publish"
        Resource = aws_sns_topic.cost_alerts.arn
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = local.account_id
          }
        }
      },
      {
        Sid    = "AllowAnomalyDetectionPublish"
        Effect = "Allow"
        Principal = {
          Service = "costalerts.amazonaws.com"
        }
        Action   = "SNS:Publish"
        Resource = aws_sns_topic.cost_alerts.arn
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = local.account_id
          }
        }
      },
      {
        Sid    = "AllowAccountAdminManage"
        Effect = "Allow"
        Principal = {
          AWS = "arn:${local.partition}:iam::${local.account_id}:root"
        }
        Action   = "SNS:*"
        Resource = aws_sns_topic.cost_alerts.arn
      }
    ]
  })
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

# -------------------------------------------------------------------------------
# Lambda IAM Role (shared exec role)
# -------------------------------------------------------------------------------
resource "aws_iam_role" "lambda_exec" {
  name                 = "cost-intelligence-lambda-exec-${var.environment}"
  description          = "Execution role for cost-intelligence Lambda functions"
  max_session_duration = 3600

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_kms_decrypt" {
  name = "cost-intelligence-lambda-kms-decrypt"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "LambdaKMSDecrypt"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey"
        ]
        Resource = [aws_kms_key.lambda_encryption.arn]
      }
    ]
  })
}

# -------------------------------------------------------------------------------
# Lambda Functions
# -------------------------------------------------------------------------------

# Cost Analyzer — triggered daily by EventBridge
resource "aws_lambda_function" "cost_analyzer" {
  filename      = "lambda/cost_analyzer.zip"
  function_name = "cost-intelligence-analyzer-${var.environment}"
  role          = aws_iam_role.lambda_exec.arn
  handler       = "index.handler"
  runtime       = "python3.12"
  timeout       = 300
  memory_size   = 256

  kms_key_arn = aws_kms_key.lambda_encryption.arn

  reserved_concurrent_executions = 5

  environment {
    variables = {
      ATHENA_WORKGROUP     = aws_athena_workgroup.cost_analysis.name
      RESULTS_BUCKET       = module.athena_query_results.bucket
      DYNAMODB_TABLE       = aws_dynamodb_table.cost_recommendations.name
      ANOMALIES_TABLE      = aws_dynamodb_table.cost_anomalies.name
      SNS_TOPIC_ARN        = aws_sns_topic.cost_alerts.arn
      ENVIRONMENT          = var.environment
    }
  }

  tracing_config {
    mode = "Active"
  }

  depends_on = [aws_iam_role_policy_attachment.lambda_basic_execution]
}

# Tag Compliance Checker
resource "aws_lambda_function" "tag_compliance_checker" {
  filename      = "lambda/tag_compliance.zip"
  function_name = "cost-intelligence-tag-compliance-${var.environment}"
  role          = aws_iam_role.lambda_exec.arn
  handler       = "index.handler"
  runtime       = "python3.12"
  timeout       = 300
  memory_size   = 128

  kms_key_arn = aws_kms_key.lambda_encryption.arn

  reserved_concurrent_executions = 3

  environment {
    variables = {
      SNS_TOPIC_ARN = aws_sns_topic.cost_alerts.arn
      ENVIRONMENT   = var.environment
    }
  }

  tracing_config {
    mode = "Active"
  }

  depends_on = [aws_iam_role_policy_attachment.lambda_basic_execution]
}

# Slack Notifier — receives SNS → posts to Slack webhook
resource "aws_lambda_function" "slack_notifier" {
  filename      = "lambda/slack_notifier.zip"
  function_name = "cost-intelligence-slack-notifier-${var.environment}"
  role          = aws_iam_role.lambda_exec.arn
  handler       = "index.handler"
  runtime       = "python3.12"
  timeout       = 30
  memory_size   = 128

  kms_key_arn = aws_kms_key.lambda_encryption.arn

  reserved_concurrent_executions = 5

  environment {
    variables = {
      ENVIRONMENT = var.environment
      # SLACK_WEBHOOK_URL should be injected at deploy time via SSM Parameter Store
      # or passed through a Secrets Manager ARN — do not hardcode here.
    }
  }

  tracing_config {
    mode = "Active"
  }

  depends_on = [aws_iam_role_policy_attachment.lambda_basic_execution]
}

# Allow SNS to invoke Slack notifier
resource "aws_lambda_permission" "sns_invoke_slack_notifier" {
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.slack_notifier.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.cost_alerts.arn
}

# -------------------------------------------------------------------------------
# Budgets & Alerts
# -------------------------------------------------------------------------------
resource "aws_budgets_budget" "monthly_budget" {
  name              = "monthly-total-budget-${var.environment}"
  budget_type       = "COST"
  limit_amount      = var.monthly_budget_limit
  limit_unit        = "USD"
  time_unit         = "MONTHLY"
  time_period_start = var.budget_time_period_start

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
    subscriber_sns_topic_arns  = [aws_sns_topic.cost_alerts.arn]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
    subscriber_sns_topic_arns  = [aws_sns_topic.cost_alerts.arn]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 90
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
    subscriber_sns_topic_arns  = [aws_sns_topic.cost_alerts.arn]
  }
}

resource "aws_budgets_budget" "ec2_budget" {
  name              = "ec2-monthly-budget-${var.environment}"
  budget_type       = "COST"
  limit_amount      = var.ec2_monthly_budget_limit
  limit_unit        = "USD"
  time_unit         = "MONTHLY"
  time_period_start = var.budget_time_period_start

  cost_filter {
    name   = "Service"
    values = ["Amazon Elastic Compute Cloud - Compute"]
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 80
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
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

# -------------------------------------------------------------------------------
# Organizations Tag Policy
# -------------------------------------------------------------------------------
resource "aws_organizations_policy" "tag_policy" {
  name        = "required-tags-policy"
  description = "Enforce required tags on EC2, RDS, and S3 resources"
  type        = "TAG_POLICY"

  content = jsonencode({
    tags = {
      Environment = {
        tag_key = {
          "@@assign" = "Environment"
        }
        tag_value = {
          "@@assign" = ["dev", "staging", "prod"]
        }
        enforced_for = {
          "@@assign" = ["ec2:instance", "rds:db", "s3:bucket"]
        }
      }
      Team = {
        tag_key = {
          "@@assign" = "Team"
        }
        enforced_for = {
          "@@assign" = ["ec2:instance", "rds:db"]
        }
      }
      ManagedBy = {
        tag_key = {
          "@@assign" = "ManagedBy"
        }
      }
    }
  })
}

# -------------------------------------------------------------------------------
# DynamoDB Tables
# -------------------------------------------------------------------------------
resource "aws_dynamodb_table" "cost_recommendations" {
  name           = "cost-recommendations-${var.environment}"
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

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.dynamodb_encryption.arn
  }

  deletion_protection_enabled = true

  tags = {
    Name        = "cost-recommendations"
    Environment = var.environment
  }
}

resource "aws_dynamodb_table" "cost_anomalies" {
  name           = "cost-anomalies-${var.environment}"
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

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.dynamodb_encryption.arn
  }

  deletion_protection_enabled = true

  tags = {
    Name        = "cost-anomalies"
    Environment = var.environment
  }
}

# -------------------------------------------------------------------------------
# EventBridge Rules
# -------------------------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "daily_cost_analysis" {
  name                = "cost-intelligence-daily-analysis-${var.environment}"
  description         = "Trigger cost analyzer Lambda at 08:00 UTC daily"
  schedule_expression = "cron(0 8 * * ? *)"
}

resource "aws_cloudwatch_event_target" "cost_analysis_lambda" {
  rule      = aws_cloudwatch_event_rule.daily_cost_analysis.name
  target_id = "CostAnalysisLambda"
  arn       = aws_lambda_function.cost_analyzer.arn
}

resource "aws_lambda_permission" "allow_eventbridge_cost_analyzer" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cost_analyzer.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.daily_cost_analysis.arn
}

resource "aws_cloudwatch_event_rule" "weekly_unused_scan" {
  name                = "cost-intelligence-weekly-unused-scan-${var.environment}"
  description         = "Scan for unused/idle resources every Monday at 09:00 UTC"
  schedule_expression = "cron(0 9 ? * MON *)"
}

resource "aws_cloudwatch_event_target" "weekly_unused_scan_lambda" {
  rule      = aws_cloudwatch_event_rule.weekly_unused_scan.name
  target_id = "TagComplianceLambda"
  arn       = aws_lambda_function.tag_compliance_checker.arn
}

resource "aws_lambda_permission" "allow_eventbridge_tag_compliance" {
  statement_id  = "AllowExecutionFromEventBridgeWeekly"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.tag_compliance_checker.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.weekly_unused_scan.arn
}

# -------------------------------------------------------------------------------
# CloudWatch Alarms for Lambda Error Rate
# -------------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "cost_analyzer_errors" {
  alarm_name          = "cost-analyzer-error-rate-${var.environment}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  alarm_description   = "Cost analyzer Lambda function has errors"
  alarm_actions       = [aws_sns_topic.cost_alerts.arn]

  dimensions = {
    FunctionName = aws_lambda_function.cost_analyzer.function_name
  }
}

resource "aws_cloudwatch_metric_alarm" "glue_crawler_failures" {
  alarm_name          = "glue-crawler-failure-${var.environment}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "glue.driver.aggregate.numFailedTasks"
  namespace           = "Glue"
  period              = 86400
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "Glue CUR crawler has failed tasks"
  alarm_actions       = [aws_sns_topic.cost_alerts.arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    JobName = var.glue_crawler_name
  }
}