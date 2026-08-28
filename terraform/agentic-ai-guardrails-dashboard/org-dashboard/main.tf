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

locals {
  agents     = "AWS/Bedrock/Agents"
  guardrails = "AWS/Bedrock/Guardrails"

  # combine = "SUM" for count-style metrics (invocations, errors, tokens);
  # "AVG" for latency-style metrics, since summing averages across
  # accounts would be meaningless.
  search_specs = {
    agent_invocations_24h = { namespace = local.agents, dimension = "Operation", metric_name = "InvocationCount", stat = "Sum", period = 86400, combine = "SUM", id_prefix = "ai", label = "Invocations" }
    guardrail_inv_24h     = { namespace = local.guardrails, dimension = "Operation", metric_name = "Invocations", stat = "Sum", period = 86400, combine = "SUM", id_prefix = "gi", label = "Invocations" }
    guardrail_intv_24h    = { namespace = local.guardrails, dimension = "Operation", metric_name = "InvocationsIntervened", stat = "Sum", period = 86400, combine = "SUM", id_prefix = "gv", label = "Interventions" }

    agent_invocation_count = { namespace = local.agents, dimension = "Operation", metric_name = "InvocationCount", stat = "Sum", period = 300, combine = "SUM", id_prefix = "ic", label = "Invocations" }
    agent_throttles        = { namespace = local.agents, dimension = "Operation", metric_name = "InvocationThrottles", stat = "Sum", period = 300, combine = "SUM", id_prefix = "it", label = "Throttles" }
    agent_client_errors    = { namespace = local.agents, dimension = "Operation", metric_name = "InvocationClientErrors", stat = "Sum", period = 300, combine = "SUM", id_prefix = "ie", label = "Client Errors" }
    agent_server_errors    = { namespace = local.agents, dimension = "Operation", metric_name = "InvocationServerErrors", stat = "Sum", period = 300, combine = "SUM", id_prefix = "is", label = "Server Errors" }

    agent_total_time    = { namespace = local.agents, dimension = "Operation", metric_name = "TotalTime", stat = "Average", period = 300, combine = "AVG", id_prefix = "lt", label = "Total Time" }
    agent_model_latency = { namespace = local.agents, dimension = "Operation", metric_name = "ModelLatency", stat = "Average", period = 300, combine = "AVG", id_prefix = "lm", label = "Model Latency" }
    agent_ttft          = { namespace = local.agents, dimension = "Operation", metric_name = "TTFT", stat = "Average", period = 300, combine = "AVG", id_prefix = "lf", label = "Time to First Token" }

    agent_input_tokens  = { namespace = local.agents, dimension = "Operation", metric_name = "InputTokenCount", stat = "Sum", period = 300, combine = "SUM", id_prefix = "ti", label = "Input Tokens" }
    agent_output_tokens = { namespace = local.agents, dimension = "Operation", metric_name = "OutputTokenCount", stat = "Sum", period = 300, combine = "SUM", id_prefix = "to", label = "Output Tokens" }

    model_invocation_count = { namespace = local.agents, dimension = "Operation", metric_name = "ModelInvocationCount", stat = "Sum", period = 300, combine = "SUM", id_prefix = "mc", label = "Model Invocations" }
    model_throttles        = { namespace = local.agents, dimension = "Operation", metric_name = "ModelInvocationThrottles", stat = "Sum", period = 300, combine = "SUM", id_prefix = "mt", label = "Model Throttles" }
    model_client_errors    = { namespace = local.agents, dimension = "Operation", metric_name = "ModelInvocationClientErrors", stat = "Sum", period = 300, combine = "SUM", id_prefix = "me", label = "Model Client Errors" }
    model_server_errors    = { namespace = local.agents, dimension = "Operation", metric_name = "ModelInvocationServerErrors", stat = "Sum", period = 300, combine = "SUM", id_prefix = "ms", label = "Model Server Errors" }

    guardrail_inv_trend  = { namespace = local.guardrails, dimension = "Operation", metric_name = "Invocations", stat = "Sum", period = 300, combine = "SUM", id_prefix = "gi2", label = "Invocations" }
    guardrail_intv_trend = { namespace = local.guardrails, dimension = "Operation", metric_name = "InvocationsIntervened", stat = "Sum", period = 300, combine = "SUM", id_prefix = "gv2", label = "Interventions" }

    guardrail_latency       = { namespace = local.guardrails, dimension = "Operation", metric_name = "InvocationLatency", stat = "Average", period = 300, combine = "AVG", id_prefix = "gl", label = "Avg Latency" }
    guardrail_client_errors = { namespace = local.guardrails, dimension = "Operation", metric_name = "InvocationClientErrors", stat = "Sum", period = 300, combine = "SUM", id_prefix = "ge", label = "Client Errors" }
    guardrail_server_errors = { namespace = local.guardrails, dimension = "Operation", metric_name = "InvocationServerErrors", stat = "Sum", period = 300, combine = "SUM", id_prefix = "gs", label = "Server Errors" }
    guardrail_throttles     = { namespace = local.guardrails, dimension = "Operation", metric_name = "InvocationThrottles", stat = "Sum", period = 300, combine = "SUM", id_prefix = "gt", label = "Throttles" }

    guardrail_text_units = { namespace = local.guardrails, dimension = "Operation", metric_name = "TextUnitCount", stat = "Sum", period = 300, combine = "SUM", id_prefix = "tu", label = "Text Units" }
  }

  # For each spec: N hidden per-account SEARCH expressions + 1 visible
  # combining expression (SUM or AVG per the spec).
  search_groups = {
    for key, spec in local.search_specs : key => concat(
      [
        for i, acct in var.member_account_ids : [{
          expression = "SEARCH('{${spec.namespace},${spec.dimension}} MetricName=\"${spec.metric_name}\"', '${spec.stat}', ${spec.period})"
          id         = "${spec.id_prefix}${i}"
          accountId  = acct
          visible    = false
        }]
      ],
      [
        [{
          expression = "${spec.combine}([${join(",", [for i, _ in var.member_account_ids : "${spec.id_prefix}${i}"])}])"
          label      = spec.label
          id         = "total_${spec.id_prefix}"
        }]
      ]
    )
  }

  # Intervention rate: two dedicated hidden per-account SEARCH groups
  # (built directly rather than reusing search_groups, since those are
  # meant to end in one *visible* total — the rate widget needs both
  # totals hidden and only the final ratio visible).
  rate_invocations_hidden = concat(
    [
      for i, acct in var.member_account_ids : [{
        expression = "SEARCH('{${local.guardrails},Operation} MetricName=\"Invocations\"', 'Sum', 86400)"
        id         = "ri${i}"
        accountId  = acct
        visible    = false
      }]
    ],
    [[{ expression = "SUM([${join(",", [for i, _ in var.member_account_ids : "ri${i}"])}])", id = "rate_invocations", visible = false }]]
  )
  rate_intervened_hidden = concat(
    [
      for i, acct in var.member_account_ids : [{
        expression = "SEARCH('{${local.guardrails},Operation} MetricName=\"InvocationsIntervened\"', 'Sum', 86400)"
        id         = "rv${i}"
        accountId  = acct
        visible    = false
      }]
    ],
    [[{ expression = "SUM([${join(",", [for i, _ in var.member_account_ids : "rv${i}"])}])", id = "rate_intervened", visible = false }]]
  )
  intervention_rate_metrics = concat(
    local.rate_invocations_hidden,
    local.rate_intervened_hidden,
    [[{ expression = "100*rate_intervened/rate_invocations", label = "Intervention Rate (%)", id = "rate" }]]
  )

  # Interventions by policy category: variable series per account, so
  # this stays as one visible SEARCH per account rather than a sum.
  policy_category_metrics = [
    for i, acct in var.member_account_ids : [{
      expression = "SEARCH('{${local.guardrails},GuardrailPolicyType} MetricName=\"InvocationsIntervened\"', 'Sum', 300)"
      id         = "pc${i}"
      accountId  = acct
      label      = acct
    }]
  ]
}

