# ai-service-inventory-dashboard (Terraform)

Terraform module version of the dashboard answering: **"which regions in this
account actually have Bedrock, Bedrock Agents, Bedrock Guardrails,
Rekognition, Comprehend, or Textract in active use?"** Functionally identical
to the CloudFormation template in `cloudformation/ai-service-inventory-dashboard`.

A daily Lambda enumerates every enabled region, checks each region for
published CloudWatch metrics under each watched service's namespace, and
publishes a `ServiceActive` (1/0) custom metric per service/region pair. The
dashboard renders that as bar charts — one overview showing active-service
count per region, and one per-service breakdown showing which regions that
service is active in.

## Why "publishes CloudWatch metrics" as the signal

Resource-based inventory (does a Rekognition collection exist, is there a
Comprehend endpoint) misses stateless usage — Textract in particular has no
persistent resource for most use, it's just API calls. Checking whether the
service has emitted **any** CloudWatch metric in a region is a service-agnostic
proxy for "this has actually been invoked here recently," and it works the
same way across all six services without needing six different SDKs' worth
of list/describe calls.

## Prerequisites

- Terraform >= 1.5.0, AWS provider >= 5.0, `hashicorp/archive` provider >= 2.4
  (used to zip the inventory-collector Lambda source at plan/apply time)
- Permissions to create: KMS key + alias, SQS queue, Lambda function + IAM
  role, EventBridge schedule rule, CloudWatch Logs group, CloudWatch dashboard
- The Lambda's role needs `ec2:DescribeRegions` and `cloudwatch:ListMetrics`
  account-wide (both are non-resource-scoped API actions) to do the scan

No QuickSight license required.

## Usage

```hcl
module "ai_service_inventory_dashboard" {
  source = "./terraform/ai-service-inventory-dashboard"

  name_prefix        = "ai-service-inventory"
  log_retention_in_days = 365
  inventory_schedule = "rate(1 day)"
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
| `name_prefix` | `ai-service-inventory` | Prefix for all resource names |
| `log_retention_in_days` | `365` | Retention for the collector's log group (365+ required to satisfy Checkov CKV_AWS_338) |
| `metric_namespace` | `AIServiceInventory` | Namespace the collector publishes into |
| `inventory_schedule` | `rate(1 day)` | How often the scan runs |

## Outputs

- `dashboard_url` — direct console link to the deployed dashboard
- `inventory_collector_function_name` — for checking Lambda logs/invocations directly
- `inventory_collector_log_group_name` — for troubleshooting the collector

## Known limitations

- **Coverage is limited to the 6 hardcoded services/namespaces** in the
  Lambda (`AWS/Bedrock`, `AWS/Bedrock/Agents`, `AWS/Bedrock/Guardrails`,
  `AWS/Rekognition`, `AWS/Comprehend`, `AWS/Textract`). To track another AI
  service, add a `label: namespace` entry to the `SERVICES` dict in
  `lambda/ai_service_inventory_collector.py` and re-apply.
- **A single-account scan.** For an AWS Organization, deploy this module in
  every member account, or extend the Lambda to assume a role into each
  account before scanning (same pattern, more IAM plumbing).
- **`list_metrics` only sees metrics published within roughly the last 14
  days to 2 weeks** by default, and a region with zero recent activity will
  correctly show `0` even if the service was used further in the past — this
  is an activity dashboard, not a historical audit trail.
- The Lambda runs with a 300-second timeout to allow time for
  `ListMetrics` calls across every enabled region (commercial accounts
  commonly have 20+ regions enabled by default); if you have opted into
  unusually many regions, keep an eye on the collector's own duration in its
  CloudWatch Logs.

## Encryption

The inventory-collector's log group, environment variables, and DLQ are all
encrypted with a dedicated customer-managed KMS key (rotation enabled).

## Extending

To scan additional AWS accounts, add cross-account `sts:AssumeRole` logic to
the Lambda and loop over a list of account/role-ARN pairs the same way it
currently loops over regions. To watch a different service, just add its
CloudWatch namespace to the `SERVICES` dict — no other code changes needed.
