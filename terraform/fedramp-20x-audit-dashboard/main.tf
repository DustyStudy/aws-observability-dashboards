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
# KMS key used to encrypt the audit-collector's log group, env vars, and DLQ
# ---------------------------------------------------------------------------
resource "aws_kms_key" "audit" {
  description         = "Encrypts FedRAMP 20x audit-collector resources for the ${var.name_prefix} dashboard"
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

resource "aws_kms_alias" "audit" {
  name          = "alias/${var.name_prefix}-observability"
  target_key_id = aws_kms_key.audit.key_id
}

# ---------------------------------------------------------------------------
# Dead-letter queue for the audit-collector Lambda
# ---------------------------------------------------------------------------
resource "aws_sqs_queue" "audit_collector_dlq" {
  name                      = "${var.name_prefix}-collector-dlq"
  message_retention_seconds = 1209600 # 14 days
  kms_master_key_id         = aws_kms_key.audit.id
}

# ---------------------------------------------------------------------------
# Log group for the audit-collector Lambda
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "audit_collector" {
  name              = "/aws/lambda/${var.name_prefix}-collector"
  retention_in_days = var.log_retention_in_days
  kms_key_id        = aws_kms_key.audit.arn
}

# ---------------------------------------------------------------------------
# IAM role for the audit-collector Lambda
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "audit_collector_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "audit_collector" {
  name               = "${var.name_prefix}-collector-role"
  assume_role_policy = data.aws_iam_policy_document.audit_collector_assume_role.json
}

