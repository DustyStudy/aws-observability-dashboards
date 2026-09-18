# network-exposure-dashboard (CloudFormation)

Dashboard covering internet-facing exposure across an account: security
groups open to the internet on sensitive ports, EC2 instances with public
IPs, publicly accessible RDS instances, internet-facing load balancers,
publicly exposed S3 buckets — plus, if you already ship VPC Flow Logs to
CloudWatch, rejected-connection trends, top source IPs, and a simple
port-scan detector.

A daily Lambda scans every enabled region for the compute/network resources
and publishes counts as CloudWatch custom metrics; the S3 check is
account-wide (S3 is a global service) and buckets are counted under their
home region. Unlike the other Lambda-backed dashboards in this repo, this one
also has an **optional** second half: log widgets against an
**already-existing** VPC Flow Logs CloudWatch Logs group. This stack does not
create or enable flow logs itself — that's a bigger decision (cost,
per-ENI/VPC scope, retention) that belongs to you, not a dashboard template.

## Prerequisites

- Permissions to create: KMS key + alias, SQS queue, Lambda function + IAM
  role, EventBridge schedule rule, CloudWatch Logs group, CloudWatch dashboard
- **Optional:** an existing VPC Flow Logs delivery to a CloudWatch Logs group,
  using the **default log format** (the dashboard's Logs Insights queries
  rely on the auto-parsed `srcAddr`/`dstAddr`/`dstPort`/`action` field names
  CloudWatch recognizes for the default format — a custom flow log format
  will need the queries rewritten with an explicit `parse` statement)

No QuickSight license required.

## Deploy

```bash
aws cloudformation deploy \
  --template-file template.yaml \
  --stack-name network-exposure-dashboard \
  --parameter-overrides \
      NamePrefix=network-exposure \
      LogRetentionInDays=365 \
      FlowLogsLogGroupName=/vpc/flow-logs \
  --capabilities CAPABILITY_NAMED_IAM
```

Leave `FlowLogsLogGroupName` unset (or omit the override) if you don't have
flow logs going to CloudWatch — the three flow-log widgets will render with
no data rather than fail the deploy.

`CAPABILITY_NAMED_IAM` is required because this stack creates a named IAM role
for the exposure-collector Lambda.

## Parameters

| Parameter | Default | Description |
|---|---|---|
| `NamePrefix` | `network-exposure` | Prefix for all resource names |
| `LogRetentionInDays` | `365` | Retention for the collector's log group (365+ required to satisfy Checkov CKV_AWS_338) |
| `MetricNamespace` | `NetworkExposure` | Namespace the collector publishes into |
| `ExposureScanSchedule` | `rate(1 day)` | How often the scan runs |
| `FlowLogsLogGroupName` | *(blank)* | Name of your **existing** VPC Flow Logs CloudWatch Logs group |

## Outputs

- `DashboardUrl` — direct console link to the deployed dashboard
- `ExposureCollectorFunctionName` — for checking Lambda logs/invocations directly
- `ExposureCollectorLogGroupName` — **this is where the actual flagged
  resource identifiers live.** The dashboard shows *counts* by region;
  the collector's own CloudWatch Logs show the specific security group IDs,
  instance IDs, DB identifiers, load balancer names, and bucket names behind
  those counts, since metrics can only carry numbers, not names.

## What "sensitive ports" means here

The collector flags any security group rule open to `0.0.0.0/0` or `::/0`,
and separately calls out the subset on these ports: `22, 3389, 3306, 5432,
1433, 27017, 6379, 9200, 5900` (SSH, RDP, and common database/cache ports).
Edit the `SENSITIVE_PORTS` set in the Lambda source and redeploy to match
your own environment's risk list.

## S3 public-access detection method

A bucket is flagged public if either:
- `GetBucketPolicyStatus` reports `IsPublic: true` (policy-based public access), or
- its ACL grants to the `AllUsers` group (legacy ACL-based public access)

This does **not** separately account for S3 Block Public Access settings —
a bucket can have a technically-public policy or ACL while Block Public
Access still prevents actual public reads. Treat a flag here as "worth a
second look," not a confirmed open bucket; verify in the console or via
`s3:GetBucketPolicyStatus` directly before acting.

## Known limitations

- **`template.yaml` is a single-account dashboard and scan.** For an AWS
  Organization, use the org-wide option below (`collector.yaml` via StackSets
  plus one `org-dashboard.yaml` in a central monitoring account) rather than
  adding cross-account `sts:AssumeRole` to the Lambda.
- **The Lambda's `SENSITIVE_PORTS` port list and public-detection logic are
  intentionally simple** — this is a triage/awareness tool, not a
  replacement for AWS Config rules, Security Hub, or IAM Access Analyzer for
  authoritative compliance findings. Pair it with the
  security-posture-dashboard in this repo for that.
