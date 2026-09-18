# eks-security-dashboard (CloudFormation)

CloudWatch dashboard covering the security posture of your EKS clusters and
the images running on them: control-plane/nodegroup version drift, node AMI
patch staleness, GuardDuty EKS Protection findings, and Inspector container
image vulnerability findings.

This README covers the single-account deployment (`template.yaml`). To roll
the same dashboard out across an AWS Organization, see
[Org-wide deployment](#org-wide-deployment) below.

## What it monitors

| Signal | Source | How it gets to the dashboard |
|---|---|---|
| EKS control-plane version drift vs. your target version | `eks:DescribeCluster` | Scheduled Lambda -> custom metric `ClusterVersionDriftCount` |
| Nodegroup Kubernetes version drift | `eks:DescribeNodegroup` | Scheduled Lambda -> custom metric `NodegroupsNeedingUpdate` |
| Stale nodegroup AMI (release older than N days) | `releaseVersion` on the nodegroup | Scheduled Lambda -> custom metric `StaleAmiNodegroups` |
| Nodegroup health issues (e.g. IAM/network problems reported by EKS) | `eks:DescribeNodegroup` health field | Scheduled Lambda -> custom metric `NodegroupHealthIssues` |
| Clusters with a public-only API endpoint | `resourcesVpcConfig` on the cluster | Scheduled Lambda -> custom metric `PublicOnlyEndpointClusters` |
| GuardDuty EKS Protection findings (runtime + audit log threats) | GuardDuty | EventBridge rule -> Logs -> Logs Insights widget |
| Critical/High image vulnerabilities (Inspector v2, ECR images) | Inspector v2 | EventBridge rule -> Logs -> Logs Insights widget |

The Lambda runs on a schedule (`rate(1 day)` by default) and walks every EKS
cluster and nodegroup in the account/region it's deployed to (in an
org-wide rollout, each member account runs its own copy). Update
`LatestEksVersion` as you roll clusters onto new Kubernetes versions.

## Prerequisites

- GuardDuty enabled with **EKS Protection** (Runtime Monitoring + Audit Log
  Monitoring) turned on for the account.
- Amazon Inspector v2 enabled with **ECR container image scanning**.
- EKS clusters/nodegroups in the same account/region as the deployment.
- Permissions to create: KMS key + alias, SQS queue, Lambda function + IAM
  role, EventBridge rules, CloudWatch Logs groups, CloudWatch dashboard

## Deploy

```bash
aws cloudformation deploy \
  --template-file template.yaml \
  --stack-name eks-security-dashboard \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides LatestEksVersion=1.31 StaleAmiDays=60 LogRetentionDays=365
```

`CAPABILITY_NAMED_IAM` is required because this stack creates a named IAM role
for the patch-check Lambda.

The Lambda source is inlined as a `ZipFile` so this is a single-file deploy
out of the box. It's kept in sync by hand with the canonical copy at
`terraform/eks-security-dashboard/lambda/eks_patch_drift_checker.py` — if you
edit the logic, update both.

## Parameters

| Parameter | Default | Description |
|---|---|---|
| `DashboardName` | `eks-security-dashboard` | Name of the dashboard; also the prefix for other resource names |
| `LatestEksVersion` | `1.31` | Kubernetes version treated as "current" for drift comparisons |
| `StaleAmiDays` | `60` | Age in days before a nodegroup AMI release is flagged stale |
| `PatchCheckSchedule` | `rate(1 day)` | How often the drift/staleness check runs |
| `LogRetentionDays` | `365` | Retention for all three log groups (365+ required to satisfy Checkov CKV_AWS_338) |

## Outputs

- `DashboardUrl` — direct console link to the deployed dashboard
- `PatchCheckFunctionName` / `PatchCheckLogGroupName` — for checking the
  drift-checker Lambda's own logs/invocations directly
- `GuardDutyEksLogGroupName` / `InspectorEksLogGroupName` — the raw finding
  logs backing the two Logs Insights widgets, if you want to write your own
  additional queries against them

## Notes

- Metrics are published under the `EKS/Security` custom namespace.
- `ClusterVersionDrift` is also emitted per-cluster (dimensioned by
  `ClusterName`) for future per-cluster alarms; the dashboard graphs the
  aggregate count.
- No CloudWatch Alarms are included by default, same as the other dashboards
  in this repo — wire up thresholds that fit your environment.
- IAM scoping: `eks:ListClusters`/`eks:ListNodegroups` use `Resource: "*"`
  because those actions don't support resource-level permissions, but
  `eks:DescribeCluster` and `eks:DescribeNodegroup` are scoped to
  `cluster/*` and `nodegroup/*` ARNs in this account/region rather than a
  bare `"*"`.

## Encryption

