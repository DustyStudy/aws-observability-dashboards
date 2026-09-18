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
# Same "one entry per account" recipe used by every org-dashboard module in
# this repo (see ../../nhi-governance-dashboard/org-dashboard/main.tf for
# the original), adapted to this dashboard's three widget shapes:
#
#   1. 24h tiles     - every network-exposure metric is dimensioned by
#                      Region. Explicit mode: each account gets one hidden
#                      SEARCH (carrying its own "accountId") and one visible
#                      SUM() adds them all up into a single org-wide number.
#                      All-accounts mode: one Metrics Insights query,
#                      SELECT SUM(metric) FROM SCHEMA(ns, Region), which sums
#                      every region of every linked account.
#   2. "by Region"   - explicit mode: one VISIBLE SEARCH per account, so
#      bar charts      per-account x per-region stays readable. All-accounts
#                      mode: SELECT SUM(metric) ... GROUP BY Region, i.e. one
#                      bar per region summed across the org (a per-account
#                      breakdown would be cut off at 500 series per query).
#   3. VPC Flow Logs - Logs Insights widgets cannot collapse across
#      panels           accounts (a log widget takes a single accountId), so
#                      every panel is repeated once per log account: the
#                      log_account_ids if set, else member_account_ids. In
#                      all-accounts mode with no log_account_ids there are no
#                      log panels (a text widget explains how to add them).
#
# Metric names/stats/periods come straight from the single-account
# dashboard (../main.tf) and the collector Lambda that publishes them.
# -----------------------------------------------------------------------
locals {
  # With no member_account_ids the dashboard queries every account linked to
  # this monitoring account through CloudWatch Metrics Insights instead of
  # listing accounts one by one, so it is not bound by the per-widget metric
  # limit. With a list, it keeps the explicit per-account approach below.
  all_accounts = length(var.member_account_ids) == 0

  # 24h tiles: 'Sum' over 86400s, exactly like the single-account tiles.
  tile_specs = {
    open_sensitive = { metric_name = "OpenSensitivePortRules", id_prefix = "tosp", label = "Open Rules (org-wide)", title = "Open SG Rules – Sensitive Ports (24h, org-wide)" }
    public_ec2     = { metric_name = "PublicEc2Instances", id_prefix = "tpe", label = "Public Instances (org-wide)", title = "Public EC2 Instances (24h, org-wide)" }
    public_rds     = { metric_name = "PubliclyAccessibleRdsInstances", id_prefix = "tpr", label = "Public RDS (org-wide)", title = "Publicly Accessible RDS (24h, org-wide)" }
    public_lb      = { metric_name = "InternetFacingLoadBalancers", id_prefix = "tlb", label = "Public LBs (org-wide)", title = "Internet-Facing Load Balancers (24h, org-wide)" }
  }

  # "by Region" bar charts: explicit mode uses SEARCH with 'Maximum' over
  # 86400s, one per account; all-accounts mode sums per Region.
  bar_specs = {
    open_sensitive = { metric_name = "OpenSensitivePortRules", id_prefix = "bosp", title = "Open SG Rules (Sensitive Ports) by Account/Region" }
    public_ec2     = { metric_name = "PublicEc2Instances", id_prefix = "bpe", title = "Public EC2 Instances by Account/Region" }
    public_rds     = { metric_name = "PubliclyAccessibleRdsInstances", id_prefix = "bpr", title = "Publicly Accessible RDS by Account/Region" }
    public_lb      = { metric_name = "InternetFacingLoadBalancers", id_prefix = "blb", title = "Internet-Facing Load Balancers by Account/Region" }
    public_s3      = { metric_name = "PubliclyAccessibleS3Buckets", id_prefix = "bs3", title = "Publicly Accessible S3 Buckets by Account/(Bucket Home) Region" }
  }

  # Every value here is a ready-to-use `metrics` array. Explicit mode: N
  # hidden per-account SEARCH entries + 1 visible SUM() expression summing
  # all of them. All-accounts mode: one Metrics Insights query. Split into
  # flat maps (accounts, totals, insights) rather than one deeply nested
  # concat/for expression - simpler to read and to keep formatted. The
  # `[for _ in [1] : ... if cond]` fragments are empty when cond is false;
  # a `cond ? a : b` between differently shaped lists would fail to type-check.
  tile_group_accounts = {
    for key, spec in local.tile_specs : key => [
      for i, acct in var.member_account_ids : [{
        expression = "SEARCH('{${var.metric_namespace},Region} MetricName=\"${spec.metric_name}\"', 'Sum', 86400)"
        id         = "${spec.id_prefix}${i}"
        accountId  = acct
        visible    = false
      }]
    ]
  }

  tile_group_totals = {
    for key, spec in local.tile_specs : key => [
      for _ in [1] : [{
        expression = "SUM([${join(",", [for i, _ in var.member_account_ids : "${spec.id_prefix}${i}"])}])"
        label      = spec.label
        id         = "total_${spec.id_prefix}"
      }] if !local.all_accounts
    ]
  }

  tile_group_insights = {
    for key, spec in local.tile_specs : key => [
      for _ in [1] : [{
        expression = "SELECT SUM(${spec.metric_name}) FROM SCHEMA(\"${var.metric_namespace}\", Region)"
        label      = spec.label
        id         = "total_${spec.id_prefix}"
        period     = 86400
      }] if local.all_accounts
    ]
  }

  tile_groups = {
    for key, spec in local.tile_specs : key => concat(
      local.tile_group_accounts[key],
      local.tile_group_totals[key],
      local.tile_group_insights[key],
    )
  }

  # Region-dimensioned metrics stay as one visible SEARCH per account in
  # explicit mode rather than collapsing to a single sum - same approach
  # nhi-governance's org-dashboard uses for SecretsWithoutRotation.
  bar_group_accounts = {
    for key, spec in local.bar_specs : key => [
      for i, acct in var.member_account_ids : [{
        expression = "SEARCH('{${var.metric_namespace},Region} MetricName=\"${spec.metric_name}\"', 'Maximum', 86400)"
        id         = "${spec.id_prefix}${i}"
        accountId  = acct
        label      = "${acct} - $${PROP('Dim.Region')}"
      }]
    ]
  }

  # All-accounts mode: one bar per Region, summed across every linked account.
  bar_group_insights = {
    for key, spec in local.bar_specs : key => [
      for _ in [1] : [{
        expression = "SELECT SUM(${spec.metric_name}) FROM SCHEMA(\"${var.metric_namespace}\", Region) GROUP BY Region"
        id         = "${spec.id_prefix}_all"
        period     = 86400
      }] if local.all_accounts
    ]
  }

  # The per-account breakdown only exists in explicit mode, so drop
  # "Account/" from the titles in all-accounts mode.
  bar_titles = {
    for key, spec in local.bar_specs : key => local.all_accounts ? replace(spec.title, "Account/", "") : spec.title
  }

  bar_groups = {
    for key, spec in local.bar_specs : key => concat(
      local.bar_group_accounts[key],
      local.bar_group_insights[key],
    )
  }

  # ---------------------------------------------------------------------
  # VPC Flow Log panels: same log group + queries as the single-account
  # dashboard, repeated once per log account (log_account_ids if set, else
  # member_account_ids, so explicit mode is unchanged). Skipped entirely when
  # no flow log group is configured. Logs Insights widgets take a single
  # accountId, so all-accounts mode cannot enumerate accounts for them.
  # ---------------------------------------------------------------------
  flow_logs_enabled = var.flow_logs_log_group_name != ""
  log_accounts      = length(var.log_account_ids) > 0 ? var.log_account_ids : var.member_account_ids

  log_panels = [
    {
      title = "VPC Flow Logs – Rejected Connections Trend (hourly)"
      view  = "timeSeries"
      query = "SOURCE '${var.flow_logs_log_group_name}' | filter action = 'REJECT' | stats count(*) as rejected by bin(1h)"
    },
    {
      title = "VPC Flow Logs – Top Source IPs (Rejected)"
      view  = "bar"
      query = "SOURCE '${var.flow_logs_log_group_name}' | filter action = 'REJECT' | stats count(*) as rejected by srcAddr | sort rejected desc | limit 10"
    },
    {
      title = "VPC Flow Logs – Possible Port Scanning (>10 distinct dest ports)"
      view  = "table"
      query = "SOURCE '${var.flow_logs_log_group_name}' | filter action = 'REJECT' | stats count_distinct(dstPort) as uniquePorts, count(*) as attempts by srcAddr | filter uniquePorts > 10 | sort uniquePorts desc | limit 10"
    },
  ]

  # Grid layout: the metric widgets above occupy rows 0-21 of the 24-column
  # grid, so log panels start at y = 22. Each panel is its own block of
  # 12x6 widgets, two per row (x = 0 / 12), panels stacked one below the other.
  log_start_y     = 22
  log_widget_h    = 6
  log_panel_rows  = ceil(length(local.log_accounts) / 2)
  log_panel_y_gap = local.log_panel_rows * local.log_widget_h

  log_widgets = flatten([
    for p, panel in local.log_panels : [
      for i, acct in local.log_accounts : {
        type   = "log"
        x      = (i % 2) * 12
        y      = local.log_start_y + p * local.log_panel_y_gap + floor(i / 2) * local.log_widget_h
        width  = 12
        height = local.log_widget_h
        properties = {
          title     = "${panel.title} - ${acct}"
          accountId = acct
          region    = data.aws_region.current.name
          view      = panel.view
          query     = panel.query
        }
      } if local.flow_logs_enabled
    ]
  ])

  # All-accounts mode with a flow log group but no log_account_ids: no log
  # panels can be built, so say so instead of leaving a silent gap.
  log_notice_widgets = [
    for _ in [1] : {
      type   = "text"
      x      = 0
      y      = local.log_start_y
      width  = 24
      height = 2
      properties = {
        markdown = "**VPC Flow Log panels are not shown.** Logs Insights widgets take a single account ID, so they cannot cover all accounts. Set `log_account_ids` / `LogAccountIds` to the account IDs you want panels for."
      }
    } if local.flow_logs_enabled && local.all_accounts && length(var.log_account_ids) == 0
  ]

  metric_widgets = [
    {
      type   = "metric"
      x      = 0
      y      = 0
      width  = 6
      height = 4
      properties = {
        title   = local.tile_specs.open_sensitive.title
        region  = data.aws_region.current.name
        view    = "singleValue"
        metrics = local.tile_groups.open_sensitive
      }
    },
    {
      type   = "metric"
      x      = 6
      y      = 0
      width  = 6
      height = 4
      properties = {
        title   = local.tile_specs.public_ec2.title
        region  = data.aws_region.current.name
        view    = "singleValue"
        metrics = local.tile_groups.public_ec2
      }
    },
    {
      type   = "metric"
      x      = 12
      y      = 0
      width  = 6
      height = 4
      properties = {
        title   = local.tile_specs.public_rds.title
        region  = data.aws_region.current.name
        view    = "singleValue"
        metrics = local.tile_groups.public_rds
      }
    },
    {
      type   = "metric"
      x      = 18
      y      = 0
      width  = 6
      height = 4
      properties = {
        title   = local.tile_specs.public_lb.title
        region  = data.aws_region.current.name
        view    = "singleValue"
        metrics = local.tile_groups.public_lb
      }
    },
    {
      type   = "metric"
      x      = 0
      y      = 4
      width  = 12
      height = 6
      properties = {
        title   = local.bar_titles.open_sensitive
        region  = data.aws_region.current.name
        view    = "bar"
        metrics = local.bar_groups.open_sensitive
      }
    },
    {
      type   = "metric"
      x      = 12
      y      = 4
      width  = 12
      height = 6
      properties = {
        title   = local.bar_titles.public_ec2
        region  = data.aws_region.current.name
        view    = "bar"
        metrics = local.bar_groups.public_ec2
      }
    },
    {
      type   = "metric"
      x      = 0
      y      = 10
      width  = 12
      height = 6
      properties = {
        title   = local.bar_titles.public_rds
        region  = data.aws_region.current.name
        view    = "bar"
        metrics = local.bar_groups.public_rds
      }
    },
    {
      type   = "metric"
      x      = 12
      y      = 10
      width  = 12
      height = 6
      properties = {
        title   = local.bar_titles.public_lb
        region  = data.aws_region.current.name
        view    = "bar"
        metrics = local.bar_groups.public_lb
      }
    },
    {
      type   = "metric"
      x      = 0
      y      = 16
      width  = 12
      height = 6
      properties = {
        title   = local.bar_titles.public_s3
        region  = data.aws_region.current.name
        view    = "bar"
        metrics = local.bar_groups.public_s3
      }
    },
  ]

  widgets = concat(local.metric_widgets, local.log_notice_widgets, local.log_widgets)
}

resource "aws_cloudwatch_dashboard" "network_exposure_org" {
  dashboard_name = var.dashboard_name

  dashboard_body = jsonencode({
    widgets = local.widgets
  })

  lifecycle {
    # CloudWatch allows at most 500 widgets per dashboard and 500 metrics per
    # widget. Explicit mode carries one metric entry per member account (+1
    # total) in each metric widget; all-accounts mode has one entry per
    # widget. Each of the three log panels adds one widget per log account.
    precondition {
      condition     = length(local.widgets) <= 500
      error_message = "Too many log accounts for a single CloudWatch dashboard (limit: 500 widgets; the three flow-log panels add 3 widgets per log account on top of the metric widgets). Shorten log_account_ids (or member_account_ids when log_account_ids is empty), or deploy several org-dashboards with different dashboard_name values."
    }

    precondition {
      condition     = length(var.member_account_ids) < 500
      error_message = "Too many member accounts for a single CloudWatch dashboard (limit: 500 metrics per widget). Leave member_account_ids empty for all-accounts mode, or split it across several org-dashboard deployments with different dashboard_name values."
    }
  }
}
