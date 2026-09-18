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
# Logs Insights (log) widgets cannot be collapsed across accounts the way
# metrics can: a CloudWatch log widget takes a single "accountId" in its
# properties. So each log panel is emitted once per member account, with
# that account's ID in the title, laid out in a grid on the 24-column
# dashboard.
# -----------------------------------------------------------------------
locals {
  # All three metrics are 24h counts, so they sum across accounts (SUM).
  metric_specs = {
    sechub_critical = { metric_name = "SecurityHubCriticalFindings", stat = "Sum", id_prefix = "shc", label = "Security Hub – Critical (24h, org-wide)" }
    sechub_high     = { metric_name = "SecurityHubHighFindings", stat = "Sum", id_prefix = "shh", label = "Security Hub – High (24h, org-wide)" }
    gd_high         = { metric_name = "GuardDutyHighSeverityFindings", stat = "Sum", id_prefix = "gdh", label = "GuardDuty – High Severity (24h, org-wide)" }
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

  # The collector's log group names (see ../collector/main.tf).
  security_hub_log_group = "/observability/${var.name_prefix}/security-hub-findings"
  guardduty_log_group    = "/observability/${var.name_prefix}/guardduty-findings"

  # One entry per Logs Insights panel of the single-account dashboard.
  # Each is rendered once per member account (width/height are per copy).
  log_panels = [
    {
      title  = "Security Hub Findings – Volume (24h)"
      view   = "bar"
      width  = 6
      height = 4
      query  = "SOURCE '${local.security_hub_log_group}' | fields @timestamp | stats count(*) as findings"
    },
    {
      title  = "Security Hub Findings by Severity"
      view   = "pie"
      width  = 12
      height = 6
      query  = "SOURCE '${local.security_hub_log_group}' | fields detail.findings.0.Severity.Label as severity | stats count(*) as findings by severity | sort findings desc"
    },
    {
      title  = "Top Failing Security Hub Controls"
      view   = "bar"
      width  = 12
      height = 6
      query  = "SOURCE '${local.security_hub_log_group}' | filter detail.findings.0.Compliance.Status = 'FAILED' | fields detail.findings.0.GeneratorId as control | stats count(*) as failures by control | sort failures desc | limit 10"
    },
    {
      title  = "GuardDuty Findings by Type"
      view   = "bar"
      width  = 12
      height = 6
      query  = "SOURCE '${local.guardduty_log_group}' | fields detail.type as findingType | stats count(*) as findings by findingType | sort findings desc | limit 10"
    },
    {
      title  = "GuardDuty Findings Trend (hourly)"
      view   = "line"
      width  = 12
      height = 6
      query  = "SOURCE '${local.guardduty_log_group}' | stats count(*) as findings by bin(1h)"
    },
  ]

  # Log panels start below the 4-tall row of metric tiles. Each panel is a
  # block of per-account widgets, `24 / width` to a row; panels stack
  # vertically so no widgets overlap.
  metric_row_height = 4
  log_panel_per_row = [for p in local.log_panels : floor(24 / p.width)]
  log_panel_rows    = [for i, p in local.log_panels : ceil(length(var.member_account_ids) / local.log_panel_per_row[i])]
  log_panel_y = [
    for i, p in local.log_panels :
    local.metric_row_height + sum(concat([0], [for j in range(i) : local.log_panel_rows[j] * local.log_panels[j].height]))
  ]

  log_widgets = flatten([
    for pi, p in local.log_panels : [
      for ai, acct in var.member_account_ids : {
        type   = "log"
        x      = (ai % local.log_panel_per_row[pi]) * p.width
        y      = local.log_panel_y[pi] + floor(ai / local.log_panel_per_row[pi]) * p.height
        width  = p.width
        height = p.height
        properties = {
          title     = "${p.title} – ${acct}"
          accountId = acct
          region    = data.aws_region.current.name
          view      = p.view
          query     = p.query
        }
      }
    ]
  ])

  metric_widgets = [
    {
      type   = "metric"
      x      = 0
      y      = 0
      width  = 8
      height = 4
      properties = {
        title   = local.metric_specs.sechub_critical.label
        view    = "singleValue"
        region  = data.aws_region.current.name
        metrics = local.metric_groups.sechub_critical
      }
    },
    {
      type   = "metric"
      x      = 8
      y      = 0
      width  = 8
      height = 4
      properties = {
        title   = local.metric_specs.sechub_high.label
        view    = "singleValue"
        region  = data.aws_region.current.name
        metrics = local.metric_groups.sechub_high
      }
    },
    {
      type   = "metric"
      x      = 16
      y      = 0
      width  = 8
      height = 4
      properties = {
        title   = local.metric_specs.gd_high.label
        view    = "singleValue"
        region  = data.aws_region.current.name
        metrics = local.metric_groups.gd_high
      }
    },
  ]
}

resource "aws_cloudwatch_dashboard" "security_posture_org" {
  dashboard_name = var.dashboard_name

  dashboard_body = jsonencode({
    widgets = concat(local.metric_widgets, local.log_widgets)
  })
}
