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
# The collector publishes one 1/0 "ServiceActive" metric per Service x
# Region in every account, so the per-service widgets keep per-account x
# per-region visibility with one SEARCH() per account (each carrying its
# own "accountId"), the same "one SEARCH per account" approach the NHI
# governance org-dashboard uses for its per-Region Secrets Manager widget.
# On top of that, org-wide totals are built with the hidden per-account
# entry + one visible SUM() pattern where a single number makes sense.
#
# With no member_account_ids (all-accounts mode) none of that is needed:
# a CloudWatch Metrics Insights query in the monitoring account spans every
# linked source account, so each widget becomes one query such as
# SELECT SUM(ServiceActive) FROM SCHEMA("<ns>", Service, Region) GROUP BY ...
# and is not bound by the per-widget metric limit.
#
# Note on the schema: the collector's metrics carry BOTH the Service and
# Region dimensions, so every SEARCH below uses {namespace,Service,Region}
# and every SCHEMA() lists both dimensions. (A {namespace,Region}-only
# schema matches nothing.)
# -----------------------------------------------------------------------
locals {
  # With no member_account_ids the dashboard queries every account linked to
  # this monitoring account through CloudWatch Metrics Insights
  # (SELECT ... GROUP BY AWS.AccountId) instead of listing accounts one by
  # one, so it is not bound by the per-widget metric limit. With a list, it
  # keeps the explicit per-account approach below.
  all_accounts = length(var.member_account_ids) == 0

  # Order matches the single-account dashboard's layout. `value` is the
  # exact "Service" dimension value the collector publishes.
  services = [
    { value = "Bedrock", title = "Bedrock", id_prefix = "bd" },
    { value = "BedrockAgents", title = "Bedrock Agents", id_prefix = "ba" },
    { value = "BedrockGuardrails", title = "Bedrock Guardrails", id_prefix = "bg" },
    { value = "Rekognition", title = "Rekognition", id_prefix = "rk" },
    { value = "Comprehend", title = "Comprehend", id_prefix = "cp" },
    { value = "Textract", title = "Textract", id_prefix = "tx" },
  ]

  # Every Service x Region metric in the namespace, collapsed to one
  # series: the number of active service/region pairs in one account.
  all_services_search = "SUM(SEARCH('{${var.metric_namespace},Service,Region} MetricName=\"ServiceActive\"', 'Maximum', 86400))"

  # Number of regions (in one account) in which one service is active.
  service_count_search = {
    for s in local.services : s.value => "SUM(SEARCH('{${var.metric_namespace},Service,Region} MetricName=\"ServiceActive\" Service=\"${s.value}\"', 'Maximum', 86400))"
  }

  # Per-region series for one service in one account (one series per
  # region; the label carries both account and region).
  service_region_search = {
    for s in local.services : s.value => "SEARCH('{${var.metric_namespace},Service,Region} MetricName=\"ServiceActive\" Service=\"${s.value}\"', 'Maximum', 86400)"
  }

  # Org-wide single number: N hidden per-account counts + 1 visible SUM().
  pairs_total_explicit = concat(
    [
      for i, acct in var.member_account_ids : [{
        expression = local.all_services_search
        id         = "ap${i}"
        accountId  = acct
        visible    = false
      }]
    ],
    [
      for _ in [1] : [{
        expression = "SUM([${join(",", [for i, _ in var.member_account_ids : "ap${i}"])}])"
        label      = "Active service/region pairs (org-wide)"
        id         = "total_ap"
      }] if !local.all_accounts
    ]
  )

  # All-accounts mode: one query summing every Service x Region metric of
  # every linked account (one datapoint per metric per daily run).
  pairs_total_insights = [
    for _ in [1] : [{
      expression = "SELECT SUM(ServiceActive) FROM SCHEMA(\"${var.metric_namespace}\", Service, Region)"
      label      = "Active service/region pairs (org-wide)"
      id         = "total_ap"
      period     = 86400
    }] if local.all_accounts
  ]

  pairs_total_metrics = concat(local.pairs_total_explicit, local.pairs_total_insights)

  # Same count, but kept per account (one visible series per account).
  pairs_by_account_explicit = [
    for i, acct in var.member_account_ids : [{
      expression = local.all_services_search
      id         = "ac${i}"
      accountId  = acct
      label      = acct
    }]
  ]

  # All-accounts mode: one series per account, largest first. Metrics
  # Insights returns at most 500 series per query, and a bar chart of that
  # many accounts is unreadable anyway, so this keeps the 100 accounts with
  # the most active service/region pairs. The org-wide totals in the other
  # widgets are not affected by this limit.
  pairs_by_account_insights = [
    for _ in [1] : [{
      expression = "SELECT SUM(ServiceActive) FROM SCHEMA(\"${var.metric_namespace}\", Service, Region) GROUP BY AWS.AccountId ORDER BY SUM() DESC LIMIT 100"
      id         = "ac_all"
      period     = 86400
    }] if local.all_accounts
  ]

  pairs_by_account_metrics = concat(local.pairs_by_account_explicit, local.pairs_by_account_insights)

  # Org-wide active account/region pairs for each service. Every service
  # gets its own id_prefix so the six N-account groups never collide inside
  # this one widget's metrics array.
  # (concat with the expansion symbol, not flatten(): flatten() would also
  # flatten each individual metric entry array into a bare object.)
  service_totals_explicit = concat([
    for s in local.services : concat(
      [
        for i, acct in var.member_account_ids : [{
          expression = local.service_count_search[s.value]
          id         = "${s.id_prefix}${i}"
          accountId  = acct
          visible    = false
        }]
      ],
      [
        for _ in [1] : [{
          expression = "SUM([${join(",", [for i, _ in var.member_account_ids : "${s.id_prefix}${i}"])}])"
          label      = s.title
          id         = "total_${s.id_prefix}"
        }] if !local.all_accounts
      ]
    )
  ]...)

  # All-accounts mode: one series per Service value (the collector publishes
  # exactly the six services above), summed over all accounts and regions.
  service_totals_insights = [
    for _ in [1] : [{
      expression = "SELECT SUM(ServiceActive) FROM SCHEMA(\"${var.metric_namespace}\", Service, Region) GROUP BY Service"
      id         = "svc_all"
      period     = 86400
    }] if local.all_accounts
  ]

  service_totals_metrics = concat(local.service_totals_explicit, local.service_totals_insights)

  # One SEARCH per account per service: which regions in which accounts
  # use this service.
  service_region_explicit = {
    for s in local.services : s.value => [
      for i, acct in var.member_account_ids : [{
        expression = local.service_region_search[s.value]
        id         = "${s.id_prefix}${i}"
        accountId  = acct
        label      = "${acct} - $${PROP('Dim.Region')}"
      }]
    ]
  }

  # All-accounts mode: one series per region holding the number of accounts
  # in which the service is active there. Grouping by Region only (not by
  # account too) keeps the query far below the 500-series limit; the
  # per-account view is the "by Account" widget above.
  service_region_insights = {
    for s in local.services : s.value => [
      for _ in [1] : [{
        expression = "SELECT SUM(ServiceActive) FROM SCHEMA(\"${var.metric_namespace}\", Service, Region) WHERE Service = '${s.value}' GROUP BY Region"
        id         = "${s.id_prefix}_all"
        period     = 86400
      }] if local.all_accounts
    ]
  }

  service_region_metrics = {
    for s in local.services : s.value => concat(local.service_region_explicit[s.value], local.service_region_insights[s.value])
  }

  # Six per-service widgets in a 2-column grid below the summary rows
  # (y = 12, 18, 24). In all-accounts mode the widget shows the number of
  # accounts using the service per region, so it is titled accordingly.
  service_widgets = [
    for idx, s in local.services : {
      type   = "metric"
      x      = (idx % 2) * 12
      y      = 12 + floor(idx / 2) * 6
      width  = 12
      height = 6
      properties = {
        title   = local.all_accounts ? "${s.title} — Accounts Using It, by Region" : "${s.title} — Active by Account/Region"
        region  = data.aws_region.current.name
        view    = "bar"
        metrics = local.service_region_metrics[s.value]
      }
    }
  ]
}

resource "aws_cloudwatch_dashboard" "ai_service_inventory_org" {
  dashboard_name = var.dashboard_name

  dashboard_body = jsonencode({
    widgets = concat(
      [
        {
          type   = "metric"
          x      = 0
          y      = 0
          width  = 6
          height = 6
          properties = {
            title   = "Active AI Service/Region Pairs (org-wide, 6 watched services)"
            region  = data.aws_region.current.name
            view    = "singleValue"
            metrics = local.pairs_total_metrics
          }
        },
        {
          type   = "metric"
          x      = 6
          y      = 0
          width  = 18
          height = 6
          properties = {
            title   = "Active Regions per AI Service (org-wide, account/region pairs)"
            region  = data.aws_region.current.name
            view    = "bar"
            metrics = local.service_totals_metrics
          }
        },
        {
          type   = "metric"
          x      = 0
          y      = 6
          width  = 24
          height = 6
          properties = {
            title   = "Active AI Services by Account (active service/region pairs per account)"
            region  = data.aws_region.current.name
            view    = "bar"
            metrics = local.pairs_by_account_metrics
          }
        },
      ],
      local.service_widgets,
    )
  })
}
