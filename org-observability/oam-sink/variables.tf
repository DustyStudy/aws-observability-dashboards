variable "sink_name" {
  description = "Name of the OAM sink."
  type        = string
  default     = "org-observability-sink"
}

variable "organization_id" {
  description = "Your AWS Organization ID (e.g. o-abc123xyz9). Every account in this organization will be permitted to link to this sink. Find it with: aws organizations describe-organization --query Organization.Id"
  type        = string

  validation {
    condition     = can(regex("^o-[a-z0-9]{10,32}$", var.organization_id))
    error_message = "organization_id must look like o-abc123xyz9 (see: aws organizations describe-organization)."
  }
}
