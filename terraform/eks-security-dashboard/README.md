# eks-security-dashboard (Terraform)

Terraform module version of the EKS security dashboard. Functionally
identical to the CloudFormation template in
`cloudformation/eks-security-dashboard`.

CloudWatch dashboard covering the security posture of your EKS clusters and
the images running on them: control-plane/nodegroup version drift, node AMI
patch staleness, GuardDuty EKS Protection findings, and Inspector container
image vulnerability findings.

This README covers the single-account deployment (the module in this
folder). To roll the same dashboard out across an AWS Organization, see
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

The Lambda (`lambda/eks_patch_drift_checker.py`) runs on a schedule
(`rate(1 day)` by default) and walks every EKS cluster and nodegroup in the
account/region it's deployed to (in an org-wide rollout, each member
account runs its own copy). Update `latest_eks_version` as you roll
clusters onto new Kubernetes versions.

## Prerequisites

- GuardDuty enabled with **EKS Protection** (Runtime Monitoring + Audit Log
  Monitoring) turned on for the account.
- Amazon Inspector v2 enabled with **ECR container image scanning**.
- EKS clusters/nodegroups in the same account/region as the deployment.
- Terraform >= 1.5.0, AWS provider >= 5.0, `hashicorp/archive` provider >= 2.4
  (used to zip the patch-check Lambda source at plan/apply time)
- Permissions to create: KMS key + alias, SQS queue, Lambda function + IAM
  role, EventBridge rules, CloudWatch Logs groups, CloudWatch dashboard

## Usage

```hcl
module "eks_security_dashboard" {
  source = "./terraform/eks-security-dashboard"

  dashboard_name     = "eks-security-dashboard"
  latest_eks_version = "1.31"
  stale_ami_days     = 60
  log_retention_days = 365
}
```

```bash
terraform init
terraform plan
terraform apply
```

The Lambda source at `lambda/eks_patch_drift_checker.py` is zipped directly
via the `archive_file` data source, so this is the canonical copy — the
CloudFormation template inlines a hand-synced copy of the same logic.

## Inputs

| Name | Default | Description |
|---|---|---|
| `dashboard_name` | `eks-security-dashboard` | Name of the dashboard; also the prefix for other resource names |
| `latest_eks_version` | `1.31` | Kubernetes version treated as "current" for drift comparisons |
| `stale_ami_days` | `60` | Age in days before a nodegroup AMI release is flagged stale |
| `patch_check_schedule` | `rate(1 day)` | How often the drift/staleness check runs |
| `log_retention_days` | `365` | Retention for all three log groups (365+ required to satisfy Checkov CKV_AWS_338) |

## Outputs

- `dashboard_url` — direct console link to the deployed dashboard
- `patch_check_function_name` / `patch_check_log_group_name` — for checking
  the drift-checker Lambda's own logs/invocations directly
- `guardduty_eks_log_group_name` / `inspector_eks_log_group_name` — the raw
  finding logs backing the two Logs Insights widgets, if you want to write
  your own additional queries against them

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

The module above is the **single-account** deployment: one apply that scans
one account/region and draws its own dashboard. To monitor every account in
an AWS Organization from one place, split it into per-account collectors plus
one central dashboard, using CloudWatch cross-account observability (OAM).
See [`org-observability/README.md`](../../org-observability/README.md) for the
shared one-time setup (StackSets trusted access, the OAM sink).

| Piece | Source | Where it runs |
|---|---|---|
| OAM Link | `org-observability/oam-link` | Every member account |
| Collector | `collector/` (this folder) | Every member account - same resources as this module minus the dashboard |
| Org dashboard | `org-dashboard/` (this folder) | Central monitoring account, applied **once** |

1. **Deploy the OAM sink** in the monitoring account (once) and roll the OAM
   Link out to every member account, as described in the org-observability
   README.
2. **Deploy the collector to every member account.** The CloudFormation
   `collector.yaml` via StackSets is the usual route (see
   `cloudformation/eks-security-dashboard/README.md`); the `collector/`
   Terraform module is the equivalent if you drive member accounts with
   Terraform (for example one provider alias per account):
   ```hcl
   module "eks_security_collector" {
     source = "./terraform/eks-security-dashboard/collector"

     dashboard_name     = "eks-security-dashboard"
     latest_eks_version = "1.31"
   }
   ```
   Use the same `dashboard_name` in every account (default
   `eks-security-dashboard`): it names the GuardDuty and Inspector log groups
   the org dashboard queries. The collector's metric namespace is fixed at
   `EKS/Security` (it is a constant in the Lambda), and the Lambda runs daily,
   so give it a day before expecting data.