resource "aws_iam_role_policy_attachment" "audit_collector_basic_execution" {
  role       = aws_iam_role.audit_collector.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "audit_collector_xray" {
  role       = aws_iam_role.audit_collector.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

data "aws_iam_policy_document" "audit_collector_permissions" {
  statement {
    sid    = "ReadConfigComplianceState"
    effect = "Allow"
    actions = [
      "config:DescribeConfigurationRecorders",
      "config:DescribeConfigurationRecorderStatus",
      "config:DescribeComplianceByConfigRule",
    ]
    resources = ["*"] # These read-only Config APIs do not support resource-level permissions
  }

  statement {
    sid    = "ReadCloudTrailHealth"
    effect = "Allow"
    actions = [
      "cloudtrail:DescribeTrails",
      "cloudtrail:GetTrailStatus",
    ]
    resources = ["*"] # Read-only trail-health checks across an account-wide, dynamic trail list
  }

  statement {
    sid    = "ReadBackupCoverage"
    effect = "Allow"
    actions = [
      "backup:ListBackupPlans",
      "backup:ListBackupJobs",
    ]
    resources = ["*"] # These read-only Backup APIs do not support resource-level permissions
  }

  statement {
    sid    = "ReadAccessAnalyzerFindings"
    effect = "Allow"
    actions = [
      "access-analyzer:ListAnalyzers",
      "access-analyzer:ListFindings",
    ]
    resources = ["*"] # Read-only checks across a dynamic, account-wide analyzer/finding list
  }

  statement {
    sid    = "ReadHighAvailabilityPosture"
    effect = "Allow"
    actions = [
      "rds:DescribeDBInstances",
      "autoscaling:DescribeAutoScalingGroups",
    ]
    resources = ["*"] # These read-only APIs do not support resource-level permissions
  }

  statement {
    sid       = "ReadAutoRemediationCoverage"
    effect    = "Allow"
    actions   = ["config:DescribeRemediationConfigurations"]
    resources = ["*"] # Read-only Config API scoped by rule name at call time, not by ARN
  }

  statement {
    sid    = "ReadNetworkSegmentationPosture"
    effect = "Allow"
    actions = [
      "ec2:DescribeVpcEndpoints",
      "ec2:DescribeVpcs",
      "ec2:DescribeNetworkAcls",
      "ec2:DescribeInstances",
    ]
    resources = ["*"] # These read-only EC2 APIs do not support resource-level permissions
  }

  statement {
    sid    = "ReadSecureCommunicationsPosture"
    effect = "Allow"
    actions = [
      "acm:ListCertificates",
      "acm:DescribeCertificate",
      "s3:ListAllMyBuckets",
      "s3:GetBucketPolicy",
    ]
    resources = ["*"] # Read-only checks across a dynamic, account-wide cert/bucket list
  }

  statement {
    sid       = "ReadSecurityHubScore"
    effect    = "Allow"
    actions   = ["securityhub:GetFindings"]
    resources = ["*"] # Read-only, account-wide finding query
  }

  statement {
    sid       = "ReadInspectorFindings"
    effect    = "Allow"
    actions   = ["inspector2:ListFindings"]
    resources = ["*"] # Read-only, account-wide finding query
  }

  statement {
    sid    = "ReadTrustedAdvisorChecks"
    effect = "Allow"
    actions = [
      "support:DescribeTrustedAdvisorChecks",
      "support:DescribeTrustedAdvisorCheckResult",
    ]
    resources = ["*"] # The Support API does not support resource-level permissions
  }

  statement {
    sid    = "ReadDetectorStatus"
    effect = "Allow"
    actions = [
      "guardduty:ListDetectors",
      "guardduty:GetDetector",
      "securityhub:DescribeHub",
      "inspector2:BatchGetAccountStatus",
    ]
    resources = ["*"] # Read-only status checks; none of these support resource-level permissions
  }

  statement {
    sid    = "ReadAccountEncryptionDefaults"
    effect = "Allow"
    actions = [
      "ec2:GetEbsEncryptionByDefault",
      "s3:GetAccountPublicAccessBlock",
    ]
    resources = ["*"] # Account-level settings, not per-resource
  }

  statement {
    sid       = "ReadPasswordPolicy"
    effect    = "Allow"
    actions   = ["iam:GetAccountPasswordPolicy"]
    resources = ["*"] # Account-level setting, not per-resource
  }

  statement {
    sid       = "ReadOwnAccountId"
    effect    = "Allow"
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"] # Required to scope the S3 account-level Block Public Access call
  }

  statement {
    sid       = "PublishAuditMetrics"
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
    resources = [aws_sqs_queue.audit_collector_dlq.arn]
  }
}

resource "aws_iam_role_policy" "audit_collector_permissions" {
  name   = "audit-evidence-read-and-metric-publish"
  role   = aws_iam_role.audit_collector.id
  policy = data.aws_iam_policy_document.audit_collector_permissions.json
}

# ---------------------------------------------------------------------------
# Audit-evidence collector Lambda: checks AWS Config recorder/rule
# compliance, CloudTrail health, AWS Backup plan coverage and recent job
# outcomes, and IAM Access Analyzer external-access findings, then publishes
# counts as CloudWatch metrics. Flagged resource identifiers are printed to
# the Lambda's own CloudWatch Logs for triage, since metrics only carry
# numbers, not names.
# ---------------------------------------------------------------------------
data "archive_file" "audit_collector" {
  type        = "zip"
  source_file = "${path.module}/lambda/fedramp20x_collector.py"
  output_path = "${path.module}/lambda/fedramp20x_collector.zip"
}

# This function calls global/regional read-only control-plane APIs (Config,
# CloudTrail, Backup, Access Analyzer) with no VPC endpoint benefit for a
# read-only audit-evidence scan, so a VPC would mean NAT gateways for nothing.
#checkov:skip=CKV_AWS_117:Read-only Config/CloudTrail/Backup/Access-Analyzer scan; a NAT gateway would add cost with no security benefit here.
#checkov:skip=CKV_AWS_272:No AWS Signer code-signing pipeline exists for this account; out of scope for a public template repo since the profile ARN is account-specific.
resource "aws_lambda_function" "audit_collector" {
  function_name = "${var.name_prefix}-collector"
  description   = "Checks AWS Config, CloudTrail, AWS Backup, and IAM Access Analyzer, and publishes FedRAMP 20x audit-evidence metrics."
  role          = aws_iam_role.audit_collector.arn
  handler       = "fedramp20x_collector.handler"
  runtime       = "python3.12"
  timeout       = 300
  memory_size   = 512

  filename         = data.archive_file.audit_collector.output_path
  source_code_hash = data.archive_file.audit_collector.output_base64sha256

  reserved_concurrent_executions = 1
  kms_key_arn                    = aws_kms_key.audit.arn

  dead_letter_config {
    target_arn = aws_sqs_queue.audit_collector_dlq.arn
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
    aws_cloudwatch_log_group.audit_collector,
    aws_iam_role_policy_attachment.audit_collector_basic_execution,
    aws_iam_role_policy_attachment.audit_collector_xray,
    aws_iam_role_policy.audit_collector_permissions,
  ]
}

# ---------------------------------------------------------------------------
# Schedule the audit collector
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "audit_collector_schedule" {
  name                = "${var.name_prefix}-collector-schedule"
  description         = "Triggers the FedRAMP 20x audit-evidence collector Lambda on a schedule."
  schedule_expression = var.audit_scan_schedule
}

resource "aws_cloudwatch_event_target" "audit_collector_target" {
  rule = aws_cloudwatch_event_rule.audit_collector_schedule.name
  arn  = aws_lambda_function.audit_collector.arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.audit_collector.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.audit_collector_schedule.arn
}

# ---------------------------------------------------------------------------
# Dashboard — combines this module's new metrics with metrics already
# published by the nhi-governance-dashboard, network-exposure-dashboard, and
# security-posture-dashboard modules (deploy those first, in the same
# account, or the widgets that read their namespaces will show no data).
# Every widget title carries its FedRAMP 20x KSI ID; see README.md.
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_dashboard" "fedramp_20x_audit" {
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
          title   = "Config Rules Non-Compliant (KSI-MLA-EVC, KSI-SVC-ACM)"
          region  = data.aws_region.current.name
          view    = "singleValue"
          metrics = [[var.metric_namespace, "ConfigRulesNonCompliant", { stat = "Maximum", period = 86400 }]]
        }
      },
      {
        type   = "metric"
        x      = 4
        y      = 0
        width  = 4
        height = 4
        properties = {
          title  = "CloudTrail Healthy: Multi-Region + Validated + Logging (KSI-MLA-OSM, KSI-MLA-LET)"
          region = data.aws_region.current.name
          view   = "singleValue"
          metrics = [
            [{ expression = "MIN([mr,val,log])", label = "CloudTrail Healthy (1=yes)", id = "healthy" }],
            [var.metric_namespace, "CloudTrailMultiRegionEnabled", { stat = "Maximum", period = 86400, id = "mr", visible = false }],
            [var.metric_namespace, "CloudTrailLogFileValidationEnabled", { stat = "Maximum", period = 86400, id = "val", visible = false }],
            [var.metric_namespace, "CloudTrailLoggingActive", { stat = "Maximum", period = 86400, id = "log", visible = false }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 0
        width  = 4
        height = 4
        properties = {
          title   = "Backup Jobs Failed, Last 24h (KSI-RPL-TRC)"
          region  = data.aws_region.current.name
          view    = "singleValue"
          metrics = [[var.metric_namespace, "BackupJobsFailed24h", { stat = "Sum", period = 86400 }]]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 4
        height = 4
        properties = {
          title   = "Access Analyzer External-Access Findings (KSI-IAM-SUS, KSI-CNA-MAT)"
          region  = data.aws_region.current.name
          view    = "singleValue"
          metrics = [[var.metric_namespace, "AccessAnalyzerExternalAccessFindings", { stat = "Maximum", period = 86400 }]]
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 0
        width  = 4
        height = 4
        properties = {
          title   = "Users Without MFA (KSI-IAM-APM)"
          region  = data.aws_region.current.name
          view    = "singleValue"
          metrics = [[var.nhi_governance_namespace, "UsersWithoutMfa", { stat = "Maximum", period = 86400 }]]
        }
      },
      {
        type   = "metric"
        x      = 20
        y      = 0
        width  = 4
        height = 4
        properties = {
          title  = "Secrets Without Rotation, All Regions (KSI-SVC-ASM)"
          region = data.aws_region.current.name
          view   = "singleValue"
          metrics = [
            [{ expression = "SUM(SEARCH('{${var.nhi_governance_namespace},Region} MetricName=\"SecretsWithoutRotation\"', 'Maximum', 86400))", label = "Secrets Without Rotation", id = "srot" }],
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
          title  = "AWS Config Rule Compliance (KSI-MLA-EVC, KSI-SVC-ACM)"
          region = data.aws_region.current.name
          view   = "timeSeries"
          metrics = [
            [var.metric_namespace, "ConfigRulesCompliant", { stat = "Maximum", period = 86400, label = "Compliant Rules" }],
            [var.metric_namespace, "ConfigRulesNonCompliant", { stat = "Maximum", period = 86400, label = "Non-Compliant Rules" }],
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
          title  = "Public-Facing Resource Exposure, All Regions (KSI-CNA-MAT, KSI-SVC-SIN)"
          region = data.aws_region.current.name
          view   = "timeSeries"
          metrics = [
            [{ expression = "SUM(SEARCH('{${var.network_exposure_namespace},Region} MetricName=\"PublicEc2Instances\"', 'Maximum', 86400))", label = "Public EC2", id = "pe" }],
            [{ expression = "SUM(SEARCH('{${var.network_exposure_namespace},Region} MetricName=\"PubliclyAccessibleRdsInstances\"', 'Maximum', 86400))", label = "Public RDS", id = "pr" }],
            [{ expression = "SUM(SEARCH('{${var.network_exposure_namespace},Region} MetricName=\"InternetFacingLoadBalancers\"', 'Maximum', 86400))", label = "Internet-Facing LBs", id = "pl" }],
            [{ expression = "SUM(SEARCH('{${var.network_exposure_namespace},Region} MetricName=\"PubliclyAccessibleS3Buckets\"', 'Maximum', 86400))", label = "Public S3 Buckets", id = "ps" }],
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
          title  = "Security Hub / GuardDuty High-Severity Findings (KSI-MLA-RVL, KSI-IAM-SUS)"
          region = data.aws_region.current.name
          view   = "timeSeries"
          metrics = [
            [var.security_observability_namespace, "SecurityHubCriticalFindings", { stat = "Sum", period = 86400, label = "Security Hub Critical" }],
            [var.security_observability_namespace, "SecurityHubHighFindings", { stat = "Sum", period = 86400, label = "Security Hub High" }],
            [var.security_observability_namespace, "GuardDutyHighSeverityFindings", { stat = "Sum", period = 86400, label = "GuardDuty High Severity" }],
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
          title  = "Backup Coverage & Job Outcomes (KSI-RPL-ABO, KSI-RPL-TRC)"
          region = data.aws_region.current.name
          view   = "timeSeries"
          metrics = [
            [var.metric_namespace, "BackupPlansCount", { stat = "Maximum", period = 86400, label = "Backup Plans" }],
            [var.metric_namespace, "BackupJobsSucceeded24h", { stat = "Sum", period = 86400, label = "Jobs Succeeded (24h)" }],
            [var.metric_namespace, "BackupJobsFailed24h", { stat = "Sum", period = 86400, label = "Jobs Failed (24h)" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 16
        width  = 12
        height = 6
        properties = {
          title  = "IAM Least Privilege – Stale Roles & External Trust (KSI-IAM-ELP, KSI-IAM-JIT)"
          region = data.aws_region.current.name
          view   = "bar"
          metrics = [
            [var.nhi_governance_namespace, "StaleIamRoles", { stat = "Maximum", period = 86400, label = "Stale IAM Roles" }],
            [var.nhi_governance_namespace, "ExternalTrustRoles", { stat = "Maximum", period = 86400, label = "External-Trust Roles" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 16
        width  = 12
        height = 6
        properties = {
          title  = "Open Security Group Rules by Region (KSI-CNA-RNT)"
          region = data.aws_region.current.name
          view   = "bar"
          metrics = [
            [{ expression = "SEARCH('{${var.network_exposure_namespace},Region} MetricName=\"OpenSecurityGroupRules\"', 'Maximum', 86400)", id = "osg", label = "Open Rules" }],
            [{ expression = "SEARCH('{${var.network_exposure_namespace},Region} MetricName=\"OpenSensitivePortRules\"', 'Maximum', 86400)", id = "ossp", label = "Open Sensitive-Port Rules" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 22
        width  = 4
        height = 4
        properties = {
          title   = "RDS Instances Not Multi-AZ (KSI-CNA-OFA)"
          region  = data.aws_region.current.name
          view    = "singleValue"
          metrics = [[var.metric_namespace, "RdsInstancesNotMultiAz", { stat = "Maximum", period = 86400 }]]
        }
      },
      {
        type   = "metric"
        x      = 4
        y      = 22
        width  = 4
        height = 4
        properties = {
          title   = "Auto Scaling Groups in a Single AZ (KSI-CNA-OFA)"
          region  = data.aws_region.current.name
          view    = "singleValue"
          metrics = [[var.metric_namespace, "AsgSingleAzCount", { stat = "Maximum", period = 86400 }]]
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 22
        width  = 4
        height = 4
        properties = {
          title   = "Config Rules Without Auto-Remediation (KSI-CNA-EIS)"
          region  = data.aws_region.current.name
          view    = "singleValue"
          metrics = [[var.metric_namespace, "ConfigRulesWithoutRemediation", { stat = "Maximum", period = 86400 }]]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 22
        width  = 4
        height = 4
        properties = {
          title   = "VPCs Relying on Default NACL Only (KSI-CNA-ULN)"
          region  = data.aws_region.current.name
          view    = "singleValue"
          metrics = [[var.metric_namespace, "VpcsWithoutCustomNacl", { stat = "Maximum", period = 86400 }]]
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 22
        width  = 4
        height = 4
        properties = {
          title   = "ACM Certificates Expiring Within 30 Days (KSI-SVC-VCM)"
          region  = data.aws_region.current.name
          view    = "singleValue"
          metrics = [[var.metric_namespace, "AcmCertsExpiringSoon", { stat = "Maximum", period = 86400 }]]
        }
      },
      {
        type   = "metric"
        x      = 20
        y      = 22
        width  = 4
        height = 4
        properties = {
          title   = "Security Hub Standards Score, % Passed (KSI-SVC-EIS)"
          region  = data.aws_region.current.name
          view    = "singleValue"
          metrics = [[var.metric_namespace, "SecurityHubStandardsScorePercent", { stat = "Maximum", period = 86400 }]]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 26
        width  = 12
        height = 6
        properties = {
          title  = "Config Auto-Remediation Coverage (KSI-CNA-EIS)"
          region = data.aws_region.current.name
          view   = "timeSeries"
          metrics = [
            [var.metric_namespace, "ConfigRulesWithRemediation", { stat = "Maximum", period = 86400, label = "Rules With Remediation" }],
            [var.metric_namespace, "ConfigRulesWithoutRemediation", { stat = "Maximum", period = 86400, label = "Rules Without Remediation" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 26
        width  = 12
        height = 6
        properties = {
          title  = "Inspector Findings, Account-Wide (KSI-SCR-MON)"
          region = data.aws_region.current.name
          view   = "timeSeries"
          metrics = [
            [var.metric_namespace, "Inspector2CriticalFindings", { stat = "Maximum", period = 86400, label = "Critical" }],
            [var.metric_namespace, "Inspector2HighFindings", { stat = "Maximum", period = 86400, label = "High" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 32
        width  = 12
        height = 6
        properties = {
          title  = "Network Segmentation & Secure Transport (KSI-CNA-ULN, KSI-SVC-VCM)"
          region = data.aws_region.current.name
          view   = "bar"
          metrics = [
            [var.metric_namespace, "VpcEndpointsCount", { stat = "Maximum", period = 86400, label = "VPC Endpoints" }],
            [var.metric_namespace, "S3BucketsWithoutSecureTransportPolicy", { stat = "Maximum", period = 86400, label = "S3 Buckets Without Secure-Transport Policy" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 32
        width  = 12
        height = 6
        properties = {
          title  = "Non-User Auth & Best-Practice Comparison (KSI-IAM-SNU, KSI-CNA-IBP)"
          region = data.aws_region.current.name
          view   = "bar"
          metrics = [
            [var.metric_namespace, "Ec2InstancesWithoutInstanceProfile", { stat = "Maximum", period = 86400, label = "EC2 Without Instance Profile" }],
            [var.metric_namespace, "TrustedAdvisorSecurityChecksFlagged", { stat = "Maximum", period = 86400, label = "Trusted Advisor Checks Flagged" }],
            [var.metric_namespace, "TrustedAdvisorAvailable", { stat = "Maximum", period = 86400, label = "Trusted Advisor Available (1=yes)" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 38
        width  = 4
        height = 4
        properties = {
          title  = "GuardDuty + Security Hub Detectors Running (KSI-MLA-OSM)"
          region = data.aws_region.current.name
          view   = "singleValue"
          metrics = [
            [{ expression = "MIN([gd,sh])", label = "Both Running (1=yes)", id = "detrun" }],
            [var.metric_namespace, "GuardDutyEnabled", { stat = "Maximum", period = 86400, id = "gd", visible = false }],
            [var.metric_namespace, "SecurityHubEnabled", { stat = "Maximum", period = 86400, id = "sh", visible = false }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 4
        y      = 38
        width  = 4
        height = 4
        properties = {
          title   = "Inspector Scanning Enabled (KSI-SCR-MON)"
          region  = data.aws_region.current.name
          view    = "singleValue"
          metrics = [[var.metric_namespace, "Inspector2Enabled", { stat = "Maximum", period = 86400 }]]
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 38
        width  = 4
        height = 4
        properties = {
          title   = "EBS Encryption By Default (KSI-SVC-SIN)"
          region  = data.aws_region.current.name
          view    = "singleValue"
          metrics = [[var.metric_namespace, "EbsEncryptionByDefaultEnabled", { stat = "Maximum", period = 86400 }]]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 38
        width  = 4
        height = 4
        properties = {
          title   = "RDS Instances Unencrypted (KSI-SVC-SIN)"
          region  = data.aws_region.current.name
          view    = "singleValue"
          metrics = [[var.metric_namespace, "RdsInstancesUnencrypted", { stat = "Maximum", period = 86400 }]]
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 38
        width  = 4
        height = 4
        properties = {
          title   = "S3 Account Block Public Access Enabled (KSI-SVC-SIN)"
          region  = data.aws_region.current.name
          view    = "singleValue"
          metrics = [[var.metric_namespace, "S3AccountBlockPublicAccessEnabled", { stat = "Maximum", period = 86400 }]]
        }
      },
      {
        type   = "metric"
        x      = 20
        y      = 38
        width  = 4
        height = 4
        properties = {
          title   = "IAM Password Policy Compliant (KSI-IAM-APM)"
          region  = data.aws_region.current.name
          view    = "singleValue"
          metrics = [[var.metric_namespace, "IamPasswordPolicyCompliant", { stat = "Maximum", period = 86400 }]]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 42
        width  = 4
        height = 4
        properties = {
          title   = "Inactive IAM Users (KSI-IAM-AAM)"
          region  = data.aws_region.current.name
          view    = "singleValue"
          metrics = [[var.nhi_governance_namespace, "InactiveIamUsers", { stat = "Maximum", period = 86400 }]]
        }
      },
    ]
  })
}
