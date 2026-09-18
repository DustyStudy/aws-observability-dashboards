variable "dashboard_name" {
  description = "Name of the cross-account CloudWatch dashboard."
  type        = string
  default     = "fedramp-20x-audit-org-dashboard"
}

variable "member_account_ids" {
  description = "Leave empty (the default) to show every account linked to this monitoring account, using CloudWatch Metrics Insights queries that group by account. Or list specific 12-digit account IDs to show only those, one metric per account (limited to roughly 500/(series+1) accounts per widget)."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for a in var.member_account_ids : can(regex("^[0-9]{12}$", a))])
    error_message = "Every member_account_ids entry must be a 12-digit AWS account ID."
  }
}

variable "metric_namespace" {
  description = "Must match the metric_namespace variable used to deploy this dashboard's own collector module in every member account."
  type        = string
  default     = "FedRAMP20xAudit"

  validation {
    condition     = can(regex("^[A-Za-z0-9_./-]+$", var.metric_namespace))
    error_message = "metric_namespace may only contain letters, numbers, underscores, dots, slashes, and hyphens."
  }
}

variable "nhi_governance_namespace" {
  description = "Must match the metric_namespace variable used to deploy the nhi-governance-dashboard collector module in every member account."
  type        = string
  default     = "NHIGovernance"

  validation {
    condition     = can(regex("^[A-Za-z0-9_./-]+$", var.nhi_governance_namespace))
    error_message = "nhi_governance_namespace may only contain letters, numbers, underscores, dots, slashes, and hyphens."
  }
}

variable "network_exposure_namespace" {
  description = "Must match the metric_namespace variable used to deploy the network-exposure-dashboard collector module in every member account."
  type        = string
  default     = "NetworkExposure"

  validation {
    condition     = can(regex("^[A-Za-z0-9_./-]+$", var.network_exposure_namespace))
    error_message = "network_exposure_namespace may only contain letters, numbers, underscores, dots, slashes, and hyphens."
  }
}

variable "security_observability_namespace" {
  description = "Must match the metric_namespace variable used to deploy the security-posture-dashboard collector module in every member account."
  type        = string
  default     = "SecurityObservability"

  validation {
    condition     = can(regex("^[A-Za-z0-9_./-]+$", var.security_observability_namespace))
    error_message = "security_observability_namespace may only contain letters, numbers, underscores, dots, slashes, and hyphens."
  }
}
