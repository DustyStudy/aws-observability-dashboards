output "dashboard_name" {
  description = "Name of the cross-account CloudWatch dashboard"
  value       = aws_cloudwatch_dashboard.network_exposure_org.dashboard_name
}

output "dashboard_url" {
  description = "Console URL to open the cross-account dashboard directly"
  value       = "https://${data.aws_region.current.name}.console.aws.amazon.com/cloudwatch/home?region=${data.aws_region.current.name}#dashboards:name=${aws_cloudwatch_dashboard.network_exposure_org.dashboard_name}"
}
