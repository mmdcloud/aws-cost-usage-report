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