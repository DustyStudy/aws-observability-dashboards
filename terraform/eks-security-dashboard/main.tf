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

data "aws_partition" "current" {}
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# KMS key used to encrypt every log group, the Lambda's env vars, and the DLQ
# ---------------------------------------------------------------------------
resource "aws_kms_key" "eks_security" {
  description         = "Encrypts log groups, Lambda env vars, and DLQ for the ${var.dashboard_name} dashboard"
  enable_key_rotation = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowAccountKeyAdministration"
        Effect    = "Allow"
        Principal = { AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root" }
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
            "kms:EncryptionContext:aws:logs:arn" = "arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:*"
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

resource "aws_kms_alias" "eks_security" {
  name          = "alias/${var.dashboard_name}-observability"
  target_key_id = aws_kms_key.eks_security.key_id
}

##############################################################################
# GuardDuty EKS Protection findings -> Logs
##############################################################################
resource "aws_cloudwatch_log_group" "guardduty_eks" {
  name              = "/aws/events/${var.dashboard_name}/guardduty-eks"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.eks_security.arn
}

resource "aws_cloudwatch_log_resource_policy" "guardduty_eks" {
  policy_name = "${var.dashboard_name}-guardduty-eks-policy"
  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowEventBridgeToCloudWatchLogs"
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource  = aws_cloudwatch_log_group.guardduty_eks.arn
    }]
  })
}

resource "aws_cloudwatch_event_rule" "guardduty_eks" {
  name        = "${var.dashboard_name}-guardduty-eks"
  description = "Routes GuardDuty findings for EKS clusters/workloads to Logs."
  event_pattern = jsonencode({
    source        = ["aws.guardduty"]
    "detail-type" = ["GuardDuty Finding"]
    detail = {
      resource = {
        resourceType = ["EKSCluster", "Container", "Kubernetes"]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "guardduty_eks" {
  rule = aws_cloudwatch_event_rule.guardduty_eks.name
  arn  = aws_cloudwatch_log_group.guardduty_eks.arn
}

##############################################################################
# Inspector v2 container image findings -> Logs
##############################################################################
resource "aws_cloudwatch_log_group" "inspector_eks" {
  name              = "/aws/events/${var.dashboard_name}/inspector-images"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.eks_security.arn
}

resource "aws_cloudwatch_log_resource_policy" "inspector_eks" {
  policy_name = "${var.dashboard_name}-inspector-policy"
  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowEventBridgeToCloudWatchLogs"
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource  = aws_cloudwatch_log_group.inspector_eks.arn
    }]
  })
}

resource "aws_cloudwatch_event_rule" "inspector_eks" {
  name        = "${var.dashboard_name}-inspector-images"
  description = "Routes Inspector2 CRITICAL/HIGH findings for ECR container images to Logs."
  event_pattern = jsonencode({
    source        = ["aws.inspector2"]
    "detail-type" = ["Inspector2 Finding"]
    detail = {
      severity = ["CRITICAL", "HIGH"]
      type     = ["PACKAGE_VULNERABILITY"]
    }
  })
}

resource "aws_cloudwatch_event_target" "inspector_eks" {
  rule = aws_cloudwatch_event_rule.inspector_eks.name
  arn  = aws_cloudwatch_log_group.inspector_eks.arn
}

##############################################################################
# Patch / version drift checker (Lambda + schedule)
##############################################################################
resource "aws_sqs_queue" "patch_check_dlq" {
  name                      = "${var.dashboard_name}-patch-check-dlq"
  message_retention_seconds = 1209600 # 14 days
  kms_master_key_id         = aws_kms_key.eks_security.arn
}

resource "aws_cloudwatch_log_group" "patch_check" {
  name              = "/aws/lambda/${var.dashboard_name}-patch-check"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.eks_security.arn
}

data "archive_file" "patch_check" {
  type             = "zip"
  source_file      = "${path.module}/lambda/eks_patch_drift_checker.py"
  output_path      = "${path.module}/build/eks_patch_drift_checker.zip"
  output_file_mode = "0666"
}

data "aws_iam_policy_document" "patch_check_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "patch_check" {
  name               = "${var.dashboard_name}-patch-check-role"
  assume_role_policy = data.aws_iam_policy_document.patch_check_assume_role.json
}

resource "aws_iam_role_policy_attachment" "patch_check_basic_execution" {
  role       = aws_iam_role.patch_check.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "patch_check_xray" {
  role       = aws_iam_role.patch_check.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

data "aws_iam_policy_document" "patch_check_permissions" {
  statement {
    sid       = "ListClustersAndNodegroups"
    effect    = "Allow"
    actions   = ["eks:ListClusters", "eks:ListNodegroups"]
    resources = ["*"] # These List actions do not support resource-level permissions
  }

  statement {
    sid       = "DescribeClusters"
    effect    = "Allow"
    actions   = ["eks:DescribeCluster"]
    resources = ["arn:${data.aws_partition.current.partition}:eks:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:cluster/*"]
  }

  statement {
    sid       = "DescribeNodegroups"
    effect    = "Allow"
    actions   = ["eks:DescribeNodegroup"]
    resources = ["arn:${data.aws_partition.current.partition}:eks:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:nodegroup/*"]
  }

  statement {
    sid       = "PublishDashboardMetrics"
    effect    = "Allow"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"] # PutMetricData does not support resource-level permissions

    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["EKS/Security"]
    }
  }

  statement {
    sid       = "SendToDlq"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.patch_check_dlq.arn]
  }
}

