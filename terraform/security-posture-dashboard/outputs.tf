output "dashboard_name" {
  description = "Name of the created CloudWatch dashboard"
  value       = aws_cloudwatch_dashboard.security_posture.dashboard_name
}

output "dashboard_url" {
  description = "Console URL to open the dashboard directly"
  value       = "https://${data.aws_region.current.name}.console.aws.amazon.com/cloudwatch/home?region=${data.aws_region.current.name}#dashboards:name=${aws_cloudwatch_dashboard.security_posture.dashboard_name}"
}

output "security_hub_log_group_name" {
  description = "Log group receiving Security Hub findings"
  value       = aws_cloudwatch_log_group.security_hub.name
}

output "guardduty_log_group_name" {
  description = "Log group receiving GuardDuty findings"
  value       = aws_cloudwatch_log_group.guardduty.name
}
