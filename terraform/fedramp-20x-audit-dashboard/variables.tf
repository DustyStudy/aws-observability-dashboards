variable "name_prefix" {
  description = "Prefix applied to all resource names created by this module."
  type        = string
  default     = "fedramp-20x-audit"

  validation {
    condition     = can(regex("^[a-z0-9-]{1,40}$", var.name_prefix))
    error_message = "name_prefix must be 1-40 lowercase alphanumeric characters or hyphens."
  }
}

variable "log_retention_in_days" {
  description = "Retention period for the audit-collector Lambda's log group. Defaults to 365 to satisfy Checkov CKV_AWS_338 (retain at least 1 year); lower it only if your compliance posture allows shorter retention — Checkov will flag anything under 365."
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
  description = "CloudWatch custom metric namespace this module's audit-collector Lambda publishes into."
  type        = string
  default     = "FedRAMP20xAudit"
}

variable "audit_scan_schedule" {
  description = "EventBridge schedule expression for the audit-collector Lambda."
  type        = string
  default     = "rate(1 day)"
}

variable "nhi_governance_namespace" {
  description = "Metric namespace used by the nhi-governance-dashboard module in this same account. Must match the metric_namespace variable you deployed that module with."
  type        = string
  default     = "NHIGovernance"
}

variable "network_exposure_namespace" {
  description = "Metric namespace used by the network-exposure-dashboard module in this same account. Must match the metric_namespace variable you deployed that module with."
  type        = string
  default     = "NetworkExposure"
}

variable "security_observability_namespace" {
  description = "Metric namespace used by the security-posture-dashboard module in this same account. Must match the metric_namespace variable you deployed that module with."
  type        = string
  default     = "SecurityObservability"
}