resource "aws_iam_role_policy" "patch_check_permissions" {
  name   = "eks-read-and-metrics"
  role   = aws_iam_role.patch_check.id
  policy = data.aws_iam_policy_document.patch_check_permissions.json
}

# This function calls the EKS and CloudWatch regional/global AWS APIs on a
# schedule; a VPC would only add NAT gateway cost with no security benefit
# for a read-only drift check.
#checkov:skip=CKV_AWS_117:Read-only EKS/CloudWatch API scan; a VPC would require a NAT gateway with no security benefit here.
#checkov:skip=CKV_AWS_272:No AWS Signer code-signing pipeline exists for this account; out of scope for a public template repo since the profile ARN is account-specific.
resource "aws_lambda_function" "patch_check" {
  function_name = "${var.dashboard_name}-patch-check"
  description   = "Scans every EKS cluster/nodegroup for version drift and stale AMIs, and publishes counts as CloudWatch metrics."
  role          = aws_iam_role.patch_check.arn
  handler       = "eks_patch_drift_checker.lambda_handler"
  runtime       = "python3.12"
  timeout       = 120
  memory_size   = 256

  filename         = data.archive_file.patch_check.output_path
  source_code_hash = data.archive_file.patch_check.output_base64sha256

  reserved_concurrent_executions = 1
  kms_key_arn                    = aws_kms_key.eks_security.arn

  dead_letter_config {
    target_arn = aws_sqs_queue.patch_check_dlq.arn
  }

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      LATEST_EKS_VERSION = var.latest_eks_version
      STALE_AMI_DAYS     = tostring(var.stale_ami_days)
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.patch_check,
    aws_iam_role_policy_attachment.patch_check_basic_execution,
    aws_iam_role_policy_attachment.patch_check_xray,
    aws_iam_role_policy.patch_check_permissions,
  ]
}

resource "aws_cloudwatch_event_rule" "patch_check_schedule" {
  name                = "${var.dashboard_name}-patch-check-schedule"
  schedule_expression = var.patch_check_schedule
}

resource "aws_cloudwatch_event_target" "patch_check_schedule" {
  rule = aws_cloudwatch_event_rule.patch_check_schedule.name
  arn  = aws_lambda_function.patch_check.arn
}

resource "aws_lambda_permission" "patch_check_schedule" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.patch_check.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.patch_check_schedule.arn
}

##############################################################################
# Dashboard
##############################################################################
resource "aws_cloudwatch_dashboard" "eks_security" {
  dashboard_name = var.dashboard_name
  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "text"
        x      = 0
        y      = 0
        width  = 24
        height = 2
        properties = {
          markdown = "## EKS Security Dashboard\nGuardDuty EKS Protection findings, Inspector container image vulnerabilities, and Kubernetes version/AMI patch drift across all clusters and nodegroups in this account/region."
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 2
        width  = 8
        height = 6
        properties = {
          title  = "Clusters with Version Drift"
          view   = "timeSeries"
          region = data.aws_region.current.name
          metrics = [
            ["EKS/Security", "ClusterVersionDriftCount", { stat = "Maximum" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 2
        width  = 8
        height = 6
        properties = {
          title  = "Nodegroups Needing Version Update"
          view   = "timeSeries"
          region = data.aws_region.current.name
          metrics = [
            ["EKS/Security", "NodegroupsNeedingUpdate", { stat = "Maximum" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 2
        width  = 8
        height = 6
        properties = {
          title  = "Nodegroups with Stale AMI (>${var.stale_ami_days}d)"
          view   = "timeSeries"
          region = data.aws_region.current.name
          metrics = [
            ["EKS/Security", "StaleAmiNodegroups", { stat = "Maximum" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 8
        width  = 8
        height = 6
        properties = {
          title  = "Nodegroup Health Issues"
          view   = "timeSeries"
          region = data.aws_region.current.name
          metrics = [
            ["EKS/Security", "NodegroupHealthIssues", { stat = "Sum" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 8
        width  = 8
        height = 6
        properties = {
          title  = "Clusters with Public-Only API Endpoint"
          view   = "timeSeries"
          region = data.aws_region.current.name
          metrics = [
            ["EKS/Security", "PublicOnlyEndpointClusters", { stat = "Maximum" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 8
        width  = 8
        height = 6
        properties = {
          title  = "Clusters Scanned (last run)"
          view   = "singleValue"
          region = data.aws_region.current.name
          metrics = [
            ["EKS/Security", "ClustersScanned", { stat = "Maximum" }]
          ]
        }
      },
      {
        type   = "log"
        x      = 0
        y      = 14
        width  = 12
        height = 8
        properties = {
          title  = "GuardDuty - EKS / Container Findings"
          view   = "table"
          region = data.aws_region.current.name
          query  = "SOURCE '${aws_cloudwatch_log_group.guardduty_eks.name}' | fields @timestamp, detail.type, detail.severity, detail.resource.eksClusterDetails.name, detail.title | sort @timestamp desc | limit 50"
        }
      },
      {
        type   = "log"
        x      = 12
        y      = 14
        width  = 12
        height = 8
        properties = {
          title  = "Inspector - Critical/High Image Findings"
          view   = "table"
          region = data.aws_region.current.name
          query  = "SOURCE '${aws_cloudwatch_log_group.inspector_eks.name}' | fields @timestamp, detail.severity, detail.title, detail.resources.0.details.awsEcrContainerImage.repositoryName | sort @timestamp desc | limit 50"
        }
      },
    ]
  })
}
