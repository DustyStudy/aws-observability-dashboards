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
- **The root module is a single-account scan.** Each collector Lambda only
  ever sees its own account. For an AWS Organization, use the org-wide
  deployment below (the `collector/` module in every member account plus one
  `org-dashboard/` in a central monitoring account) rather than adding
  cross-account `sts:AssumeRole` logic to the Lambda.
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

## Observability

The inventory-collector Lambda has active AWS X-Ray tracing enabled, so a
slow or failing multi-region scan shows up as a trace in the X-Ray console,
not just a CloudWatch Logs line.

## Extending

To cover additional AWS accounts, use the org-wide deployment below. To watch
a different service, just add its CloudWatch namespace to the `SERVICES` dict
— the collector needs no other code changes (for org-wide use, also add the
service to the `services` list in `org-dashboard/main.tf` so it gets its own
widget).

## Org-wide deployment

Answer "which regions in **which accounts** use which AI services?" across an
entire AWS Organization. Nothing about the collector changes — each account
still scans only itself and publishes `ServiceActive` locally. A central
monitoring account then reads all of them through CloudWatch cross-account
observability (OAM). See [`org-observability/README.md`](../../org-observability/README.md)
for the one-time setup and the full architecture.

1. **Collector in every member account.** Deploy the `collector/` module
   (the collector without the dashboard) to each member account, or roll
   out the equivalent CloudFormation `collector.yaml` from
   `cloudformation/ai-service-inventory-dashboard` with a `SERVICE_MANAGED`
   StackSet:
   ```bash
   aws cloudformation create-stack-set \
     --stack-set-name ai-service-inventory-collector \
     --template-body file://../../cloudformation/ai-service-inventory-dashboard/collector.yaml \
     --permission-model SERVICE_MANAGED \
     --auto-deployment Enabled=true,RetainStacksOnAccountRemoval=false \
     --capabilities CAPABILITY_NAMED_IAM \
     --region us-east-1

   aws cloudformation create-stack-instances \
     --stack-set-name ai-service-inventory-collector \
     --deployment-targets OrganizationalUnitIds=<your-root-or-OU-id> \
     --regions us-east-1 \
     --region us-east-1
   ```
2. **OAM Link.** Every member account also needs the OAM Link
   (`org-observability/oam-link`, sharing CloudWatch metrics) pointing at the
   monitoring account's OAM Sink (`org-observability/oam-sink`). Deploy the
   sink once in the monitoring account and the link via a StackSet (or the
   Terraform equivalent), as described in `org-observability/README.md`.
3. **Apply `org-dashboard/` once**, in the monitoring account, after the
   collectors have run at least once (the default schedule is `rate(1 day)`).
   To show every linked account, leave `member_account_ids` empty (the
   default):
   ```hcl
   module "ai_service_inventory_org_dashboard" {
     source = "./terraform/ai-service-inventory-dashboard/org-dashboard"
   }
   ```
   To restrict it to specific accounts, list them:
   ```hcl
   module "ai_service_inventory_org_dashboard" {
     source = "./terraform/ai-service-inventory-dashboard/org-dashboard"

     member_account_ids = ["111111111111", "222222222222", "333333333333"]
   }
   ```
   No StackSet is needed for this piece. It builds the widgets natively with
   `for` expressions and `jsonencode()`. Variable validation rejects account
   IDs that are not 12 digits and metric namespaces containing characters
   other than letters, numbers, `_`, `.`, `/` and `-`.

| Name | Default | Description |
|---|---|---|
| `dashboard_name` | `ai-service-inventory-org-dashboard` | Name of the cross-account dashboard |
| `member_account_ids` | `[]` (all linked accounts) | Optional list of 12-digit member account IDs to include (the accounts running the collector and linked via OAM) |
| `metric_namespace` | `AIServiceInventory` | Must match `metric_namespace` used for the collector in every member account |

Output: `dashboard_url`.

`org-dashboard/` has two modes, chosen by `member_account_ids`:

- **All accounts (default, `member_account_ids = []`)**: each widget is a
  CloudWatch Metrics Insights query over every account linked to the
  monitoring account, for example
  `SELECT SUM(ServiceActive) FROM SCHEMA("AIServiceInventory", Service, Region) GROUP BY Service`.
  There is no account list to maintain and no per-widget account ceiling.
- **Explicit list (`member_account_ids = ["111111111111", ...]`)**: one
  metric per account per series, limited to roughly 500/(series+1) accounts
  per widget. The dashboard is exactly what it was before all-accounts mode
  existed.

All-accounts mode is new and has **not been verified against a live AWS
Organization**. Things to know before relying on it:

- Metrics Insights returns at most 500 time series per query, so the
  per-account breakdown is truncated beyond that. To keep the chart
  readable the "by Account" widget asks for the 100 accounts with the most
  active service/region pairs (`ORDER BY SUM() DESC LIMIT 100`); the
  org-wide totals and the per-service widgets are unaffected.
- Each `SUM` is over the period (86400 s). The collector publishes
  `ServiceActive` once per schedule (`rate(1 day)` by default), so this is
  correct as long as the schedule is not shorter than one day; a shorter
  schedule would count an account more than once per period.
- The queries also include any `ServiceActive` metrics the monitoring
  account itself publishes in this namespace.
- Use the explicit list to restrict the dashboard to specific accounts.

What the widgets show in each mode:

| Widget | All-accounts mode (Metrics Insights) | Explicit list |
|---|---|---|
| Active AI Service/Region Pairs (org-wide) | `SELECT SUM(ServiceActive) FROM SCHEMA("<ns>", Service, Region)` | hidden per-account counts plus one `SUM()` |
| Active Regions per AI Service | `... GROUP BY Service` (one series per service) | per-account counts summed per service |
| Active AI Services by Account | `... GROUP BY AWS.AccountId ORDER BY SUM() DESC LIMIT 100` (top 100 accounts) | one series per account |
| One panel per service | `... WHERE Service = '<service>' GROUP BY Region`: the **number of accounts** using the service in each region, titled "<service> — Accounts Using It, by Region" | one series per account **and** region (labelled `<account> - <region>`), titled "<service> — Active by Account/Region" |

The per-service panels change meaning in all-accounts mode on purpose:
grouping by account and region would need accounts x regions series and
truncate at 500, so they group by region only and show how many accounts use
each service there (the org-wide shadow-AI adoption view). For per-account,
per-region detail, use the explicit list.

**Scale limitation (explicit list only).** CloudWatch allows at most 500
metrics per dashboard widget, and the explicit pattern uses one metric per
account per series, so a widget with S series supports roughly 500/(S+1)
accounts. The by-service summary widget here has 6 series (roughly 70
accounts). Also note that each per-service `SEARCH` returns one series per
enabled region per account (the collector publishes a `0` for inactive
regions too), so those panels reach the widget cap sooner; very large
organizations should use all-accounts mode, or split accounts across several
org-dashboards by applying this module multiple times with different
`dashboard_name` and `member_account_ids` subsets.
