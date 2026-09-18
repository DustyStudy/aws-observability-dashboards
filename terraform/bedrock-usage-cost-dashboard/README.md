# bedrock-usage-cost-dashboard (Terraform)

Terraform module version of the CloudWatch dashboard covering Bedrock usage
and estimated cost. Functionally identical to the CloudFormation template in
`cloudformation/bedrock-usage-cost-dashboard`.

## Prerequisites

- Bedrock in use in this account/region (for the usage widgets to show data)
- **Cost Explorer enabled** for the account/payer — usually enabled by
  default, but confirm in Billing console if the cost widgets stay empty
- Terraform >= 1.5.0, AWS provider >= 5.0, `hashicorp/archive` provider >= 2.4
  (used to zip the cost-collector Lambda source at plan/apply time)
- Permissions to create: KMS key + alias, SQS queue, Lambda function + IAM
  role, EventBridge schedule rule, CloudWatch Logs group, CloudWatch dashboard

No QuickSight license required.

## Usage

```hcl
module "bedrock_usage_cost_dashboard" {
  source = "./terraform/bedrock-usage-cost-dashboard"

  name_prefix               = "bedrock-observability"
  log_retention_in_days     = 365
  cost_collection_schedule  = "rate(1 day)"
}
```

```bash
terraform init
terraform plan
terraform apply
```

## Inputs

| Name | Default | Description |
|---|---|---|
| `name_prefix` | `bedrock-observability` | Prefix for all resource names |
| `log_retention_in_days` | `365` | Retention for the cost-collector's log group (365+ required to satisfy Checkov CKV_AWS_338) |
| `metric_namespace` | `BedrockCostObservability` | Namespace the cost-collector publishes into |
| `cost_collection_schedule` | `rate(1 day)` | How often the cost collector runs — daily is the practical ceiling since Cost Explorer data lags 24-48h |

## Outputs

- `dashboard_url` — direct console link to the deployed dashboard
- `cost_collector_function_name` — for checking Lambda logs/invocations directly
- `cost_collector_log_group_name` — for troubleshooting the cost collector

## Cost widget behavior

- The cost widgets will be **empty for the first ~24-48 hours** after deploy,
  since they depend on the first scheduled Lambda run and Cost Explorer's own
  data lag. If you want data immediately, manually invoke the Lambda once
  after apply:
  ```bash
  aws lambda invoke --function-name "$(terraform output -raw cost_collector_function_name)" /dev/stdout
  ```
- Costs shown are **unblended cost by usage type**, not amortized/blended —
  fine for spotting trends, not a substitute for your actual invoice.
- If the cost widgets fail to populate, check the Lambda's CloudWatch Logs
  first and the DLQ (`<name_prefix>-cost-collector-dlq`) second.

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
the full background (OAM Sink/Link setup).

1. **Collector in every member account.** Deploy the `collector` submodule
   (this folder) to each member account. It is the single-account module minus
   the dashboard, so each account publishes its own `EstimatedDailyCostUSD`
   metric locally. Terraform has no native StackSets primitive, so use your own
   multi-account deployment approach (or the CloudFormation StackSet of
   `cloudformation/bedrock-usage-cost-dashboard/collector.yaml`, which
   publishes the identical metrics):
   ```hcl
   module "bedrock_usage_cost_collector" {
     source = "./terraform/bedrock-usage-cost-dashboard/collector"

     name_prefix = "bedrock-observability"
   }
   ```
2. **OAM Link.** Every member account also needs the OAM Link
   (`../../org-observability/oam-link`) sharing `AWS::CloudWatch::Metric` with
   the monitoring account's OAM Sink. This is what lets the central dashboard
   read each account's local metrics, including the native `AWS/Bedrock`
   ones, which need no collector at all.
3. **Deploy the `org-dashboard` submodule once**, in the monitoring account:
   ```hcl
   module "bedrock_usage_cost_org_dashboard" {
     source = "./terraform/bedrock-usage-cost-dashboard/org-dashboard"

     member_account_ids = ["111111111111", "222222222222", "333333333333"]
     metric_namespace   = "BedrockCostObservability"
   }
   ```

### Org-dashboard variables

| Variable | Default | Description |
|---|---|---|
| `dashboard_name` | `bedrock-usage-cost-org-dashboard` | Name of the cross-account CloudWatch dashboard |
| `member_account_ids` | (required) | Member account IDs to include (the accounts you deployed the collector and OAM Link to); must contain at least one |
| `metric_namespace` | `BedrockCostObservability` | Must match the `metric_namespace` used for the collector module in every member account |

Output: `dashboard_url`, a direct console link to the org-dashboard.

### Widgets

| Widget | Combine across accounts |
|---|---|
| Bedrock Invocations (org-wide) | `SUM` |
| Bedrock Invocations by Model and Account | one `SEARCH` per account, stacked, labelled `<account> - <model>` |
| Bedrock Token Volume (Input vs Output, org-wide) | `SUM` |
| Bedrock Invocation Latency (org-wide, avg ms) | `AVG` (never `SUM`) |
| Bedrock Errors & Throttles (org-wide) | `SUM` |
| Estimated Total Daily Cost (org-wide, USD) | `SUM` of every account's `TOTAL` series |
| Estimated Daily Cost by Usage Type and Account | one `SEARCH` per account, labelled `<account> - <usage type>` |
| Estimated Daily Cost per Account (USD) | each account's own `TOTAL` series side by side (cost attribution) |

Native `AWS/Bedrock` metrics (invocations, tokens, latency, errors,
throttles) need **no collector** in the member accounts, only the OAM Link.
Only the three cost widgets depend on the collector.

### Limitation: metrics per widget

CloudWatch allows at most 500 metrics per widget, and this pattern uses one
metric per account per series (plus one combining expression per series). A
widget with `S` series therefore needs `S x (accounts + 1)` metrics, so it
supports roughly `500 / (S + 1)` accounts as a safe rule of thumb. The widest
widget here (Errors & Throttles, `S = 3`) tops out around 125-165 accounts.
Very large organizations should split their accounts across several
org-dashboards: deploy the org-dashboard multiple times, each with a different
`dashboard_name` and a different subset of `member_account_ids`.
