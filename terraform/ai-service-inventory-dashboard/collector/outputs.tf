output "inventory_collector_function_name" {
  description = "Name of the scheduled inventory-collector Lambda"
  value       = aws_lambda_function.inventory_collector.function_name
}

output "inventory_collector_log_group_name" {
  description = "Log group for the inventory-collector Lambda"
  value       = aws_cloudwatch_log_group.inventory_collector.name
}
