terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# KMS key used to encrypt both CloudWatch Logs groups at rest
# ---------------------------------------------------------------------------
resource "aws_kms_key" "logs" {
  description         = "Encrypts CloudWatch Logs for the ${var.name_prefix} observability dashboard"
  enable_key_rotation = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowAccountKeyAdministration"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowCloudWatchLogsToUseKey"
        Effect    = "Allow"
        Principal = { Service = "logs.${data.aws_region.current.name}.amazonaws.com" }
        Action = [
          "kms:Encrypt*",
          "kms:Decrypt*",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:Describe*",
        ]
        Resource = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:*"
          }
        }
      },
    ]
  })
}

resource "aws_kms_alias" "logs" {
  name          = "alias/${var.name_prefix}-observability-logs"
  target_key_id = aws_kms_key.logs.key_id
}

# ---------------------------------------------------------------------------
# Log groups that receive raw finding events via EventBridge
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "security_hub" {
  name              = "/observability/${var.name_prefix}/security-hub-findings"
  retention_in_days = var.log_retention_in_days
  kms_key_id        = aws_kms_key.logs.arn
}

resource "aws_cloudwatch_log_group" "guardduty" {
  name              = "/observability/${var.name_prefix}/guardduty-findings"
  retention_in_days = var.log_retention_in_days
  kms_key_id        = aws_kms_key.logs.arn
}

# Resource policy allowing EventBridge to write into both log groups
resource "aws_cloudwatch_log_resource_policy" "eventbridge_to_logs" {
  policy_name = "${var.name_prefix}-eventbridge-to-logs"

  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowEventBridgeToWriteLogs"
        Effect    = "Allow"
        Principal = { Service = "events.amazonaws.com" }
        Action    = ["logs:PutLogEvents", "logs:CreateLogStream"]
        Resource = [
          aws_cloudwatch_log_group.security_hub.arn,
          aws_cloudwatch_log_group.guardduty.arn,
        ]
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# EventBridge rules routing findings into the log groups above
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "security_hub_findings" {
  name        = "${var.name_prefix}-security-hub-findings"
  description = "Routes Security Hub imported findings to CloudWatch Logs."

  event_pattern = jsonencode({
    source        = ["aws.securityhub"]
    "detail-type" = ["Security Hub Findings - Imported"]
  })
}

resource "aws_cloudwatch_event_target" "security_hub_to_logs" {
  rule = aws_cloudwatch_event_rule.security_hub_findings.name
  arn  = aws_cloudwatch_log_group.security_hub.arn
}

resource "aws_cloudwatch_event_rule" "guardduty_findings" {
  name        = "${var.name_prefix}-guardduty-findings"
  description = "Routes GuardDuty findings to CloudWatch Logs."

  event_pattern = jsonencode({
    source        = ["aws.guardduty"]
    "detail-type" = ["GuardDuty Finding"]
  })
}

resource "aws_cloudwatch_event_target" "guardduty_to_logs" {
  rule = aws_cloudwatch_event_rule.guardduty_findings.name
  arn  = aws_cloudwatch_log_group.guardduty.arn
}

# ---------------------------------------------------------------------------
# Metric filters — promote key fields to CloudWatch metrics for the
# single-value widgets on the dashboard.
#
# NOTE: these patterns assume a single finding per event (detail.findings[0]).
# Security Hub can batch multiple findings into one event; if you see gaps
# between log volume and metric counts, split multi-finding events with a
# subscription filter -> Lambda before counting, or accept this as an
# approximation for the top-line numbers.
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_metric_filter" "security_hub_critical" {
  name           = "${var.name_prefix}-security-hub-critical"
  log_group_name = aws_cloudwatch_log_group.security_hub.name
  pattern        = "{ $.detail.findings[0].Severity.Label = \"CRITICAL\" }"

  metric_transformation {
    name          = "SecurityHubCriticalFindings"
    namespace     = var.metric_namespace
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_log_metric_filter" "security_hub_high" {
  name           = "${var.name_prefix}-security-hub-high"
  log_group_name = aws_cloudwatch_log_group.security_hub.name
  pattern        = "{ $.detail.findings[0].Severity.Label = \"HIGH\" }"

  metric_transformation {
    name          = "SecurityHubHighFindings"
    namespace     = var.metric_namespace
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_log_metric_filter" "guardduty_high_severity" {
  name           = "${var.name_prefix}-guardduty-high-severity"
  log_group_name = aws_cloudwatch_log_group.guardduty.name
  pattern        = "{ $.detail.severity >= 7 }"

  metric_transformation {
    name          = "GuardDutyHighSeverityFindings"
    namespace     = var.metric_namespace
    value         = "1"
    default_value = "0"
  }
}

