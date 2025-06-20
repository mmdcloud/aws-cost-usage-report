## Data Sources
data "aws_caller_identity" "current" {}


## S3 Bucket for Cost Reports
resource "aws_s3_bucket" "cost_reports" {
  bucket = "cost-reports-${data.aws_caller_identity.current.account_id}"
  tags = {
    Name        = "Cost and Usage Reports"
    Environment = "Production"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "cost_reports_lifecycle" {
  bucket = aws_s3_bucket.cost_reports.id
  rule {
    id = "archive-old-reports"
    status = "Enabled"
    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }
    transition {
      days          = 90
      storage_class = "GLACIER"
    }
  }
}

## S3 Bucket for Glue Catalog
resource "aws_s3_bucket" "glue_catalog_cost_reports" {
  bucket = "glue-catalog-cost-reports-${data.aws_caller_identity.current.account_id}"
  tags = {
    Name        = "Cost and Usage Reports"
    Environment = "Production"
  }
}

resource "aws_s3_bucket_policy" "cost_reports" {
  bucket = aws_s3_bucket.cost_reports.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "billingreports.amazonaws.com"
        },
        Action = [
          "s3:GetBucketAcl",
          "s3:GetBucketPolicy"
        ],
        Resource = aws_s3_bucket.cost_reports.arn
      },
      {
        Effect = "Allow",
        Principal = {
          Service = "billingreports.amazonaws.com"
        },
        Action = "s3:PutObject",
        Resource = "${aws_s3_bucket.cost_reports.arn}/*"
      }
    ]
  })
}

## Cost and Usage Report Definition
resource "aws_cur_report_definition" "cost_usage_report" {
  report_name                = "daily-cost-usage-report"
  time_unit                  = "DAILY"
  format                     = "Parquet" # Recommended for Athena
  compression                = "Parquet"
  additional_schema_elements = ["RESOURCES"]
  s3_bucket                  = aws_s3_bucket.cost_reports.bucket
  s3_prefix                  = "reports"
  s3_region                  = aws_s3_bucket.cost_reports.region
  additional_artifacts       = ["ATHENA"]
  refresh_closed_reports     = true
  report_versioning          = "OVERWRITE_REPORT"

  depends_on = [aws_s3_bucket_policy.cost_reports]
}

## Athena Workgroup for Querying Reports
resource "aws_athena_workgroup" "cost_analysis" {
  name = "cost-analysis"

  configuration {
    enforce_workgroup_configuration = true
    publish_cloudwatch_metrics_enabled = true

    result_configuration {
      output_location = "s3://${aws_s3_bucket.cost_reports.bucket}/query_results/"

      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }
  }
}

## IAM Policy for Athena Access
resource "aws_iam_policy" "athena_cost_query" {
  name        = "AthenaCostQueryAccess"
  description = "Allows querying cost and usage reports"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "athena:*",
          "glue:GetDatabase",
          "glue:GetTable",
          "glue:GetTables",
          "glue:GetPartition",
          "glue:GetPartitions",
          "glue:CreateTable",
          "glue:UpdateTable"
        ],
        Resource = "*"
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
          aws_s3_bucket.cost_reports.arn,
          "${aws_s3_bucket.cost_reports.arn}/*"
        ]
      }
    ]
  })
}