3. **Apply the org dashboard once**, in the monitoring account and the same
   region as the OAM sink and the collectors. With no `member_account_ids`
   the metric tiles cover every linked account:
   ```hcl
   module "eks_security_org_dashboard" {
     source = "./terraform/eks-security-dashboard/org-dashboard"

     # Optional: GuardDuty and Inspector log panels for these accounts only
     log_account_ids = ["111111111111", "222222222222"]
   }
   ```
   or restrict it to an explicit list of accounts:
   ```bash
   cd terraform/eks-security-dashboard/org-dashboard
   terraform init
   terraform apply -var 'member_account_ids=["111111111111","222222222222"]'
   ```

Every widget from the single-account dashboard is carried over. `org-dashboard/`
has two modes for the six metric tiles, chosen by `member_account_ids`:

- **All accounts (default, `member_account_ids = []`)**: each tile is a
  CloudWatch Metrics Insights query over every account linked to the
  monitoring account, for example
  `SELECT SUM(ClusterVersionDriftCount) FROM SCHEMA("EKS/Security")`. The
  collector publishes these counts without dimensions, so `SCHEMA` lists none.
  There is no account list to maintain and no account ceiling.
- **Explicit list (`member_account_ids = ["111111111111", ...]`)**: one hidden
  metric per account plus one visible `SUM()` per tile, limited to 499
  accounts per widget (500 metrics including the `SUM()`).

The GuardDuty and Inspector Logs Insights panels take a single `accountId`, so
they can never cover "all accounts": they are repeated once per account
(each titled with its account ID), for the accounts in `log_account_ids` if
set, otherwise for `member_account_ids`. In all-accounts mode without
`log_account_ids` no log panels are drawn, and the note above the log section
says how to enable them.

All-accounts mode is new and has **not been verified against a live AWS
Organization**. Things to know before relying on it:

- Metrics Insights returns at most 500 time series per query. Each tile here
  is one summed series, so the tiles are unaffected.
- Each `SUM` is taken over the period (86400 s), so it is only correct if the
  collector publishes at most once per period. The collector publishes once
  on every run of its EventBridge schedule (`patch_check_schedule`, default
  `rate(1 day)`); with a shorter schedule an account would be counted more
  than once per day, so keep the default or use a schedule of one day or more.
- The queries also include any metrics the monitoring account itself
  publishes in this namespace.
- Use the explicit list (`member_account_ids`) to restrict the dashboard to
  specific accounts.
- Log panels are always per account (see above).

### Org dashboard inputs

| Name | Default | Description |
|---|---|---|
| `dashboard_name` | `eks-security-org-dashboard` | Name of the org dashboard. Keep it different from the collector's `dashboard_name` |
| `member_account_ids` | `[]` | Empty = all-accounts mode (Metrics Insights queries over every linked account). Otherwise a list of 12-digit account IDs to show, one metric per account (max 499) |
| `log_account_ids` | `[]` | 12-digit IDs of the accounts that get GuardDuty and Inspector log panels (max 246). If empty, log panels are created for `member_account_ids`; in all-accounts mode none are created |
| `metric_namespace` | `EKS/Security` | Namespace the collector publishes to; only change if you forked the collector. Letters, digits, `_`, `.`, `/` and `-` only |
| `collector_dashboard_name` | `eks-security-dashboard` | The `dashboard_name` the collectors were deployed with (used to build the log group names) |

The only output is `dashboard_url`.

### Org-wide limitations

In all-accounts mode the metric tiles have no account limit. In explicit
mode CloudWatch allows at most 500 metrics per widget and this pattern uses
one metric per account per series (plus one combining expression), so the
single-series tiles here fit at most 499 accounts. The log panels are the
tighter limit: they add one widget per account per panel (two per account),
and a dashboard is capped at 500 widgets. With 8 fixed widgets that is at
most 246 log accounts per dashboard; validation on `log_account_ids` rejects
a longer list, and a precondition rejects a `member_account_ids` list longer
than 246 when `log_account_ids` is empty (set `log_account_ids` to a subset,
or split the accounts). Very large organizations that need log panels for
more accounts should apply this configuration multiple times with a
different `dashboard_name` and a different subset of `log_account_ids` each
time.
