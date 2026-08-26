output "dashboard_name" {
  description = "Name of the created CloudWatch dashboard"
  value       = aws_cloudwatch_dashboard.agentic_ai_guardrails.dashboard_name
}

output "dashboard_url" {
  description = "Console URL to open the dashboard directly"
  value       = "https://${data.aws_region.current.name}.console.aws.amazon.com/cloudwatch/home?region=${data.aws_region.current.name}#dashboards:name=${aws_cloudwatch_dashboard.agentic_ai_guardrails.dashboard_name}"
}
