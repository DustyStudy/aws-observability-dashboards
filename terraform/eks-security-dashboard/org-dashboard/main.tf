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
# General recipe used throughout this file: for any un-dimensioned metric
# a collector publishes locally in every account, build one hidden
# per-account metric entry (each carrying its own "accountId") plus one
# visible SUM() expression that adds them all up. This is the same
# approach the CloudFormation version implements with a Lambda-backed
# custom resource — Terraform can do it natively with `for` because HCL
# has real loops and jsonencode(), unlike CloudFormation's DashboardBody
# string.
#
# The two Logs Insights panels (GuardDuty, Inspector) cannot be collapsed
# this way: a log widget takes a single accountId, so one widget per
# member account per panel is emitted instead.
# -----------------------------------------------------------------------
locals {
  metric_specs = {
    version_drift    = { metric_name = "ClusterVersionDriftCount", stat = "Maximum", id_prefix = "vd", label = "Clusters with Version Drift (org-wide)" }
    nodegroup_update = { metric_name = "NodegroupsNeedingUpdate", stat = "Maximum", id_prefix = "nu", label = "Nodegroups Needing Version Update (org-wide)" }
    stale_ami        = { metric_name = "StaleAmiNodegroups", stat = "Maximum", id_prefix = "sa", label = "Nodegroups with Stale AMI (org-wide)" }
    health_issues    = { metric_name = "NodegroupHealthIssues", stat = "Sum", id_prefix = "hi", label = "Nodegroup Health Issues (org-wide)" }
    public_endpoint  = { metric_name = "PublicOnlyEndpointClusters", stat = "Maximum", id_prefix = "po", label = "Clusters with Public-Only API Endpoint (org-wide)" }
    clusters_scanned = { metric_name = "ClustersScanned", stat = "Maximum", id_prefix = "cs", label = "Clusters Scanned (org-wide, last run)" }
  }

  # Every value here is a ready-to-use `metrics` array: N hidden
  # per-account entries + 1 visible SUM() expression summing all of them.
  # Split into two flat maps (accounts, totals) rather than one deeply
  # nested concat/for expression — simpler to read and to keep formatted.
  metric_group_accounts = {
    for key, spec in local.metric_specs : key => [
      for i, acct in var.member_account_ids : [
        var.metric_namespace, spec.metric_name,
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

  # Log panels: same log groups and queries as the single-account
  # dashboard; the log group names come from the collector's dashboard_name.
  guardduty_log_group = "/aws/events/${var.collector_dashboard_name}/guardduty-eks"
  inspector_log_group = "/aws/events/${var.collector_dashboard_name}/inspector-images"

  # Log section starts below the 2-row metric grid (y=2..13) and a 2-high
  # note (y=14..15); each account then takes one 8-high row: GuardDuty on
  # the left half, Inspector on the right half. No two widgets overlap.
  log_start_y = 16
  log_row_h   = 8

  log_widgets = flatten([
    for i, acct in var.member_account_ids : [
      {
        type   = "log"
        x      = 0
        y      = local.log_start_y + local.log_row_h * i
        width  = 12
        height = local.log_row_h
        properties = {
          title     = "GuardDuty - EKS / Container Findings - ${acct}"
          view      = "table"
          region    = data.aws_region.current.name
          accountId = acct
          query     = "SOURCE '${local.guardduty_log_group}' | fields @timestamp, detail.type, detail.severity, detail.resource.eksClusterDetails.name, detail.title | sort @timestamp desc | limit 50"
        }
      },
      {
        type   = "log"
        x      = 12
        y      = local.log_start_y + local.log_row_h * i
        width  = 12
        height = local.log_row_h
        properties = {
          title     = "Inspector - Critical/High Image Findings - ${acct}"
          view      = "table"
          region    = data.aws_region.current.name
          accountId = acct
          query     = "SOURCE '${local.inspector_log_group}' | fields @timestamp, detail.severity, detail.title, detail.resources.0.details.awsEcrContainerImage.repositoryName | sort @timestamp desc | limit 50"
        }
      },
    ]
  ])
}

resource "aws_cloudwatch_dashboard" "eks_security_org" {
  dashboard_name = var.dashboard_name

  dashboard_body = jsonencode({
    widgets = concat(
      [
        {
          type   = "text"
          x      = 0
          y      = 0
          width  = 24
          height = 2
          properties = {
            markdown = "## EKS Security Dashboard (org-wide)\nGuardDuty EKS Protection findings, Inspector container image vulnerabilities, and Kubernetes version/AMI patch drift across all clusters and nodegroups in ${length(var.member_account_ids)} member account(s). Counts are summed across accounts; finding logs are shown per account."
          }
        },
        {
          type   = "metric"
          x      = 0
          y      = 2
          width  = 8
          height = 6
          properties = {
            title   = local.metric_specs.version_drift.label
            view    = "timeSeries"
            region  = data.aws_region.current.name
            metrics = local.metric_groups.version_drift
          }
        },
        {
          type   = "metric"
          x      = 8
          y      = 2
          width  = 8
          height = 6
          properties = {
            title   = local.metric_specs.nodegroup_update.label
            view    = "timeSeries"
            region  = data.aws_region.current.name
            metrics = local.metric_groups.nodegroup_update
          }
        },
        {
          type   = "metric"
          x      = 16
          y      = 2
          width  = 8
          height = 6
          properties = {
            title   = local.metric_specs.stale_ami.label
            view    = "timeSeries"
            region  = data.aws_region.current.name
            metrics = local.metric_groups.stale_ami
          }
        },
        {
          type   = "metric"
          x      = 0
          y      = 8
          width  = 8
          height = 6
          properties = {
            title   = local.metric_specs.health_issues.label
            view    = "timeSeries"
            region  = data.aws_region.current.name
            metrics = local.metric_groups.health_issues
          }
        },
        {
          type   = "metric"
          x      = 8
          y      = 8
          width  = 8
          height = 6
          properties = {
            title   = local.metric_specs.public_endpoint.label
            view    = "timeSeries"
            region  = data.aws_region.current.name
            metrics = local.metric_groups.public_endpoint
          }
        },
        {
          type   = "metric"
          x      = 16
          y      = 8
          width  = 8
          height = 6
          properties = {
            title   = local.metric_specs.clusters_scanned.label
            view    = "singleValue"
            region  = data.aws_region.current.name
            metrics = local.metric_groups.clusters_scanned
          }
        },
        {
          type   = "text"
          x      = 0
          y      = 14
          width  = 24
          height = 2
          properties = {
            markdown = "### Findings by member account\nA Logs Insights widget can only query one account, so each member account has its own GuardDuty (left) and Inspector (right) panel."
          }
        },
      ],
      local.log_widgets,
    )
  })
}
