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
  description = "Every member account ID whose EKS security collector metrics and finding logs should appear on this dashboard (the same accounts you deployed the collector module and an OAM Link to). Does not need to include the monitoring account itself unless it also runs its own collector. Each account adds two log widgets, so at most 246 accounts fit on one dashboard (500-widget limit); split larger orgs across several org-dashboards."
  type        = list(string)

  validation {
    condition     = length(var.member_account_ids) > 0
    error_message = "member_account_ids must contain at least one account ID."
  }

  validation {
    condition     = alltrue([for a in var.member_account_ids : can(regex("^[0-9]{12}$", a))])
    error_message = "Every entry in member_account_ids must be a 12-digit AWS account ID."
  }

  validation {
    condition     = length(var.member_account_ids) <= 246
    error_message = "A dashboard holds at most 500 widgets and each account adds 2 log widgets (plus 8 fixed widgets), so at most 246 accounts fit; split the accounts across several org-dashboards with different dashboard_name values."
  }
}

variable "metric_namespace" {
  description = "Namespace the collector publishes to. The collector hard-codes EKS/Security (in the Lambda source and in its IAM cloudwatch:namespace condition) and exposes no variable for it, so leave the default unless you have forked the collector."
  type        = string
  default     = "EKS/Security"
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
