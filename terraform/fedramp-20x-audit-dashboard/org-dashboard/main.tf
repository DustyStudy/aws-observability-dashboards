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

# -----------------------------------------------------------------------
# Same "hidden per-account entry + one visible SUM() expression" recipe
# used by every org-dashboard module in this repo (see
# ../../nhi-governance-dashboard/org-dashboard/main.tf for the original).
# This dashboard reads four different namespaces (this module's own audit
# metrics, plus nhi-governance, network-exposure, and security-posture's),
# so each spec carries its own `namespace` instead of a single shared one.
# -----------------------------------------------------------------------
locals {
  metric_specs = {
    non_compliant    = { namespace = var.metric_namespace, metric_name = "ConfigRulesNonCompliant", stat = "Maximum", id_prefix = "cnc", label = "Config Rules Non-Compliant (KSI-MLA-EVC, KSI-SVC-ACM)" }
    compliant        = { namespace = var.metric_namespace, metric_name = "ConfigRulesCompliant", stat = "Maximum", id_prefix = "cc", label = "Compliant Rules" }
    ct_logging       = { namespace = var.metric_namespace, metric_name = "CloudTrailLoggingActive", stat = "Sum", id_prefix = "ctl", label = "Accounts With CloudTrail Logging Active (KSI-MLA-OSM, KSI-MLA-LET)" }
    backup_failed    = { namespace = var.metric_namespace, metric_name = "BackupJobsFailed24h", stat = "Sum", id_prefix = "bjf", label = "Jobs Failed (24h)" }
    backup_succeeded = { namespace = var.metric_namespace, metric_name = "BackupJobsSucceeded24h", stat = "Sum", id_prefix = "bjs", label = "Jobs Succeeded (24h)" }
    backup_plans     = { namespace = var.metric_namespace, metric_name = "BackupPlansCount", stat = "Maximum", id_prefix = "bpc", label = "Backup Plans" }
    aa_findings      = { namespace = var.metric_namespace, metric_name = "AccessAnalyzerExternalAccessFindings", stat = "Maximum", id_prefix = "aaf", label = "Access Analyzer External-Access Findings (KSI-IAM-SUS)" }
    no_mfa           = { namespace = var.nhi_governance_namespace, metric_name = "UsersWithoutMfa", stat = "Maximum", id_prefix = "mfa", label = "Users Without MFA, Org-Wide (KSI-IAM-APM)" }
    stale_roles      = { namespace = var.nhi_governance_namespace, metric_name = "StaleIamRoles", stat = "Maximum", id_prefix = "sr", label = "Stale IAM Roles, Org-Wide (KSI-IAM-ELP)" }
    external_trust   = { namespace = var.nhi_governance_namespace, metric_name = "ExternalTrustRoles", stat = "Maximum", id_prefix = "et", label = "External-Trust Roles" }
    sechub_critical  = { namespace = var.security_observability_namespace, metric_name = "SecurityHubCriticalFindings", stat = "Sum", id_prefix = "shc", label = "Security Hub Critical" }
    sechub_high      = { namespace = var.security_observability_namespace, metric_name = "SecurityHubHighFindings", stat = "Sum", id_prefix = "shh", label = "Security Hub High" }
    gd_high          = { namespace = var.security_observability_namespace, metric_name = "GuardDutyHighSeverityFindings", stat = "Sum", id_prefix = "gdh", label = "GuardDuty High Severity" }
    pub_ec2          = { namespace = var.network_exposure_namespace, metric_name = "PublicEc2Instances", stat = "Maximum", id_prefix = "pe", label = "Public EC2" }
    pub_rds          = { namespace = var.network_exposure_namespace, metric_name = "PubliclyAccessibleRdsInstances", stat = "Maximum", id_prefix = "pr", label = "Public RDS" }
    pub_lb           = { namespace = var.network_exposure_namespace, metric_name = "InternetFacingLoadBalancers", stat = "Maximum", id_prefix = "plb", label = "Internet-Facing LBs" }
    pub_s3           = { namespace = var.network_exposure_namespace, metric_name = "PubliclyAccessibleS3Buckets", stat = "Maximum", id_prefix = "ps3", label = "Public S3 Buckets" }
    rds_not_maz      = { namespace = var.metric_namespace, metric_name = "RdsInstancesNotMultiAz", stat = "Sum", id_prefix = "rma", label = "RDS Instances Not Multi-AZ, Org-Wide (KSI-CNA-OFA)" }
    asg_single_az    = { namespace = var.metric_namespace, metric_name = "AsgSingleAzCount", stat = "Sum", id_prefix = "asa", label = "Auto Scaling Groups in a Single AZ, Org-Wide (KSI-CNA-OFA)" }
    remediated       = { namespace = var.metric_namespace, metric_name = "ConfigRulesWithRemediation", stat = "Sum", id_prefix = "crr", label = "Rules With Remediation" }
    not_remediated   = { namespace = var.metric_namespace, metric_name = "ConfigRulesWithoutRemediation", stat = "Sum", id_prefix = "cnr", label = "Config Rules Without Auto-Remediation, Org-Wide (KSI-CNA-EIS)" }
    vpc_no_nacl      = { namespace = var.metric_namespace, metric_name = "VpcsWithoutCustomNacl", stat = "Sum", id_prefix = "vnn", label = "VPCs Relying on Default NACL Only, Org-Wide (KSI-CNA-ULN)" }
    vpc_endpoints    = { namespace = var.metric_namespace, metric_name = "VpcEndpointsCount", stat = "Sum", id_prefix = "vpe", label = "VPC Endpoints" }
    acm_expiring     = { namespace = var.metric_namespace, metric_name = "AcmCertsExpiringSoon", stat = "Sum", id_prefix = "ace", label = "ACM Certificates Expiring Within 30 Days, Org-Wide (KSI-SVC-VCM)" }
    s3_insecure      = { namespace = var.metric_namespace, metric_name = "S3BucketsWithoutSecureTransportPolicy", stat = "Sum", id_prefix = "s3i", label = "S3 Buckets Without Secure-Transport Policy" }
    sechub_score     = { namespace = var.metric_namespace, metric_name = "SecurityHubStandardsScorePercent", stat = "Average", id_prefix = "shs", label = "Security Hub Standards Score, Org-Wide Avg % Passed (KSI-SVC-EIS)" }
    inspector_crit   = { namespace = var.metric_namespace, metric_name = "Inspector2CriticalFindings", stat = "Sum", id_prefix = "icr", label = "Critical" }
    inspector_high   = { namespace = var.metric_namespace, metric_name = "Inspector2HighFindings", stat = "Sum", id_prefix = "ihi", label = "High" }
    ec2_no_profile   = { namespace = var.metric_namespace, metric_name = "Ec2InstancesWithoutInstanceProfile", stat = "Sum", id_prefix = "enp", label = "EC2 Without Instance Profile" }
    ta_flagged       = { namespace = var.metric_namespace, metric_name = "TrustedAdvisorSecurityChecksFlagged", stat = "Sum", id_prefix = "taf", label = "Trusted Advisor Checks Flagged" }
    gd_enabled       = { namespace = var.metric_namespace, metric_name = "GuardDutyEnabled", stat = "Sum", id_prefix = "gde", label = "Accounts With GuardDuty Enabled, Org-Wide (KSI-MLA-OSM)" }
    sh_enabled       = { namespace = var.metric_namespace, metric_name = "SecurityHubEnabled", stat = "Sum", id_prefix = "she", label = "Accounts With Security Hub Enabled, Org-Wide (KSI-MLA-OSM)" }
    insp_enabled     = { namespace = var.metric_namespace, metric_name = "Inspector2Enabled", stat = "Sum", id_prefix = "ine", label = "Accounts With Inspector Enabled, Org-Wide (KSI-SCR-MON)" }
    ebs_default      = { namespace = var.metric_namespace, metric_name = "EbsEncryptionByDefaultEnabled", stat = "Sum", id_prefix = "ebd", label = "Accounts With EBS Encryption By Default, Org-Wide (KSI-SVC-SIN)" }
    rds_unencrypted  = { namespace = var.metric_namespace, metric_name = "RdsInstancesUnencrypted", stat = "Sum", id_prefix = "rdu", label = "RDS Instances Unencrypted, Org-Wide (KSI-SVC-SIN)" }
    s3_block_public  = { namespace = var.metric_namespace, metric_name = "S3AccountBlockPublicAccessEnabled", stat = "Sum", id_prefix = "s3b", label = "Accounts With S3 Block Public Access Enabled, Org-Wide (KSI-SVC-SIN)" }
    password_policy  = { namespace = var.metric_namespace, metric_name = "IamPasswordPolicyCompliant", stat = "Sum", id_prefix = "pwp", label = "Accounts With Compliant Password Policy, Org-Wide (KSI-IAM-APM)" }
    inactive_users   = { namespace = var.nhi_governance_namespace, metric_name = "InactiveIamUsers", stat = "Sum", id_prefix = "iau", label = "Inactive IAM Users, Org-Wide (KSI-IAM-AAM)" }
  }

  # Every value here is a ready-to-use `metrics` array: N hidden
  # per-account entries + 1 visible SUM() expression summing all of them.
  metric_group_accounts = {
    for key, spec in local.metric_specs : key => [
      for i, acct in var.member_account_ids : [
        spec.namespace, spec.metric_name,
        { stat = spec.stat, period = 86400, accountId = acct, id = "${spec.id_prefix}${i}", visible = false }
      ]
    ]
  }

  metric_group_totals = {
    for key, spec in local.metric_specs : key => [[{
      expression = "SUM([${join(",", [for i, _ in var.member_account_ids : "${spec.id_prefix}${i}"])}])"
      label      = spec.label
      id         = "total_${spec.id_prefix}"
    }]]
  }

  metric_groups = {
    for key, spec in local.metric_specs : key => concat(local.metric_group_accounts[key], local.metric_group_totals[key])
  }

  # OpenSecurityGroupRules is dimensioned by Region within each account, so
  # this one stays as one SEARCH expression per account instead of
  # collapsing to a single org-wide sum — same approach
  # nhi-governance-dashboard's org-dashboard uses for SecretsWithoutRotation.
  open_sg_by_account_region_metrics = [
    for i, acct in var.member_account_ids : [{
      expression = "SEARCH('{${var.network_exposure_namespace},Region} MetricName=\\\"OpenSecurityGroupRules\\\"', 'Maximum', 86400)"
      id         = "osg${i}"
      accountId  = acct
      label      = "${acct} - $${PROP('Dim.Region')}"
    }]
  ]
}

