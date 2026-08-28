output "dashboard_url" {
  description = "Console URL to open the cross-account dashboard directly"
  value       = "https://${data.aws_region.current.name}.console.aws.amazon.com/cloudwatch/home?region=${data.aws_region.current.name}#dashboards:name=${aws_cloudwatch_dashboard.nhi_governance_org.dashboard_name}"
}
