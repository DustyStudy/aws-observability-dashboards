variable "name_prefix" {
  description = "Prefix applied to the dashboard name created by this module."
  type        = string
  default     = "agentic-ai-observability"

  validation {
    condition     = can(regex("^[a-z0-9-]{1,40}$", var.name_prefix))
    error_message = "name_prefix must be 1-40 lowercase alphanumeric characters or hyphens."
  }
}
