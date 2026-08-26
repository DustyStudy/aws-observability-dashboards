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
# KMS key used to encrypt the cost-collector's log group, env vars, and DLQ
# ---------------------------------------------------------------------------
resource "aws_kms_key" "observability" {
  description         = "Encrypts cost-collector resources for the ${var.name_prefix} dashboard"
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

resource "aws_kms_alias" "observability" {
  name          = "alias/${var.name_prefix}-observability"
  target_key_id = aws_kms_key.observability.key_id
}

# ---------------------------------------------------------------------------
# Dead-letter queue for the cost-collector Lambda
# ---------------------------------------------------------------------------
resource "aws_sqs_queue" "cost_collector_dlq" {
  name                      = "${var.name_prefix}-cost-collector-dlq"
  message_retention_seconds = 1209600 # 14 days
  kms_master_key_id         = aws_kms_key.observability.arn
}

# ---------------------------------------------------------------------------
# Log group for the cost-collector Lambda
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "cost_collector" {
  name              = "/aws/lambda/${var.name_prefix}-cost-collector"
  retention_in_days = var.log_retention_in_days
  kms_key_id        = aws_kms_key.observability.arn
}

# ---------------------------------------------------------------------------
# IAM role for the cost-collector Lambda
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "cost_collector_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cost_collector" {
  name               = "${var.name_prefix}-cost-collector-role"
  assume_role_policy = data.aws_iam_policy_document.cost_collector_assume_role.json
}

resource "aws_iam_role_policy_attachment" "cost_collector_basic_execution" {
  role       = aws_iam_role.cost_collector.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "cost_collector_xray" {
  role       = aws_iam_role.cost_collector.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

data "aws_iam_policy_document" "cost_collector_permissions" {
  statement {
    sid       = "ReadCostExplorer"
    effect    = "Allow"
    actions   = ["ce:GetCostAndUsage"]
    resources = ["*"] # Cost Explorer does not support resource-level permissions
  }

  statement {
    sid       = "PublishCustomMetrics"
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
    resources = [aws_sqs_queue.cost_collector_dlq.arn]
  }
}

resource "aws_iam_role_policy" "cost_collector_permissions" {
  name   = "cost-explorer-read-and-metric-publish"
  role   = aws_iam_role.cost_collector.id
  policy = data.aws_iam_policy_document.cost_collector_permissions.json
}

# ---------------------------------------------------------------------------
# Cost-collector Lambda: pulls yesterday's Bedrock cost by usage type from
# Cost Explorer and republishes it as a CloudWatch custom metric so it can
# sit on the same dashboard as the native Bedrock usage metrics.
# ---------------------------------------------------------------------------
data "archive_file" "cost_collector" {
  type        = "zip"
  source_file = "${path.module}/lambda/bedrock_cost_collector.py"
  output_path = "${path.module}/lambda/bedrock_cost_collector.zip"
}

# Cost Explorer has no VPC endpoint/PrivateLink support, so placing this
# function in a VPC would require a NAT gateway with no security benefit
# for a read-only, scheduled cost lookup.
#checkov:skip=CKV_AWS_117:Cost Explorer has no VPC endpoint support; a NAT gateway would add cost with no security benefit here.
#checkov:skip=CKV_AWS_272:No AWS Signer code-signing pipeline exists for this account; out of scope for a public template repo since the profile ARN is account-specific.
resource "aws_lambda_function" "cost_collector" {
  function_name = "${var.name_prefix}-cost-collector"
  description   = "Publishes yesterday's Bedrock cost-by-usage-type from Cost Explorer as a CloudWatch metric."
  role          = aws_iam_role.cost_collector.arn
  handler       = "bedrock_cost_collector.handler"
  runtime       = "python3.12"
  timeout       = 30
  memory_size   = 128

  filename         = data.archive_file.cost_collector.output_path
  source_code_hash = data.archive_file.cost_collector.output_base64sha256

  reserved_concurrent_executions = 1
  kms_key_arn                    = aws_kms_key.observability.arn

  dead_letter_config {
    target_arn = aws_sqs_queue.cost_collector_dlq.arn
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
    aws_cloudwatch_log_group.cost_collector,
    aws_iam_role_policy_attachment.cost_collector_basic_execution,
    aws_iam_role_policy_attachment.cost_collector_xray,
    aws_iam_role_policy.cost_collector_permissions,
  ]
}

# ---------------------------------------------------------------------------
# Schedule the cost collector
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "cost_collector_schedule" {
  name                = "${var.name_prefix}-cost-collector-schedule"
  description         = "Triggers the Bedrock cost-collector Lambda on a schedule."
  schedule_expression = var.cost_collection_schedule
}

resource "aws_cloudwatch_event_target" "cost_collector_target" {
  rule = aws_cloudwatch_event_rule.cost_collector_schedule.name
  arn  = aws_lambda_function.cost_collector.arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cost_collector.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.cost_collector_schedule.arn
}

# ---------------------------------------------------------------------------
# Dashboard
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_dashboard" "bedrock_usage_cost" {
  dashboard_name = "${var.name_prefix}-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "Bedrock Invocations by Model"
          region  = data.aws_region.current.name
          view    = "timeSeries"
          stacked = true
          metrics = [
            [{ expression = "SEARCH('{AWS/Bedrock,ModelId} MetricName=\"Invocations\"', 'Sum', 300)", label = "Invocations", id = "e1" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Bedrock Token Volume (Input vs Output)"
          region = data.aws_region.current.name
          view   = "timeSeries"
          metrics = [
            [{ expression = "SEARCH('{AWS/Bedrock,ModelId} MetricName=\"InputTokenCount\"', 'Sum', 300)", label = "Input Tokens", id = "e1" }],
            [{ expression = "SEARCH('{AWS/Bedrock,ModelId} MetricName=\"OutputTokenCount\"', 'Sum', 300)", label = "Output Tokens", id = "e2" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Bedrock Invocation Latency (avg, ms)"
          region = data.aws_region.current.name
          view   = "timeSeries"
          metrics = [
            [{ expression = "SEARCH('{AWS/Bedrock,ModelId} MetricName=\"InvocationLatency\"', 'Average', 300)", label = "Avg Latency", id = "e1" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Bedrock Errors & Throttles"
          region = data.aws_region.current.name
          view   = "timeSeries"
          metrics = [
            [{ expression = "SEARCH('{AWS/Bedrock,ModelId} MetricName=\"InvocationClientErrors\"', 'Sum', 300)", label = "Client Errors", id = "e1" }],
            [{ expression = "SEARCH('{AWS/Bedrock,ModelId} MetricName=\"InvocationServerErrors\"', 'Sum', 300)", label = "Server Errors", id = "e2" }],
            [{ expression = "SEARCH('{AWS/Bedrock,ModelId} MetricName=\"InvocationThrottles\"', 'Sum', 300)", label = "Throttles", id = "e3" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 18
        height = 6
        properties = {
          title  = "Estimated Daily Cost by Usage Type"
          region = data.aws_region.current.name
          view   = "bar"
          metrics = [
            [{ expression = "SEARCH('{${var.metric_namespace},UsageType} MetricName=\"EstimatedDailyCostUSD\"', 'Maximum', 86400)", label = "Cost", id = "e1" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 18
        y      = 12
        width  = 6
        height = 6
        properties = {
          title  = "Estimated Total Daily Cost (USD)"
          region = data.aws_region.current.name
          view   = "singleValue"
          metrics = [
            [var.metric_namespace, "EstimatedDailyCostUSD", "UsageType", "TOTAL", { stat = "Maximum", period = 86400 }],
          ]
        }
      },
    ]
  })
}
