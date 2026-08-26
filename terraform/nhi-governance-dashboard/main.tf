terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.4"
    }
  }
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# KMS key used to encrypt the NHI-collector's log group, env vars, and DLQ
# ---------------------------------------------------------------------------
resource "aws_kms_key" "nhi" {
  description         = "Encrypts NHI-collector resources for the ${var.name_prefix} dashboard"
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
      {
        Sid       = "AllowLambdaAndSqsServices"
        Effect    = "Allow"
        Principal = { Service = ["lambda.amazonaws.com", "sqs.amazonaws.com"] }
        Action = [
          "kms:Encrypt*",
          "kms:Decrypt*",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:Describe*",
        ]
        Resource = "*"
      },
    ]
  })
}

resource "aws_kms_alias" "nhi" {
  name          = "alias/${var.name_prefix}-observability"
  target_key_id = aws_kms_key.nhi.key_id
}

# ---------------------------------------------------------------------------
# Dead-letter queue for the NHI-collector Lambda
# ---------------------------------------------------------------------------
resource "aws_sqs_queue" "nhi_collector_dlq" {
  name                      = "${var.name_prefix}-collector-dlq"
  message_retention_seconds = 1209600 # 14 days
  kms_master_key_id         = aws_kms_key.nhi.arn
}

# ---------------------------------------------------------------------------
# Log group for the NHI-collector Lambda
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "nhi_collector" {
  name              = "/aws/lambda/${var.name_prefix}-collector"
  retention_in_days = var.log_retention_in_days
  kms_key_id        = aws_kms_key.nhi.arn
}

# ---------------------------------------------------------------------------
# IAM role for the NHI-collector Lambda
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "nhi_collector_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "nhi_collector" {
  name               = "${var.name_prefix}-collector-role"
  assume_role_policy = data.aws_iam_policy_document.nhi_collector_assume_role.json
}

resource "aws_iam_role_policy_attachment" "nhi_collector_basic_execution" {
  role       = aws_iam_role.nhi_collector.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "nhi_collector_xray" {
  role       = aws_iam_role.nhi_collector.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

data "aws_iam_policy_document" "nhi_collector_permissions" {
  statement {
    sid    = "ReadIamCredentialReportAndRoles"
    effect = "Allow"
    actions = [
      "iam:GenerateCredentialReport",
      "iam:GetCredentialReport",
      "iam:ListRoles",
      "iam:ListOpenIDConnectProviders",
      "iam:ListSAMLProviders",
    ]
    resources = ["*"] # These IAM read/report actions do not support resource-level permissions
  }

  statement {
    sid       = "ListEnabledRegions"
    effect    = "Allow"
    actions   = ["ec2:DescribeRegions"]
    resources = ["*"] # DescribeRegions does not support resource-level permissions
  }

  statement {
    sid       = "ReadSecretsRotationStatus"
    effect    = "Allow"
    actions   = ["secretsmanager:ListSecrets"]
    resources = ["*"] # Read-only checks across a dynamic, account-wide secret list
  }

  statement {
    sid       = "PublishGovernanceMetrics"
    effect    = "Allow"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"] # PutMetricData does not support resource-level permissions

    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = [var.metric_namespace]
    }
  }

  statement {
    sid       = "SendToDlq"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.nhi_collector_dlq.arn]
  }
}

resource "aws_iam_role_policy" "nhi_collector_permissions" {
  name   = "nhi-scan-and-metric-publish"
  role   = aws_iam_role.nhi_collector.id
  policy = data.aws_iam_policy_document.nhi_collector_permissions.json
}

# ---------------------------------------------------------------------------
# NHI-collector Lambda: pulls the IAM credential report plus role/provider
# metadata, checks Secrets Manager rotation status per region, and
# publishes counts as CloudWatch metrics. Flagged identifiers (usernames,
# role names, secret names) are printed to the Lambda's own CloudWatch Logs
# for triage, since metrics only carry numbers, not names.
# ---------------------------------------------------------------------------
data "archive_file" "nhi_collector" {
  type        = "zip"
  source_file = "${path.module}/lambda/nhi_governance_collector.py"
  output_path = "${path.module}/lambda/nhi_governance_collector.zip"
}

# This function calls global IAM APIs and Secrets Manager ListSecrets
# across every enabled region — all public endpoints with no VPC endpoint
# benefit for a read-only governance scan, so a VPC would mean NAT gateways
# in every region for nothing.
#checkov:skip=CKV_AWS_117:Global IAM + multi-region Secrets Manager scan; a NAT gateway in every region would add cost with no security benefit here.
#checkov:skip=CKV_AWS_272:No AWS Signer code-signing pipeline exists for this account; out of scope for a public template repo since the profile ARN is account-specific.
resource "aws_lambda_function" "nhi_collector" {
  function_name = "${var.name_prefix}-collector"
  description   = "Pulls IAM credential report and role data, checks Secrets Manager rotation, and publishes NHI governance metrics."
  role          = aws_iam_role.nhi_collector.arn
  handler       = "nhi_governance_collector.handler"
  runtime       = "python3.12"
  timeout       = 180
  memory_size   = 256

  filename         = data.archive_file.nhi_collector.output_path
  source_code_hash = data.archive_file.nhi_collector.output_base64sha256

  reserved_concurrent_executions = 1
  kms_key_arn                    = aws_kms_key.nhi.arn

  dead_letter_config {
    target_arn = aws_sqs_queue.nhi_collector_dlq.arn
  }

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      METRIC_NAMESPACE     = var.metric_namespace
      STALE_THRESHOLD_DAYS = tostring(var.stale_threshold_days)
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.nhi_collector,
    aws_iam_role_policy_attachment.nhi_collector_basic_execution,
    aws_iam_role_policy_attachment.nhi_collector_xray,
    aws_iam_role_policy.nhi_collector_permissions,
  ]
}

