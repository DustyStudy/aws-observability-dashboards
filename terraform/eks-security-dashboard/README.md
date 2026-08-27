# eks-security-dashboard (Terraform)

Terraform module version of the EKS security dashboard. Functionally
identical to the CloudFormation template in
`cloudformation/eks-security-dashboard`.

CloudWatch dashboard covering the security posture of your EKS clusters and
the images running on them: control-plane/nodegroup version drift, node AMI
patch staleness, GuardDuty EKS Protection findings, and Inspector container
image vulnerability findings.

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
account/region it's deployed to. Update `latest_eks_version` as you roll
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
