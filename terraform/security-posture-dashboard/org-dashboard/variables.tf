variable "dashboard_name" {
  description = "Name of the cross-account CloudWatch dashboard."
  type        = string
  default     = "security-posture-org-dashboard"
}

variable "member_account_ids" {
  description = "Leave empty (the default) to show every account linked to this monitoring account, using CloudWatch Metrics Insights queries that group by account. Or list specific 12-digit account IDs to show only those, one metric per account (limited to roughly 500/(series+1) accounts per widget). Log panels are always per-account: they are emitted for log_account_ids if set, else for these accounts (up to 99, since each account adds 5 log widgets and a dashboard holds at most 500 widgets)."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for a in var.member_account_ids : can(regex("^[0-9]{12}$", a))])
    error_message = "Every member_account_ids entry must be a 12-digit AWS account ID."
  }
}

variable "log_account_ids" {
  description = "Optional 12-digit account IDs to get per-account Logs Insights panels (a CloudWatch log widget takes a single accountId, so all-accounts mode cannot enumerate accounts for logs). If empty, log panels are emitted for member_account_ids; when that is also empty (all-accounts mode) there are no log panels. Each account adds 5 log widgets and a dashboard holds at most 500 widgets, so at most 99 accounts."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for a in var.log_account_ids : can(regex("^[0-9]{12}$", a))])
    error_message = "Every log_account_ids entry must be a 12-digit AWS account ID."
  }

  validation {
    condition     = length(var.log_account_ids) <= 99
    error_message = "A dashboard holds at most 500 widgets: 3 metric widgets plus 5 log widgets per account, so log_account_ids can hold at most 99 accounts. Split the accounts across several org-dashboards."
  }
}

variable "metric_namespace" {
  description = "Must match the metric_namespace variable used when deploying the collector module in every member account."
  type        = string
  default     = "SecurityObservability"

  validation {
    condition     = can(regex("^[A-Za-z0-9_./-]+$", var.metric_namespace))
    error_message = "metric_namespace may only contain letters, numbers, underscores, dots, slashes, and hyphens."
  }
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
