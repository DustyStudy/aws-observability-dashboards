variable "name_prefix" {
  description = "Prefix applied to all resource names created by this module."
  type        = string
  default     = "nhi-governance"

  validation {
    condition     = can(regex("^[a-z0-9-]{1,40}$", var.name_prefix))
    error_message = "name_prefix must be 1-40 lowercase alphanumeric characters or hyphens."
  }
}

variable "log_retention_in_days" {
  description = "Retention period for the NHI-collector Lambda's log group. Defaults to 365 to satisfy Checkov CKV_AWS_338 (retain at least 1 year); lower it only if your compliance posture allows shorter retention — Checkov will flag anything under 365."
  type        = number
  default     = 365

  validation {
    condition = contains(
      [1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1827, 3653],
      var.log_retention_in_days
    )
    error_message = "log_retention_in_days must be a value CloudWatch Logs accepts (see AWS docs for allowed retention values)."
  }
}

variable "metric_namespace" {
  description = "CloudWatch custom metric namespace the NHI-collector Lambda publishes into."
  type        = string
  default     = "NHIGovernance"
}

variable "stale_threshold_days" {
  description = "Age in days beyond which an access key, IAM role, or user is considered stale/inactive."
  type        = number
  default     = 90
}

variable "governance_scan_schedule" {
  description = "EventBridge schedule expression for the NHI-collector Lambda."
  type        = string
  default     = "rate(1 day)"
}

variable "enable_lambda_reserved_concurrency" {
  type        = bool
  description = <<-EOT
    Whether to set reserved_concurrent_executions on this dashboard's
    Lambda function. A newly created AWS account can start with an
    account-wide Lambda concurrency limit as low as 10, in which case
    reserving even 1 unit of concurrency leaves less than the minimum
    unreserved amount AWS requires, and the apply fails with "decreases
    account's UnreservedConcurrentExecution below its minimum value". Set
    to false to deploy unreserved (relying on the account's shared pool)
    until a quota increase is granted, or in a throwaway test account
    where per-function isolation doesn't matter. See docs/PROOF.md.
  EOT
  default     = true
}
