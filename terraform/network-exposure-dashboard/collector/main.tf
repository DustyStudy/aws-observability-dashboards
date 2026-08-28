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
# KMS key used to encrypt the exposure-collector's log group, env vars, and DLQ
# ---------------------------------------------------------------------------
resource "aws_kms_key" "exposure" {
  description         = "Encrypts exposure-collector resources for the ${var.name_prefix} dashboard"
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

resource "aws_kms_alias" "exposure" {
  name          = "alias/${var.name_prefix}-observability"
  target_key_id = aws_kms_key.exposure.key_id
}

# ---------------------------------------------------------------------------
# Dead-letter queue for the exposure-collector Lambda
# ---------------------------------------------------------------------------
resource "aws_sqs_queue" "exposure_collector_dlq" {
  name                      = "${var.name_prefix}-collector-dlq"
  message_retention_seconds = 1209600 # 14 days
  kms_master_key_id         = aws_kms_key.exposure.arn
}

# ---------------------------------------------------------------------------
# Log group for the exposure-collector Lambda
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "exposure_collector" {
  name              = "/aws/lambda/${var.name_prefix}-collector"
  retention_in_days = var.log_retention_in_days
  kms_key_id        = aws_kms_key.exposure.arn
}

# ---------------------------------------------------------------------------
# IAM role for the exposure-collector Lambda
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "exposure_collector_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "exposure_collector" {
  name               = "${var.name_prefix}-collector-role"
  assume_role_policy = data.aws_iam_policy_document.exposure_collector_assume_role.json
}

resource "aws_iam_role_policy_attachment" "exposure_collector_basic_execution" {
  role       = aws_iam_role.exposure_collector.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "exposure_collector_xray" {
  role       = aws_iam_role.exposure_collector.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

# Every "*" resource below is on an action AWS documents as not supporting
# resource-level permissions (Describe*, List*, PutMetricData, etc.) — see
# the inline comment on each statement.
#checkov:skip=CKV_AWS_356:Every "*" here is on a Describe/List/PutMetricData-style action with no resource-level permission support; see per-statement comments.
data "aws_iam_policy_document" "exposure_collector_permissions" {
  statement {
    sid       = "ListEnabledRegions"
    effect    = "Allow"
    actions   = ["ec2:DescribeRegions"]
    resources = ["*"] # DescribeRegions does not support resource-level permissions
  }

  statement {
    sid    = "DescribeNetworkAndComputeResources"
    effect = "Allow"
    actions = [
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeInstances",
      "rds:DescribeDBInstances",
      "elasticloadbalancing:DescribeLoadBalancers",
    ]
    resources = ["*"] # These Describe/List actions do not support resource-level permissions
  }

  statement {
    sid    = "ReadS3ExposurePosture"
    effect = "Allow"
    actions = [
      "s3:ListAllMyBuckets",
      "s3:GetBucketLocation",
      "s3:GetBucketPolicyStatus",
      "s3:GetBucketAcl",
    ]
    resources = ["*"] # Read-only checks across a dynamic, account-wide bucket list
  }

  statement {
    sid       = "PublishExposureMetrics"
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
    resources = [aws_sqs_queue.exposure_collector_dlq.arn]
  }
}

resource "aws_iam_role_policy" "exposure_collector_permissions" {
  name   = "exposure-scan-and-metric-publish"
  role   = aws_iam_role.exposure_collector.id
  policy = data.aws_iam_policy_document.exposure_collector_permissions.json
}

# ---------------------------------------------------------------------------
# Exposure-collector Lambda: scans every enabled region for internet-open
# security group rules, publicly reachable EC2/RDS/load balancers, and
# (account-wide) publicly exposed S3 buckets; republishes counts as
# CloudWatch metrics. Full resource identifiers for anything flagged are
# printed to the Lambda's own CloudWatch Logs for triage, since metrics
# only carry numbers, not names.
# ---------------------------------------------------------------------------
data "archive_file" "exposure_collector" {
  type        = "zip"
  source_file = "${path.module}/../lambda/network_exposure_collector.py"
  output_path = "${path.module}/build/network_exposure_collector.zip"
}

# This function calls EC2/RDS/ELB Describe APIs and CloudWatch
# PutMetricData across every enabled region plus global S3 APIs — all
# regional/global public endpoints, so a VPC would require NAT gateways in
# every region with no security benefit for a read-only exposure scan.
#checkov:skip=CKV_AWS_117:Multi-region public-endpoint scan; a NAT gateway in every region would add cost with no security benefit here.
#checkov:skip=CKV_AWS_272:No AWS Signer code-signing pipeline exists for this account; out of scope for a public template repo since the profile ARN is account-specific.
resource "aws_lambda_function" "exposure_collector" {
  function_name = "${var.name_prefix}-collector"
  description   = "Scans enabled regions for internet-exposed network/compute resources and publishes counts per region."
  role          = aws_iam_role.exposure_collector.arn
  handler       = "network_exposure_collector.handler"
  runtime       = "python3.12"
  timeout       = 300
  memory_size   = 256

  filename         = data.archive_file.exposure_collector.output_path
  source_code_hash = data.archive_file.exposure_collector.output_base64sha256

  reserved_concurrent_executions = 1
  kms_key_arn                    = aws_kms_key.exposure.arn

  dead_letter_config {
    target_arn = aws_sqs_queue.exposure_collector_dlq.arn
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
    aws_cloudwatch_log_group.exposure_collector,
    aws_iam_role_policy_attachment.exposure_collector_basic_execution,
    aws_iam_role_policy_attachment.exposure_collector_xray,
    aws_iam_role_policy.exposure_collector_permissions,
  ]
}

# ---------------------------------------------------------------------------
# Schedule the exposure collector
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "exposure_collector_schedule" {
  name                = "${var.name_prefix}-collector-schedule"
  description         = "Triggers the network-exposure-collector Lambda on a schedule."
  schedule_expression = var.exposure_scan_schedule
}

resource "aws_cloudwatch_event_target" "exposure_collector_target" {
  rule = aws_cloudwatch_event_rule.exposure_collector_schedule.name
  arn  = aws_lambda_function.exposure_collector.arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.exposure_collector.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.exposure_collector_schedule.arn
}

