# AWS Cost Management Infrastructure

[![Terraform](https://img.shields.io/badge/Terraform-1.0+-623CE4?logo=terraform)](https://www.terraform.io/)
[![AWS](https://img.shields.io/badge/AWS-Cloud-FF9900?logo=amazon-aws)](https://aws.amazon.com/)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A comprehensive Terraform infrastructure for AWS cost monitoring, analysis, and optimization. This solution provides automated cost tracking, budget alerts, anomaly detection, and detailed cost analytics using AWS native services.

## 📋 Table of Contents

- [Features](#features)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Configuration](#configuration)
- [Usage](#usage)
- [Cost Optimization](#cost-optimization)
- [Monitoring and Alerts](#monitoring-and-alerts)
- [Security](#security)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)
- [License](#license)

## ✨ Features

### Cost Reporting & Analytics
- **AWS Cost and Usage Reports (CUR)**: Daily Parquet-formatted reports with resource-level details
- **Amazon Athena Integration**: SQL-based cost analysis with dedicated workgroup
- **AWS Glue Crawler**: Automated schema discovery and catalog updates
- **Historical Analysis**: 30-day query results retention with lifecycle management

### Budget Management
- **Monthly Budget Tracking**: Organization-wide spending limits with configurable thresholds
- **Service-Specific Budgets**: Granular EC2 cost monitoring
- **Multi-Threshold Alerts**: 80%, 90% (forecasted), and 100% spending notifications
- **SNS Integration**: Email and Slack notifications for budget breaches

### Cost Allocation & Governance
- **Tag-Based Cost Allocation**: Track costs by Environment, Team, and Project
- **Tag Enforcement**: AWS Organizations policies for required tags
- **Compliance Automation**: Lambda-based tag compliance checking

### Data Storage & Management
- **Cost Recommendations Tracking**: DynamoDB table for optimization opportunities
- **Anomaly Detection Storage**: Historical anomaly data with TTL management
- **Automated Lifecycle Policies**: S3 data tiering (Standard → IA → Glacier → Deletion)

### Automation
- **Daily Cost Analysis**: EventBridge-triggered cost reviews at 8 AM UTC
- **Weekly Resource Scans**: Unused resource detection every Monday
- **Automated Crawler**: Nightly Glue crawler updates at 1 AM UTC

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        AWS Account                              │
│                                                                 │
│  ┌──────────────┐         ┌──────────────┐                    │
│  │   AWS CUR    │────────▶│  S3 Bucket   │                    │
│  │   Reports    │         │ (Cost Data)  │                    │
│  └──────────────┘         └──────┬───────┘                    │
│                                   │                             │
│                          ┌────────▼────────┐                   │
│                          │  Glue Crawler   │                   │
│                          │  (Daily @ 1AM)  │                   │
│                          └────────┬────────┘                   │
│                                   │                             │
│  ┌──────────────┐         ┌──────▼───────┐                    │
│  │   Athena     │────────▶│ Glue Catalog │                    │
│  │  Workgroup   │         │   Database   │                    │
│  └──────┬───────┘         └──────────────┘                    │
│         │                                                       │
│         └──────────────┐                                       │
│                        ▼                                       │
│              ┌──────────────────┐                             │
│              │   S3 Bucket      │                             │
│              │ (Query Results)  │                             │
│              └──────────────────┘                             │
│                                                                 │
│  ┌──────────────┐         ┌──────────────┐                    │
│  │   Budgets    │────────▶│  SNS Topic   │───────┐           │
│  │  (Alerts)    │         │              │       │           │
│  └──────────────┘         └──────────────┘       │           │
│                                                    ▼           │
│  ┌──────────────┐         ┌──────────────┐   ┌─────────┐    │
│  │  EventBridge │────────▶│   Lambda     │   │  Email  │    │
│  │    Rules     │         │  Functions   │   │ / Slack │    │
│  └──────────────┘         └──────────────┘   └─────────┘    │
│                                                                 │
│  ┌──────────────┐                                             │
│  │   DynamoDB   │                                             │
│  │   Tables     │                                             │
│  └──────────────┘                                             │
└─────────────────────────────────────────────────────────────────┘
```

## 📦 Prerequisites

### Required Tools
- [Terraform](https://www.terraform.io/downloads.html) >= 1.0
- [AWS CLI](https://aws.amazon.com/cli/) >= 2.0
- AWS Account with appropriate permissions

### AWS Permissions Required
The IAM user/role executing this Terraform must have permissions for:
- S3 (bucket creation, policies, lifecycle)
- AWS Cost and Usage Reports
- AWS Glue (crawler, catalog, database)
- Amazon Athena (workgroup configuration)
- AWS Budgets
- SNS (topic creation, subscriptions)
- EventBridge (rules, targets)
- Lambda (function creation, permissions)
- DynamoDB (table creation)
- IAM (role/policy creation)
- KMS (key creation)
- AWS Organizations (for tag policies)

### Additional Requirements
- **S3 Module**: This configuration requires a custom S3 module located at `./modules/s3`
- **Lambda Functions**: Pre-packaged Lambda deployment packages:
  - `lambda/tag_compliance.zip`
  - Lambda functions for cost analysis and Slack notifications (referenced but not included)

## 🚀 Quick Start

### 1. Clone the Repository
```bash
git clone <repository-url>
cd <repository-directory>
```

### 2. Create Variables File
Create a `terraform.tfvars` file:

```hcl
# Required Variables
region               = "us-east-1"
alert_email          = "your-team@example.com"
monthly_budget_limit = "10000"
environment          = "production"

# Glue Configuration
glue_database_name = "cost_usage_db"
glue_crawler_name  = "cost-usage-crawler"
```

### 3. Initialize Terraform
```bash
terraform init
```

### 4. Review the Plan
```bash
terraform plan
```

### 5. Apply Configuration
```bash
terraform apply
```

### 6. Confirm SNS Subscription
Check your email for SNS subscription confirmation and click the confirmation link.

## ⚙️ Configuration

### Required Variables

| Variable | Description | Type | Example |
|----------|-------------|------|---------|
| `region` | AWS region for deployment | string | `us-east-1` |
| `alert_email` | Email for cost alerts | string | `ops@example.com` |
| `monthly_budget_limit` | Monthly budget in USD | string | `10000` |
| `environment` | Environment name | string | `production` |
| `glue_database_name` | Glue catalog database name | string | `cost_usage_db` |
| `glue_crawler_name` | Glue crawler name | string | `cost-usage-crawler` |

### Optional Customizations

#### Modify Budget Thresholds
Edit `main.tf` lines 318-341 to adjust notification thresholds:
```hcl
notification {
  comparison_operator = "GREATER_THAN"
  threshold          = 80  # Change to desired percentage
  threshold_type     = "PERCENTAGE"
  # ... rest of configuration
}
```

#### Adjust Lifecycle Policies
Modify S3 lifecycle rules (lines 60-77) to customize data retention:
```hcl
transition {
  days          = 30   # Days before moving to IA
  storage_class = "STANDARD_IA"
}
```

#### Update Crawler Schedule
Change Glue crawler execution time (line 164):
```hcl
schedule = "cron(0 1 * * ? *)"  # Currently 1 AM UTC daily
```

## 📊 Usage

### Querying Cost Data with Athena

1. **Access Athena Console**
   - Navigate to Amazon Athena in AWS Console
   - Select the `cost-analysis` workgroup

2. **Sample Queries**

```sql
-- Daily cost by service
SELECT 
  line_item_usage_start_date,
  line_item_product_code,
  SUM(line_item_unblended_cost) as daily_cost
FROM cost_usage_db.<table_name>
WHERE year = '2024' AND month = '01'
GROUP BY line_item_usage_start_date, line_item_product_code
ORDER BY daily_cost DESC;

-- Cost by environment tag
SELECT 
  resource_tags_user_environment as environment,
  SUM(line_item_unblended_cost) as total_cost
FROM cost_usage_db.<table_name>
WHERE year = '2024' AND month = '01'
GROUP BY resource_tags_user_environment
ORDER BY total_cost DESC;

-- Top 10 most expensive resources
SELECT 
  line_item_resource_id,
  line_item_product_code,
  SUM(line_item_unblended_cost) as resource_cost
FROM cost_usage_db.<table_name>
WHERE year = '2024' AND month = '01'
GROUP BY line_item_resource_id, line_item_product_code
ORDER BY resource_cost DESC
LIMIT 10;
```

### Accessing Cost Recommendations

Query the DynamoDB table:
```bash
aws dynamodb scan \
  --table-name cost-recommendations \
  --filter-expression "status = :s" \
  --expression-attribute-values '{":s":{"S":"pending"}}'
```

### Managing Budgets

Update monthly budget limit:
```bash
# Update terraform.tfvars
monthly_budget_limit = "15000"

# Apply changes
terraform apply -var-file=terraform.tfvars
```

## 💰 Cost Optimization

### Built-in Optimizations

1. **S3 Lifecycle Management**
   - Cost reports: Standard → IA (30d) → Glacier (90d) → Delete (365d)
   - Query results: Automatic deletion after 30 days

2. **DynamoDB On-Demand Pricing**
   - Pay-per-request billing for variable workloads
   - TTL enabled for automatic data expiration

3. **KMS Key Rotation**
   - Automated annual rotation for compliance

### Recommended Actions

- Review the `cost-recommendations` DynamoDB table weekly
- Analyze unused resources from weekly scans
- Right-size resources based on Athena query insights
- Consolidate tagged resources by team/project for showback

## 🔔 Monitoring and Alerts

### Alert Types

| Alert | Threshold | Notification Channel |
|-------|-----------|---------------------|
| Budget Warning | 80% of monthly limit | Email + SNS |
| Budget Critical | 100% of monthly limit | Email + SNS |
| Budget Forecast | 90% forecasted spend | Email |
| EC2 Budget | 80% of service limit | SNS Topic |

### Automated Monitoring

- **Daily Cost Analysis**: Runs at 8 AM UTC
- **Weekly Unused Resource Scan**: Every Monday at 9 AM UTC
- **Glue Crawler**: Daily at 1 AM UTC for fresh data

### CloudWatch Logs

Lambda functions log to CloudWatch Logs with the following patterns:
- `/aws/lambda/tag-compliance-checker`
- `/aws/lambda/cost-analyzer`
- `/aws/lambda/slack-notifier`

## 🔒 Security

### Implemented Security Controls

1. **Encryption at Rest**
   - S3 buckets: SSE-S3 encryption
   - Athena results: SSE-S3 encryption
   - SNS topics: KMS encryption
   - DynamoDB: Point-in-time recovery enabled

2. **Least Privilege IAM**
   - Service-specific roles for Glue, Athena, Lambda
   - Scoped policies with resource-level permissions
   - No wildcard permissions

3. **Data Protection**
   - S3 versioning enabled on critical buckets
   - DynamoDB point-in-time recovery
   - KMS key rotation enabled

4. **Network Security**
   - S3 bucket policies restrict access to AWS services
   - No public bucket access

### Security Best Practices

- Review IAM policies quarterly
- Enable AWS Config for compliance monitoring
- Implement AWS GuardDuty for threat detection
- Use AWS CloudTrail for audit logging
- Rotate KMS keys according to compliance requirements

## 🐛 Troubleshooting

### Common Issues

#### Cost Reports Not Appearing in S3

**Symptom**: No data in the cost reports bucket after 24 hours

**Solutions**:
1. Verify Cost and Usage Report is active in AWS Billing Console
2. Check bucket policy allows `billingreports.amazonaws.com`
3. Confirm S3 region matches `var.region`
4. Wait up to 24 hours for first report delivery

#### Glue Crawler Failing

**Symptom**: Crawler state shows "Failed"

**Solutions**:
1. Check CloudWatch Logs for crawler errors
2. Verify IAM role has S3 read permissions
3. Ensure cost reports exist in `s3://bucket/reports/`
4. Validate crawler S3 path configuration

#### Athena Queries Timing Out

**Symptom**: Queries exceed time limits or fail

**Solutions**:
1. Add partition filters (year, month) to queries
2. Limit date range in WHERE clauses
3. Use appropriate data types in GROUP BY
4. Review query execution statistics in Athena console

#### Budget Alerts Not Received

**Symptom**: No notifications despite exceeding thresholds

**Solutions**:
1. Confirm SNS subscription in AWS Console
2. Check spam folder for confirmation email
3. Verify email address in `terraform.tfvars`
4. Review SNS topic policies and subscriptions

### Debug Mode

Enable Terraform debug logging:
```bash
export TF_LOG=DEBUG
export TF_LOG_PATH=./terraform-debug.log
terraform apply
```

## 🤝 Contributing

We welcome contributions! Please follow these guidelines:

1. **Fork the Repository**
2. **Create a Feature Branch**
   ```bash
   git checkout -b feature/your-feature-name
   ```
3. **Make Your Changes**
   - Follow Terraform best practices
   - Update documentation as needed
   - Add comments for complex logic
4. **Test Your Changes**
   ```bash
   terraform fmt -check
   terraform validate
   terraform plan
   ```
5. **Submit a Pull Request**
   - Describe changes clearly
   - Reference any related issues
   - Include test results

### Development Guidelines

- Use meaningful resource names
- Follow the existing code structure
- Document all variables in README
- Include examples for new features
- Keep commits atomic and well-described

## 📝 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 📞 Support

- **Issues**: Submit via GitHub Issues
- **Questions**: Use GitHub Discussions
- **Security**: Email security concerns to security@example.com

## 🙏 Acknowledgments

- AWS for comprehensive cost management services
- Terraform community for infrastructure-as-code excellence
- Contributors and maintainers

---

**Note**: This infrastructure incurs AWS costs. Review the [Cost Optimization](#cost-optimization) section and monitor your AWS billing dashboard regularly.

**Estimated Monthly Cost**: $5-50 USD depending on:
- Number of AWS resources (affects CUR report size)
- Athena query frequency and data scanned
- Lambda invocations
- DynamoDB read/write operations
- S3 storage volume

For production use, consider implementing additional cost controls and regularly reviewing the generated recommendations.
