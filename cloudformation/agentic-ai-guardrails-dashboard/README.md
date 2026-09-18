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

## Org-wide deployment

Bedrock Agents and Guardrails publish their metrics natively in every
account, so no per-account collector is needed: deploy an OAM Link in every
member account (see [`org-observability/README.md`](../../org-observability/README.md))
sharing `AWS::CloudWatch::Metric`, then deploy `org-dashboard.yaml` once in
the central monitoring account.

`org-dashboard.yaml` has two modes, chosen by the `MemberAccountIds` parameter:

- **All accounts (default, `MemberAccountIds` left empty)**: each widget is a
  CloudWatch Metrics Insights query over every account linked to the
  monitoring account, for example
  `SELECT SUM(InvocationCount) FROM SCHEMA("AWS/Bedrock/Agents", Operation)`,
  and the policy-category panel adds `GROUP BY AWS.AccountId,
  GuardrailPolicyType`. There is no account list to maintain and no
  per-widget account ceiling.
- **Explicit list (`MemberAccountIds=111111111111,222222222222`)**: one
  `SEARCH()` per account per series, limited to roughly 500/(series+1)
  accounts per widget.

All-accounts mode is new and has **not been verified against a live AWS
Organization**. Things to know before relying on it:

- Metrics Insights returns at most 500 time series per query; totals are
  unaffected, but the per-account, per-policy-category breakdown in the
  "Guardrail Interventions by Policy Category" panel is truncated beyond that.
- The queries also include any Bedrock Agents / Guardrails metrics the
  monitoring account itself publishes.
- Use the explicit list to restrict the dashboard to specific accounts.
- Count-style panels (invocations, errors, throttles, tokens, text units)
  use `SUM`; latency panels use `AVG`. In all-accounts mode an Insights `AVG`
  is taken over all matched observations, so busier accounts and operations
  weigh more; explicit mode instead averages the per-series averages equally,
  so latency numbers can differ slightly between the two modes.
- Each query uses `SCHEMA(..., Operation)`, the same dimension set the
  explicit-mode `SEARCH()` expressions target, and sums across every
  `Operation` value. The policy-category panel is a variable-series panel
  (`SCHEMA(..., GuardrailPolicyType)` with `GROUP BY AWS.AccountId,
  GuardrailPolicyType`); its series legend labels come from Insights rather
  than the account-ID label used in explicit mode.
- Intervention Rate is still `100 * intervened / invocations` via metric math
  over two hidden queries, and shows `#N/A` in periods with no invocations.

## Extending

The same pattern (native metrics + `SEARCH()`, no pipeline) applies to any
other Bedrock capability with its own CloudWatch namespace — check
`AWS/Bedrock/AgentCore` if you move to AgentCore-hosted agents, or
`AWS/Bedrock/KnowledgeBases` for RAG retrieval metrics — and add widgets the
same way.
