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
# KMS key used to encrypt the inventory-collector's log group, env vars, and DLQ
# ---------------------------------------------------------------------------
resource "aws_kms_key" "inventory" {
  description         = "Encrypts inventory-collector resources for the ${var.name_prefix} dashboard"
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

resource "aws_kms_alias" "inventory" {
  name          = "alias/${var.name_prefix}-observability"
  target_key_id = aws_kms_key.inventory.key_id
}

# ---------------------------------------------------------------------------
# Dead-letter queue for the inventory-collector Lambda
# ---------------------------------------------------------------------------
resource "aws_sqs_queue" "inventory_collector_dlq" {
  name                      = "${var.name_prefix}-collector-dlq"
  message_retention_seconds = 1209600 # 14 days
  kms_master_key_id         = aws_kms_key.inventory.arn
}

# ---------------------------------------------------------------------------
# Log group for the inventory-collector Lambda
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "inventory_collector" {
  name              = "/aws/lambda/${var.name_prefix}-collector"
  retention_in_days = var.log_retention_in_days
  kms_key_id        = aws_kms_key.inventory.arn
}

# ---------------------------------------------------------------------------
# IAM role for the inventory-collector Lambda
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "inventory_collector_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "inventory_collector" {
  name               = "${var.name_prefix}-collector-role"
  assume_role_policy = data.aws_iam_policy_document.inventory_collector_assume_role.json
}

resource "aws_iam_role_policy_attachment" "inventory_collector_basic_execution" {
  role       = aws_iam_role.inventory_collector.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "inventory_collector_xray" {
  role       = aws_iam_role.inventory_collector.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

data "aws_iam_policy_document" "inventory_collector_permissions" {
  statement {
    sid       = "ListEnabledRegions"
    effect    = "Allow"
    actions   = ["ec2:DescribeRegions"]
    resources = ["*"] # DescribeRegions does not support resource-level permissions
  }

  statement {
    sid       = "ListServiceMetricsAcrossRegions"
    effect    = "Allow"
    actions   = ["cloudwatch:ListMetrics"]
    resources = ["*"] # ListMetrics does not support resource-level permissions
  }

  statement {
    sid       = "PublishInventoryMetrics"
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
    resources = [aws_sqs_queue.inventory_collector_dlq.arn]
  }
}

resource "aws_iam_role_policy" "inventory_collector_permissions" {
  name   = "inventory-scan-and-metric-publish"
  role   = aws_iam_role.inventory_collector.id
  policy = data.aws_iam_policy_document.inventory_collector_permissions.json
}

# ---------------------------------------------------------------------------
# Inventory-collector Lambda: scans every enabled region for CloudWatch
# metric activity under each watched AI service's namespace, and
# republishes presence as a 1/0 custom metric per service/region.
# ---------------------------------------------------------------------------
data "archive_file" "inventory_collector" {
  type        = "zip"
  source_file = "${path.module}/../lambda/ai_service_inventory_collector.py"
  output_path = "${path.module}/build/ai_service_inventory_collector.zip"
}

# This function calls EC2 DescribeRegions and CloudWatch
# ListMetrics/PutMetricData across every enabled region — all regional
# public endpoints with no VPC endpoint coverage in every region, so a VPC
# would require NAT gateways in every region with no security benefit for a
# read-only inventory scan.
#checkov:skip=CKV_AWS_117:Multi-region public-endpoint scan; a VPC would require NAT gateways in every region with no security benefit here.
#checkov:skip=CKV_AWS_272:No AWS Signer code-signing pipeline exists for this account; out of scope for a public template repo since the profile ARN is account-specific.
resource "aws_lambda_function" "inventory_collector" {
  function_name = "${var.name_prefix}-collector"
  description   = "Scans enabled regions for AI service CloudWatch activity and publishes a presence metric per service/region."
  role          = aws_iam_role.inventory_collector.arn
  handler       = "ai_service_inventory_collector.handler"
  runtime       = "python3.12"
  timeout       = 300
  memory_size   = 256

  filename         = data.archive_file.inventory_collector.output_path
  source_code_hash = data.archive_file.inventory_collector.output_base64sha256

  reserved_concurrent_executions = 1
  kms_key_arn                    = aws_kms_key.inventory.arn

  dead_letter_config {
    target_arn = aws_sqs_queue.inventory_collector_dlq.arn
  }

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      METRIC_NAMESPACE = var.metric_namespace
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.inventory_collector,
    aws_iam_role_policy_attachment.inventory_collector_basic_execution,
    aws_iam_role_policy_attachment.inventory_collector_xray,
    aws_iam_role_policy.inventory_collector_permissions,
  ]
}

# ---------------------------------------------------------------------------
# Schedule the inventory collector
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "inventory_collector_schedule" {
  name                = "${var.name_prefix}-collector-schedule"
  description         = "Triggers the AI service inventory-collector Lambda on a schedule."
  schedule_expression = var.inventory_schedule
}

resource "aws_cloudwatch_event_target" "inventory_collector_target" {
  rule = aws_cloudwatch_event_rule.inventory_collector_schedule.name
  arn  = aws_lambda_function.inventory_collector.arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.inventory_collector.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.inventory_collector_schedule.arn
}

