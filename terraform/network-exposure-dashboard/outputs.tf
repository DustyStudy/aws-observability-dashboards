output "dashboard_name" {
  description = "Name of the created CloudWatch dashboard"
  value       = aws_cloudwatch_dashboard.network_exposure.dashboard_name
}

output "dashboard_url" {
  description = "Console URL to open the dashboard directly"
  value       = "https://${data.aws_region.current.name}.console.aws.amazon.com/cloudwatch/home?region=${data.aws_region.current.name}#dashboards:name=${aws_cloudwatch_dashboard.network_exposure.dashboard_name}"
}

output "exposure_collector_function_name" {
  description = "Name of the scheduled exposure-collector Lambda"
  value       = aws_lambda_function.exposure_collector.function_name
}

output "exposure_collector_log_group_name" {
  description = "Log group for the exposure-collector Lambda (also where flagged resource identifiers are printed)"
  value       = aws_cloudwatch_log_group.exposure_collector.name
}
