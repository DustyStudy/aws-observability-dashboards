variable "dashboard_name" {
  description = "Name of the CloudWatch dashboard to create; also used as the prefix for other resource names."
  type        = string
  default     = "eks-security-dashboard"

  validation {
    condition     = can(regex("^[a-z0-9-]{1,40}$", var.dashboard_name))
    error_message = "dashboard_name must be 1-40 lowercase alphanumeric characters or hyphens."
  }
}

variable "latest_eks_version" {
  description = "Kubernetes version considered \"current\" for drift comparisons."
  type        = string
  default     = "1.31"
}

variable "stale_ami_days" {
  description = "Age in days after which a nodegroup AMI release is flagged stale."
  type        = number
  default     = 60
}

variable "patch_check_schedule" {
  description = "EventBridge schedule expression for the patch-drift check."
  type        = string
  default     = "rate(1 day)"
}

variable "log_retention_days" {
  description = "Retention period for the EventBridge-fed log groups and the patch-check Lambda's own log group. Defaults to 365 to satisfy Checkov CKV_AWS_338 (retain at least 1 year); lower it only if your compliance posture allows shorter retention — Checkov will flag anything under 365."
  type        = number
  default     = 365

  validation {
    condition = contains(
      [1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1827, 3653],
      var.log_retention_days
    )
    error_message = "log_retention_days must be a value CloudWatch Logs accepts (see AWS docs for allowed retention values)."
  }
}
