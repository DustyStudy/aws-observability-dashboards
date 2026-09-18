# bedrock-usage-cost-dashboard (CloudFormation)

CloudWatch dashboard covering Bedrock usage and estimated cost: invocations by
model, input/output token volume, invocation latency, client/server errors and
throttles — all read directly from native `AWS/Bedrock` CloudWatch metrics
using search expressions (no EventBridge pipeline needed, unlike the
security-posture-dashboard). A daily Lambda pulls Bedrock's cost-by-usage-type
from Cost Explorer and republishes it as a CloudWatch custom metric so cost
sits on the same dashboard as usage.

## Prerequisites

- Bedrock in use in this account/region (for the usage widgets to show data)
- **Cost Explorer enabled** for the account/payer — usually enabled by
  default, but confirm in Billing console if the cost widgets stay empty
- Permissions to create: KMS key + alias, SQS queue, Lambda function + IAM
  role, EventBridge schedule rule, CloudWatch Logs group, CloudWatch dashboard

No QuickSight license required.

## Deploy

```bash
aws cloudformation deploy \
  --template-file template.yaml \
  --stack-name bedrock-usage-cost-dashboard \
  --parameter-overrides NamePrefix=bedrock-observability LogRetentionInDays=365 \
  --capabilities CAPABILITY_NAMED_IAM
```

`CAPABILITY_NAMED_IAM` is required because this stack creates a named IAM role
for the cost-collector Lambda.

## Parameters

| Parameter | Default | Description |
|---|---|---|
| `NamePrefix` | `bedrock-observability` | Prefix for all resource names |
| `LogRetentionInDays` | `365` | Retention for the cost-collector's log group (365+ required to satisfy Checkov CKV_AWS_338) |
| `MetricNamespace` | `BedrockCostObservability` | Namespace the cost-collector publishes into |
| `CostCollectionSchedule` | `rate(1 day)` | How often the cost collector runs — daily is the practical ceiling since Cost Explorer data lags 24-48h |

## Outputs

- `DashboardUrl` — direct console link to the deployed dashboard
- `CostCollectorFunctionName` — for checking Lambda logs/invocations directly
- `CostCollectorLogGroupName` — for troubleshooting the cost collector

## Cost widget behavior

- The cost widgets will be **empty for the first ~24-48 hours** after deploy,
  since they depend on the first scheduled Lambda run and Cost Explorer's own
  data lag. If you want data immediately, manually invoke the Lambda once
  after deploy:
  ```bash
  aws lambda invoke --function-name <CostCollectorFunctionName> /dev/stdout
  ```
- Costs shown are **unblended cost by usage type**, not amortized/blended —
  fine for spotting trends, not a substitute for your actual invoice.
- If the cost widgets fail to invoke, check the Lambda's CloudWatch Logs
  first and the DLQ (`<NamePrefix>-cost-collector-dlq`) second.

## Encryption

The cost-collector's log group, environment variables, and DLQ are all
encrypted with a dedicated customer-managed KMS key (rotation enabled).

## Observability

The cost-collector Lambda has active AWS X-Ray tracing enabled, so a slow or
failing invocation (e.g. Cost Explorer taking longer than usual) shows up as
a trace in the X-Ray console, not just a CloudWatch Logs line.

## Extending

To add another AI service's usage (SageMaker, Rekognition, Comprehend), most
services publish their own CloudWatch metrics natively the same way Bedrock
does — check the service's CloudWatch metrics reference and add a widget with
a `SEARCH()` expression scoped to that namespace, no new pipeline required. If
a service's cost needs its own breakdown, copy the cost-collector Lambda
pattern and change the Cost Explorer service filter.

## Org-wide deployment

To see Bedrock usage and cost across every account in an AWS Organization on
one dashboard, deploy the per-account collector everywhere and a single
org-dashboard in a central monitoring account. See
[`../../org-observability/README.md`](../../org-observability/README.md) for
the full background (OAM Sink/Link setup, StackSets prerequisites).

`org-dashboard.yaml` has two modes, chosen by the `MemberAccountIds` parameter:

- **All accounts (default, `MemberAccountIds` left empty)**: each widget is a
  CloudWatch Metrics Insights query over every account linked to the
  monitoring account,
  for example `SELECT SUM(Invocations) FROM SCHEMA("AWS/Bedrock", ModelId)`.
  The by-account and by-model panels add `GROUP BY AWS.AccountId, ...`. There
  is no account list to maintain and no per-widget account ceiling.
- **Explicit list (`MemberAccountIds=111111111111,222222222222`)**: one metric per account
  per series, limited to roughly 500/(series+1) accounts per widget. This is
  the behavior the dashboard had before all-accounts mode existed, unchanged.

All-accounts mode is new and has **not been verified against a live AWS
Organization**. Things to know before relying on it:

- Metrics Insights returns at most 500 time series per query. Totals (the
  queries without `GROUP BY`) are unaffected, but the per-account and
  per-model breakdowns are truncated beyond that. Those three queries use
  `ORDER BY SUM() DESC LIMIT 500`, so what is kept is the top 500 series by
  value rather than an arbitrary subset; lower the `LIMIT` if a panel with
  hundreds of series is unreadable.
- Each cost total is a `SUM` over the period (86400 s). The cost collector
  publishes once per run (`rate(1 day)` by default) and each value is a
  gauge: the previous day's Bedrock cost for that account, timestamped at
  publish time. Summing is therefore correct only while every account
  publishes at most once per day; if the collector runs more often (or is
  redeployed, triggering an extra run in the same UTC day), that account is
  counted more than once for the period. Explicit-list mode is not affected,
  because it takes the per-account `Maximum` before adding accounts up. Cost
  Explorer data lags 24-48 hours, so a shorter schedule buys nothing.
