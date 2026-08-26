# agentic-ai-guardrails-dashboard (CloudFormation)

CloudWatch dashboard covering Bedrock Agents activity and Bedrock Guardrails
behavior: agent invocations/latency/token usage, agent-to-model call health,
guardrail invocation volume and intervention rate, and — the part most public
dashboards skip — **guardrail interventions broken down by policy category**
(content policy, topic policy, word policy, sensitive-information policy,
contextual grounding policy), so you can see *what kind* of thing your agents
are triggering guardrails on, not just that they are.

Both Bedrock Agents and Bedrock Guardrails publish runtime metrics natively to
CloudWatch, so — like the bedrock-usage-cost-dashboard — this is just a
CloudWatch Dashboard built on `SEARCH()` expressions. No EventBridge pipeline,
no Lambda, no Logs groups.

## Prerequisites

- Bedrock Agents in use in this account/region (for the agent widgets)
- Bedrock Guardrails attached to at least one agent or model call (for the
  guardrail widgets)
- **Your agent's execution role must have explicit `cloudwatch:PutMetricData`
  permission scoped to the `AWS/Bedrock/Agents` namespace**, or agent metrics
  won't appear at all. If the agent widgets stay empty, check this first —
  it's the most common reason for missing data. Example policy:
  ```json
  {
    "Version": "2012-10-17",
    "Statement": {
      "Effect": "Allow",
      "Resource": "*",
      "Action": "cloudwatch:PutMetricData",
      "Condition": {
        "StringEquals": { "cloudwatch:namespace": "AWS/Bedrock/Agents" }
      }
    }
  }
  ```
- Permissions to create a CloudWatch dashboard (no other resources needed)

No QuickSight license required.

## Deploy

```bash
aws cloudformation deploy \
  --template-file template.yaml \
  --stack-name agentic-ai-guardrails-dashboard \
  --parameter-overrides NamePrefix=agentic-ai-observability
```

## Parameters

| Parameter | Default | Description |
|---|---|---|
| `NamePrefix` | `agentic-ai-observability` | Prefix for the dashboard name |

## Outputs

- `DashboardUrl` — direct console link to the deployed dashboard

## How the metric search expressions work

Every widget uses `SEARCH('{namespace,Dimension} MetricName="..."', stat,
period)` rather than naming specific agents or guardrails, so the dashboard
works unmodified regardless of how many agents/guardrails you have — it just
picks up whatever's publishing.

Two things worth knowing about that approach:

- **Scope is account/region-wide.** The searches match on the `Operation`
  dimension alone, which both services publish as an aggregate rollup
  alongside more granular dimension sets (e.g. `Operation, AgentAliasArn,
  ModelId` for agents). If you want a dashboard scoped to one specific agent
  or guardrail, add that resource's ARN to the search expression's dimension
  list (e.g. `{AWS/Bedrock/Agents,Operation,AgentAliasArn} MetricName="..."`)
  and filter to the ARN you care about.
- **Intervention Rate is a derived metric**, computed as
  `100 * InvocationsIntervened / Invocations` via CloudWatch metric math. It
  will show `#N/A` in any period with zero guardrail invocations (division by
  zero) — that's expected, not a bug.

## Extending

The same pattern (native metrics + `SEARCH()`, no pipeline) applies to any
other Bedrock capability with its own CloudWatch namespace — check
`AWS/Bedrock/AgentCore` if you move to AgentCore-hosted agents, or
`AWS/Bedrock/KnowledgeBases` for RAG retrieval metrics — and add widgets the
same way.
