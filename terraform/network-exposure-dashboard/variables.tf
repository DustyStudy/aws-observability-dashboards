variable "name_prefix" {
  description = "Prefix applied to all resource names created by this module."
  type        = string
  default     = "network-exposure"

  validation {
    condition     = can(regex("^[a-z0-9-]{1,40}$", var.name_prefix))
    error_message = "name_prefix must be 1-40 lowercase alphanumeric characters or hyphens."
  }
}

variable "log_retention_in_days" {
  description = "Retention period for the exposure-collector Lambda's log group. Defaults to 365 to satisfy Checkov CKV_AWS_338 (retain at least 1 year); lower it only if your compliance posture allows shorter retention — Checkov will flag anything under 365."
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
  description = "CloudWatch custom metric namespace the exposure-collector Lambda publishes into."
  type        = string
  default     = "NetworkExposure"
}

variable "exposure_scan_schedule" {
  description = "EventBridge schedule expression for the exposure-collector Lambda."
  type        = string
  default     = "rate(1 day)"
}

variable "flow_logs_log_group_name" {
  description = "Name of an EXISTING CloudWatch Logs group that your VPC Flow Logs already deliver to (this module does not create or enable flow logs). Leave blank to deploy without the flow-log widgets — they'll render with no data rather than fail."
  type        = string
  default     = ""
}
