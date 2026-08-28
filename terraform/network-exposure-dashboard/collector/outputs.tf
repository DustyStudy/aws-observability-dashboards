output "exposure_collector_function_name" {
  description = "Name of the scheduled exposure-collector Lambda"
  value       = aws_lambda_function.exposure_collector.function_name
}

output "exposure_collector_log_group_name" {
  description = "Log group for the exposure-collector Lambda (also where flagged resource identifiers are printed)"
  value       = aws_cloudwatch_log_group.exposure_collector.name
}
