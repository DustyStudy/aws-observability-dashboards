variable "dashboard_name" {
  description = "Name of the cross-account CloudWatch dashboard."
  type        = string
  default     = "agentic-ai-guardrails-org-dashboard"
}

variable "member_account_ids" {
  description = "Every member account ID to include on this dashboard."
  type        = list(string)

  validation {
    condition     = length(var.member_account_ids) > 0
    error_message = "member_account_ids must contain at least one account ID."
  }
}
