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

## Extending

To add another AI service's usage (SageMaker, Rekognition, Comprehend), most
services publish their own CloudWatch metrics natively the same way Bedrock
does — check the service's CloudWatch metrics reference and add a widget with
a `SEARCH()` expression scoped to that namespace, no new pipeline required. If
a service's cost needs its own breakdown, copy the cost-collector Lambda
pattern and change the Cost Explorer service filter.