- The 300-second Lambda timeout allows for scanning security groups,
  instances, RDS, and load balancers across every enabled region — if you
  have very large security group counts, watch the collector's own duration
  in its CloudWatch Logs.

## Encryption

The exposure-collector's log group, environment variables, and DLQ are all
encrypted with a dedicated customer-managed KMS key (rotation enabled).

## Observability

The exposure-collector Lambda has active AWS X-Ray tracing enabled, so a
slow or failing multi-region scan shows up as a trace in the X-Ray console,
not just a CloudWatch Logs line.

## Extending

To flag additional resource types (CloudFront distributions, API Gateway
endpoints, EFS mount targets), add a check function to the Lambda following
the same pattern (describe the resource, test its public-facing condition,
append to `metric_data` and `findings`), and add a widget referencing the new
metric name.

## Org-wide deployment

`template.yaml` above scans and displays a single account. To cover an entire
AWS Organization, use the two halves this folder already ships:

- `collector.yaml` - the per-account scanner (same Lambda, metrics, and KMS/DLQ
  hardening as `template.yaml`, minus the dashboard), deployed to every member
  account with a StackSet.
- `org-dashboard.yaml` - ONE dashboard in a central monitoring account that
  reads every member account's local metrics and logs through CloudWatch
  cross-account observability (OAM). It contains no scanning logic.

Steps (the one-time sink setup and StackSet mechanics are described in
[`org-observability/README.md`](../../org-observability/README.md)):

1. **OAM Sink** in the monitoring account (`org-observability/oam-sink`), and an
   **OAM Link** StackSet to every member account
   (`org-observability/oam-link`, sharing Metrics and Logs).
2. **Collector StackSet**: deploy `collector.yaml` to every member account
   (`--permission-model SERVICE_MANAGED --capabilities CAPABILITY_NAMED_IAM`).
   Keep `MetricNamespace` identical in every account.
3. **Deploy the org-dashboard once**, in the monitoring account, after the
   collectors have run at least once (the default schedule is `rate(1 day)`):

   ```bash
   aws cloudformation deploy \
     --template-file org-dashboard.yaml \
     --stack-name network-exposure-org-dashboard \
     --parameter-overrides \
         MemberAccountIds=111111111111,222222222222,333333333333 \
         FlowLogsLogGroupName=/vpc/flow-logs \
     --capabilities CAPABILITY_NAMED_IAM \
     --region us-east-1
   ```

   `CAPABILITY_NAMED_IAM` is required because the stack creates a named role
   for its dashboard-generator Lambda (CloudFormation cannot loop-generate a
   `DashboardBody`, so a small Lambda-backed custom resource renders it from
   the account list).

### Org-dashboard parameters

| Parameter | Default | Description |
|---|---|---|
| `DashboardName` | `network-exposure-org-dashboard` | Name of the cross-account dashboard |
| `MemberAccountIds` | *(required)* | Comma-separated member account IDs (the accounts you deployed the collector and OAM Link to) |
| `MetricNamespace` | `NetworkExposure` | Must match the collector's `MetricNamespace` |
| `FlowLogsLogGroupName` | *(blank)* | **Existing** VPC Flow Logs log group, queried by the same name in every member account. Blank omits the three flow-log panels |
| `LogRetentionDays` | `365` | Retention for the generator Lambda's own log group |

### What the org dashboard shows

- **24h tiles** (sensitive-port SG rules, public EC2, public RDS, internet-facing
  load balancers): org-wide totals summed across all member accounts and regions.
- **By Region bar charts** (the four above plus public S3 buckets): one series
  per account per region, so you can see which account and region an exposure
  sits in.
- **VPC Flow Log panels** (rejected-connection trend, top rejected source IPs,
  possible port scans): Logs Insights widgets cannot combine accounts, because
  a log widget takes a single `accountId`. The dashboard therefore repeats each
  panel once per member account, with the account ID in the title, laid out
  two per row. Each account must already deliver default-format flow logs to
  the named log group; an account without it shows an empty widget.

### Limits: how many accounts one org-dashboard supports

CloudWatch allows at most 500 metrics per widget and 500 widgets per
dashboard. This pattern uses one metric per account per series (plus one
`SUM()` for the tiles), so a widget with S series supports roughly
500/(S+1) accounts. Every metric widget on this dashboard has a single
series, which puts the hard ceiling at 499 accounts. Log panels are the
tighter constraint: each of the three flow-log panels adds one widget per
account (9 metric widgets + 3 x N log widgets), so with flow logs enabled
the dashboard tops out at 163 accounts. Very large organizations should
split their accounts across several org-dashboards: deploy the stack multiple
times with different `DashboardName` and `MemberAccountIds` subsets (and leave
the flow-log group blank on all but the deployments that need those panels).
The generator Lambda fails the deploy with a clear message if a single stack would exceed either limit.
