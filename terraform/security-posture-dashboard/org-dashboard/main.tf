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
# With no member_account_ids the metric tiles are instead CloudWatch
# Metrics Insights queries over every account linked to this monitoring
# account (see `all_accounts` below).
#
# Logs Insights (log) widgets cannot be collapsed across accounts the way
# metrics can: a CloudWatch log widget takes a single "accountId" in its
# properties, and Metrics Insights does not apply to logs. So each log
# panel is emitted once per log account (log_account_ids, or
# member_account_ids when that is empty), with that account's ID in the
# title, laid out in a grid on the 24-column dashboard.
# -----------------------------------------------------------------------
locals {
  # With no member_account_ids the dashboard queries every account linked to
  # this monitoring account through CloudWatch Metrics Insights
  # (SELECT ... FROM SCHEMA(...)) instead of listing accounts one by one, so
  # the metric tiles are not bound by the per-widget metric limit. With a
  # list, they keep the explicit per-account approach below.
  all_accounts = length(var.member_account_ids) == 0

  # Accounts that get per-account log panels. Explicit mode without
  # log_account_ids keeps the original behavior (log panels for every
  # member account); all-accounts mode without log_account_ids has none.
  log_accounts = length(var.log_account_ids) > 0 ? var.log_account_ids : var.member_account_ids

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
    for key, spec in local.metric_specs : key => [
      for _ in [1] : [{
        expression = "SUM([${join(",", [for i, _ in var.member_account_ids : "${spec.id_prefix}${i}"])}])"
        label      = spec.label
        id         = "total_${spec.id_prefix}"
      }] if !local.all_accounts
    ]
  }

  metric_group_insights = {
    for key, spec in local.metric_specs : key => [
      for _ in [1] : [{
        expression = "SELECT SUM(${spec.metric_name}) FROM SCHEMA(\"${var.metric_namespace}\")"
        label      = spec.label
        id         = "total_${spec.id_prefix}"
        period     = 86400
      }] if local.all_accounts
    ]
  }

  metric_groups = {
    for key, spec in local.metric_specs : key => concat(
      local.metric_group_accounts[key],
      local.metric_group_totals[key],
      local.metric_group_insights[key],
    )
  }

  # The collector's log group names (see ../collector/main.tf).
  security_hub_log_group = "/observability/${var.name_prefix}/security-hub-findings"
  guardduty_log_group    = "/observability/${var.name_prefix}/guardduty-findings"

  # One entry per Logs Insights panel of the single-account dashboard.
  # Each is rendered once per log account (width/height are per copy).
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
  log_panel_rows    = [for i, p in local.log_panels : ceil(length(local.log_accounts) / local.log_panel_per_row[i])]
  log_panel_y = [
    for i, p in local.log_panels :
    local.metric_row_height + sum(concat([0], [for j in range(i) : local.log_panel_rows[j] * local.log_panels[j].height]))
  ]

  log_widgets = flatten([
    for pi, p in local.log_panels : [
      for ai, acct in local.log_accounts : {
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

  # In all-accounts mode with no log_account_ids there are no log panels;
  # a single text widget makes that gap visible instead of leaving the
  # dashboard looking complete.
  log_note_widgets = [
    for _ in [1] : {
      type   = "text"
      x      = 0
      y      = local.metric_row_height
      width  = 24
      height = 2
      properties = {
        markdown = "Log panels are per-account: set `log_account_ids` to add per-account Logs Insights panels."
      }
    } if local.all_accounts && length(local.log_accounts) == 0
  ]
}

resource "aws_cloudwatch_dashboard" "security_posture_org" {
  dashboard_name = var.dashboard_name

  dashboard_body = jsonencode({
    widgets = concat(local.metric_widgets, local.log_note_widgets, local.log_widgets)
  })

  lifecycle {
    # 3 metric widgets + 5 log widgets per log account must stay within the
    # 500-widget dashboard limit. (Checked here rather than in a variable
    # validation because the effective list depends on two variables.)
    precondition {
      condition     = length(local.log_accounts) <= 99
      error_message = "A dashboard holds at most 500 widgets: 3 metric widgets plus 5 log widgets per log account, so at most 99 accounts can have log panels. Set log_account_ids (or, when it is empty, member_account_ids) to at most 99 accounts, or split them across several org-dashboards."
    }
  }
}
