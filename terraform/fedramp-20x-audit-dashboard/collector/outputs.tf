output "audit_collector_function_name" {
  description = "Name of the scheduled audit-evidence collector Lambda"
  value       = aws_lambda_function.audit_collector.function_name
}

output "audit_collector_log_group_name" {
  description = "Log group for the audit-collector Lambda (also where flagged resource IDs are printed)"
  value       = aws_cloudwatch_log_group.audit_collector.name
}
