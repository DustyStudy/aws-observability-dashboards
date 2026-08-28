variable "monitoring_sink_arn" {
  description = "ARN of the OAM sink in the monitoring account (the sink_arn output from ../oam-sink). Every source account links to the same sink ARN."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-zA-Z-]*:oam:[a-z0-9-]+:[0-9]{12}:sink/.+$", var.monitoring_sink_arn))
    error_message = "monitoring_sink_arn must be a valid OAM sink ARN, e.g. arn:aws:oam:us-east-1:111122223333:sink/abc-123."
  }
}

variable "label_template" {
  description = "How this account is labeled in the monitoring account's console. $AccountName, $AccountEmail, and $AccountEmailNoDomain are supported."
  type        = string
  default     = "$AccountName"
}
