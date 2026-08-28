output "cost_collector_function_name" {
  description = "Name of the scheduled Bedrock cost-collector Lambda"
  value       = aws_lambda_function.cost_collector.function_name
}

output "cost_collector_log_group_name" {
  description = "Log group for the cost-collector Lambda"
  value       = aws_cloudwatch_log_group.cost_collector.name
}
