variable "dashboard_name" {
  description = "Name of the cross-account CloudWatch dashboard."
  type        = string
  default     = "network-exposure-org-dashboard"
}

variable "member_account_ids" {
  description = "Every member account ID whose network-exposure collector metrics (and, optionally, VPC Flow Logs) should appear on this dashboard (the same accounts you deployed the collector module and an OAM Link to). Does not need to include the monitoring account itself unless it also runs its own collector."
  type        = list(string)

  validation {
    condition     = length(var.member_account_ids) > 0
    error_message = "member_account_ids must contain at least one account ID."
  }
}

variable "metric_namespace" {
  description = "Must match the metric_namespace variable used when deploying the collector module in every member account."
  type        = string
  default     = "NetworkExposure"
}

variable "flow_logs_log_group_name" {
  description = "Name of the EXISTING CloudWatch Logs group your VPC Flow Logs deliver to. The same name is queried in every member account (one log widget per account per panel, since log widgets take a single accountId). Leave blank to omit the three flow-log panels entirely, rather than emitting empty widgets for every account."
  type        = string
  default     = ""
}
