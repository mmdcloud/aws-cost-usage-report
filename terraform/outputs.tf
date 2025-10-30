output "report_bucket_name" {
  value = module.cost_reports.bucket
}

output "athena_workgroup_name" {
  value = aws_athena_workgroup.cost_analysis.name
}