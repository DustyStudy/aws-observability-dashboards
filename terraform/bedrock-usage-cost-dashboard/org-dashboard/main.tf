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
# Two patterns are used in this file:
#
# 1. search_specs — native AWS/Bedrock metrics (dimensioned by ModelId), so
#    one hidden per-account SEARCH() plus one visible combining expression.
#    Count-style metrics (invocations, tokens, errors, throttles) combine
#    with SUM(); latency-style metrics combine with AVG(), since summing
#    averages across accounts would be meaningless. These need no
#    collector at all, only the OAM Link in every member account.
#
# 2. metric_specs — the cost collector's fully-specified metric
#    (UsageType=TOTAL), so one hidden per-account metric entry (each
#    carrying its own "accountId") plus one visible SUM() expression.
#
# Metric-math IDs must be unique within a single widget. Every ID is built
# as "<id_prefix>_<index>" and every id_prefix below is distinct and free
# of underscores/digits, so IDs can never collide even if a widget
# combines several groups (e.g. input vs output tokens).
# -----------------------------------------------------------------------
locals {
  bedrock = "AWS/Bedrock"

  search_specs = {
    invocations   = { metric_name = "Invocations", stat = "Sum", period = 300, combine = "SUM", id_prefix = "inv", label = "Invocations" }
    input_tokens  = { metric_name = "InputTokenCount", stat = "Sum", period = 300, combine = "SUM", id_prefix = "tin", label = "Input Tokens" }
    output_tokens = { metric_name = "OutputTokenCount", stat = "Sum", period = 300, combine = "SUM", id_prefix = "tout", label = "Output Tokens" }
    latency       = { metric_name = "InvocationLatency", stat = "Average", period = 300, combine = "AVG", id_prefix = "lat", label = "Avg Latency" }
    client_errors = { metric_name = "InvocationClientErrors", stat = "Sum", period = 300, combine = "SUM", id_prefix = "cerr", label = "Client Errors" }
    server_errors = { metric_name = "InvocationServerErrors", stat = "Sum", period = 300, combine = "SUM", id_prefix = "serr", label = "Server Errors" }
    throttles     = { metric_name = "InvocationThrottles", stat = "Sum", period = 300, combine = "SUM", id_prefix = "thr", label = "Throttles" }
  }

  metric_specs = {
    total_cost = { metric_name = "EstimatedDailyCostUSD", usage_type = "TOTAL", stat = "Maximum", id_prefix = "ctot", label = "Estimated Total Daily Cost (org-wide, USD)" }
  }

  # For each search spec: N hidden per-account SEARCH expressions + 1
  # visible combining expression (SUM or AVG per the spec).
  # Split into two flat maps (accounts, totals) rather than one deeply
  # nested concat/for expression — simpler to read and to keep formatted.
  search_group_accounts = {
    for key, spec in local.search_specs : key => [
      for i, acct in var.member_account_ids : [{
        expression = "SEARCH('{${local.bedrock},ModelId} MetricName=\"${spec.metric_name}\"', '${spec.stat}', ${spec.period})"
        id         = "${spec.id_prefix}_${i}"
        accountId  = acct
        visible    = false
      }]
    ]
  }

  search_group_totals = {
    for key, spec in local.search_specs : key => [[{
      expression = "${spec.combine}([${join(",", [for i, _ in var.member_account_ids : "${spec.id_prefix}_${i}"])}])"
      label      = spec.label
      id         = "total_${spec.id_prefix}"
    }]]
  }

  search_groups = {
    for key, spec in local.search_specs : key => concat(local.search_group_accounts[key], local.search_group_totals[key])
  }

  # Un-dimensioned-style cost metric: N hidden per-account entries + 1
  # visible SUM() across all of them.
  metric_group_accounts = {
    for key, spec in local.metric_specs : key => [
      for i, acct in var.member_account_ids : [
        var.metric_namespace, spec.metric_name, "UsageType", spec.usage_type,
        { stat = spec.stat, period = 86400, accountId = acct, id = "${spec.id_prefix}_${i}", visible = false }
      ]
    ]
  }

  metric_group_totals = {
    for key, spec in local.metric_specs : key => [[{
      expression = "SUM([${join(",", [for i, _ in var.member_account_ids : "${spec.id_prefix}_${i}"])}])"
      label      = spec.label
      id         = "total_${spec.id_prefix}"
    }]]
  }

  metric_groups = {
    for key, spec in local.metric_specs : key => concat(local.metric_group_accounts[key], local.metric_group_totals[key])
  }

  # Invocations by model: variable series per account (one per ModelId), so
  # this stays as one visible SEARCH per account, labelled "<account> -
  # <model>", rather than collapsing to a sum.
  invocations_by_model_metrics = [
    for i, acct in var.member_account_ids : [{
      expression = "SEARCH('{${local.bedrock},ModelId} MetricName=\"Invocations\"', 'Sum', 300)"
      id         = "invm_${i}"
      accountId  = acct
      label      = "${acct} - $${PROP('Dim.ModelId')}"
    }]
  ]

  # Cost attribution per account: each account's own TOTAL series, shown
  # side by side (the main org use case for this dashboard).
  cost_per_account_metrics = [
    for i, acct in var.member_account_ids : [
      var.metric_namespace, "EstimatedDailyCostUSD", "UsageType", "TOTAL",
      { stat = "Maximum", period = 86400, accountId = acct, id = "cacct_${i}", label = acct }
    ]
  ]

  # Cost by usage type: variable series per account (one per UsageType),
  # so one visible SEARCH per account rather than a sum.
  cost_by_usage_type_metrics = [
    for i, acct in var.member_account_ids : [{
      expression = "SEARCH('{${var.metric_namespace},UsageType} MetricName=\"EstimatedDailyCostUSD\"', 'Maximum', 86400)"
      id         = "cuse_${i}"
      accountId  = acct
      label      = "${acct} - $${PROP('Dim.UsageType')}"
    }]
  ]
}

