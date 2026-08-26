# nhi-governance-dashboard (Terraform)

Terraform module version of the non-human identity (NHI) governance
dashboard. Functionally identical to the CloudFormation template in
`cloudformation/nhi-governance-dashboard`.

Covers the NHI risks security teams are being asked about right now:
stale/unrotated IAM access keys, console users without MFA, IAM users
nobody's used in 90+ days, IAM roles nobody's assumed in 90+ days, roles that
trust an external AWS account or a wildcard principal, the account's workload
identity federation footprint (OIDC/SAML providers), and Secrets Manager
secrets without rotation enabled.

A daily Lambda pulls the **IAM credential report** plus IAM role metadata and
identity provider lists, checks Secrets Manager rotation status per region,
and publishes counts as CloudWatch custom metrics.

IAM and STS are global services, so most of these metrics are account-wide
(not per-region). Secrets Manager is regional and gets its own per-region
breakdown.

## Prerequisites

- Terraform >= 1.5.0, AWS provider >= 5.0, `hashicorp/archive` provider >= 2.4
  (used to zip the NHI-collector Lambda source at plan/apply time)
- Permissions to create: KMS key + alias, SQS queue, Lambda function + IAM
  role, EventBridge schedule rule, CloudWatch Logs group, CloudWatch dashboard
- The Lambda's role needs IAM credential-report and read permissions
  (`iam:GenerateCredentialReport`, `iam:GetCredentialReport`,
  `iam:ListRoles`, `iam:ListOpenIDConnectProviders`,
  `iam:ListSAMLProviders`) — all read-only, none of them modify or delete
  anything

No QuickSight license required.

## Usage

```hcl
module "nhi_governance_dashboard" {
  source = "./terraform/nhi-governance-dashboard"

  name_prefix           = "nhi-governance"
  log_retention_in_days = 365
  stale_threshold_days  = 90
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
| `name_prefix` | `nhi-governance` | Prefix for all resource names |
| `log_retention_in_days` | `365` | Retention for the collector's log group (365+ required to satisfy Checkov CKV_AWS_338) |
| `metric_namespace` | `NHIGovernance` | Namespace the collector publishes into |
| `stale_threshold_days` | `90` | Age threshold for flagging access keys, IAM roles, and IAM users as stale/inactive |
| `governance_scan_schedule` | `rate(1 day)` | How often the scan runs |

## Outputs

- `dashboard_url` — direct console link to the deployed dashboard
- `nhi_collector_function_name` — for checking Lambda logs/invocations directly
- `nhi_collector_log_group_name` — **this is where the actual flagged
  identities live.** The dashboard shows *counts*; the collector's own
  CloudWatch Logs show the specific usernames, role names, and secret names
  behind those counts, since metrics can only carry numbers, not names.

## What each metric actually measures

- **Stale Access Keys** — active access keys not rotated in `stale_threshold_days`
  (via `access_key_N_last_rotated` in the credential report)
- **Users Without MFA** — IAM users with a console password enabled but no
  MFA device active. Pure service accounts (access keys only, no console
  password) are intentionally excluded — MFA doesn't apply to them
- **Inactive IAM Users** — users older than the threshold whose password and
  all active access keys have gone unused for that long (or never been used)
- **Stale IAM Roles** — roles (excluding AWS service-linked roles) with no
  `RoleLastUsed` activity in the threshold window, or never assumed at all
- **External-Trust Roles** — roles whose trust policy allows a different AWS
  account or a wildcard (`"AWS": "*"`) principal to assume them. This
  doesn't flag `Service` or `Federated` principals (Lambda execution roles,
  OIDC-federated roles) as "external" — those are normal and tracked
  separately via the identity-provider metrics
- **OIDC / SAML Providers** — count of workload identity federation
  providers configured in the account

## Known limitations

- **Single-account scan.** For an AWS Organization, deploy this module in
  every member account, or extend the Lambda with cross-account
  `sts:AssumeRole`.
- **The credential report only covers IAM users**, not IAM roles' own
  temporary credentials or federated/SSO identities — this dashboard's
  "non-human identity" coverage is IAM users, IAM roles, and workload
  federation, not a full inventory of every credential type in the account
  (no coverage of Cognito identity pools or third-party IdP-issued tokens,
  for example).
- **This is a triage/awareness tool**, not a policy engine — it doesn't
  auto-remediate anything (no key rotation, no role deletion). Pair it with
  the security-posture-dashboard in this repo, or with dedicated tools like
  IAM Access Analyzer, for enforcement.
- Report generation via `GenerateCredentialReport`/`GetCredentialReport` is
  asynchronous; the Lambda polls for completion with a short retry loop,
  which is normally fast but can occasionally add a few seconds to cold runs.

## Encryption

The NHI-collector's log group, environment variables, and DLQ are all
encrypted with a dedicated customer-managed KMS key (rotation enabled).

## Extending

To track additional non-human identity surfaces, the same pattern applies:
Cognito identity pool role mappings, EKS IRSA role bindings (via the OIDC
provider already surfaced here), or GitHub Actions OIDC trust relationships
specifically (a subset of the external-trust-roles check, if you want it
broken out on its own).