All three log groups, the patch-check Lambda's environment variables, and
its DLQ are encrypted with a dedicated customer-managed KMS key (rotation
enabled).

## Observability

The patch-check Lambda has active AWS X-Ray tracing enabled, so a slow or
failing run (e.g. a large number of clusters/nodegroups) shows up as a trace
in the X-Ray console, not just a CloudWatch Logs line.

## Extending

To track another EKS security signal — say, Pod Security Standards
violations or a specific admission-controller policy — add a new EventBridge
rule + Logs group pair for event-driven signals (matching the GuardDuty/
Inspector pattern), or a new metric in the patch-check Lambda for anything
you can pull from the EKS/EC2 APIs directly.

## Org-wide deployment

`template.yaml` above is the **single-account** deployment: one stack that
scans one account/region and draws its own dashboard. To monitor every
account in an AWS Organization from one place, split it into per-account
collectors plus one central dashboard, using CloudWatch cross-account
observability (OAM). See [`org-observability/README.md`](../../org-observability/README.md)
for the shared one-time setup (StackSets trusted access, the OAM sink).

| Piece | Template | Where it runs |
|---|---|---|
| OAM Link | `org-observability/oam-link/template.yaml` | Every member account (StackSet), sharing Metrics + Logs |
| Collector | `collector.yaml` (this folder) | Every member account (StackSet) - same resources as `template.yaml` minus the dashboard |
| Org dashboard | `org-dashboard.yaml` (this folder) | Central monitoring account, deployed **once** |

1. **Deploy the OAM sink** in the monitoring account (once) and roll the OAM
   Link out to every member account, as described in the org-observability
   README.
2. **Deploy the collector via a StackSet** to every member account, in the
   region(s) you want to monitor:
   ```bash
   aws cloudformation create-stack-set \
     --stack-set-name eks-security-collector \
     --template-body file://collector.yaml \
     --permission-model SERVICE_MANAGED \
     --auto-deployment Enabled=true,RetainStacksOnAccountRemoval=false \
     --capabilities CAPABILITY_NAMED_IAM \
     --region us-east-1

   aws cloudformation create-stack-instances \
     --stack-set-name eks-security-collector \
     --deployment-targets OrganizationalUnitIds=<your-root-or-OU-id> \
     --regions us-east-1 \
     --region us-east-1
   ```
   Leave the collector's `DashboardName` at the same value in every account
   (default `eks-security-dashboard`): it names the GuardDuty and Inspector
   log groups the org dashboard queries. The collector's metric namespace is
   fixed at `EKS/Security` (it is a constant in the Lambda), and the Lambda
   runs daily, so give it a day before expecting data.
3. **Deploy the org dashboard once**, in the monitoring account and the same
   region as the OAM sink and the collectors:
   ```bash
   aws cloudformation deploy \
     --template-file org-dashboard.yaml \
     --stack-name eks-security-org-dashboard \
     --parameter-overrides MemberAccountIds=111111111111,222222222222,333333333333 \
     --capabilities CAPABILITY_NAMED_IAM \
     --region us-east-1
   ```

`org-dashboard.yaml` has no scanning logic. Because CloudFormation cannot
loop-generate JSON inside a `DashboardBody`, a small Lambda-backed custom
resource renders the dashboard from the account list. Every widget from the
single-account dashboard is carried over: each count is summed across all
member accounts, and the GuardDuty and Inspector Logs Insights panels are
repeated once per member account (a log widget takes a single `accountId`
and cannot combine accounts), each titled with its account ID.

### Org dashboard parameters

| Parameter | Default | Description |
|---|---|---|
| `DashboardName` | `eks-security-org-dashboard` | Name of the org dashboard; also the prefix for the generator Lambda's resources. Keep it different from the collector's `DashboardName` |
| `MemberAccountIds` | (required) | Comma-separated 12-digit member account IDs to include |
| `MetricNamespace` | `EKS/Security` | Namespace the collector publishes to; only change if you forked the collector |
| `CollectorDashboardName` | `eks-security-dashboard` | The `DashboardName` the collectors were deployed with (used to build the log group names) |
| `LogRetentionDays` | `365` | Retention for the generator Lambda's own log group |

### Org-wide limitations

CloudWatch allows at most 500 metrics per widget, and this pattern uses one
metric per account per series (plus one combining expression), so a widget
with S series supports roughly 500/(S+1) accounts. The metric widgets here
each have a single series, so they are not the limiting factor. The log
panels are: they add one widget per account per panel (two per account), and
a dashboard is capped at 500 widgets. With 8 fixed widgets that is at most
246 accounts per dashboard; the generator Lambda rejects a larger list.
Very large organizations should split their accounts across several
org-dashboards, deploying this stack multiple times with a different
`DashboardName` (and stack name) and a different subset of `MemberAccountIds`
each time.
