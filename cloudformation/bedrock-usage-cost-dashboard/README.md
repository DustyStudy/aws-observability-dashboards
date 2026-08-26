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

## Extending

To add another AI service's usage (SageMaker, Rekognition, Comprehend), most
services publish their own CloudWatch metrics natively the same way Bedrock
does — check the service's CloudWatch metrics reference and add a widget with
a `SEARCH()` expression scoped to that namespace, no new pipeline required. If
a service's cost needs its own breakdown, copy the cost-collector Lambda
pattern and change the Cost Explorer service filter.
