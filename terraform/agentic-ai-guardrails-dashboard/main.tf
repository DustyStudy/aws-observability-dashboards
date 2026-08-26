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

resource "aws_cloudwatch_dashboard" "agentic_ai_guardrails" {
  dashboard_name = "${var.name_prefix}-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 6
        height = 4
        properties = {
          title  = "Agent Invocations (24h)"
          region = data.aws_region.current.name
          view   = "singleValue"
          metrics = [
            [{ expression = "SEARCH('{AWS/Bedrock/Agents,Operation} MetricName=\"InvocationCount\"', 'Sum', 86400)", label = "Invocations", id = "e1" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 6
        y      = 0
        width  = 6
        height = 4
        properties = {
          title  = "Guardrail Invocations (24h)"
          region = data.aws_region.current.name
          view   = "singleValue"
          metrics = [
            [{ expression = "SEARCH('{AWS/Bedrock/Guardrails,Operation} MetricName=\"Invocations\"', 'Sum', 86400)", label = "Invocations", id = "e1" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 6
        height = 4
        properties = {
          title  = "Guardrail Interventions (24h)"
          region = data.aws_region.current.name
          view   = "singleValue"
          metrics = [
            [{ expression = "SEARCH('{AWS/Bedrock/Guardrails,Operation} MetricName=\"InvocationsIntervened\"', 'Sum', 86400)", label = "Interventions", id = "e1" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 18
        y      = 0
        width  = 6
        height = 4
        properties = {
          title  = "Guardrail Intervention Rate (24h)"
          region = data.aws_region.current.name
          view   = "singleValue"
          metrics = [
            [{ expression = "SEARCH('{AWS/Bedrock/Guardrails,Operation} MetricName=\"Invocations\"', 'Sum', 86400)", id = "invocations", visible = false }],
            [{ expression = "SEARCH('{AWS/Bedrock/Guardrails,Operation} MetricName=\"InvocationsIntervened\"', 'Sum', 86400)", id = "intervened", visible = false }],
            [{ expression = "100*intervened/invocations", label = "Intervention Rate (%)", id = "rate" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 4
        width  = 12
        height = 6
        properties = {
          title  = "Agent Invocations, Throttles & Errors"
          region = data.aws_region.current.name
          view   = "timeSeries"
          metrics = [
            [{ expression = "SEARCH('{AWS/Bedrock/Agents,Operation} MetricName=\"InvocationCount\"', 'Sum', 300)", label = "Invocations", id = "e1" }],
            [{ expression = "SEARCH('{AWS/Bedrock/Agents,Operation} MetricName=\"InvocationThrottles\"', 'Sum', 300)", label = "Throttles", id = "e2" }],
            [{ expression = "SEARCH('{AWS/Bedrock/Agents,Operation} MetricName=\"InvocationClientErrors\"', 'Sum', 300)", label = "Client Errors", id = "e3" }],
            [{ expression = "SEARCH('{AWS/Bedrock/Agents,Operation} MetricName=\"InvocationServerErrors\"', 'Sum', 300)", label = "Server Errors", id = "e4" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 4
        width  = 12
        height = 6
        properties = {
          title  = "Agent Latency (avg, ms)"
          region = data.aws_region.current.name
          view   = "timeSeries"
          metrics = [
            [{ expression = "SEARCH('{AWS/Bedrock/Agents,Operation} MetricName=\"TotalTime\"', 'Average', 300)", label = "Total Time", id = "e1" }],
            [{ expression = "SEARCH('{AWS/Bedrock/Agents,Operation} MetricName=\"ModelLatency\"', 'Average', 300)", label = "Model Latency", id = "e2" }],
            [{ expression = "SEARCH('{AWS/Bedrock/Agents,Operation} MetricName=\"TTFT\"', 'Average', 300)", label = "Time to First Token", id = "e3" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 10
        width  = 12
        height = 6
        properties = {
          title  = "Agent Token Usage"
          region = data.aws_region.current.name
          view   = "timeSeries"
          metrics = [
            [{ expression = "SEARCH('{AWS/Bedrock/Agents,Operation} MetricName=\"InputTokenCount\"', 'Sum', 300)", label = "Input Tokens", id = "e1" }],
            [{ expression = "SEARCH('{AWS/Bedrock/Agents,Operation} MetricName=\"OutputTokenCount\"', 'Sum', 300)", label = "Output Tokens", id = "e2" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 10
        width  = 12
        height = 6
        properties = {
          title  = "Agent → Model Call Health"
          region = data.aws_region.current.name
          view   = "timeSeries"
          metrics = [
            [{ expression = "SEARCH('{AWS/Bedrock/Agents,Operation} MetricName=\"ModelInvocationCount\"', 'Sum', 300)", label = "Model Invocations", id = "e1" }],
            [{ expression = "SEARCH('{AWS/Bedrock/Agents,Operation} MetricName=\"ModelInvocationThrottles\"', 'Sum', 300)", label = "Model Throttles", id = "e2" }],
            [{ expression = "SEARCH('{AWS/Bedrock/Agents,Operation} MetricName=\"ModelInvocationClientErrors\"', 'Sum', 300)", label = "Model Client Errors", id = "e3" }],
            [{ expression = "SEARCH('{AWS/Bedrock/Agents,Operation} MetricName=\"ModelInvocationServerErrors\"', 'Sum', 300)", label = "Model Server Errors", id = "e4" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 16
        width  = 12
        height = 6
        properties = {
          title  = "Guardrail Invocations vs Interventions"
          region = data.aws_region.current.name
          view   = "timeSeries"
          metrics = [
            [{ expression = "SEARCH('{AWS/Bedrock/Guardrails,Operation} MetricName=\"Invocations\"', 'Sum', 300)", label = "Invocations", id = "e1" }],
            [{ expression = "SEARCH('{AWS/Bedrock/Guardrails,Operation} MetricName=\"InvocationsIntervened\"', 'Sum', 300)", label = "Interventions", id = "e2" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 16
        width  = 12
        height = 6
        properties = {
          title  = "Guardrail Interventions by Policy Category"
          region = data.aws_region.current.name
          view   = "bar"
          metrics = [
            [{ expression = "SEARCH('{AWS/Bedrock/Guardrails,GuardrailPolicyType} MetricName=\"InvocationsIntervened\"', 'Sum', 300)", label = "Interventions", id = "e1" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 22
        width  = 12
        height = 6
        properties = {
          title  = "Guardrail Latency & Errors"
          region = data.aws_region.current.name
          view   = "timeSeries"
          metrics = [
            [{ expression = "SEARCH('{AWS/Bedrock/Guardrails,Operation} MetricName=\"InvocationLatency\"', 'Average', 300)", label = "Avg Latency", id = "e1" }],
            [{ expression = "SEARCH('{AWS/Bedrock/Guardrails,Operation} MetricName=\"InvocationClientErrors\"', 'Sum', 300)", label = "Client Errors", id = "e2" }],
            [{ expression = "SEARCH('{AWS/Bedrock/Guardrails,Operation} MetricName=\"InvocationServerErrors\"', 'Sum', 300)", label = "Server Errors", id = "e3" }],
            [{ expression = "SEARCH('{AWS/Bedrock/Guardrails,Operation} MetricName=\"InvocationThrottles\"', 'Sum', 300)", label = "Throttles", id = "e4" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 22
        width  = 12
        height = 6
        properties = {
          title  = "Guardrail Text Units Consumed"
          region = data.aws_region.current.name
          view   = "timeSeries"
          metrics = [
            [{ expression = "SEARCH('{AWS/Bedrock/Guardrails,Operation} MetricName=\"TextUnitCount\"', 'Sum', 300)", label = "Text Units", id = "e1" }],
          ]
        }
      },
    ]
  })
}
