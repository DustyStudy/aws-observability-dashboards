output "nhi_collector_function_name" {
  description = "Name of the scheduled NHI-collector Lambda"
  value       = aws_lambda_function.nhi_collector.function_name
}

output "nhi_collector_log_group_name" {
  description = "Log group for the NHI-collector Lambda (also where flagged identities are printed)"
  value       = aws_cloudwatch_log_group.nhi_collector.name
}