resource "aws_cloudwatch_dashboard" "bedrock_usage_cost_org" {
  dashboard_name = var.dashboard_name

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "Bedrock Invocations (org-wide)"
          region  = data.aws_region.current.name
          view    = "timeSeries"
          metrics = local.search_groups.invocations
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "Bedrock Invocations by Model and Account"
          region  = data.aws_region.current.name
          view    = "timeSeries"
          stacked = true
          metrics = local.invocations_by_model_metrics
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title   = "Bedrock Token Volume (Input vs Output, org-wide)"
          region  = data.aws_region.current.name
          view    = "timeSeries"
          metrics = concat(local.search_groups.input_tokens, local.search_groups.output_tokens)
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title   = "Bedrock Invocation Latency (org-wide, avg ms)"
          region  = data.aws_region.current.name
          view    = "timeSeries"
          metrics = local.search_groups.latency
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 12
        height = 6
        properties = {
          title   = "Bedrock Errors & Throttles (org-wide)"
          region  = data.aws_region.current.name
          view    = "timeSeries"
          metrics = concat(local.search_groups.client_errors, local.search_groups.server_errors, local.search_groups.throttles)
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 12
        width  = 12
        height = 6
        properties = {
          title   = local.metric_specs.total_cost.label
          region  = data.aws_region.current.name
          view    = "singleValue"
          metrics = local.metric_groups.total_cost
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 18
        width  = 12
        height = 6
        properties = {
          title   = "Estimated Daily Cost by Usage Type and Account"
          region  = data.aws_region.current.name
          view    = "bar"
          metrics = local.cost_by_usage_type_metrics
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 18
        width  = 12
        height = 6
        properties = {
          title   = "Estimated Daily Cost per Account (USD)"
          region  = data.aws_region.current.name
          view    = "bar"
          metrics = local.cost_per_account_metrics
        }
      },
    ]
  })
}
