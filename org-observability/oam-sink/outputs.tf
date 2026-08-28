output "sink_arn" {
  description = "ARN of the sink. Every account's OAM Link (see ../oam-link) needs this value as its monitoring_sink_arn variable."
  value       = aws_oam_sink.this.arn
}

output "sink_name" {
  value = var.sink_name
}