resource "aws_cloudwatch_dashboard" "fedramp_20x_audit_org" {
  dashboard_name = var.dashboard_name

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 4
        height = 4
        properties = {
          title   = local.metric_specs.non_compliant.label
          view    = "singleValue"
          region  = data.aws_region.current.name
          metrics = local.metric_groups.non_compliant
        }
      },
      {
        type   = "metric"
        x      = 4
        y      = 0
        width  = 4
        height = 4
        properties = {
          title   = local.metric_specs.ct_logging.label
          view    = "singleValue"
          region  = data.aws_region.current.name
          metrics = local.metric_groups.ct_logging
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
          view    = "singleValue"
          region  = data.aws_region.current.name
          metrics = local.metric_groups.backup_failed
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 4
        height = 4
        properties = {
          title   = local.metric_specs.aa_findings.label
          view    = "singleValue"
          region  = data.aws_region.current.name
          metrics = local.metric_groups.aa_findings
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 0
        width  = 4
        height = 4
        properties = {
          title   = local.metric_specs.no_mfa.label
          view    = "singleValue"
          region  = data.aws_region.current.name
          metrics = local.metric_groups.no_mfa
        }
      },
      {
        type   = "metric"
        x      = 20
        y      = 0
        width  = 4
        height = 4
        properties = {
          title   = local.metric_specs.stale_roles.label
          view    = "singleValue"
          region  = data.aws_region.current.name
          metrics = local.metric_groups.stale_roles
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 4
        width  = 12
        height = 6
        properties = {
          title   = "AWS Config Rule Compliance, Org-Wide (KSI-MLA-EVC, KSI-SVC-ACM)"
          view    = "timeSeries"
          region  = data.aws_region.current.name
          metrics = concat(local.metric_groups.compliant, local.metric_groups.non_compliant)
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 4
        width  = 12
        height = 6
        properties = {
          title   = "Backup Coverage & Job Outcomes, Org-Wide (KSI-RPL-ABO, KSI-RPL-TRC)"
          view    = "timeSeries"
          region  = data.aws_region.current.name
          metrics = concat(local.metric_groups.backup_plans, local.metric_groups.backup_succeeded, local.metric_groups.backup_failed)
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 10
        width  = 12
        height = 6
        properties = {
          title   = "Security Hub / GuardDuty High-Severity Findings, Org-Wide (KSI-MLA-RVL, KSI-IAM-SUS)"
          view    = "timeSeries"
          region  = data.aws_region.current.name
          metrics = concat(local.metric_groups.sechub_critical, local.metric_groups.sechub_high, local.metric_groups.gd_high)
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 10
        width  = 12
        height = 6
        properties = {
          title   = "Public-Facing Resources, Org-Wide (KSI-CNA-MAT, KSI-SVC-SIN)"
          view    = "timeSeries"
          region  = data.aws_region.current.name
          metrics = concat(local.metric_groups.pub_ec2, local.metric_groups.pub_rds, local.metric_groups.pub_lb, local.metric_groups.pub_s3)
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 16
        width  = 12
        height = 6
        properties = {
          title   = "Open Security Group Rules by Account/Region (KSI-CNA-RNT)"
          view    = "bar"
          region  = data.aws_region.current.name
          metrics = local.open_sg_by_account_region_metrics
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 16
        width  = 12
        height = 6
        properties = {
          title   = "External-Trust IAM Roles, Org-Wide (KSI-IAM-JIT)"
          view    = "timeSeries"
          region  = data.aws_region.current.name
          metrics = local.metric_groups.external_trust
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 22
        width  = 4
        height = 4
        properties = {
          title   = local.metric_specs.rds_not_maz.label
          view    = "singleValue"
          region  = data.aws_region.current.name
          metrics = local.metric_groups.rds_not_maz
        }
      },
      {
        type   = "metric"
        x      = 4
        y      = 22
        width  = 4
        height = 4
        properties = {
          title   = local.metric_specs.asg_single_az.label
          view    = "singleValue"
          region  = data.aws_region.current.name
          metrics = local.metric_groups.asg_single_az
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 22
        width  = 4
        height = 4
        properties = {
          title   = local.metric_specs.not_remediated.label
          view    = "singleValue"
          region  = data.aws_region.current.name
          metrics = local.metric_groups.not_remediated
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 22
        width  = 4
        height = 4
        properties = {
          title   = local.metric_specs.vpc_no_nacl.label
          view    = "singleValue"
          region  = data.aws_region.current.name
          metrics = local.metric_groups.vpc_no_nacl
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 22
        width  = 4
        height = 4
        properties = {
          title   = local.metric_specs.acm_expiring.label
          view    = "singleValue"
          region  = data.aws_region.current.name
          metrics = local.metric_groups.acm_expiring
        }
      },
      {
        type   = "metric"
        x      = 20
        y      = 22
        width  = 4
        height = 4
        properties = {
          title   = local.metric_specs.sechub_score.label
          view    = "singleValue"
          region  = data.aws_region.current.name
          metrics = local.metric_groups.sechub_score
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 26
        width  = 12
        height = 6
        properties = {
          title   = "Config Auto-Remediation Coverage, Org-Wide (KSI-CNA-EIS)"
          view    = "timeSeries"
          region  = data.aws_region.current.name
          metrics = concat(local.metric_groups.remediated, local.metric_groups.not_remediated)
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 26
        width  = 12
        height = 6
        properties = {
          title   = "Inspector Findings, Org-Wide (KSI-SCR-MON)"
          view    = "timeSeries"
          region  = data.aws_region.current.name
          metrics = concat(local.metric_groups.inspector_crit, local.metric_groups.inspector_high)
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 32
        width  = 12
        height = 6
        properties = {
          title   = "Non-User Auth & Best-Practice Comparison, Org-Wide (KSI-IAM-SNU, KSI-CNA-IBP)"
          view    = "timeSeries"
          region  = data.aws_region.current.name
          metrics = concat(local.metric_groups.ec2_no_profile, local.metric_groups.ta_flagged)
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 32
        width  = 12
        height = 6
        properties = {
          title   = "Network Segmentation & Secure Transport, Org-Wide (KSI-CNA-ULN, KSI-SVC-VCM)"
          view    = "timeSeries"
          region  = data.aws_region.current.name
          metrics = concat(local.metric_groups.vpc_endpoints, local.metric_groups.s3_insecure)
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 38
        width  = 4
        height = 4
        properties = {
          title   = local.metric_specs.gd_enabled.label
          view    = "singleValue"
          region  = data.aws_region.current.name
          metrics = local.metric_groups.gd_enabled
        }
      },
      {
        type   = "metric"
        x      = 4
        y      = 38
        width  = 4
        height = 4
        properties = {
          title   = local.metric_specs.sh_enabled.label
          view    = "singleValue"
          region  = data.aws_region.current.name
          metrics = local.metric_groups.sh_enabled
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 38
        width  = 4
        height = 4
        properties = {
          title   = local.metric_specs.insp_enabled.label
          view    = "singleValue"
          region  = data.aws_region.current.name
          metrics = local.metric_groups.insp_enabled
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 38
        width  = 4
        height = 4
        properties = {
          title   = local.metric_specs.ebs_default.label
          view    = "singleValue"
          region  = data.aws_region.current.name
          metrics = local.metric_groups.ebs_default
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 38
        width  = 4
        height = 4
        properties = {
          title   = local.metric_specs.rds_unencrypted.label
          view    = "singleValue"
          region  = data.aws_region.current.name
          metrics = local.metric_groups.rds_unencrypted
        }
      },
      {
        type   = "metric"
        x      = 20
        y      = 38
        width  = 4
        height = 4
        properties = {
          title   = local.metric_specs.s3_block_public.label
          view    = "singleValue"
          region  = data.aws_region.current.name
          metrics = local.metric_groups.s3_block_public
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 42
        width  = 4
        height = 4
        properties = {
          title   = local.metric_specs.password_policy.label
          view    = "singleValue"
          region  = data.aws_region.current.name
          metrics = local.metric_groups.password_policy
        }
      },
      {
        type   = "metric"
        x      = 4
        y      = 42
        width  = 4
        height = 4
        properties = {
          title   = local.metric_specs.inactive_users.label
          view    = "singleValue"
          region  = data.aws_region.current.name
          metrics = local.metric_groups.inactive_users
        }
      },
    ]
  })
}
