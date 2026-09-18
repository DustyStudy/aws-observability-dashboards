variable "dashboard_name" {
  description = "Name of the cross-account CloudWatch dashboard. Keep this different from the dashboard_name used for the per-account collector deployments."
  type        = string
  default     = "eks-security-org-dashboard"

  validation {
    condition     = can(regex("^[a-z0-9-]{1,40}$", var.dashboard_name))
    error_message = "dashboard_name must be 1-40 lowercase alphanumeric characters or hyphens."
  }
}

variable "member_account_ids" {
  description = "Leave empty (the default) to show the metric tiles for every account linked to this monitoring account, using CloudWatch Metrics Insights queries that group by account. Or list specific 12-digit account IDs to show only those, one metric per account (at most 499 accounts, since each widget also holds one SUM expression within the 500-metric limit). When log_account_ids is empty, this list also decides which accounts get GuardDuty and Inspector log panels (see log_account_ids for the limit)."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for a in var.member_account_ids : can(regex("^[0-9]{12}$", a))])
    error_message = "Every entry in member_account_ids must be a 12-digit AWS account ID."
  }

  validation {
    condition     = length(var.member_account_ids) <= 499
    error_message = "A metric widget holds at most 500 metrics and each account adds one (plus one combining expression), so at most 499 accounts fit in member_account_ids; leave it empty for all-accounts mode or split the accounts across several org-dashboards with different dashboard_name values."
  }
}

variable "log_account_ids" {
  description = "12-digit IDs of the accounts that get GuardDuty and Inspector log panels. A Logs Insights widget can only query one account, so log panels cannot be generated for \"all accounts\": list the accounts you want here. If empty (the default), log panels are created for member_account_ids; in all-accounts mode (member_account_ids also empty) no log panels are created. Each account adds two log widgets, so at most 246 accounts fit on one dashboard (500-widget limit); split larger orgs across several org-dashboards."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for a in var.log_account_ids : can(regex("^[0-9]{12}$", a))])
    error_message = "Every entry in log_account_ids must be a 12-digit AWS account ID."
  }

  validation {
    condition     = length(var.log_account_ids) <= 246
    error_message = "A dashboard holds at most 500 widgets and each account adds 2 log widgets (plus 8 fixed widgets), so at most 246 accounts fit in log_account_ids; split the accounts across several org-dashboards with different dashboard_name values."
  }
}

variable "metric_namespace" {
  description = "Namespace the collector publishes to. The collector hard-codes EKS/Security (in the Lambda source and in its IAM cloudwatch:namespace condition) and exposes no variable for it, so leave the default unless you have forked the collector."
  type        = string
  default     = "EKS/Security"

  validation {
    condition     = can(regex("^[A-Za-z0-9_./-]+$", var.metric_namespace))
    error_message = "metric_namespace may only contain letters, numbers, underscores, dots, slashes, and hyphens."
  }
}

variable "collector_dashboard_name" {
  description = "The dashboard_name the collector module was deployed with in the member accounts. The collector derives its GuardDuty and Inspector log group names from it (/aws/events/<name>/guardduty-eks and /aws/events/<name>/inspector-images), and this dashboard queries those log groups. Must be the same in every member account."
  type        = string
  default     = "eks-security-dashboard"

  validation {
    condition     = can(regex("^[a-z0-9-]{1,40}$", var.collector_dashboard_name))
    error_message = "collector_dashboard_name must be 1-40 lowercase alphanumeric characters or hyphens."
  }
}