- `AVG` latency in Metrics Insights is taken over all matched observations
  (every account and model together). Explicit-list mode instead averages the
  per-account, per-model averages with equal weight, so the two modes can
  differ when traffic is uneven.
- The queries also include any metrics the monitoring account itself
  publishes (its own Bedrock usage and, if it runs a collector, its cost).
- Use the explicit list to restrict the dashboard to specific accounts.

1. **Collector via StackSets.** Deploy `collector.yaml` (this folder) to every
   member account. It is the single-account stack minus the dashboard, so each
   account publishes its own `EstimatedDailyCostUSD` metric locally:
   ```bash
   aws cloudformation create-stack-set      --stack-set-name bedrock-usage-cost-collector      --template-body file://collector.yaml      --permission-model SERVICE_MANAGED      --auto-deployment Enabled=true,RetainStacksOnAccountRemoval=false      --capabilities CAPABILITY_NAMED_IAM      --region us-east-1

   aws cloudformation create-stack-instances      --stack-set-name bedrock-usage-cost-collector      --deployment-targets OrganizationalUnitIds=<your-root-or-OU-id>      --regions us-east-1      --region us-east-1
   ```
2. **OAM Link.** Every member account also needs the OAM Link StackSet
   (`../../org-observability/oam-link`) sharing `AWS::CloudWatch::Metric` with
   the monitoring account's OAM Sink. This is what lets the central dashboard
   read each account's local metrics, including the native `AWS/Bedrock`
   ones, which need no collector at all.
3. **Deploy the org-dashboard once**, in the monitoring account, after the
   collectors have run at least once:
   ```bash
   aws cloudformation deploy      --template-file org-dashboard.yaml      --stack-name bedrock-usage-cost-org-dashboard      --capabilities CAPABILITY_NAMED_IAM      --region us-east-1
   ```
   This covers every linked account. To restrict it to specific accounts, add
   `--parameter-overrides MemberAccountIds=111111111111,222222222222,333333333333`.

### Org-dashboard parameters

| Parameter | Default | Description |
|---|---|---|
| `DashboardName` | `bedrock-usage-cost-org-dashboard` | Name of the cross-account CloudWatch dashboard |
| `MemberAccountIds` | empty | Empty = every account linked to the monitoring account (Metrics Insights queries); otherwise comma-delimited 12-digit account IDs to include, one metric per account |
| `MetricNamespace` | `BedrockCostObservability` | Must match the `MetricNamespace` used for `collector.yaml` in every member account (letters, numbers, `_`, `.`, `/`, `-` only) |
| `LogRetentionDays` | `365` | Retention for the dashboard-generator Lambda's own log group |

The stack uses a Lambda-backed custom resource to render the `DashboardBody`
(CloudFormation cannot loop-generate JSON), with the same hardening as the
other org-dashboards: KMS-encrypted log group, DLQ, a role scoped to this one
dashboard, reserved concurrency of 1 and X-Ray tracing.

### Widgets

| Widget | All accounts (default) | Explicit list |
|---|---|---|
| Bedrock Invocations (org-wide) | `SELECT SUM(Invocations) FROM SCHEMA("AWS/Bedrock", ModelId)` | `SUM` of one `SEARCH` per account |
| Bedrock Invocations by Model and Account | `... GROUP BY AWS.AccountId, ModelId ORDER BY SUM() DESC LIMIT 500`, stacked | one `SEARCH` per account, stacked, labelled `<account> - <model>` |
| Bedrock Token Volume (Input vs Output, org-wide) | `SUM(InputTokenCount)` and `SUM(OutputTokenCount)` queries | `SUM` |
| Bedrock Invocation Latency (org-wide, avg ms) | `SELECT AVG(InvocationLatency) FROM SCHEMA("AWS/Bedrock", ModelId)` | `AVG` (never `SUM`) |
| Bedrock Errors & Throttles (org-wide) | `SUM(InvocationClientErrors)`, `SUM(InvocationServerErrors)`, `SUM(InvocationThrottles)` queries | `SUM` |
| Estimated Total Daily Cost (org-wide, USD) | `SELECT SUM(EstimatedDailyCostUSD) FROM SCHEMA("<namespace>", UsageType) WHERE UsageType = 'TOTAL'` | `SUM` of every account's `TOTAL` series |
| Estimated Daily Cost by Usage Type and Account | `... GROUP BY AWS.AccountId, UsageType ORDER BY SUM() DESC LIMIT 500` | one `SEARCH` per account, labelled `<account> - <usage type>` |
| Estimated Daily Cost per Account (USD) | `... WHERE UsageType = 'TOTAL' GROUP BY AWS.AccountId ORDER BY SUM() DESC LIMIT 500` | each account's own `TOTAL` series side by side (cost attribution) |

Native `AWS/Bedrock` metrics (invocations, tokens, latency, errors,
throttles) need **no collector** in the member accounts, only the OAM Link.
Only the three cost widgets depend on the collector.

### Limitation: metrics per widget (explicit-list mode)

This applies only when `MemberAccountIds` is non-empty; all-accounts mode is
not bound by it (see the 500-series-per-query note above). CloudWatch allows
at most 500 metrics per widget, and this pattern uses one
metric per account per series (plus one combining expression per series). A
widget with `S` series therefore needs `S x (accounts + 1)` metrics, so it
supports roughly `500 / (S + 1)` accounts as a safe rule of thumb. The widest
widget here (Errors & Throttles, `S = 3`) tops out around 125-165 accounts.
Very large organizations should split their accounts across several
org-dashboards: deploy the org-dashboard multiple times, each with a different
`DashboardName` and a different subset of `MemberAccountIds`.