resource "aws_cloudwatch_dashboard" "agentic_ai_guardrails_org" {
  dashboard_name = var.dashboard_name

  dashboard_body = jsonencode({
    widgets = [
      {
        type       = "metric", x = 0, y = 0, width = 6, height = 4
        properties = { title = "Agent Invocations (org-wide, 24h)", region = data.aws_region.current.name, view = "singleValue", metrics = local.search_groups.agent_invocations_24h }
      },
      {
        type       = "metric", x = 6, y = 0, width = 6, height = 4
        properties = { title = "Guardrail Invocations (org-wide, 24h)", region = data.aws_region.current.name, view = "singleValue", metrics = local.search_groups.guardrail_inv_24h }
      },
      {
        type       = "metric", x = 12, y = 0, width = 6, height = 4
        properties = { title = "Guardrail Interventions (org-wide, 24h)", region = data.aws_region.current.name, view = "singleValue", metrics = local.search_groups.guardrail_intv_24h }
      },
      {
        type       = "metric", x = 18, y = 0, width = 6, height = 4
        properties = { title = "Guardrail Intervention Rate (org-wide, 24h)", region = data.aws_region.current.name, view = "singleValue", metrics = local.intervention_rate_metrics }
      },
      {
        type       = "metric", x = 0, y = 4, width = 12, height = 6
        properties = {
          title   = "Agent Invocations, Throttles & Errors (org-wide)", region = data.aws_region.current.name, view = "timeSeries"
          metrics = concat(local.search_groups.agent_invocation_count, local.search_groups.agent_throttles, local.search_groups.agent_client_errors, local.search_groups.agent_server_errors)
        }
      },
      {
        type       = "metric", x = 12, y = 4, width = 12, height = 6
        properties = {
          title   = "Agent Latency (org-wide, avg ms)", region = data.aws_region.current.name, view = "timeSeries"
          metrics = concat(local.search_groups.agent_total_time, local.search_groups.agent_model_latency, local.search_groups.agent_ttft)
        }
      },
      {
        type       = "metric", x = 0, y = 10, width = 12, height = 6
        properties = {
          title   = "Agent Token Usage (org-wide)", region = data.aws_region.current.name, view = "timeSeries"
          metrics = concat(local.search_groups.agent_input_tokens, local.search_groups.agent_output_tokens)
        }
      },
      {
        type       = "metric", x = 12, y = 10, width = 12, height = 6
        properties = {
          title   = "Agent → Model Call Health (org-wide)", region = data.aws_region.current.name, view = "timeSeries"
          metrics = concat(local.search_groups.model_invocation_count, local.search_groups.model_throttles, local.search_groups.model_client_errors, local.search_groups.model_server_errors)
        }
      },
      {
        type       = "metric", x = 0, y = 16, width = 12, height = 6
        properties = {
          title   = "Guardrail Invocations vs Interventions (org-wide)", region = data.aws_region.current.name, view = "timeSeries"
          metrics = concat(local.search_groups.guardrail_inv_trend, local.search_groups.guardrail_intv_trend)
        }
      },
      {
        type       = "metric", x = 12, y = 16, width = 12, height = 6
        properties = { title = "Guardrail Interventions by Policy Category (org-wide)", region = data.aws_region.current.name, view = "bar", metrics = local.policy_category_metrics }
      },
      {
        type       = "metric", x = 0, y = 22, width = 12, height = 6
        properties = {
          title   = "Guardrail Latency & Errors (org-wide)", region = data.aws_region.current.name, view = "timeSeries"
          metrics = concat(local.search_groups.guardrail_latency, local.search_groups.guardrail_client_errors, local.search_groups.guardrail_server_errors, local.search_groups.guardrail_throttles)
        }
      },
      {
        type       = "metric", x = 12, y = 22, width = 12, height = 6
        properties = { title = "Guardrail Text Units Consumed (org-wide)", region = data.aws_region.current.name, view = "timeSeries", metrics = local.search_groups.guardrail_text_units }
      },
    ]
  })
}
