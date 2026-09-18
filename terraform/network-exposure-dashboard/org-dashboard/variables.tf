variable "dashboard_name" {
  description = "Name of the cross-account CloudWatch dashboard."
  type        = string
  default     = "network-exposure-org-dashboard"
}

variable "member_account_ids" {
  description = "Leave empty (the default) to show every account linked to this monitoring account, using CloudWatch Metrics Insights queries. Or list specific 12-digit account IDs to show only those, one metric per account (limited to roughly 500/(series+1) accounts per widget). The VPC Flow Log panels are always per-account: they use log_account_ids if set, otherwise this list."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for a in var.member_account_ids : can(regex("^[0-9]{12}$", a))])
    error_message = "Every member_account_ids entry must be a 12-digit AWS account ID."
  }
}

variable "log_account_ids" {
  description = "Account IDs (12 digits) to show the VPC Flow Log panels for, one set of panels per account (Logs Insights widgets take a single account ID, so they cannot cover 'all accounts'). If empty, the panels use member_account_ids; in all-accounts mode (member_account_ids empty) no log panels are shown. Only used when flow_logs_log_group_name is set."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for a in var.log_account_ids : can(regex("^[0-9]{12}$", a))])
    error_message = "Every log_account_ids entry must be a 12-digit AWS account ID."
  }
}

variable "metric_namespace" {
  description = "Must match the metric_namespace variable used when deploying the collector module in every member account."
  type        = string
  default     = "NetworkExposure"

  validation {
    condition     = can(regex("^[A-Za-z0-9_./-]+$", var.metric_namespace))
    error_message = "metric_namespace may only contain letters, numbers, underscores, dots, slashes, and hyphens."
  }
}

variable "flow_logs_log_group_name" {
  description = "Name of the EXISTING CloudWatch Logs group your VPC Flow Logs deliver to. The same name is queried in every account the log panels cover (one log widget per account per panel, since log widgets take a single accountId; see log_account_ids). Leave blank to omit the three flow-log panels entirely, rather than emitting empty widgets for every account."
  type        = string
  default     = ""
}
