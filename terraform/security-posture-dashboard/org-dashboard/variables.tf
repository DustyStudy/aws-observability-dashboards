variable "dashboard_name" {
  description = "Name of the cross-account CloudWatch dashboard."
  type        = string
  default     = "security-posture-org-dashboard"
}

variable "member_account_ids" {
  description = "Every member account ID whose security-posture collector metrics and logs should appear on this dashboard (the same accounts you deployed the collector module and an OAM Link to). Does not need to include the monitoring account itself unless it also runs its own collector. Each account adds 5 log widgets, and a dashboard holds at most 500 widgets, so at most 99 accounts fit on one dashboard."
  type        = list(string)

  validation {
    condition     = length(var.member_account_ids) > 0
    error_message = "member_account_ids must contain at least one account ID."
  }

  validation {
    condition     = length(var.member_account_ids) <= 99
    error_message = "A dashboard holds at most 500 widgets: 3 metric widgets plus 5 log widgets per account, so member_account_ids can hold at most 99 accounts. Split the accounts across several org-dashboards."
  }
}

variable "metric_namespace" {
  description = "Must match the metric_namespace variable used when deploying the collector module in every member account."
  type        = string
  default     = "SecurityObservability"
}

variable "name_prefix" {
  description = "Must match the name_prefix variable used when deploying the collector module in every member account; it forms the collector's log group names (/observability/<name_prefix>/security-hub-findings and /observability/<name_prefix>/guardduty-findings) that the log widgets query."
  type        = string
  default     = "security-posture"

  validation {
    condition     = can(regex("^[a-z0-9-]{1,40}$", var.name_prefix))
    error_message = "name_prefix must be 1-40 lowercase alphanumeric characters or hyphens."
  }
}
