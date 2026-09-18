# ai-service-inventory-dashboard (CloudFormation)

Dashboard answering: **"which regions in this account actually have Bedrock,
Bedrock Agents, Bedrock Guardrails, Rekognition, Comprehend, or Textract in
active use?"** — useful for spotting shadow AI adoption (a service quietly
in use in a region nobody signed off on), not just checking whether a
service is *available* in a region.

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

- Permissions to create: KMS key + alias, SQS queue, Lambda function + IAM
  role, EventBridge schedule rule, CloudWatch Logs group, CloudWatch dashboard
- The Lambda's role needs `ec2:DescribeRegions` and `cloudwatch:ListMetrics`
  account-wide (both are non-resource-scoped API actions) to do the scan

No QuickSight license required.

## Deploy

```bash
aws cloudformation deploy \
  --template-file template.yaml \
  --stack-name ai-service-inventory-dashboard \
  --parameter-overrides NamePrefix=ai-service-inventory LogRetentionInDays=365 \
  --capabilities CAPABILITY_NAMED_IAM
```

`CAPABILITY_NAMED_IAM` is required because this stack creates a named IAM role
for the inventory-collector Lambda.

## Parameters

| Parameter | Default | Description |
|---|---|---|
| `NamePrefix` | `ai-service-inventory` | Prefix for all resource names |
| `LogRetentionInDays` | `365` | Retention for the collector's log group (365+ required to satisfy Checkov CKV_AWS_338) |
| `MetricNamespace` | `AIServiceInventory` | Namespace the collector publishes into |
| `InventorySchedule` | `rate(1 day)` | How often the scan runs |

## Outputs

- `DashboardUrl` — direct console link to the deployed dashboard
- `InventoryCollectorFunctionName` — for checking Lambda logs/invocations directly
- `InventoryCollectorLogGroupName` — for troubleshooting the collector

## Known limitations

- **Coverage is limited to the 6 hardcoded services/namespaces** in the
  Lambda (`AWS/Bedrock`, `AWS/Bedrock/Agents`, `AWS/Bedrock/Guardrails`,
  `AWS/Rekognition`, `AWS/Comprehend`, `AWS/Textract`). To track another AI
  service, add a `label: namespace` entry to the `SERVICES` dict in the
  Lambda source and redeploy.
- **`template.yaml` is a single-account scan.** Each collector Lambda only
  ever sees its own account. For an AWS Organization, use the org-wide
  deployment below (`collector.yaml` via StackSets + one `org-dashboard.yaml`
  in a central monitoring account) rather than adding cross-account
  `sts:AssumeRole` logic to the Lambda.
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
service to the `SERVICES` list in `org-dashboard.yaml` so it gets its own
widget).

## Org-wide deployment

Answer "which regions in **which accounts** use which AI services?" across an
entire AWS Organization. Nothing about the collector changes — each account
still scans only itself and publishes `ServiceActive` locally. A central
monitoring account then reads all of them through CloudWatch cross-account
observability (OAM). See [`org-observability/README.md`](../../org-observability/README.md)
for the one-time setup and the full architecture.

1. **Collector via StackSets.** Create a `SERVICE_MANAGED` StackSet from
   `collector.yaml` and deploy it to every member account (or the OUs you
   care about):
   ```bash
   aws cloudformation create-stack-set \
     --stack-set-name ai-service-inventory-collector \
     --template-body file://collector.yaml \
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
   sink once in the monitoring account and the link via its own StackSet, as
   described in `org-observability/README.md`.
3. **Deploy `org-dashboard.yaml` once**, in the monitoring account, after the
   collectors have run at least once (the default schedule is `rate(1 day)`):
   ```bash
   aws cloudformation deploy \
     --template-file org-dashboard.yaml \
     --stack-name ai-service-inventory-org-dashboard \
     --parameter-overrides MemberAccountIds=111111111111,222222222222,333333333333 \
     --capabilities CAPABILITY_NAMED_IAM \
     --region us-east-1
   ```
   CloudFormation cannot loop-generate a `DashboardBody`, so the template
   uses a Lambda-backed custom resource that renders the dashboard from
   `MemberAccountIds` (KMS-encrypted log group and DLQ, X-Ray tracing, a role
   that can only manage this one dashboard).

| Parameter | Default | Description |
|---|---|---|
| `DashboardName` | `ai-service-inventory-org-dashboard` | Name of the cross-account dashboard |
| `MemberAccountIds` | (required) | Comma-separated member account IDs to include (the accounts running the collector and linked via OAM) |
| `MetricNamespace` | `AIServiceInventory` | Must match `MetricNamespace` used for `collector.yaml` in every member account |
| `LogRetentionDays` | `365` | Retention for the dashboard-generator Lambda's log group |

Output: `DashboardUrl`.

The org dashboard shows: the org-wide count of active service/region pairs,
the number of active account/region pairs per service, active pairs per
account, and one panel per service with one series per account **and**
region (labelled `<account> - <region>`), so a service quietly in use in an
unapproved region of a specific account stands out.

**Scale limitation.** CloudWatch allows at most 500 metrics per dashboard
widget, and this pattern uses one metric per account per series, so a widget
with S series supports roughly 500/(S+1) accounts. The by-service summary
widget here has 6 series (roughly 70 accounts). Also note that each
per-service `SEARCH` returns one series per enabled region per account (the
collector publishes a `0` for inactive regions too), so those panels reach
the widget cap sooner; very large organizations should split accounts across
several org-dashboards by deploying this stack multiple times with different
`DashboardName` and `MemberAccountIds` subsets.
