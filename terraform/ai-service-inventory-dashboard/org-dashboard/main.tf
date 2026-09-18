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
# Note on the schema: the collector's metrics carry BOTH the Service and
# Region dimensions, so every SEARCH below uses {namespace,Service,Region}.
# (A {namespace,Region}-only schema matches nothing.)
# -----------------------------------------------------------------------
locals {
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
  pairs_total_metrics = concat(
    [
      for i, acct in var.member_account_ids : [{
        expression = local.all_services_search
        id         = "ap${i}"
        accountId  = acct
        visible    = false
      }]
    ],
    [[{
      expression = "SUM([${join(",", [for i, _ in var.member_account_ids : "ap${i}"])}])"
      label      = "Active service/region pairs (org-wide)"
      id         = "total_ap"
    }]]
  )

  # Same count, but kept per account (one visible series per account).
  pairs_by_account_metrics = [
    for i, acct in var.member_account_ids : [{
      expression = local.all_services_search
      id         = "ac${i}"
      accountId  = acct
      label      = acct
    }]
  ]

  # Org-wide active account/region pairs for each service. Every service
  # gets its own id_prefix so the six N-account groups never collide inside
  # this one widget's metrics array.
  # (concat with the expansion symbol, not flatten(): flatten() would also
  # flatten each individual metric entry array into a bare object.)
  service_totals_metrics = concat([
    for s in local.services : concat(
      [
        for i, acct in var.member_account_ids : [{
          expression = local.service_count_search[s.value]
          id         = "${s.id_prefix}${i}"
          accountId  = acct
          visible    = false
        }]
      ],
      [[{
        expression = "SUM([${join(",", [for i, _ in var.member_account_ids : "${s.id_prefix}${i}"])}])"
        label      = s.title
        id         = "total_${s.id_prefix}"
      }]]
    )
  ]...)

  # One SEARCH per account per service: which regions in which accounts
  # use this service.
  service_region_metrics = {
    for s in local.services : s.value => [
      for i, acct in var.member_account_ids : [{
        expression = local.service_region_search[s.value]
        id         = "${s.id_prefix}${i}"
        accountId  = acct
        label      = "${acct} - $${PROP('Dim.Region')}"
      }]
    ]
  }

  # Six per-service widgets in a 2-column grid below the summary rows
  # (y = 12, 18, 24).
  service_widgets = [
    for idx, s in local.services : {
      type   = "metric"
      x      = (idx % 2) * 12
      y      = 12 + floor(idx / 2) * 6
      width  = 12
      height = 6
      properties = {
        title   = "${s.title} — Active by Account/Region"
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
