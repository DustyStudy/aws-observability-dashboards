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

- **Single-account scan**, same as the ai-service-inventory-dashboard — for
  an AWS Organization, deploy via StackSets or add cross-account
  `sts:AssumeRole` to the Lambda.
- **The Lambda's `SENTITIVE_PORTS` port list and public-detection logic are
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
