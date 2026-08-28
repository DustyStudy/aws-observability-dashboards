output "security_hub_log_group_name" {
  description = "Log group receiving Security Hub findings"
  value       = aws_cloudwatch_log_group.security_hub.name
}

output "guardduty_log_group_name" {
  description = "Log group receiving GuardDuty findings"
  value       = aws_cloudwatch_log_group.guardduty.name
}