# ---------------------------------------------------------------------------
# Schedule the NHI collector
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "nhi_collector_schedule" {
  name                = "${var.name_prefix}-collector-schedule"
  description         = "Triggers the NHI-governance-collector Lambda on a schedule."
  schedule_expression = var.governance_scan_schedule
}

resource "aws_cloudwatch_event_target" "nhi_collector_target" {
  rule = aws_cloudwatch_event_rule.nhi_collector_schedule.name
  arn  = aws_lambda_function.nhi_collector.arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.nhi_collector.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.nhi_collector_schedule.arn
}

# ---------------------------------------------------------------------------
# Dashboard
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_dashboard" "nhi_governance" {
  dashboard_name = "${var.name_prefix}-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 4
        height = 4
        properties = {
          title   = "Stale Access Keys (>${var.stale_threshold_days}d)"
          region  = data.aws_region.current.name
          view    = "singleValue"
          metrics = [[var.metric_namespace, "StaleAccessKeys", { stat = "Maximum", period = 86400 }]]
        }
      },
      {
        type   = "metric"
        x      = 4
        y      = 0
        width  = 4
        height = 4
        properties = {
          title   = "Users Without MFA"
          region  = data.aws_region.current.name
          view    = "singleValue"
          metrics = [[var.metric_namespace, "UsersWithoutMfa", { stat = "Maximum", period = 86400 }]]
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 0
        width  = 4
        height = 4
        properties = {
          title   = "Inactive IAM Users (>${var.stale_threshold_days}d)"
          region  = data.aws_region.current.name
          view    = "singleValue"
          metrics = [[var.metric_namespace, "InactiveIamUsers", { stat = "Maximum", period = 86400 }]]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 4
        height = 4
        properties = {
          title   = "Stale IAM Roles (>${var.stale_threshold_days}d)"
          region  = data.aws_region.current.name
          view    = "singleValue"
          metrics = [[var.metric_namespace, "StaleIamRoles", { stat = "Maximum", period = 86400 }]]
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 0
        width  = 4
        height = 4
        properties = {
          title   = "External-Trust IAM Roles"
          region  = data.aws_region.current.name
          view    = "singleValue"
          metrics = [[var.metric_namespace, "ExternalTrustRoles", { stat = "Maximum", period = 86400 }]]
        }
      },
      {
        type   = "metric"
        x      = 20
        y      = 0
        width  = 4
        height = 4
        properties = {
          title  = "Workload Identity Providers (OIDC+SAML)"
          region = data.aws_region.current.name
          view   = "singleValue"
          metrics = [
            [{ expression = "oidc+saml", label = "Identity Providers", id = "total" }],
            [var.metric_namespace, "OidcProviders", { stat = "Maximum", period = 86400, id = "oidc", visible = false }],
            [var.metric_namespace, "SamlProviders", { stat = "Maximum", period = 86400, id = "saml", visible = false }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 4
        width  = 12
        height = 6
        properties = {
          title  = "Access Keys: Total vs Stale (trend)"
          region = data.aws_region.current.name
          view   = "timeSeries"
          metrics = [
            [var.metric_namespace, "TotalActiveAccessKeys", { stat = "Maximum", period = 86400, label = "Total Active Keys" }],
            [var.metric_namespace, "StaleAccessKeys", { stat = "Maximum", period = 86400, label = "Stale Keys" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 4
        width  = 12
        height = 6
        properties = {
          title  = "IAM Roles: Total vs Stale (trend)"
          region = data.aws_region.current.name
          view   = "timeSeries"
          metrics = [
            [var.metric_namespace, "TotalIamRoles", { stat = "Maximum", period = 86400, label = "Total Roles" }],
            [var.metric_namespace, "StaleIamRoles", { stat = "Maximum", period = 86400, label = "Stale Roles" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 10
        width  = 12
        height = 6
        properties = {
          title  = "Secrets Manager – Secrets Without Rotation by Region"
          region = data.aws_region.current.name
          view   = "bar"
          metrics = [
            [{ expression = "SEARCH('{${var.metric_namespace},Region} MetricName=\"SecretsWithoutRotation\"', 'Maximum', 86400)", label = "No Rotation", id = "e1" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 10
        width  = 12
        height = 6
        properties = {
          title  = "Workload Identity Providers – OIDC vs SAML"
          region = data.aws_region.current.name
          view   = "bar"
          metrics = [
            [var.metric_namespace, "OidcProviders", { stat = "Maximum", period = 86400, label = "OIDC" }],
            [var.metric_namespace, "SamlProviders", { stat = "Maximum", period = 86400, label = "SAML" }],
          ]
        }
      },
    ]
  })
}
