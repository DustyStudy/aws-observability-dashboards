output "dashboard_name" {
  description = "Name of the created CloudWatch dashboard"
  value       = aws_cloudwatch_dashboard.ai_service_inventory.dashboard_name
}

output "dashboard_url" {
  description = "Console URL to open the dashboard directly"
  value       = "https://${data.aws_region.current.name}.console.aws.amazon.com/cloudwatch/home?region=${data.aws_region.current.name}#dashboards:name=${aws_cloudwatch_dashboard.ai_service_inventory.dashboard_name}"
}

output "inventory_collector_function_name" {
  description = "Name of the scheduled inventory-collector Lambda"
  value       = aws_lambda_function.inventory_collector.function_name
}

output "inventory_collector_log_group_name" {
  description = "Log group for the inventory-collector Lambda"
  value       = aws_cloudwatch_log_group.inventory_collector.name
}
