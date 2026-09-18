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
#                      Region, so each account gets one hidden SEARCH
#                      (carrying its own "accountId") and one visible SUM()
#                      adds them all up into a single org-wide number.
#   2. "by Region"   - one VISIBLE SEARCH per account, so per-account x
#      bar charts      per-region stays readable instead of collapsing.
#   3. VPC Flow Logs - Logs Insights widgets cannot collapse across
#      panels           accounts (a log widget takes a single accountId), so
#                      every panel is repeated once per member account.
#
# Metric names/stats/periods come straight from the single-account
# dashboard (../main.tf) and the collector Lambda that publishes them.
# -----------------------------------------------------------------------
locals {
  # 24h tiles: SEARCH with 'Sum' over 86400s, exactly like the single-account tiles.
  tile_specs = {
    open_sensitive = { metric_name = "OpenSensitivePortRules", id_prefix = "tosp", label = "Open Rules (org-wide)", title = "Open SG Rules – Sensitive Ports (24h, org-wide)" }
    public_ec2     = { metric_name = "PublicEc2Instances", id_prefix = "tpe", label = "Public Instances (org-wide)", title = "Public EC2 Instances (24h, org-wide)" }
    public_rds     = { metric_name = "PubliclyAccessibleRdsInstances", id_prefix = "tpr", label = "Public RDS (org-wide)", title = "Publicly Accessible RDS (24h, org-wide)" }
    public_lb      = { metric_name = "InternetFacingLoadBalancers", id_prefix = "tlb", label = "Public LBs (org-wide)", title = "Internet-Facing Load Balancers (24h, org-wide)" }
  }

  # "by Region" bar charts: SEARCH with 'Maximum' over 86400s, one per account.
  bar_specs = {
    open_sensitive = { metric_name = "OpenSensitivePortRules", id_prefix = "bosp", title = "Open SG Rules (Sensitive Ports) by Account/Region" }
    public_ec2     = { metric_name = "PublicEc2Instances", id_prefix = "bpe", title = "Public EC2 Instances by Account/Region" }
    public_rds     = { metric_name = "PubliclyAccessibleRdsInstances", id_prefix = "bpr", title = "Publicly Accessible RDS by Account/Region" }
    public_lb      = { metric_name = "InternetFacingLoadBalancers", id_prefix = "blb", title = "Internet-Facing Load Balancers by Account/Region" }
    public_s3      = { metric_name = "PubliclyAccessibleS3Buckets", id_prefix = "bs3", title = "Publicly Accessible S3 Buckets by Account/(Bucket Home) Region" }
  }

  # Every value here is a ready-to-use `metrics` array: N hidden per-account
  # SEARCH entries + 1 visible SUM() expression summing all of them. Split
  # into two flat maps (accounts, totals) rather than one deeply nested
  # concat/for expression - simpler to read and to keep formatted.
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
    for key, spec in local.tile_specs : key => [[{
      expression = "SUM([${join(",", [for i, _ in var.member_account_ids : "${spec.id_prefix}${i}"])}])"
      label      = spec.label
      id         = "total_${spec.id_prefix}"
    }]]
  }

  tile_groups = {
    for key, spec in local.tile_specs : key => concat(local.tile_group_accounts[key], local.tile_group_totals[key])
  }

  # Region-dimensioned metrics stay as one visible SEARCH per account
  # rather than collapsing to a single sum - same approach nhi-governance's
  # org-dashboard uses for SecretsWithoutRotation.
  bar_groups = {
    for key, spec in local.bar_specs : key => [
      for i, acct in var.member_account_ids : [{
        expression = "SEARCH('{${var.metric_namespace},Region} MetricName=\"${spec.metric_name}\"', 'Maximum', 86400)"
        id         = "${spec.id_prefix}${i}"
        accountId  = acct
        label      = "${acct} - $${PROP('Dim.Region')}"
      }]
    ]
  }

  # ---------------------------------------------------------------------
  # VPC Flow Log panels: same log group + queries as the single-account
  # dashboard, repeated once per member account. Skipped entirely when no
  # flow log group is configured.
  # ---------------------------------------------------------------------
  flow_logs_enabled = var.flow_logs_log_group_name != ""

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
  log_panel_rows  = ceil(length(var.member_account_ids) / 2)
  log_panel_y_gap = local.log_panel_rows * local.log_widget_h

  log_widgets = flatten([
    for p, panel in local.log_panels : [
      for i, acct in var.member_account_ids : {
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
        title   = local.bar_specs.open_sensitive.title
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
        title   = local.bar_specs.public_ec2.title
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
        title   = local.bar_specs.public_rds.title
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
        title   = local.bar_specs.public_lb.title
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
        title   = local.bar_specs.public_s3.title
        region  = data.aws_region.current.name
        view    = "bar"
        metrics = local.bar_groups.public_s3
      }
    },
  ]

  widgets = concat(local.metric_widgets, local.log_widgets)
}

resource "aws_cloudwatch_dashboard" "network_exposure_org" {
  dashboard_name = var.dashboard_name

  dashboard_body = jsonencode({
    widgets = local.widgets
  })

  lifecycle {
    # CloudWatch allows at most 500 widgets per dashboard and 500 metrics per
    # widget. Metric widgets here carry one entry per account (+1 total), and
    # the three log panels add one widget per account each.
    precondition {
      condition     = length(local.widgets) <= 500 && length(var.member_account_ids) < 500
      error_message = "Too many member accounts for a single CloudWatch dashboard (limits: 500 widgets, 500 metrics per widget). Split member_account_ids across several org-dashboard deployments with different dashboard_name values."
    }
  }
}
