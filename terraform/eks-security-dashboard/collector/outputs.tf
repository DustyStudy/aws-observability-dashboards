output "guardduty_eks_log_group_name" {
  value = aws_cloudwatch_log_group.guardduty_eks.name
}

output "inspector_eks_log_group_name" {
  value = aws_cloudwatch_log_group.inspector_eks.name
}

output "patch_check_function_name" {
  value = aws_lambda_function.patch_check.function_name
}

output "patch_check_log_group_name" {
  description = "Log group for the patch-check Lambda (its own execution logs, not the EventBridge-fed finding logs above)"
  value       = aws_cloudwatch_log_group.patch_check.name
}
