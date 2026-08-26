output "dashboard_name" {
  description = "Name of the created CloudWatch dashboard"
  value       = aws_cloudwatch_dashboard.nhi_governance.dashboard_name
}

output "dashboard_url" {
  description = "Console URL to open the dashboard directly"
  value       = "https://${data.aws_region.current.name}.console.aws.amazon.com/cloudwatch/home?region=${data.aws_region.current.name}#dashboards:name=${aws_cloudwatch_dashboard.nhi_governance.dashboard_name}"
}

output "nhi_collector_function_name" {
  description = "Name of the scheduled NHI-collector Lambda"
  value       = aws_lambda_function.nhi_collector.function_name
}

output "nhi_collector_log_group_name" {
  description = "Log group for the NHI-collector Lambda (also where flagged identities are printed)"
  value       = aws_cloudwatch_log_group.nhi_collector.name
}
